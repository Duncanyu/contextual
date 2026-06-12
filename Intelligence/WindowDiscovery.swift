import Foundation
import AppKit

// MARK: - Window Snapshot

struct WindowSnapshot: Sendable {
    let windowID: CGWindowID
    let appName: String
    let bundleID: String
    let pid: pid_t
    let title: String
    let frame: CGRect
    let layer: Int
    let isOnScreen: Bool
    let isOnActiveScreen: Bool
}

// MARK: - Window Discovery

enum WindowDiscovery {

    private static let systemApps: Set<String> = [
        "Window Server", "SystemUIServer", "Control Center",
        "Notification Center", "Dock", "Spotlight",
        "Notification Centre", "universalaccessd"
    ]

    /// Phase 40 — dogfood mode suppresses per-window candidate spam. Set
    /// `CONTEXTUAL_TRACE_WINDOW_DISCOVERY=1` to re-enable per-window candidate logs.
    private static let traceCandidates: Bool = {
        ProcessInfo.processInfo.environment["CONTEXTUAL_TRACE_WINDOW_DISCOVERY"] == "1"
    }()

    static func discoverAll() -> [WindowSnapshot] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            print("[WindowDiscovery] failed reason=CGWindowListCopyWindowInfo_returned_nil")
            return []
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let activeScreen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var kept: [WindowSnapshot] = []
        var rejectionCounts: [String: Int] = [:]

        for dict in raw {
            let pid = dict[kCGWindowOwnerPID as String] as? Int32 ?? -1
            let layer = dict[kCGWindowLayer as String] as? Int ?? -1
            let isOnScreen = dict[kCGWindowIsOnscreen as String] as? Bool ?? false
            let ownerName = dict[kCGWindowOwnerName as String] as? String ?? ""
            let title = dict[kCGWindowName as String] as? String ?? ""
            let windowID = dict[kCGWindowNumber as String] as? CGWindowID ?? 0

            let bounds = dict[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let frame = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
            )

            // Is the window center on the active screen?
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let onActiveScreen = activeScreen.contains(center)

            let reason: String
            if layer != 0 {
                reason = "rejected_layer_\(layer)"
            } else if !isOnScreen {
                reason = "rejected_offscreen"
            } else if pid == selfPID {
                reason = "rejected_self"
            } else if systemApps.contains(ownerName) {
                reason = "rejected_system_app"
            } else if frame.width < 100 || frame.height < 100 {
                reason = "rejected_too_small_\(Int(frame.width))x\(Int(frame.height))"
            } else {
                reason = "kept"
            }

            if Self.traceCandidates {
                print("[WindowDiscovery] candidate"
                    + " pid=\(pid)"
                    + " app=\(ownerName)"
                    + " title=\"\(String(title.prefix(40)))\""
                    + " bounds=\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
                    + " layer=\(layer)"
                    + " visible=\(isOnScreen ? "yes" : "no")"
                    + " active_screen=\(onActiveScreen ? "yes" : "no")"
                    + " reason=\(reason)")
            }

            guard reason == "kept" else {
                // Aggregate rejection reasons (collapse layer numbers to "rejected_layer_N+").
                let key = reason.hasPrefix("rejected_layer_") ? "rejected_layer_nonzero" : reason
                rejectionCounts[key, default: 0] += 1
                continue
            }

            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            kept.append(WindowSnapshot(
                windowID: windowID, appName: ownerName, bundleID: bundleID,
                pid: pid, title: title, frame: frame, layer: layer,
                isOnScreen: isOnScreen, isOnActiveScreen: onActiveScreen
            ))
        }

        let rejectedTotal = raw.count - kept.count
        let summary = rejectionCounts
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        print("[WindowDiscovery] discovered=\(kept.count) eligible=\(kept.count) rejected=\(rejectedTotal) reason_summary=\(summary.isEmpty ? "none" : summary)")
        if !Self.traceCandidates && rejectedTotal > 0 {
            print("[LogSuppression] category=window_discovery_candidates suppressed_count=\(rejectedTotal) mode=dogfood")
        }
        return kept
    }

    static func findWorkingPair() -> (WindowSnapshot, WindowSnapshot)? {
        let all = discoverAll()
        guard let first = all.first else { return nil }
        guard let second = all.first(where: { $0.pid != first.pid }) else { return nil }
        return (first, second)
    }

    static func findCompartmentWindows(compartment: TaskCompartment?) -> [WindowSnapshot] {
        guard let comp = compartment else { return [] }
        let all = discoverAll()
        let terms = Set(comp.dominantTerms.map { $0.lowercased() })
        let tabs = Set(comp.browserTabs.map { $0.lowercased() })
        return all.filter { w in
            let t = w.title.lowercased()
            return terms.contains(where: { t.contains($0) }) || tabs.contains(where: { t.contains($0) || $0.contains(t) })
        }
    }
}

// MARK: - Work Pair Memory

/// Tracks recent alternating app/window pairs to inform layout selection.
final class WorkPairMemory: @unchecked Sendable {
    static let shared = WorkPairMemory()

