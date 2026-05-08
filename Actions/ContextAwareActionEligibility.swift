import Foundation

struct ActionEligibilityDecision: Equatable, Sendable {
	let eligibleActionIds: [String]
	let reasonCodes: [String]
	let debugSummary: [String: String]
}

/// Context-aware eligibility + ordering for actions (no execution, no UI).
/// Uses canonical fused metadata when present; otherwise preserves existing behavior.
enum ContextAwareActionEligibility {
	static func evaluate(
		currentCandidateActionIds: [String],
		triggerType: TriggerType,
		context: ContextModel,
		contextType: ContextType,
		features: ContextFeatures,
		fused: FusedContextPacket?
	) -> ActionEligibilityDecision {
		let base = uniquePreserveOrder(currentCandidateActionIds)
		guard !base.isEmpty else {
			return ActionEligibilityDecision(eligibleActionIds: [], reasonCodes: ["no_candidates"], debugSummary: ["count": "0"])
		}

		// Strong selected text should preserve base actions (no removals from rich context).
		let strongSelection = context.selectedTextAvailable && context.selectedTextLength >= 30
		if strongSelection {
			let ordered = reorder(base, prefer: preferredOrder(contextType: contextType, features: features, fused: fused))
			return ActionEligibilityDecision(
				eligibleActionIds: ordered,
				reasonCodes: ["strong_selection_preserved"],
				debugSummary: ["count": "\(ordered.count)"]
			)
		}

		guard let fused else {
			return ActionEligibilityDecision(eligibleActionIds: base, reasonCodes: ["no_rich_context"], debugSummary: ["count": "\(base.count)"])
		}

		if fused.isStale || fused.freshnessScore < 0.30 || fused.confidence < 0.45 {
			return ActionEligibilityDecision(eligibleActionIds: base, reasonCodes: ["rich_context_ignored_stale"], debugSummary: ["count": "\(base.count)"])
		}

		let isManual = triggerType == .manualInvocation

		let kinds = Set(fused.visualKinds)
		let hints = Set(fused.uiStructureHints)

		let isEditorLike = kinds.contains(.editor) || hints.contains("ax_editor_like") || hints.contains("visual_monospace_region") || contextType == .code
		let isTerminalLike = kinds.contains(.terminal) || features.isLikelyLog || contextType == .errorLog
		let isDialogLike = kinds.contains(.dialog) || hints.contains("visual_dialog_like")
		let isArticleLike = kinds.contains(.article) || kinds.contains(.browser) || contextType == .article || contextType == .notes
		let isFormLike = kinds.contains(.form) || hints.contains("ax_form_like")

		// No text but rich context exists: do not invent text actions. Keep base only.
		let hasAnyText = context.selectedTextAvailable || context.clipboardTextAvailable || context.screenOCRAvailable || fused.textAvailability
		if !hasAnyText {
			return ActionEligibilityDecision(eligibleActionIds: base, reasonCodes: ["rich_context_no_text_safe"], debugSummary: ["count": "\(base.count)"])
		}

		var out = base
		var reasons: [String] = []

		// Form-heavy weak/no text: limit automatic actions conservatively (do not affect manual invocation).
		if isFormLike && !isManual {
			let keep = ["explain_text", "summarize_text", "analyze_screen"]
			out = out.filter { keep.contains($0) }
			reasons.append("form_actions_limited")
		}

		// Ensure explain stays eligible for editor/terminal/dialog contexts if present in base.
		if (isEditorLike || isTerminalLike || isDialogLike), base.contains("explain_text") {
			reasons.append(isTerminalLike ? "terminal_error_actions" : (isEditorLike ? "editor_actions" : "dialog_explain"))
		}

		if isArticleLike {
			reasons.append("reading_actions")
		}

		out = reorder(out, prefer: preferredOrder(contextType: contextType, features: features, fused: fused))

		if reasons.isEmpty {
			reasons.append("no_rich_adjustment")
		}

		return ActionEligibilityDecision(
			eligibleActionIds: out,
			reasonCodes: reasons,
			debugSummary: ["count": "\(out.count)"]
		)
	}

	private static func preferredOrder(contextType: ContextType, features: ContextFeatures, fused: FusedContextPacket?) -> [String] {
		let kinds = Set(fused?.visualKinds ?? [])
		let hints = Set(fused?.uiStructureHints ?? [])
		let editorLike = kinds.contains(.editor) || hints.contains("ax_editor_like") || hints.contains("visual_monospace_region") || contextType == .code
		let terminalLike = kinds.contains(.terminal) || features.isLikelyLog || contextType == .errorLog
		let articleLike = kinds.contains(.article) || kinds.contains(.browser) || contextType == .article || contextType == .notes

		if terminalLike || editorLike {
			return ["explain_text", "summarize_text", "rewrite_text", "analyze_screen"]
		}
		if articleLike {
			return ["summarize_text", "explain_text", "rewrite_text", "analyze_screen"]
		}
		return ["explain_text", "summarize_text", "rewrite_text", "analyze_screen"]
	}

	private static func reorder(_ ids: [String], prefer: [String]) -> [String] {
		let set = Set(ids)
		var out: [String] = []
		out.reserveCapacity(ids.count)
		for p in prefer where set.contains(p) {
			out.append(p)
		}
		for id in ids where !out.contains(id) {
			out.append(id)
		}
		return out
	}

	private static func uniquePreserveOrder(_ ids: [String]) -> [String] {
		var seen = Set<String>()
		var out: [String] = []
		out.reserveCapacity(ids.count)
		for id in ids where seen.insert(id).inserted {
			out.append(id)
		}
		return out
	}

