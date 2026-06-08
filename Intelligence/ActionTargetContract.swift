import Foundation
import AppKit

// MARK: - Source Evidence Type

enum ActionTargetEvidenceType: String, Sendable, Codable, Equatable {
    case work_pair
    case workspace_pattern
    case active_window_pair
    case user_selected
    case generic_runtime
    case browser_tab
    case media_state
}

// MARK: - Target Descriptor

struct ActionTargetDescriptor: Sendable, Codable, Equatable {
    let role: String
    let appBundleID: String?
    let windowID: UInt32?
    let titleFingerprint: String?
    let appName: String?
    let presentAtGeneration: Bool

    init(
        role: String,
        appBundleID: String? = nil,
        windowID: UInt32? = nil,
        titleFingerprint: String? = nil,
        appName: String? = nil,
        presentAtGeneration: Bool = true
    ) {
        self.role = role
        self.appBundleID = appBundleID
        self.windowID = windowID
        self.titleFingerprint = titleFingerprint
        self.appName = appName
        self.presentAtGeneration = presentAtGeneration
    }

    static func titleHash(_ title: String) -> String {
        let tokens = title.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 3 }
            .sorted()
            .prefix(5)
            .joined(separator: "_")
        return String(abs(tokens.hashValue), radix: 36)
    }
}

// MARK: - Action Target Contract

struct ActionTargetContract: Sendable, Codable, Equatable {
    let contractID: String       // stable ID for log correlation between proposal and click
    let capabilityID: String
    let requiredTargetCount: Int
    let targets: [ActionTargetDescriptor]
    let evidenceType: ActionTargetEvidenceType
    let sourceConfidence: Double
    let fallbackAllowed: Bool
    let generatedAt: Date
    let expirySeconds: TimeInterval

    var isExpired: Bool { Date().timeIntervalSince(generatedAt) > expirySeconds }
    var ageSeconds: TimeInterval { Date().timeIntervalSince(generatedAt) }

    func log() {
        print("[ActionTargetContract] capability=\(capabilityID) required_targets=\(requiredTargetCount) source=\(evidenceType.rawValue) confidence=\(String(format: "%.2f", sourceConfidence)) fallback_allowed=\(fallbackAllowed ? "yes" : "no")")
        for t in targets {
            print("[ActionTargetContract] target=\(t.role)/\(t.appName ?? "unknown")/\(t.titleFingerprint ?? "no_hash")/\(t.appBundleID ?? "no_bundle") present_at_generation=\(t.presentAtGeneration ? "yes" : "no")")
        }
    }

    static func forLayoutPair(
        capabilityID: String,
        windowA: WindowSnapshot,
        windowB: WindowSnapshot,
        evidenceType: ActionTargetEvidenceType,
        confidence: Double,
        fallbackAllowed: Bool = false
    ) -> ActionTargetContract {
        let a = ActionTargetDescriptor(
            role: "primary_work",
            appBundleID: windowA.bundleID.isEmpty ? nil : windowA.bundleID,
            windowID: windowA.windowID,
            titleFingerprint: ActionTargetDescriptor.titleHash(windowA.title),
            appName: windowA.appName
        )
        let b = ActionTargetDescriptor(
            role: "secondary_work",
            appBundleID: windowB.bundleID.isEmpty ? nil : windowB.bundleID,
            windowID: windowB.windowID,
            titleFingerprint: ActionTargetDescriptor.titleHash(windowB.title),
            appName: windowB.appName
        )
        return ActionTargetContract(
            contractID: makeID(capabilityID),
            capabilityID: capabilityID,
            requiredTargetCount: 2,
            targets: [a, b],
            evidenceType: evidenceType,
            sourceConfidence: confidence,
            fallbackAllowed: fallbackAllowed,
            generatedAt: Date(),
            expirySeconds: 120
        )
    }

    /// Build a contract from app name strings (no live window discovery required).
    /// Used at panel-candidate creation time where we have app names but not window objects.
    static func forLayoutApps(
        capabilityID: String,
        appNames: [String],
        evidenceType: ActionTargetEvidenceType,
        confidence: Double,
        fallbackAllowed: Bool = false
    ) -> ActionTargetContract {
        let targets = appNames.prefix(2).enumerated().map { idx, name in
            ActionTargetDescriptor(
                role: idx == 0 ? "primary_work" : "secondary_work",
                appName: name
            )
        }
        return ActionTargetContract(
            contractID: makeID(capabilityID),
            capabilityID: capabilityID,
            requiredTargetCount: min(2, appNames.count),
            targets: targets,
            evidenceType: evidenceType,
            sourceConfidence: confidence,
            fallbackAllowed: fallbackAllowed,
            generatedAt: Date(),
            expirySeconds: 120
        )
    }

