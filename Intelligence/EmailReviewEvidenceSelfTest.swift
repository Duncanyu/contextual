import Foundation

/// Phase 4P — Email/reviewing evidence family self-test.
///
/// Run with:
/// - `CONTEXTUAL_RUN_EMAIL_REVIEW_EVIDENCE_SELFTEST=1`
///
/// Deterministic — no AppKit, no network, no AI calls.
@MainActor
struct EmailReviewEvidenceSelfTest {

	static func run() async {
		print("[EmailReviewEvidenceSelfTest] starting...")

		testGmailInferenceUsesEmailFamily()
		testGmailDoesNotEmitProductEvidence()
		testEmailAnswerDoesNotUseProductVocabulary()
		testProductReviewStillUsesProductFamily()
		testOutlookInferenceUsesEmailFamily()

		print("[EmailReviewEvidenceSelfTest] finished. ok=true, failures=0")
		print("[EmailReviewEvidenceSelfTest] env selftest ok=true")
	}

	private static func testGmailInferenceUsesEmailFamily() {
		let goal = "Review Recent Emails in Gmail Inbox"
		let reqs = AgenticEvidenceRequirementsInferrer.infer(
			goal: goal,
			workflow: "reviewing",
			windowTitle: "Inbox - Gmail",
			evidenceObservations: [],
			semanticEntities: [],
			contextCategory: "org.mozilla.firefox"
		)
		check("gmail_requires_email_subject", reqs.contains(where: { $0.kind == .emailSubject }))
		check("gmail_requires_email_snippet", reqs.contains(where: { $0.kind == .emailSnippet }))
		check("gmail_does_not_require_product_title", !reqs.contains(where: { $0.kind == .productTitle }))
		check("gmail_does_not_require_specs", !reqs.contains(where: { $0.kind == .specs }))
	}

	private static func testGmailDoesNotEmitProductEvidence() {
		let observations = AgenticEvidenceExtractionBridge.extract(
			goal: "Review Recent Emails in Gmail Inbox",
			workflow: "reviewing",
			windowTitle: "Inbox - Gmail",
			ocrText: """
			Gmail
			Inbox
			mail.google.com
			Starred
			Sent
			Drafts
			""",
			axText: nil,
			graph: nil,
			semanticEntities: [],
			structuredFacts: [],
			comparisonTitles: []
		)
		check("gmail_observations_no_product_title", !observations.contains(where: { $0.kind == .productTitle }))
		check("gmail_observations_no_specs", !observations.contains(where: { $0.kind == .specs }))
		check("gmail_observations_no_price", !observations.contains(where: { $0.kind == .price }))
		check("gmail_observations_no_reviews", !observations.contains(where: { $0.kind == .reviewCount || $0.kind == .reviewText || $0.kind == .rating }))
	}

	private static func testEmailAnswerDoesNotUseProductVocabulary() {
		let reqs = AgenticEvidenceRequirementsInferrer.infer(
			goal: "Review Recent Emails in Gmail Inbox",
			workflow: "reviewing",
			windowTitle: "Inbox - Gmail",
			evidenceObservations: [],
			semanticEntities: [],
			contextCategory: "org.mozilla.firefox"
		)

		let state = AgenticEvidenceState(
			goal: "Review Recent Emails in Gmail Inbox",
			requirements: reqs,
			satisfied: [.inboxContext],
			missing: [.emailSubject, .emailSnippet],
			missingOptional: [],
			confidence: 0.25,
			shouldGatherMore: true,
			recommendedAction: .observe
		)

		let session = AgenticSessionState(
			planId: "test_plan",
			goal: "Review Recent Emails in Gmail Inbox",
			workflow: "reviewing",
			stepIndex: 1,
			maxSteps: 5,
			llmCallsUsed: 0,
			ocrCallsUsed: 0,
			scrollsUsed: 0,
			findsUsed: 0,
			maxScrolls: 2,
			maxFinds: 2,
			startedAt: Date(),
			observations: [
				AgenticObservation(
					stepIndex: 1,
					activeApp: "Firefox",
					windowTitle: "Inbox - Gmail",
					contextSummary: nil,
					selectedText: nil,
					ocrExcerpt: "Gmail Inbox",
					quality: .weak,
					freshnessScore: 0.85,
					observedAt: Date(),
					sources: ["window_title", "ocr_excerpt"],
					isPostControlObservation: false,
					snapshotID: UUID(),
					previousSnapshotID: nil,
					textHash: nil
				),
			],
			extractedFacts: [],
			finalAnswer: nil,
			stopReason: .partial_evidence_budget_exhausted,
			actionsExecuted: [],
			forceObserveNext: false,
			lastActionWasControl: false,
			blockedActions: [],
			controlDecisionLog: [],
			ineffectiveControlCount: 0,
			failedControlActions: [],
			worldStateTransitions: [],
			discoveredEntities: [],
			lastObservationSnapshotID: nil,
			lastObservationTextHash: nil,
			screenStateGraph: nil,
			groundedTargets: [],
			primaryGroundedTarget: nil,
			semanticEntities: [],
			structuredFacts: [],
			semanticReadiness: nil,
			evidenceRequirements: reqs,
			evidenceState: state,
			evidenceObservations: [
				AgenticEvidenceObservation(
					id: "wt_inbox",
					kind: .inboxContext,
					text: "inbox_context",
					normalized: "inbox_context",
					confidence: 0.55,
					source: .windowTitle,
					reason: "email_window_title"
				),
			]
		)

		let runtime = AgenticRuntime()
		let answer = runtime.buildPremiumAnswerTestBridge(session: session)
		check("email_answer_mentions_inbox", answer.lowercased().contains("inbox") || answer.lowercased().contains("app/page"))
		check("email_answer_no_product_label", !answer.contains("Product:"))
		check("email_answer_no_specs_label", !answer.contains("Specs:"))
		check("email_answer_no_reviews_label", !answer.contains("Reviews:"))
	}

	private static func testProductReviewStillUsesProductFamily() {
		let goal = "Review this charger"
		let reqs = AgenticEvidenceRequirementsInferrer.infer(
			goal: goal,
			workflow: "browsing",
			windowTitle: "UGREEN 100W 5-Port GaN Charger - Firefox",
			evidenceObservations: [],
			semanticEntities: [],
			contextCategory: "org.mozilla.firefox"
		)
		check("product_review_requires_product_title", reqs.contains(where: { $0.kind == .productTitle }))
		check("product_review_requires_specs", reqs.contains(where: { $0.kind == .specs }))
	}

	private static func testOutlookInferenceUsesEmailFamily() {
		let goal = "Review recent emails"
		let reqs = AgenticEvidenceRequirementsInferrer.infer(
			goal: goal,
			workflow: "reviewing",
			windowTitle: "Inbox - Outlook",
			evidenceObservations: [],
			semanticEntities: [],
			contextCategory: "com.microsoft.Outlook"
		)
		check("outlook_requires_email_subject", reqs.contains(where: { $0.kind == .emailSubject }))
		check("outlook_no_product_title", !reqs.contains(where: { $0.kind == .productTitle }))
	}

	private static func check(_ name: String, _ condition: Bool) {
		if !condition {
			print("[EmailReviewEvidenceSelfTest] FAIL: \(name)")
			fatalError("[EmailReviewEvidenceSelfTest] test failed: \(name)")
		} else {
			print("[EmailReviewEvidenceSelfTest] PASS: \(name)")
		}
	}
}
