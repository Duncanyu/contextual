import Foundation

enum RichContextProposalSelfTest {
	static func run() -> Bool {
		print("[RichProposal] selftest starting")

		let baseScores: [ActionRelevanceScore] = [
			ActionRelevanceScore(actionId: "summarize_text", score: 0.70, reason: "base"),
			ActionRelevanceScore(actionId: "explain_text", score: 0.70, reason: "base"),
			ActionRelevanceScore(actionId: "rewrite_text", score: 0.70, reason: "base")
		]

		func fused(
			kinds: [VisualUIKind] = [],
			hints: [String] = [],
			typing: TypingState? = nil,
			pointer: PointerState? = nil,
			conf: Double = 0.75,
			fresh: Double = 0.75,
			stale: Bool = false,
			conflict: Double = 0.0
		) -> FusedContextPacket {
			FusedContextPacket(
				id: UUID(),
				createdAt: Date(),
				primarySource: .selectedText,
				availableSources: [.activeApp, .selectedText, .visualDescriptor],
				staleSources: [],
				appName: "TestApp",
				bundleIdentifier: "test.bundle",
				windowTitleAvailable: false,
				primaryTextSource: .selectedText,
				textAvailability: true,
				textLength: 120,
				lineCount: 6,
				hasSelectedText: true,
				hasClipboardText: false,
				hasOCRText: false,
				hasAXText: false,
				hasWindowSnapshot: false,
				hasVisualDescriptor: !kinds.isEmpty,
				hasTypingActivity: typing != nil,
				hasPointerActivity: pointer != nil,
				visualKinds: kinds,
				uiStructureHints: hints,
				typingState: typing,
				pointerState: pointer,
				confidence: conf,
				freshnessScore: fresh,
				conflictScore: conflict,
				isStale: stale,
				suppressedSources: [],
				supportingSources: [],
				arbitrationReasons: ["selftest"],
				debugSummaryMetadata: ["selftest": "1"]
			)
		}

		let ctxStrongSelection = ContextModel()
		var ctx = ctxStrongSelection
		ctx.selectedTextAvailable = true
		ctx.selectedTextLength = 120

		let editor = RichContextProposalAdjuster.adjust(
			relevance: baseScores,
			context: ctx,
			fused: fused(kinds: [.editor]),
			contextType: .code,
			features: FeatureExtractor.extract(from: "func foo() { return 1 }"),
			isManualInvocation: false
		)
		print("[RichProposal] selftest case=editor primary=\(editor.adjustedPrimaryActionId ?? "nil") reason=\(editor.reasonCodes.first ?? "nil")")

		let terminal = RichContextProposalAdjuster.adjust(
			relevance: baseScores,
			context: ctx,
			fused: fused(kinds: [.terminal]),
			contextType: .errorLog,
			features: FeatureExtractor.extract(from: "Error: exception stack trace"),
			isManualInvocation: false
		)
		print("[RichProposal] selftest case=terminal primary=\(terminal.adjustedPrimaryActionId ?? "nil") reason=\(terminal.reasonCodes.first ?? "nil")")

		let article = RichContextProposalAdjuster.adjust(
			relevance: baseScores,
			context: ctx,
			fused: fused(kinds: [.article, .browser]),
			contextType: .article,
			features: FeatureExtractor.extract(from: String(repeating: "word ", count: 80)),
			isManualInvocation: false
		)
		print("[RichProposal] selftest case=article primary=\(article.adjustedPrimaryActionId ?? "nil") reason=\(article.reasonCodes.first ?? "nil")")

		var weakCtx = ContextModel()
		weakCtx.selectedTextAvailable = false
		weakCtx.selectedTextLength = 0
		let formSuppress = RichContextProposalAdjuster.adjust(
			relevance: baseScores,
			context: weakCtx,
			fused: fused(kinds: [.form], hints: ["ax_form_like"], typing: .active, pointer: .interacting),
			contextType: .random,
			features: FeatureExtractor.extract(from: "x"),
			isManualInvocation: false
		)
		print("[RichProposal] selftest case=form suppress=\(formSuppress.shouldSuppressAutomaticProposal) reason=\(formSuppress.reasonCodes.first ?? "nil")")

		let staleIgnored = RichContextProposalAdjuster.adjust(
			relevance: baseScores,
			context: ctx,
			fused: fused(kinds: [.editor], conf: 0.30, fresh: 0.10, stale: true),
			contextType: .code,
			features: FeatureExtractor.extract(from: "func foo() {}"),
			isManualInvocation: false
		)
		let staleOk = staleIgnored.reasonCodes.contains("rich_context_ignored_stale")
		print("[RichProposal] selftest case=stale ignored=\(staleOk)")

		let manualNotSuppressed = RichContextProposalAdjuster.adjust(
			relevance: baseScores,
			context: weakCtx,
			fused: fused(kinds: [.form], hints: ["ax_form_like"], typing: .active, pointer: .interacting),
			contextType: .random,
			features: FeatureExtractor.extract(from: "x"),
			isManualInvocation: true
		)
		print("[RichProposal] selftest case=manual suppress=\(manualNotSuppressed.shouldSuppressAutomaticProposal)")

		let ok = (editor.adjustedPrimaryActionId == "explain_text")
			&& (terminal.adjustedPrimaryActionId == "explain_text")
			&& (article.adjustedPrimaryActionId == "summarize_text")
			&& (formSuppress.shouldSuppressAutomaticProposal == true)
			&& (staleIgnored.reasonCodes.contains("rich_context_ignored_stale"))
			&& (manualNotSuppressed.shouldSuppressAutomaticProposal == false)

		print("[RichProposal] selftest finished ok=\(ok)")
		return ok
	}
}