    static func forBrowserAction(
        capabilityID: String,
        urlDomain: String?,
        evidenceType: ActionTargetEvidenceType = .browser_tab,
        confidence: Double = 0.8
    ) -> ActionTargetContract {
        let t = ActionTargetDescriptor(
            role: "active_browser_tab",
            titleFingerprint: urlDomain.map { ActionTargetDescriptor.titleHash($0) },
            appName: "Browser"
        )
        return ActionTargetContract(
            contractID: makeID(capabilityID),
            capabilityID: capabilityID,
            requiredTargetCount: 1,
            targets: [t],
            evidenceType: evidenceType,
            sourceConfidence: confidence,
            fallbackAllowed: false,
            generatedAt: Date(),
            expirySeconds: 60
        )
    }

    static func forMediaAction(
        capabilityID: String,
        mediaSourceType: String,
        confidence: Double
    ) -> ActionTargetContract {
        let t = ActionTargetDescriptor(role: "media_source", appName: mediaSourceType)
        return ActionTargetContract(
            contractID: makeID(capabilityID),
            capabilityID: capabilityID,
            requiredTargetCount: 1,
            targets: [t],
            evidenceType: .media_state,
            sourceConfidence: confidence,
            fallbackAllowed: false,
            generatedAt: Date(),
            expirySeconds: 30
        )
    }

    private static func makeID(_ capabilityID: String) -> String {
        "ctc:\(capabilityID):\(UUID().uuidString.prefix(8))"
    }
}

// MARK: - Preflight Result

enum PreflightStatus: String { case ok, blocked }

enum PreflightTargetCheckResult: String {
    case ok
    case missing
    case stale
    case roleMismatch = "role_mismatch"
    case alreadySatisfied = "already_satisfied"
}

struct ActionPreflightResult {
    let status: PreflightStatus
    let targetCheck: PreflightTargetCheckResult
    let reason: String
}

// MARK: - Action Preflight

@MainActor
enum ActionPreflight {

    static func check(
        contract: ActionTargetContract?,
        capabilityID: String,
        alreadySatisfiedCheck: (() -> Bool)? = nil
    ) -> ActionPreflightResult {

        if let check = alreadySatisfiedCheck, check() {
            print("[ActionPreflight] capability=\(capabilityID) status=blocked reason=already_satisfied")
            print("[ActionPreflight] target_check=already_satisfied")
            print("[ActionPreflight] blocked capability=\(capabilityID) reason=already_satisfied")
            return ActionPreflightResult(status: .blocked, targetCheck: .alreadySatisfied, reason: "already_satisfied")
        }

        guard let contract = contract else {
            print("[ActionPreflight] capability=\(capabilityID) status=ok reason=generic_mode_no_contract")
            print("[ActionPreflight] target_check=ok")
            return ActionPreflightResult(status: .ok, targetCheck: .ok, reason: "generic_mode")
        }

        let cid = contract.contractID
        if contract.isExpired {
            print("[ActionPreflight] capability=\(capabilityID) contract_id=\(cid) status=blocked reason=contract_expired age_s=\(Int(contract.ageSeconds))")
            print("[ActionPreflight] target_check=stale")
            print("[ActionPreflight] blocked capability=\(capabilityID) reason=target_contract_failed")
            return ActionPreflightResult(status: .blocked, targetCheck: .stale, reason: "contract_expired")
        }

        let liveWindows = WindowDiscovery.discoverAll()
        for target in contract.targets {
            guard isPresent(target, in: liveWindows) else {
                if contract.fallbackAllowed {
                    print("[ActionPreflight] capability=\(capabilityID) contract_id=\(cid) status=ok reason=fallback_allowed_target_missing target=\(target.role)/\(target.appName ?? "?")")
                    print("[ActionPreflight] target_check=missing")
                    return ActionPreflightResult(status: .ok, targetCheck: .missing, reason: "fallback_allowed")
                }
                print("[ActionPreflight] capability=\(capabilityID) contract_id=\(cid) status=blocked reason=target_missing target=\(target.role)/\(target.appName ?? "?")")
                print("[ActionPreflight] target_check=missing")
                print("[ActionPreflight] blocked capability=\(capabilityID) reason=target_contract_failed")
                print("[ActionPreflight] blocked capability=\(capabilityID) reason=substitution_not_allowed")
                return ActionPreflightResult(status: .blocked, targetCheck: .missing, reason: "target_missing_no_fallback")
            }
        }

        print("[ActionPreflight] capability=\(capabilityID) contract_id=\(cid) status=ok reason=all_targets_present")
        print("[ActionPreflight] target_check=ok")
        return ActionPreflightResult(status: .ok, targetCheck: .ok, reason: "targets_verified")
    }

