import Foundation

/// T18.3.3 situational context synthesizer tests (not wired to app launch).
enum SituationalContextSynthesizerSelfTest {

	static func run() -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let now = Date()

		func browserSnap(title: String) -> CanonicalGeneratedExecutionContextSnapshot {
			CanonicalGeneratedExecutionContextSnapshot(
				activeApp: "Firefox",
				windowTitle: title,
				bundleIdentifier: "org.mozilla.firefox",
				inferredWorkflow: .unknown,
				generatedAt: now,
				freshnessScore: 0.52,
				packetIsStale: false
			)
		}

		let youtube = SituationalContextSynthesizer.synthesize(from: browserSnap(title: "Swift Concurrency — YouTube — Mozilla Firefox"))
		check("youtube_metadata_only", youtube.primaryAvailableSource == .metadataOnly)
		check("youtube_not_stale_failure", !youtube.missingContextReasons.contains("stale_context"))
		check("youtube_has_no_fused_reason", youtube.missingContextReasons.contains("no_fused_packet"))
		check(
			"youtube_perception_recommended",
			youtube.perceptionRecommendation == .recommended || youtube.perceptionRecommendation == .useful
		)
		check("youtube_summary_safe", !youtube.situationalSummary.lowercased().contains("http"))

		let reddit = SituationalContextSynthesizer.synthesize(from: browserSnap(title: "r/macapps — Reddit — Mozilla Firefox"))
		check("reddit_metadata_only", reddit.primaryAvailableSource == .metadataOnly)
		check("reddit_browsing_workflow", reddit.inferredWorkflow == .browsing)

		let jobBank = SituationalContextSynthesizer.synthesize(
			from: browserSnap(title: "Search results - Job Bank - Government of Canada")
		)
		check("job_bank_research", jobBank.inferredWorkflow == .research)
		check("job_bank_guidance_metadata", jobBank.assistantGuidance.contains(where: { $0.contains("metadata") }))

		let selectionWins = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Notes",
			inferredWorkflow: .writing,
			selectedText: "fresh selection text",
			clipboardText: "old clipboard payload from prior app",
			generatedAt: now,
			freshnessScore: 0.7,
			sourceMetadata: CanonicalExecutionSourceMetadata(
				selectedTextCapturedAt: now,
				clipboardCapturedAt: now.addingTimeInterval(-400),
				lastSourceTrigger: LastSourceTrigger.selectedTextChanged.rawValue
			)
		)
		let ranked = SituationalContextSynthesizer.synthesize(from: selectionWins)
		check("selection_outranks_clipboard", ranked.primaryAvailableSource == .selectedText)
		check("clipboard_suppressed_or_stale", ranked.clipboardSignal.availability != .available || ranked.clipboardSignal.availability == .suppressed)

		let staleClipSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Xcode",
			windowTitle: "AppDelegate.swift",
			bundleIdentifier: "com.apple.dt.Xcode",
			inferredWorkflow: .debugging,
			clipboardText: "unrelated huge clip",
			generatedAt: now,
			freshnessScore: 0.55,
			sourceMetadata: CanonicalExecutionSourceMetadata(
				clipboardCapturedAt: now.addingTimeInterval(-500),
				lastSourceTrigger: LastSourceTrigger.activeAppChanged.rawValue,
				fusedPrimarySource: "selected_text"
			),
			packetIsStale: false
		)
		let staleClip = SituationalContextSynthesizer.synthesize(from: staleClipSnap)
		check("stale_clipboard_suppressed", staleClip.clipboardSignal.availability == .suppressed)
		check(
			"guidance_no_clipboard",
			staleClip.assistantGuidance.contains(where: { $0.lowercased().contains("do not use clipboard") })
		)

		let noFused = SituationalContextSynthesizer.synthesize(from: browserSnap(title: "Example — Firefox"))
		check("no_fused_lists_reason", noFused.missingContextReasons.contains("no_fused_packet"))
		check("no_fused_still_metadata", noFused.primaryAvailableSource == .metadataOnly)

		let xcode = SituationalContextSynthesizer.synthesize(
			from: CanonicalGeneratedExecutionContextSnapshot(
				activeApp: "Xcode",
				windowTitle: "Contextual — AppDelegate.swift",
				bundleIdentifier: "com.apple.dt.Xcode",
				inferredWorkflow: .debugging,
				selectedText: "func updateAvailableActions() async {",
				workflowConfidence: 0.72,
				generatedAt: now,
				freshnessScore: 0.8,
				sourceMetadata: CanonicalExecutionSourceMetadata(
					selectedTextCapturedAt: now,
					lastSourceTrigger: LastSourceTrigger.selectedTextChanged.rawValue
				)
			)
		)
		check("xcode_selection_primary", xcode.primaryAvailableSource == .selectedText)
		check(
			"xcode_debug_guidance",
			xcode.assistantGuidance.contains(where: { $0.lowercased().contains("debug") || $0.lowercased().contains("code") })
		)

		let snap = browserSnap(title: "Talk — YouTube")
		let a = SituationalContextSynthesizer.synthesize(from: snap, referenceTime: now)
		let b = SituationalContextSynthesizer.synthesize(from: snap, referenceTime: now)
		check("deterministic_summary", a.situationalSummary == b.situationalSummary)
		check("deterministic_primary", a.primaryAvailableSource == b.primaryAvailableSource)

		let prompt = DynamicGeneratedProposalPromptBuilder.build(
			snapshot: snap,
			existingStaticActions: [],
			reusableCount: 0,
			history: nil,
			budget: .conservative,
			situational: a
		)
		check("prompt_includes_situational", prompt.contains("situational_context=provided"))
		check("prompt_includes_guidance", prompt.contains("assistant_guidance="))
		check("prompt_includes_summary", prompt.contains(a.situationalSummary))

		let promptWithout = DynamicGeneratedProposalPromptBuilder.build(
			snapshot: snap,
			existingStaticActions: [],
			reusableCount: 0,
			history: nil,
			budget: .conservative,
			situational: nil
		)
		check("prompt_without_situational", promptWithout.contains("situational_context=not_provided"))

		let staleFusedSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Firefox",
			windowTitle: "Tutorial — YouTube",
			bundleIdentifier: "org.mozilla.firefox",
			inferredWorkflow: .unknown,
			generatedAt: now,
			freshnessScore: 0.2,
			fusedPacketId: UUID(),
			packetIsStale: true
		)
		let staleFusedSituational = SituationalContextSynthesizer.synthesize(from: staleFusedSnap)
		check(
			"stale_fused_still_synthesizes",
			staleFusedSituational.primaryAvailableSource == .metadataOnly
				|| staleFusedSituational.primaryAvailableSource == .workflowApp
		)
		check(
			"stale_fused_not_total_block",
			!staleFusedSituational.assistantGuidance.isEmpty
		)

		let ok = failures.isEmpty
		print("[SituationalContext] selftest ok=\(ok) failures=\(failures.joined(separator: ";"))")
		return ok
	}
}