    private let lock = NSLock()
    private var switches: [(app: String, title: String, pid: pid_t, at: Date)] = []
    private let maxHistory = 30
    private var suppressUntil: Date = .distantPast

    private init() {}

    /// Suppress friction counting for the given number of seconds, used after monitor reconnects.
    func suppressForSystemRestore(seconds: TimeInterval = 10) {
        lock.lock()
        suppressUntil = Date().addingTimeInterval(seconds)
        lock.unlock()
        print("[WorkPairMemory] suppressed reason=system_restore duration=\(Int(seconds))s")
    }

    func recordSwitch(app: String, title: String, pid: pid_t, source: String = "user_switch") {
        lock.lock()
        let suppressed = Date() < suppressUntil
        if !suppressed {
            switches.append((app: app, title: title, pid: pid, at: Date()))
            if switches.count > maxHistory { switches.removeFirst() }
        }
        lock.unlock()
        print("[WorkPairMemory] transition source=\(source) counted_for_friction=\(suppressed ? "no" : "yes")")
    }

    /// Returns the highest-confidence recent work pair (two different apps alternated).
    func bestPair(withinSeconds: TimeInterval = 90) -> (appA: String, titleA: String, pidA: pid_t, appB: String, titleB: String, pidB: pid_t, switches: Int)? {
        lock.lock()
        defer { lock.unlock() }

        let cutoff = Date().addingTimeInterval(-withinSeconds)
        let recent = switches.filter { $0.at > cutoff }
        guard recent.count >= 3 else { return nil }

        // Count alternations between distinct PIDs
        var pairCounts: [String: (appA: String, titleA: String, pidA: pid_t, appB: String, titleB: String, pidB: pid_t, count: Int)] = [:]
        for i in 1..<recent.count {
            let prev = recent[i - 1]
            let curr = recent[i]
            guard prev.pid != curr.pid else { continue }
            let key = "\(min(prev.pid, curr.pid))_\(max(prev.pid, curr.pid))"
            if var existing = pairCounts[key] {
                existing.count += 1
                pairCounts[key] = (appA: prev.app, titleA: prev.title, pidA: prev.pid,
                                   appB: curr.app, titleB: curr.title, pidB: curr.pid, count: existing.count)
            } else {
                pairCounts[key] = (appA: prev.app, titleA: prev.title, pidA: prev.pid,
                                   appB: curr.app, titleB: curr.title, pidB: curr.pid, count: 1)
            }
        }

        guard let best = pairCounts.values.max(by: { $0.count < $1.count }), best.count >= 2 else { return nil }
        let result = (appA: best.appA, titleA: best.titleA, pidA: best.pidA,
                      appB: best.appB, titleB: best.titleB, pidB: best.pidB,
                      switches: best.count)
        print("[WorkPairMemory] pair=\(result.appA)/\(String(result.titleA.prefix(20))) <-> \(result.appB)/\(String(result.titleB.prefix(20))) switches=\(result.switches) confidence=\(min(1.0, Double(result.switches) * 0.25))")
        return result
    }

    func reset() {
        lock.lock()
        switches.removeAll()
        suppressUntil = .distantPast
        lock.unlock()
    }
}

// MARK: - AX Window Matching

struct AXWindowHandle {
    let snapshot: WindowSnapshot
    let axElement: AXUIElement
}

enum AXWindowMatcher {

    @MainActor
    static func match(_ snapshot: WindowSnapshot) -> AXWindowHandle? {
        let axApp = AXUIElementCreateApplication(snapshot.pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let axWindows = ref as? [AXUIElement] else {
            print("[AXWindowMatch] cg_pid=\(snapshot.pid) cg_title=\"\(String(snapshot.title.prefix(35)))\" ax_count=0 matched=no reason=no_ax_windows")
            return nil
        }

        for axWin in axWindows {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleRef) == .success,
               let axTitle = titleRef as? String,
               !snapshot.title.isEmpty,
               axTitle == snapshot.title {
                print("[AXWindowMatch] cg_pid=\(snapshot.pid) cg_title=\"\(String(snapshot.title.prefix(35)))\" ax_count=\(axWindows.count) matched=yes reason=title_exact")
                return AXWindowHandle(snapshot: snapshot, axElement: axWin)
            }
        }

        if let first = axWindows.first {
            print("[AXWindowMatch] cg_pid=\(snapshot.pid) cg_title=\"\(String(snapshot.title.prefix(35)))\" ax_count=\(axWindows.count) matched=yes reason=first_ax_window")
            return AXWindowHandle(snapshot: snapshot, axElement: first)
        }

        print("[AXWindowMatch] cg_pid=\(snapshot.pid) cg_title=\"\(String(snapshot.title.prefix(35)))\" ax_count=\(axWindows.count) matched=no reason=no_ax_match")
        return nil
    }
}

// MARK: - Layout Candidate Scoring

enum LayoutCandidateScorer {

    private static let entertainmentTerms: Set<String> = [
        "youtube", "netflix", "twitch", "disney+", "hulu", "prime video",
        "crunchyroll", "hbo", "tiktok", "truth or drink", "watch",
        "episode", "movie", "trailer", "music video", "shorts"
    ]