    private static func isPresent(_ target: ActionTargetDescriptor, in windows: [WindowSnapshot]) -> Bool {
        if let wid = target.windowID, wid != 0 {
            if windows.contains(where: { $0.windowID == wid }) { return true }
        }
        if let bid = target.appBundleID, !bid.isEmpty {
            if windows.contains(where: { $0.bundleID == bid }) { return true }
        }
        if let name = target.appName, !name.isEmpty {
            if windows.contains(where: { $0.appName.caseInsensitiveCompare(name) == .orderedSame }) { return true }
        }
        return false
    }
}

// MARK: - Layout Intent Mode

enum LayoutIntentMode: String {
    case genericRuntimeLayout = "generic_runtime_layout"
    case proposalBoundLayout = "proposal_bound_layout"
    case restoreThenLayout = "restore_then_layout"
}

// MARK: - Self-test

@MainActor
enum ActionTargetContractSelfTest {

    static func run() -> Bool {
        print("[ActionTargetContractSelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { print("[ActionTargetContractSelfTest] pass case=\(name)") }
            else { print("[ActionTargetContractSelfTest] fail case=\(name)"); failures.append(name) }
        }

        // Expired contract blocks execution
        let expired = ActionTargetContract(
            contractID: "ctc:test:expired",
            capabilityID: "arrange_side_by_side",
            requiredTargetCount: 2,
            targets: [],
            evidenceType: .work_pair,
            sourceConfidence: 0.9,
            fallbackAllowed: false,
            generatedAt: Date().addingTimeInterval(-200),
            expirySeconds: 120
        )
        let expiredResult = ActionPreflight.check(contract: expired, capabilityID: "arrange_side_by_side")
        check("expired_contract_blocked", expiredResult.status == .blocked)
        check("expired_contract_stale", expiredResult.targetCheck == .stale)

        // Already satisfied blocks
        let fresh = ActionTargetContract(
            contractID: "ctc:test:fresh",
            capabilityID: "arrange_side_by_side",
            requiredTargetCount: 2,
            targets: [],
            evidenceType: .work_pair,
            sourceConfidence: 0.9,
            fallbackAllowed: false,
            generatedAt: Date(),
            expirySeconds: 120
        )
        let satisfiedResult = ActionPreflight.check(contract: fresh, capabilityID: "arrange_side_by_side", alreadySatisfiedCheck: { true })
        check("already_satisfied_blocked", satisfiedResult.status == .blocked)
        check("already_satisfied_check", satisfiedResult.targetCheck == .alreadySatisfied)

        // No contract = generic mode = ok
        let noContract = ActionPreflight.check(contract: nil, capabilityID: "arrange_side_by_side")
        check("no_contract_ok", noContract.status == .ok)

        // Contract with missing target and fallback_allowed=false → blocked
        let missingTarget = ActionTargetDescriptor(role: "primary_work", appName: "NonExistentApp12345")
        let boundContract = ActionTargetContract(
            contractID: "ctc:test:bound",
            capabilityID: "arrange_side_by_side",
            requiredTargetCount: 1,
            targets: [missingTarget],
            evidenceType: .work_pair,
            sourceConfidence: 0.9,
            fallbackAllowed: false,
            generatedAt: Date(),
            expirySeconds: 120
        )
        let missingResult = ActionPreflight.check(contract: boundContract, capabilityID: "arrange_side_by_side")
        check("missing_target_no_fallback_blocked", missingResult.status == .blocked)
        check("missing_target_check", missingResult.targetCheck == .missing)

        let ok = failures.isEmpty
        print("[ActionTargetContractSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
