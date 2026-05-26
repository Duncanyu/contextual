import Foundation

/// Phase 4R self-test — Strong context anchor preservation.
///
/// Run with: `CONTEXTUAL_RUN_STRONG_CONTEXT_ANCHOR_SELFTEST=1`
///
/// Deterministic — no AppKit, no network, no model calls.
enum StrongContextAnchorSelfTest {

	static func run() -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[StrongContextAnchorSelfTest] FAIL \(name)")
			}
		}

		let now = Date()
		let bundle = "org.mozilla.firefox"

		// MARK: 1) Strong context → shouldStore

		do {
			let title = "Anker Laptop Charger 140W MAX USB C Charger 4-Port GaN"
			let ocr = String(repeating: "Anker 140W GaN 4-Port USB-C Charger. ", count: 10) // >200 chars
			let decision = StrongContextAnchorHeuristic.evaluate(
				now: now,
				currentTitle: title,
				currentOCR: ocr,
				currentWorkflow: .browsing,
				currentBundleId: bundle,
				anchor: nil
			)
			check("strong_context_should_store", decision.shouldStore && !decision.shouldPreserve)
		}

		// MARK: 2) Weak transient title + recent strong anchor → shouldPreserve

		do {
			let anchor = StrongContextAnchor(
				appName: "Firefox",
				bundleIdentifier: bundle,
				windowTitle: "Anker Laptop Charger 140W MAX USB C Charger 4-Port GaN",
				ocrExcerpt: "Anker Prime 140W GaN Charger $76 4-Port",
				axExcerpt: nil,
				workflow: .browsing,
				storedAt: now.addingTimeInterval(-5)
			)
			let decision = StrongContextAnchorHeuristic.evaluate(
				now: now,
				currentTitle: "Duncanyu (Duncan Yu)",
				currentOCR: "import Foundation\nclass Foo {}",
				currentWorkflow: .browsing,
				currentBundleId: bundle,
				anchor: anchor
			)
			check("weak_title_should_preserve", !decision.shouldStore && decision.shouldPreserve)
		}

		// MARK: 3) Expired anchor → no preserve

		do {
			let anchor = StrongContextAnchor(
				appName: "Firefox",
				bundleIdentifier: bundle,
				windowTitle: "Anker Laptop Charger 140W MAX USB C Charger 4-Port GaN",
				ocrExcerpt: "Anker Prime 140W GaN Charger $76 4-Port",
				axExcerpt: nil,
				workflow: .browsing,
				storedAt: now.addingTimeInterval(-(StrongContextAnchor.ttlSeconds + 2))
			)
			let decision = StrongContextAnchorHeuristic.evaluate(
				now: now,
				currentTitle: "Duncanyu (Duncan Yu)",
				currentOCR: nil,
				currentWorkflow: .browsing,
				currentBundleId: bundle,
				anchor: anchor
			)
			check("expired_anchor_not_preserved", !decision.shouldStore && !decision.shouldPreserve && decision.reason == "anchor_expired")
		}

		// MARK: 4) Profile/settings proposal rejected when context lacks family tokens

		do {
			let isolated = IsolatedProposalContext(
				appName: "Firefox",
				bundleIdentifier: bundle,
				windowTitle: "Anker Laptop Charger 140W MAX USB C Charger 4-Port GaN",
				selectedText: nil,
				ocrExcerpt: "Anker Prime 140W 4-Port GaN Charger",
				axExcerpt: nil,
				recentChanges: nil,
				includedSources: ["window_title", "ocr_excerpt"],
				excludedSources: []
			)
			let res = ProposalCapabilityValidator.validate(
				title: "Edit Profile Settings",
				goal: "Edit profile",
				isolated: isolated,
				stage: "early"
			)
			check("profile_settings_rejected", !res.accepted && res.reason == "context_family_mismatch")
		}

		// MARK: 5) Profile/settings proposal allowed when context supports it

		do {
			let isolated = IsolatedProposalContext(
				appName: "Firefox",
				bundleIdentifier: bundle,
				windowTitle: "Edit profile settings",
				selectedText: nil,
				ocrExcerpt: "Profile settings account preferences",
				axExcerpt: nil,
				recentChanges: nil,
				includedSources: ["window_title", "ocr_excerpt"],
				excludedSources: []
			)
			let res = ProposalCapabilityValidator.validate(
				title: "Edit Profile Settings",
				goal: "Edit profile",
				isolated: isolated,
				stage: "early"
			)
			check("profile_settings_allowed_when_grounded", res.accepted)
		}

		let ok = failures.isEmpty
		print("[StrongContextAnchorSelfTest] ok=\(ok) failures=\(failures.count)")
		return ok
	}
}