	static func selfTest() -> Bool {
		print("[ActionEligibility] selftest starting")

		let candidates = ["summarize_text", "explain_text", "rewrite_text", "analyze_screen"]

		func fused(
			kinds: [VisualUIKind],
			hints: [String] = [],
			textAvailable: Bool = true,
			stale: Bool = false,
			conf: Double = 0.75,
			fresh: Double = 0.75
		) -> FusedContextPacket {
			FusedContextPacket(
				id: UUID(),
				createdAt: Date(),
				primarySource: .selectedText,
				availableSources: [.activeApp, .visualDescriptor],
				staleSources: [],
				appName: "TestApp",
				bundleIdentifier: "test.bundle",
				windowTitleAvailable: false,
				primaryTextSource: .selectedText,
				textAvailability: textAvailable,
				textLength: 120,
				lineCount: 6,
				hasSelectedText: true,
				hasClipboardText: false,
				hasOCRText: false,
				hasAXText: false,
				hasWindowSnapshot: false,
				hasVisualDescriptor: true,
				hasTypingActivity: false,
				hasPointerActivity: false,
				visualKinds: kinds,
				uiStructureHints: hints,
				typingState: nil,
				pointerState: nil,
				confidence: conf,
				freshnessScore: fresh,
				conflictScore: 0,
				isStale: stale,
				debugSummaryMetadata: ["selftest": "1"]
			)
		}

		// Strong selection preserves.
		var ctxSel = ContextModel()
		ctxSel.selectedTextAvailable = true
		ctxSel.selectedTextLength = 120
		let sel = evaluate(currentCandidateActionIds: candidates, triggerType: .selectedTextEligible, context: ctxSel, contextType: .code, features: FeatureExtractor.extract(from: "func foo() {}"), fused: fused(kinds: [.editor]))
		let selActions = sel.eligibleActionIds.joined(separator: ",")
		print("[ActionEligibility] selftest case=strong_selection reason=\(sel.reasonCodes.first ?? "nil") actions=\(selActions)")

		// Editor ensures explain first.
		var ctxWeak = ContextModel()
		ctxWeak.selectedTextAvailable = false
		ctxWeak.selectedTextLength = 0
		ctxWeak.clipboardTextAvailable = true
		ctxWeak.clipboardTextLength = 120
		let editor = evaluate(currentCandidateActionIds: candidates, triggerType: .clipboardTextEligible, context: ctxWeak, contextType: .code, features: FeatureExtractor.extract(from: "func foo() {}"), fused: fused(kinds: [.editor]))
		print("[ActionEligibility] selftest case=editor first=\(editor.eligibleActionIds.first ?? "nil")")

		// Article ensures summarize first.
		let article = evaluate(currentCandidateActionIds: candidates, triggerType: .clipboardTextEligible, context: ctxWeak, contextType: .article, features: FeatureExtractor.extract(from: String(repeating: "word ", count: 80)), fused: fused(kinds: [.article, .browser]))
		print("[ActionEligibility] selftest case=article first=\(article.eligibleActionIds.first ?? "nil")")

		// Form limits automatic for weak/no text.
		var ctxNoText = ContextModel()
		ctxNoText.selectedTextAvailable = false
		ctxNoText.selectedTextLength = 0
		ctxNoText.clipboardTextAvailable = false
		ctxNoText.clipboardTextLength = 0
		let form = evaluate(currentCandidateActionIds: candidates, triggerType: .clipboardTextEligible, context: ctxNoText, contextType: .random, features: FeatureExtractor.extract(from: "x"), fused: fused(kinds: [.form], hints: ["ax_form_like"]))
		let formActions = form.eligibleActionIds.joined(separator: ",")
		print("[ActionEligibility] selftest case=form actions=\(formActions) reason=\(form.reasonCodes.first ?? "nil")")

		// No text + rich context: do not invent actions (keep base).
		let noText = evaluate(
			currentCandidateActionIds: candidates,
			triggerType: .clipboardTextEligible,
			context: ctxNoText,
			contextType: .random,
			features: FeatureExtractor.extract(from: ""),
			fused: fused(kinds: [.editor], textAvailable: false)
		)
		print("[ActionEligibility] selftest case=no_text reason=\(noText.reasonCodes.first ?? "nil") actions=\(noText.eligibleActionIds.joined(separator: ","))")

		// Stale ignored.
		let stale = evaluate(currentCandidateActionIds: candidates, triggerType: .clipboardTextEligible, context: ctxWeak, contextType: .code, features: FeatureExtractor.extract(from: "func foo() {}"), fused: fused(kinds: [.editor], stale: true, conf: 0.2, fresh: 0.1))
		print("[ActionEligibility] selftest case=stale reason=\(stale.reasonCodes.first ?? "nil")")

		// Manual invocation not over-limited for form.
		let formManual = evaluate(currentCandidateActionIds: candidates, triggerType: .manualInvocation, context: ctxNoText, contextType: .random, features: FeatureExtractor.extract(from: "x"), fused: fused(kinds: [.form], hints: ["ax_form_like"]))
		let formManualActions = formManual.eligibleActionIds.joined(separator: ",")
		print("[ActionEligibility] selftest case=form_manual actions=\(formManualActions)")

		let ok = sel.reasonCodes.contains("strong_selection_preserved")
			&& editor.eligibleActionIds.first == "explain_text"
			&& article.eligibleActionIds.first == "summarize_text"
			&& form.reasonCodes.contains("form_actions_limited")
			&& noText.reasonCodes.contains("rich_context_no_text_safe")
			&& stale.reasonCodes.contains("rich_context_ignored_stale")
			&& formManual.eligibleActionIds.count == candidates.count

		print("[ActionEligibility] selftest finished ok=\(ok)")
		return ok
	}
}