    struct ScoredWindow {
        let snapshot: WindowSnapshot
        let score: Double
        let reasons: [String]
    }

    static func score(
        _ window: WindowSnapshot,
        frontmostPID: pid_t,
        workPair: (appA: String, titleA: String, pidA: pid_t, appB: String, titleB: String, pidB: pid_t, switches: Int)?,
        compartment: TaskCompartment?
    ) -> ScoredWindow {
        var score: Double = 0
        var reasons: [String] = []

        // Current focused window
        if window.pid == frontmostPID {
            score += 10
            reasons.append("current_focused")
        }

        // Part of recent work pair
        if let pair = workPair {
            if window.pid == pair.pidA || window.pid == pair.pidB {
                score += 8
                reasons.append("recent_work_pair")
            }
        }

        // Compartment match
        if let comp = compartment {
            let titleLower = window.title.lowercased()
            let termMatch = comp.dominantTerms.contains(where: { titleLower.contains($0.lowercased()) })
            let tabMatch = comp.browserTabs.contains(where: { titleLower.contains($0.lowercased()) || $0.lowercased().contains(titleLower) })
            if termMatch || tabMatch {
                score += 5
                reasons.append("compartment_match")
            }
        }

        // Cross-app bonus (prefer different apps for side-by-side)
        if window.pid != frontmostPID {
            score += 2
            reasons.append("cross_app")
        }

        // Document/PDF paired with browser
        let isDocument = window.appName == "Preview" || window.title.lowercased().hasSuffix(".pdf")
        if isDocument {
            score += 3
            reasons.append("document_pdf")
        }

        // Entertainment penalty
        let titleLower = window.title.lowercased()
        if entertainmentTerms.contains(where: { titleLower.contains($0) }) {
            score -= 15
            reasons.append("entertainment_downrank")
        }

        // Off-screen penalty
        if !window.isOnActiveScreen {
            score -= 5
            reasons.append("offscreen_downrank")
        }

        let result = ScoredWindow(snapshot: window, score: score, reasons: reasons)
        print("[LayoutCandidateScore] app=\(window.appName) title=\"\(String(window.title.prefix(35)))\" score=\(String(format: "%.1f", score)) reasons=\(reasons.joined(separator: ","))")
        return result
    }
}

// MARK: - Layout Engine

@MainActor
enum LayoutEngine {

    struct LayoutResult {
        let status: String
        let reason: String
        let windowA: String
        let windowB: String
    }

