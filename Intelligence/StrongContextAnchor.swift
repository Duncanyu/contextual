import Foundation

/// Phase 4R — Strong context anchoring for proposal generation.
///
/// Purpose:
/// Prevent transient weak browser titles (profile/account names, generic pages,
/// code-like OCR contamination) from replacing a recently-seen strong page
/// context (product/article/page title + grounded OCR) used for proposal
/// synthesis.
///
/// This is in-memory only (no persistence) and purely deterministic.
struct StrongContextAnchor: Sendable, Equatable {
	let appName: String
	let bundleIdentifier: String?
	let windowTitle: String
	let ocrExcerpt: String?
	let axExcerpt: String?
	let workflow: InferredWorkflow
	let storedAt: Date

	static let ttlSeconds: TimeInterval = 45

	func isExpired(at now: Date) -> Bool {
		now.timeIntervalSince(storedAt) > Self.ttlSeconds
	}
}

enum StrongContextAnchorHeuristic {

	struct Decision: Sendable, Equatable {
		let shouldStore: Bool
		let shouldPreserve: Bool
		let reason: String
	}

	static func evaluate(
		now: Date,
		currentTitle: String,
		currentOCR: String?,
		currentWorkflow: InferredWorkflow,
		currentBundleId: String?,
		anchor: StrongContextAnchor?
	) -> Decision {
		let title = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
		let wf = currentWorkflow.rawValue.lowercased()
		let ocr = (currentOCR ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

		let isContentWorkflow = wf.contains("brows") || wf.contains("shop") || wf.contains("research") || wf.contains("read") || wf.contains("review") || wf.contains("product")

		let titleIsStrong = isStrongPageTitle(title)
		let ocrIsStrong = ocr.count >= 200 && !looksCodeLike(ocr)
		let currentIsStrong = isContentWorkflow && (ocrIsStrong || (titleIsStrong && ocr.count >= 120))

		// Store / refresh anchor only on strong contexts.
		if currentIsStrong {
			return Decision(shouldStore: true, shouldPreserve: false, reason: "current_strong_context")
		}

		// Preserve a recent strong anchor when current context is weak.
		guard let anchor else {
			return Decision(shouldStore: false, shouldPreserve: false, reason: "no_anchor")
		}
		if anchor.isExpired(at: now) {
			return Decision(shouldStore: false, shouldPreserve: false, reason: "anchor_expired")
		}
		if let aBundle = anchor.bundleIdentifier?.lowercased(),
		   let cBundle = currentBundleId?.lowercased(),
		   !aBundle.isEmpty,
		   !cBundle.isEmpty,
		   aBundle != cBundle {
			return Decision(shouldStore: false, shouldPreserve: false, reason: "bundle_mismatch")
		}

		if isWeakTransientTitle(title) || looksCodeLike(ocr) {
			return Decision(shouldStore: false, shouldPreserve: true, reason: "weak_title_rejected")
		}

		return Decision(shouldStore: false, shouldPreserve: false, reason: "current_context_not_strong_but_not_weak")
	}

	// MARK: - Title heuristics

	private static func isStrongPageTitle(_ title: String) -> Bool {
		guard !title.isEmpty else { return false }
		// Require enough substance to be a real page entity (not a short label/name).
		let tokens = title.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.count > 1 }
		if tokens.count < 4 { return false }
		let lower = title.lowercased()
		// Avoid generic browser chrome or assistant chrome.
		let generic = ["new tab", "about:blank", "mozilla firefox", "firefox", "chrome", "safari", "profile", "account", "settings"]
		if generic.contains(lower) { return false }
		if lower.contains("contextual") || lower.contains("runtime") { return false }
		return true
	}

	private static func isWeakTransientTitle(_ title: String) -> Bool {
		let lower = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		if lower.isEmpty { return true }
		// Short titles are commonly profile/account labels, not stable page entities.
		let tokens = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !$0.isEmpty }
		if tokens.count <= 2 { return true }
		// Settings/profile/account surfaces should not overwrite strong product/page anchors.
		let weakNeedles = ["profile", "account", "settings", "edit profile", "sign in", "log in"]
		if weakNeedles.contains(where: { lower.contains($0) }) { return true }
		return false
	}

	// MARK: - OCR heuristics

	private static func looksCodeLike(_ text: String) -> Bool {
		let lower = text.lowercased()
		if lower.contains("func ") || lower.contains("class ") || lower.contains("import ") { return true }
		if lower.contains("{") && lower.contains("}") { return true }
		if lower.contains("};") || lower.contains("->") { return true }
		return false
	}
}
