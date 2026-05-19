import Foundation

/// T18.3.3B clipboard primary-source tests (not wired to app launch).
enum SituationalClipboardRelevanceSelfTest {

	static func run() -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let now = Date()

		func firefoxSnap(title: String, clipboard: String?, trigger: LastSourceTrigger) -> CanonicalGeneratedExecutionContextSnapshot {
			CanonicalGeneratedExecutionContextSnapshot(
				activeApp: "Firefox",
				windowTitle: title,
				bundleIdentifier: "org.mozilla.firefox",
				inferredWorkflow: .unknown,
				clipboardText: clipboard,
				generatedAt: now,
				freshnessScore: 0.52,
				sourceMetadata: CanonicalExecutionSourceMetadata(
					clipboardCapturedAt: now.addingTimeInterval(-120),
					contextUpdatedAt: now,
					lastSourceTrigger: trigger.rawValue
				)
			)
		}

		let youtube = SituationalContextSynthesizer.synthesize(
			from: firefoxSnap(
				title: "Swift Concurrency — YouTube — Mozilla Firefox",
				clipboard: "old unrelated clip from prior app with lots of text content",
				trigger: .windowTitleChanged
			)
		)
		check("firefox_primary_metadata", youtube.primaryAvailableSource == .metadataOnly)
		check("firefox_clipboard_suppressed", youtube.clipboardSignal.availability == .suppressed)
		check("firefox_clipboard_not_primary", youtube.clipboardSignal.canBePrimary == false)

		let xcode = SituationalContextSynthesizer.synthesize(
			from: CanonicalGeneratedExecutionContextSnapshot(
				activeApp: "Xcode",
				windowTitle: "AppDelegate.swift",
				bundleIdentifier: "com.apple.dt.Xcode",
				inferredWorkflow: .debugging,
				clipboardText: "stale clipboard from notes",
				generatedAt: now,
				freshnessScore: 0.7,
				sourceMetadata: CanonicalExecutionSourceMetadata(
					clipboardCapturedAt: now.addingTimeInterval(-300),
					contextUpdatedAt: now,
					lastSourceTrigger: LastSourceTrigger.windowTitleChanged.rawValue
				)
			)
		)
		check("xcode_metadata_primary", xcode.primaryAvailableSource == .metadataOnly)

		let freshSelection = SituationalContextSynthesizer.synthesize(
			from: CanonicalGeneratedExecutionContextSnapshot(
				activeApp: "Xcode",
				windowTitle: "Editor.swift",
				inferredWorkflow: .debugging,
				selectedText: "func foo() {}",
				clipboardText: "noise",
				generatedAt: now,
				freshnessScore: 0.8,
				sourceMetadata: CanonicalExecutionSourceMetadata(
					selectedTextCapturedAt: now,
					clipboardCapturedAt: now.addingTimeInterval(-200),
					lastSourceTrigger: LastSourceTrigger.selectedTextChanged.rawValue
				)
			)
		)
		check("selection_primary", freshSelection.primaryAvailableSource == .selectedText)

		let freshClip = SituationalContextSynthesizer.synthesize(
			from: CanonicalGeneratedExecutionContextSnapshot(
				activeApp: "Notes",
				windowTitle: "Meeting notes",
				clipboardText: String(repeating: "a", count: 80),
				generatedAt: now,
				freshnessScore: 0.75,
				sourceMetadata: CanonicalExecutionSourceMetadata(
					clipboardCapturedAt: now,
					contextUpdatedAt: now,
					lastSourceTrigger: LastSourceTrigger.clipboardTextChanged.rawValue
				)
			)
		)
		check("fresh_clipboard_can_primary", freshClip.clipboardSignal.canBePrimary)
		check("fresh_clipboard_primary", freshClip.primaryAvailableSource == .clipboard)

		let snap = firefoxSnap(title: "Page — Firefox", clipboard: "x", trigger: .windowTitleChanged)
		let prompt = DynamicGeneratedProposalPromptBuilder.build(
			snapshot: snap,
			existingStaticActions: [],
			reusableCount: 0,
			history: nil,
			budget: .conservative,
			situational: SituationalContextSynthesizer.synthesize(from: snap)
		)
		check("compact_prompt_under_budget", prompt.utf8.count <= DynamicGeneratedProposalPromptBuilder.compactPromptByteBudget)

		let ok = failures.isEmpty
		print("[SituationalClipboard] selftest ok=\(ok) failures=\(failures.joined(separator: ";"))")
		return ok
	}
}