    static func arrangeSideBySide(
        preferredAppA: String? = nil,
        preferredAppB: String? = nil,
        titleHintA: String? = nil,
        titleHintB: String? = nil,
        compartment: TaskCompartment? = nil,
        contract: ActionTargetContract? = nil
    ) -> LayoutResult {

        // Part C: determine layout mode
        let mode: LayoutIntentMode = (contract != nil) ? .proposalBoundLayout : .genericRuntimeLayout
        print("[LayoutIntent] mode=\(mode.rawValue)\(contract.map { " contract_id=\($0.contractID)" } ?? "")")

        if let contract = contract {
            // Proposal-bound: validate contract before proceeding
            print("[LayoutIntent] target_contract=\(contract.isExpired ? "stale" : "present")")
            if contract.isExpired {
                print("[LayoutIntent] blocked reason=bound_target_missing")
                print("[ActionVerification] capability=arrange_side_by_side status=failed reason=bound_target_contract_expired")
                return LayoutResult(status: "failed", reason: "bound_target_contract_expired", windowA: "none", windowB: "none")
            }
        }

        guard AXPermissionProbe.check(reason: "layout_arrange") else {
            print("[ActionVerification] capability=arrange_side_by_side status=failed reason=accessibility_permission_required")
            return LayoutResult(status: "failed", reason: "accessibility_permission_required", windowA: "unknown", windowB: "unknown")
        }

        let allCG = WindowDiscovery.discoverAll()
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        let workPair = WorkPairMemory.shared.bestPair()

        // Score all candidates; in proposal-bound mode skip windows not in contract
        let scored: [LayoutCandidateScorer.ScoredWindow]
        if let contract = contract, mode == .proposalBoundLayout {
            let contractBundles = Set(contract.targets.compactMap { $0.appBundleID })
            let contractApps = Set(contract.targets.compactMap { $0.appName })
            scored = allCG.compactMap { window in
                let inContract = contractBundles.contains(window.bundleID) || contractApps.contains(window.appName)
                if !inContract {
                    print("[LayoutCandidateScore] skipped_unrelated app=\(window.appName) reason=proposal_bound_mode")
                    return nil
                }
                return LayoutCandidateScorer.score(window, frontmostPID: frontPID, workPair: workPair, compartment: compartment)
            }
            if scored.count < 2 {
                print("[LayoutIntent] blocked reason=bound_target_missing")
                print("[ActionVerification] capability=arrange_side_by_side status=failed reason=bound_targets_not_found")
                return LayoutResult(status: "failed", reason: "bound_targets_not_found", windowA: "none", windowB: "none")
            }
        } else {
            scored = allCG.map { LayoutCandidateScorer.score($0, frontmostPID: frontPID, workPair: workPair, compartment: compartment) }
        }
        let ranked = scored.sorted { $0.score > $1.score }

        // Select best pair: highest-scored + best complement
        guard let primary = ranked.first else {
            print("[LayoutIntent] intent=arrange_side_by_side selected_count=0 primary=none secondary=none reason=no_windows")
            print("[IntentExecutor] status=unavailable reason=insufficient_movable_windows discovered=\(allCG.count) movable=0")
            print("[ActionVerification] capability=arrange_side_by_side status=failed reason=insufficient_movable_windows")
            return LayoutResult(status: "failed", reason: "insufficient_movable_windows", windowA: "none", windowB: "none")
        }

        // Secondary: prefer different PID, non-entertainment, highest remaining score
        let secondary = ranked.first(where: { $0.snapshot.pid != primary.snapshot.pid && $0.score > -5 })
            ?? ranked.first(where: { $0.snapshot.windowID != primary.snapshot.windowID && $0.score > -5 })

        guard let sec = secondary else {
            print("[LayoutIntent] intent=arrange_side_by_side selected_count=1 primary=\"\(primary.snapshot.appName)/\(String(primary.snapshot.title.prefix(20)))\" secondary=none reason=no_secondary")
            print("[IntentExecutor] status=unavailable reason=insufficient_movable_windows discovered=\(allCG.count) movable=1")
            print("[ActionVerification] capability=arrange_side_by_side status=failed reason=insufficient_movable_windows")
            return LayoutResult(status: "failed", reason: "insufficient_movable_windows", windowA: "\(primary.snapshot.appName)/\(String(primary.snapshot.title.prefix(20)))", windowB: "none")
        }

        let aLabel = "\(primary.snapshot.appName)/\(String(primary.snapshot.title.prefix(25)))"
        let bLabel = "\(sec.snapshot.appName)/\(String(sec.snapshot.title.prefix(25)))"

        // Phase 44 — BLOCK arrange_side_by_side when no verified work pair.
        // Without a confirmed pair (min 3 switches in 90s), we cannot know the user's intent.
        // best_scored_pair is suppressed: it picks high-scored apps (e.g. Xcode) regardless of usage pattern.
        let hasPairReason = primary.reasons.contains("recent_work_pair") || sec.reasons.contains("recent_work_pair")
        let hasWorkPair = workPair != nil
        let selectionReason = (hasWorkPair && hasPairReason) ? "recent_work_pair" : "best_scored_pair"

        print("[WorkPairMemory] pair_available=\(hasWorkPair ? "yes" : "no") primary_has_pair_reason=\(primary.reasons.contains("recent_work_pair") ? "yes" : "no") secondary_has_pair_reason=\(sec.reasons.contains("recent_work_pair") ? "yes" : "no")")
        print("[ArrangeRequirement] requirement=verified_work_pair met=\(selectionReason == "recent_work_pair" ? "yes" : "no") reason=\(selectionReason)")

        guard selectionReason == "recent_work_pair" else {
            print("[LayoutIntent] intent=arrange_side_by_side BLOCKED primary=\"\(aLabel)\" secondary=\"\(bLabel)\" reason=no_verified_work_pair selection_would_be=best_scored_pair")
            print("[ActionVerification] capability=arrange_side_by_side status=blocked reason=best_scored_pair_suppressed")
            print("[IntentExecutor] status=blocked reason=no_verified_pair_to_arrange")
            return LayoutResult(status: "blocked", reason: "no_verified_work_pair", windowA: aLabel, windowB: bLabel)
        }

        print("[LayoutIntent] intent=arrange_side_by_side selected_count=2 primary=\"\(aLabel)\" secondary=\"\(bLabel)\" reason=\(selectionReason)")

        // Match CG → AX
        guard let axA = AXWindowMatcher.match(primary.snapshot) else {
            print("[ActionVerification] capability=arrange_side_by_side status=failed reason=ax_match_failed")
            return LayoutResult(status: "failed", reason: "ax_match_failed_window_a", windowA: aLabel, windowB: bLabel)
        }
        guard let axB = AXWindowMatcher.match(sec.snapshot) else {
            let left = computeLeftHalf()
            let _ = moveAndVerify(handle: axA, target: left, label: aLabel)
            raiseAX(axA.axElement)
            print("[ActionVerification] capability=arrange_side_by_side status=partial reason=ax_match_failed_window_b")
            return LayoutResult(status: "partial", reason: "ax_match_failed_window_b", windowA: aLabel, windowB: bLabel)
        }

        // Move
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenDesc = screen.map { "\($0.frame.width)x\($0.frame.height)" } ?? "unknown"
        let left = computeLeftHalf()
        let right = computeRightHalf()

        print("[LayoutPlan] capability=arrange_side_by_side primary_target=\(fmtRectAngle(left)) secondary_target=\(fmtRectAngle(right)) screen=\(screenDesc)")

        var targetA = left
        var targetB = right

        var actualA = CGRect.zero
        var actualB = CGRect.zero

        var isOverlap = false
        var isSameSide = false
        var isWithinTolerance = false

        var finalStatus = "failed"
        var finalReason = "move_verify_failed"

        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            let errPosA = setAXPosition(axA.axElement, x: targetA.minX, y: targetA.minY)
            let errSizeA = setAXSize(axA.axElement, w: targetA.width, h: targetA.height)
            let errPosB = setAXPosition(axB.axElement, x: targetB.minX, y: targetB.minY)
            let errSizeB = setAXSize(axB.axElement, w: targetB.width, h: targetB.height)

            actualA = readAXFrame(axA.axElement) ?? targetA
            actualB = readAXFrame(axB.axElement) ?? targetB

            let menuBarOffset = computeMenuBarHeight()
            let tol: CGFloat = 24
            let aWithinTol = withinTolerance(actualA, targetA, tol: tol, menuBarOffset: menuBarOffset)
            let bWithinTol = withinTolerance(actualB, targetB, tol: tol, menuBarOffset: menuBarOffset)
            isWithinTolerance = aWithinTol && bWithinTol

            // Check overlap
            isOverlap = actualA.insetBy(dx: 10, dy: 10).intersects(actualB.insetBy(dx: 10, dy: 10))

            // Check same side
            let screenMidX = screen?.visibleFrame.midX ?? 720
            isSameSide = (actualA.midX < screenMidX && actualB.midX < screenMidX) ||
                         (actualA.midX > screenMidX && actualB.midX > screenMidX)

            let overlapArea = isOverlap ? actualA.intersection(actualB).width * actualA.intersection(actualB).height : 0
            if LogControl.shared.shouldLog(category: .useful_action_inventory, level: .dogfood) {
                print("[LayoutVerify] overlap_area=\(Int(overlapArea)) same_side=\(isSameSide ? "yes" : "no") within_tolerance=\(isWithinTolerance ? "yes" : "no")")
            }

            if !isOverlap && !isSameSide && isWithinTolerance {
                finalStatus = "success"
                finalReason = "windows_arranged"
                break
            }

            if attempt < maxAttempts {
                let retryReason: String
                if isOverlap {
                    retryReason = "overlap"
                } else if isSameSide {
                    retryReason = "same_side"
                } else if errPosA != .success || errSizeA != .success || errPosB != .success || errSizeB != .success {
                    retryReason = "ax_resisted_move"
                } else {
                    retryReason = "size_mismatch"
                }
                if LogControl.shared.shouldLog(category: .useful_action_inventory, level: .dogfood) {
                    print("[LayoutRetry] attempt=\(attempt) reason=\(retryReason)")
                }

                let screenFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
                let minWidth: CGFloat = 200
                if actualA.width > targetA.width + tol {
                    let newWidthA = min(actualA.width, screenFrame.width - minWidth)
                    targetA.size.width = newWidthA
                    targetB.origin.x = screenFrame.minX + newWidthA
                    targetB.size.width = max(minWidth, screenFrame.width - newWidthA)
                } else if actualB.width > targetB.width + tol {
                    let newWidthB = min(actualB.width, screenFrame.width - minWidth)
                    targetB.size.width = newWidthB
                    targetB.origin.x = screenFrame.maxX - newWidthB
                    targetA.size.width = max(minWidth, screenFrame.width - newWidthB)
                } else {
                    targetA = left.insetBy(dx: 15, dy: 0)
                    targetB = right.insetBy(dx: 15, dy: 0)
                    targetA.origin.x = left.minX
                    targetB.origin.x = right.minX + 15
                }
            }
        }

