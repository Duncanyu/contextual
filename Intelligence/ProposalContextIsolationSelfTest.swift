import Foundation

/// Phase 4P self-test for proposal context isolation, stale-entity rejection,
/// and planner-recovery validation consistency.
///
/// Run with: `CONTEXTUAL_RUN_PROPOSAL_CONTEXT_ISOLATION_SELFTEST=1`
///
/// Deterministic — no AppKit, no network, no AI calls.
enum ProposalContextIsolationSelfTest {

	static func run() -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[ProposalContextIsolationSelfTest] FAIL \(name)")
			}
		}

		// MARK: 1 — Huge unrelated clipboard excluded from planner input

		do {
			let snapshot = makeSnapshot(
				app: "Firefox",
				bundle: "org.mozilla.firefox",
				window: "Anker Laptop Power Bank - Amazon",
				selectedText: nil,
				ocr: "Anker Prime 27,650mAh 250W Power Bank\n$129.99\n4.7 out of 5 stars",
				clipboard: "AGENTS.md\n# Coding Rules for Context-Aware macOS Assistant\nDo not build outside the current ticket."
			)
			let isolated = ProposalContextIsolationGate.isolate(
				snapshot: snapshot,
				clipboardSuppressionReason: .huge_clipboard_unrelated
			)
			check("clipboard_excluded_huge_unrelated",
				  isolated.excludedSources.contains(where: { $0.name == "clipboard" && $0.reason == "huge_clipboard_unrelated" }))
			check("planner_input_sources_no_clipboard",
				  !isolated.includedSources.contains("clipboard"))
			check("ocr_kept_for_real_product",
				  isolated.ocrExcerpt?.contains("Anker Prime") == true)
		}

		// MARK: 2 — Dev artifact OCR is suppressed (Firefox window, but OCR contains .swift / AppDelegate)

		do {
			let snapshot = makeSnapshot(
				app: "Firefox",
				bundle: "org.mozilla.firefox",
				window: "Anker Laptop Power Bank - Amazon",
				selectedText: nil,
				ocr: "AppDelegate.swift\nimport AppKit\nclass AppDelegate: NSObject {}",
				clipboard: nil
			)
			let isolated = ProposalContextIsolationGate.isolate(snapshot: snapshot)
			check("ocr_dev_artifact_suppressed",
				  isolated.excludedSources.contains(where: { $0.name == "ocr_excerpt" && $0.reason == "dev_artifact_text" }))
			check("ocr_dev_artifact_not_in_groundingText",
				  !isolated.groundingText.lowercased().contains("appdelegate"))
		}

		// MARK: 3 — In Xcode itself, .swift OCR is admitted (it IS the active context)

		do {
			let snapshot = makeSnapshot(
				app: "Xcode",
				bundle: "com.apple.dt.Xcode",
				window: "AppDelegate.swift — Contextual",
				selectedText: nil,
				ocr: "AppDelegate.swift\nimport AppKit\nclass AppDelegate: NSObject {}",
				clipboard: nil
			)
			let isolated = ProposalContextIsolationGate.isolate(snapshot: snapshot)
			check("xcode_swift_ocr_kept",
				  isolated.ocrExcerpt?.contains("AppDelegate") == true)
		}

		// MARK: 4 — Stale-context-entity reason: "Review AGENTS.md File" on Firefox product page

		do {
			let snapshot = makeSnapshot(
				app: "Firefox",
				bundle: "org.mozilla.firefox",
				window: "Anker Laptop Power Bank - Amazon",
				selectedText: nil,
				ocr: "Anker Prime 27,650mAh 250W Power Bank\n$129.99",
				clipboard: nil
			)
			let isolated = ProposalContextIsolationGate.isolate(snapshot: snapshot)
			let reason = ProposalContextIsolationGate.staleContextEntityReason(
				title: "Review AGENTS.md File",
				isolated: isolated
			)
			check("agents_md_title_rejected_as_stale", reason != nil)
		}

		// MARK: 5 — Validator rejects "Review AGENTS.md File" with reason=stale_context_entity

		do {
			let snapshot = makeSnapshot(
				app: "Firefox",
				bundle: "org.mozilla.firefox",
				window: "Anker Laptop Power Bank - Amazon",
				selectedText: nil,
				ocr: "Anker Prime 27,650mAh 250W Power Bank\n$129.99",
				clipboard: nil
			)
			let isolated = ProposalContextIsolationGate.isolate(snapshot: snapshot)
			let result = ProposalCapabilityValidator.validate(
				title: "Review AGENTS.md File",
				goal: "Review the file",
				isolated: isolated,
				stage: "early"
			)
			check("validator_rejects_agents_md", result.accepted == false)
			check("validator_reason_stale_context_entity", result.reason == "stale_context_entity")
		}

		// MARK: 6 — Validator still rejects unsafe verbs

		do {
			let snapshot = makeSnapshot(
				app: "Firefox",
				bundle: "org.mozilla.firefox",
				window: "Anker Laptop Power Bank - Amazon",
				selectedText: nil,
				ocr: "Anker Prime 27,650mAh 250W Power Bank",
				clipboard: nil
			)
			let isolated = ProposalContextIsolationGate.isolate(snapshot: snapshot)
			let result = ProposalCapabilityValidator.validate(
				title: "Purchase Anker Prime USB C Charger",
				goal: "Buy this charger",
				isolated: isolated,
				stage: "early"
			)
			check("validator_rejects_purchase", result.accepted == false)
			check("validator_reason_unsupported_capability", result.reason == "unsupported_capability")
		}

		// MARK: 7 — Validator accepts a genuinely-grounded title on the active page

		do {
			let snapshot = makeSnapshot(
				app: "Firefox",
				bundle: "org.mozilla.firefox",
				window: "Anker Laptop Power Bank - Amazon",
				selectedText: nil,
				ocr: "Anker Prime 27,650mAh 250W Power Bank\n$129.99",
				clipboard: nil
			)
			let isolated = ProposalContextIsolationGate.isolate(snapshot: snapshot)
			let result = ProposalCapabilityValidator.validate(
				title: "Summarize Anker Prime Power Bank details",
				goal: "Summarize this product",
				isolated: isolated,
				stage: "early"
			)
			check("validator_accepts_grounded_title", result.accepted)
		}

		// MARK: 8 — Zero-overlap title rejected even without dev-artifact tokens

		do {
			let snapshot = makeSnapshot(
				app: "Firefox",
				bundle: "org.mozilla.firefox",
				window: "Anker Laptop Power Bank - Amazon",
				selectedText: nil,
				ocr: "Anker Prime 27,650mAh 250W Power Bank",
				clipboard: nil
			)
			let isolated = ProposalContextIsolationGate.isolate(snapshot: snapshot)
			let result = ProposalCapabilityValidator.validate(
				title: "Summarize wikipedia astronomy section",
				goal: "Summarize",
				isolated: isolated,
				stage: "early"
			)
			check("validator_rejects_zero_overlap_title", result.accepted == false)
		}

		// MARK: 9 — Consistent stage label: early + activation use same isolation

		do {
			let snapshot = makeSnapshot(
				app: "Firefox",
				bundle: "org.mozilla.firefox",
				window: "Anker Laptop Power Bank - Amazon",
				selectedText: nil,
				ocr: "Anker Prime 27,650mAh 250W Power Bank",
				clipboard: nil
			)
			let isolated = ProposalContextIsolationGate.isolate(snapshot: snapshot)
			let early = ProposalCapabilityValidator.validate(
				title: "Review AGENTS.md File",
				goal: "Review",
				isolated: isolated,
				stage: "early"
			)
			let activation = ProposalCapabilityValidator.validate(
				title: "Review AGENTS.md File",
				goal: "Review",
				isolated: isolated,
				stage: "activation"
			)
			check("validator_consistent_early_eq_activation",
				  early.accepted == activation.accepted && early.reason == activation.reason)
		}

		// MARK: 10 — Recent_changes carrying clipboard-derived text is excluded

		do {
			let snapshot = makeSnapshot(
				app: "Firefox",
				bundle: "org.mozilla.firefox",
				window: "Anker Laptop Power Bank - Amazon",
				selectedText: nil,
				ocr: "Anker Prime 27,650mAh 250W Power Bank",
				clipboard: nil
			)
			let isolated = ProposalContextIsolationGate.isolate(
				snapshot: snapshot,
				situationalRecentChanges: "Edited AppDelegate.swift\nCommitted implementation_plan.md"
			)
			check("recent_changes_dev_artifact_excluded",
				  isolated.excludedSources.contains(where: { $0.name == "recent_changes" }))
			check("recent_changes_not_in_groundingText",
				  !isolated.groundingText.lowercased().contains("appdelegate"))
		}

		// MARK: 11 — Snapshot clipboard text still present → gate excludes it as pipeline-suppressed

		do {
			let snapshot = makeSnapshot(
				app: "Firefox",
				bundle: "org.mozilla.firefox",
				window: "Anker Laptop Power Bank - Amazon",
				selectedText: nil,
				ocr: "Anker Prime 27,650mAh 250W Power Bank",
				clipboard: "stale clipboard text"
			)
			let isolated = ProposalContextIsolationGate.isolate(snapshot: snapshot) // no explicit reason
			check("clipboard_excluded_pipeline_suppressed",
				  isolated.excludedSources.contains(where: { $0.name == "clipboard" }))
		}

		let ok = failures.isEmpty
		print("[ProposalContextIsolationSelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}

	// MARK: - Snapshot builder

	private static func makeSnapshot(
		app: String,
		bundle: String,
		window: String,
		selectedText: String?,
		ocr: String?,
		clipboard: String?
	) -> CanonicalGeneratedExecutionContextSnapshot {
		CanonicalGeneratedExecutionContextSnapshot(
			activeApp: app,
			windowTitle: window,
			bundleIdentifier: bundle,
			inferredWorkflow: .browsing,
			selectedText: selectedText,
			clipboardText: clipboard,
			recentOCRExcerpt: ocr,
			contextSummary: nil,
			workflowConfidence: 0.8,
			freshnessScore: 0.9
		)
	}
}