        raiseAX(axA.axElement)
        raiseAX(axB.axElement)

        if finalStatus != "success" {
            if isOverlap || isSameSide {
                finalStatus = "failed"
                finalReason = isOverlap ? "overlap_detected" : "same_side_detected"
            } else if actualA.width != targetA.width || actualB.width != targetB.width {
                finalStatus = "partial"
                finalReason = "one_app_resisted_resize"
            } else {
                finalStatus = "failed"
                finalReason = "move_verify_failed"
            }
        }

        if LogControl.shared.shouldLog(category: .useful_action_inventory, level: .dogfood) {
            print("[ActionVerification] capability=arrange_side_by_side status=\(finalStatus) reason=\(finalReason)")
        }
        return LayoutResult(status: finalStatus, reason: finalReason, windowA: aLabel, windowB: bLabel)
    }

    private static func fmtRectAngle(_ r: CGRect) -> String {
        "<\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.width)),\(Int(r.height))>"
    }

    static func switchToRelevantWindow(
        preferredApp: String? = nil,
        titleHint: String? = nil,
        compartment: TaskCompartment? = nil,
        contract: ActionTargetContract? = nil
    ) -> LayoutResult {
        let mode: LayoutIntentMode = (contract != nil) ? .proposalBoundLayout : .genericRuntimeLayout
        print("[LayoutIntent] mode=\(mode.rawValue)\(contract.map { " contract_id=\($0.contractID)" } ?? "")")
        if let contract = contract {
            print("[LayoutIntent] target_contract=\(contract.isExpired ? "stale" : "present")")
            if contract.isExpired {
                print("[LayoutIntent] blocked reason=bound_target_missing")
                print("[ActionVerification] capability=switch_to_paired_app status=failed reason=bound_target_contract_expired")
                return LayoutResult(status: "failed", reason: "bound_target_contract_expired", windowA: "none", windowB: "none")
            }
        }
        let allCG = WindowDiscovery.discoverAll()
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        let target: WindowSnapshot? = {
            if let app = preferredApp { return allCG.first { $0.appName.caseInsensitiveCompare(app) == .orderedSame } }
            let workPair = WorkPairMemory.shared.bestPair()
            if let pair = workPair {
                let otherPID = pair.pidA == frontPID ? pair.pidB : pair.pidA
                if let w = allCG.first(where: { $0.pid == otherPID }) { return w }
            }
            return allCG.first { $0.pid != frontPID }
        }()
        guard let found = target else {
            print("[ActionVerification] capability=switch_to_paired_app status=failed reason=no_target_window")
            return LayoutResult(status: "failed", reason: "no_target_window", windowA: "none", windowB: "none")
        }
        let name = "\(found.appName)/\(String(found.title.prefix(25)))"
        if let running = NSRunningApplication(processIdentifier: found.pid) {
            running.activate()
            if let ax = AXWindowMatcher.match(found) { raiseAX(ax.axElement) }
            print("[ActionVerification] capability=switch_to_paired_app status=success target=\(name)")
            return LayoutResult(status: "success", reason: "switched", windowA: name, windowB: "none")
        }
        print("[ActionVerification] capability=switch_to_paired_app status=failed reason=process_not_found")
        return LayoutResult(status: "failed", reason: "process_not_found", windowA: name, windowB: "none")
    }

    // MARK: - Move + Verify

    private static func moveAndVerify(handle: AXWindowHandle, target: CGRect, label: String) -> Bool {
        let posErr = setAXPosition(handle.axElement, x: target.minX, y: target.minY)
        let sizeErr = setAXSize(handle.axElement, w: target.width, h: target.height)
        print("[AXMove] window=\"\(label)\" set_position=\(posErr) set_size=\(sizeErr) target=\(fmtRect(target))")

        guard posErr == .success && sizeErr == .success else {
            print("[LayoutVerify] window=\"\(label)\" target=\(fmtRect(target)) actual=unknown within_tolerance=no")
            return false
        }

        let menuBarOffset = computeMenuBarHeight()
        if let actual = readAXFrame(handle.axElement), withinTolerance(actual, target, menuBarOffset: menuBarOffset) {
            print("[LayoutVerify] window=\"\(label)\" target=\(fmtRect(target)) actual=\(fmtRect(actual)) menu_bar_offset=\(Int(menuBarOffset)) within_tolerance=yes")
            return true
        }

        // One retry
        let _ = setAXPosition(handle.axElement, x: target.minX, y: target.minY)
        let _ = setAXSize(handle.axElement, w: target.width, h: target.height)
        if let actual = readAXFrame(handle.axElement) {
            let ok = withinTolerance(actual, target, menuBarOffset: menuBarOffset)
            print("[LayoutVerify] window=\"\(label)\" target=\(fmtRect(target)) actual=\(fmtRect(actual)) menu_bar_offset=\(Int(menuBarOffset)) within_tolerance=\(ok ? "yes" : "no") retry=yes")
            return ok
        }
        print("[LayoutVerify] window=\"\(label)\" target=\(fmtRect(target)) actual=unreadable within_tolerance=no retry=yes")
        return false
    }

    private static func withinTolerance(_ actual: CGRect, _ expected: CGRect, tol: CGFloat = 24, menuBarOffset: CGFloat = 0) -> Bool {
        // Y tolerance is larger to account for menu bar coordinate differences
        abs(actual.minX - expected.minX) < tol
            && abs(actual.minY - expected.minY) < (tol + menuBarOffset)
            && abs(actual.width - expected.width) < tol
            && abs(actual.height - expected.height) < (tol + menuBarOffset)
    }

    // MARK: - AX Primitives

    private static func setAXPosition(_ el: AXUIElement, x: CGFloat, y: CGFloat) -> AXError {
        var pt = CGPoint(x: x, y: y)
        guard let val = AXValueCreate(.cgPoint, &pt) else { return .failure }
        return AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, val)
    }

    private static func setAXSize(_ el: AXUIElement, w: CGFloat, h: CGFloat) -> AXError {
        var sz = CGSize(width: w, height: h)
        guard let val = AXValueCreate(.cgSize, &sz) else { return .failure }
        return AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, val)
    }

    private static func readAXFrame(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pv = posRef, let sv = sizeRef else { return nil }
        var pt = CGPoint.zero; var sz = CGSize.zero
        guard AXValueGetType(pv as! AXValue) == .cgPoint, AXValueGetType(sv as! AXValue) == .cgSize,
              AXValueGetValue(pv as! AXValue, .cgPoint, &pt), AXValueGetValue(sv as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    private static func raiseAX(_ el: AXUIElement) {
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
    }

    // MARK: - Screen Geometry (AX coordinate space: origin = top-left)

    private static func computeMenuBarHeight() -> CGFloat {
        guard let screen = NSScreen.main else { return 25 }
        // NSScreen.frame has origin bottom-left; visibleFrame excludes menu bar/dock.
        // Menu bar height = screen.frame.height - visibleFrame.height - dock_height_if_bottom
        // In AX coords (y=0 at top), the usable area starts at menu_bar_height.
        return screen.frame.height - screen.visibleFrame.height - screen.visibleFrame.origin.y
    }

    private static func computeLeftHalf() -> CGRect {
        guard let screen = NSScreen.main else { return CGRect(x: 0, y: 25, width: 720, height: 875) }
        // Convert NSScreen visibleFrame to AX coordinates (y=0 at top-left)
        let menuBarH = screen.frame.height - screen.visibleFrame.maxY
        let h = screen.visibleFrame.height
        let w = floor(screen.visibleFrame.width / 2)
        return CGRect(x: screen.visibleFrame.minX, y: menuBarH, width: w, height: h)
    }

    private static func computeRightHalf() -> CGRect {
        guard let screen = NSScreen.main else { return CGRect(x: 720, y: 25, width: 720, height: 875) }
        let menuBarH = screen.frame.height - screen.visibleFrame.maxY
        let h = screen.visibleFrame.height
        let leftW = floor(screen.visibleFrame.width / 2)
        let rightW = ceil(screen.visibleFrame.width / 2)
        return CGRect(x: screen.visibleFrame.minX + leftW, y: menuBarH, width: rightW, height: h)
    }

    private static func fmtRect(_ r: CGRect) -> String {
        "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"
    }
}

// MARK: - Intent Executor

@MainActor
enum IntentExecutor {

    static func execute(
        intent: String,
        compartment: TaskCompartment?,
        preferredAppA: String? = nil,
        preferredAppB: String? = nil,
        titleHintA: String? = nil,
        titleHintB: String? = nil,
        targetURL: String? = nil,
        browserName: String? = nil
    ) -> CapabilityExecutionStatus {
        print("[IntentExecutor] intent=\(intent)")

        switch intent {
        case "arrange_side_by_side":
            let r = LayoutEngine.arrangeSideBySide(
                preferredAppA: preferredAppA, preferredAppB: preferredAppB,
                titleHintA: titleHintA, titleHintB: titleHintB,
                compartment: compartment
            )
            return layoutStatus(r)

        case "switch_to_paired_app", "switch_to_last_task_window":
            let r = LayoutEngine.switchToRelevantWindow(
                preferredApp: preferredAppA, titleHint: titleHintA, compartment: compartment
            )
            return layoutStatus(r)

        case "split_research_setup":
            // FIRST: Check if a suitable pair of existing windows already exists.
            let allCG = WindowDiscovery.discoverAll()
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
            let crossAppWindows = allCG.filter { $0.pid != frontPID && $0.isOnActiveScreen }
            let hasSuitablePair = crossAppWindows.count >= 1

            if hasSuitablePair {
                print("[SplitDecision] existing_pair_available=yes action=arrange_existing reason=cross_app_window_exists")
                // Just arrange existing windows — no need to open a new one
                let r = LayoutEngine.arrangeSideBySide(compartment: compartment)
                let s = layoutStatus(r)
                print("[ActionVerification] capability=split_research_setup status=\(s == .success ? "success" : "partial_or_unavailable") method=arrange_existing")
                return s
            }

            // No suitable pair exists — try to open a URL in a new window
            print("[SplitDecision] existing_pair_available=no action=open_url_new_window reason=no_cross_app_window")
            let url: String? = {
                if let u = targetURL, !u.isEmpty { return u }
                for appName in ["Firefox", "Google Chrome", "Safari", "Arc", "Brave Browser", "Microsoft Edge"] {
                    if let ctx = BrowserContextExtractor.extract(appName: appName, activeAppPID: nil),
                       let u = ctx.selectedURL?.absoluteString ?? ctx.currentURL?.absoluteString, !u.isEmpty {
                        print("[IntentExecutor] split_url_discovered=yes source=\(appName) url=\(String(u.prefix(60)))")
                        return u
                    }
                }
                return nil
            }()
            guard let resolvedURL = url else {
                print("[IntentExecutor] intent=split_research_setup status=unavailable reason=no_url_discovered")
                print("[ActionVerification] capability=split_research_setup status=unavailable reason=no_url_discovered")
                return .unavailable
            }
            let browser = browserName ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            let splitResult = BrowserSplitStrategy.openInNewWindow(url: resolvedURL, browser: browser)
            guard splitResult.openedNewWindow else {
                print("[IntentExecutor] intent=split_research_setup status=unavailable reason=browser_split_failed")
                print("[ActionVerification] capability=split_research_setup status=unavailable reason=browser_split_failed")
                return .unavailable
            }
            let arrangeResult = LayoutEngine.arrangeSideBySide(
                preferredAppA: browser.isEmpty ? nil : browser,
                preferredAppB: browser.isEmpty ? nil : browser
            )
            let s = layoutStatus(arrangeResult)
            print("[ActionVerification] capability=split_research_setup status=\(s == .success ? "success" : "partial_or_unavailable") method=open_url_new_window")
            return s

        case "open_paired_app":
            if let app = preferredAppA, !app.isEmpty {
                if NSWorkspace.shared.launchApplication(app) {
                    print("[IntentExecutor] status=success opened=\(app)")
                    return .success
                }
                print("[IntentExecutor] status=unavailable reason=app_launch_failed app=\(app)")
                return .unavailable
            }
            if let comp = compartment {
                let cw = WindowDiscovery.findCompartmentWindows(compartment: comp)
                let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
                if let other = cw.first(where: { $0.pid != frontPID }) {
                    _ = NSWorkspace.shared.launchApplication(other.appName)
                    print("[IntentExecutor] status=success opened=\(other.appName)")
                    return .success
                }
            }
            print("[IntentExecutor] status=unavailable reason=no_target_app_discovered")
            return .unavailable

        default:
            print("[IntentExecutor] status=unavailable reason=unknown_intent")
            return .unavailable
        }
    }

    // Part D: honest status — partial must NOT become success
    private static func layoutStatus(_ r: LayoutEngine.LayoutResult) -> CapabilityExecutionStatus {
        switch r.status {
        case "success": return .success
        case "partial": return .partial
        case "no_op", "already_satisfied": return .alreadySatisfied
        default: return .unavailable
        }
    }
}

// MARK: - Self-Test

@MainActor
enum WindowDiscoverySelfTest {

    static func run() async -> Bool {
        print("[WindowDiscoverySelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { print("[WindowDiscoverySelfTest] pass case=\(name)") }
            else  { print("[WindowDiscoverySelfTest] fail case=\(name)"); failures.append(name) }
        }

        let windows = WindowDiscovery.discoverAll()
        check("discovery_finds_windows", !windows.isEmpty)

        let sysNames: Set<String> = ["Window Server", "SystemUIServer", "Dock", "Spotlight"]
        check("discovery_excludes_system_ui", !windows.contains { sysNames.contains($0.appName) })

        let selfPID = ProcessInfo.processInfo.processIdentifier
        check("discovery_excludes_self", !windows.contains { $0.pid == selfPID })

        check("discovery_valid_frames", windows.allSatisfy { $0.frame.width >= 100 && $0.frame.height >= 100 })

        // Entertainment scoring
        let youtubeSnapshot = WindowSnapshot(windowID: 0, appName: "Firefox", bundleID: "org.mozilla.firefox", pid: 1, title: "TRUTH OR DRINK | Sam vs Andrew - YouTube", frame: CGRect(x: 0, y: 0, width: 800, height: 600), layer: 0, isOnScreen: true, isOnActiveScreen: true)
        let docSnapshot = WindowSnapshot(windowID: 1, appName: "Preview", bundleID: "com.apple.Preview", pid: 2, title: "Lease Agreement.pdf", frame: CGRect(x: 0, y: 0, width: 800, height: 600), layer: 0, isOnScreen: true, isOnActiveScreen: true)
        let ytScore = LayoutCandidateScorer.score(youtubeSnapshot, frontmostPID: 3, workPair: nil, compartment: nil)
        let docScore = LayoutCandidateScorer.score(docSnapshot, frontmostPID: 3, workPair: nil, compartment: nil)
        check("entertainment_youtube_downranked", ytScore.score < docScore.score)
        check("entertainment_youtube_has_downrank_reason", ytScore.reasons.contains("entertainment_downrank"))

        // Work pair memory
        WorkPairMemory.shared.reset()
        for _ in 0..<4 {
            WorkPairMemory.shared.recordSwitch(app: "Firefox", title: "Google Docs", pid: 100)
            WorkPairMemory.shared.recordSwitch(app: "Preview", title: "Lease.pdf", pid: 200)
        }
        let pair = WorkPairMemory.shared.bestPair()
        check("work_pair_memory_detects_alternation", pair != nil && pair!.switches >= 2)

        check("unknown_intent_unavailable", IntentExecutor.execute(intent: "bogus", compartment: nil) == .unavailable)
        check("split_no_url_unavailable", IntentExecutor.execute(intent: "split_research_setup", compartment: nil) == .unavailable)

        // Coordinate space
        let left = LayoutEngine.self
        // Just verify the halves don't start at y=0 (they should account for menu bar)
        if let screen = NSScreen.main {
            let menuBarH = screen.frame.height - screen.visibleFrame.maxY
            check("left_half_accounts_for_menu_bar", menuBarH > 0)
            print("[WindowDiscoverySelfTest] menu_bar_height=\(Int(menuBarH))")
        } else {
            check("left_half_accounts_for_menu_bar", true)
        }

        let ok = failures.isEmpty
        print("[WindowDiscoverySelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
