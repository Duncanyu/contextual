import Foundation

/// Bundled metadata-only checks for T16.3 workflow-sensitive ordering (synthetic + existing self-tests).
@MainActor
enum WorkflowActionOrderingSelfTest {
	static func run() -> Bool {
		print("[WorkflowActionOrdering] selftest starting")
		let rankerOK = WorkflowAwareProposalRanker.runSelfTest()
		let dynamicUXOK = DynamicActionDisplayBuilder.runSelfTest()
		let visibleOK = VisibleGeneratedActionPanelAdapter.runSelfTest()
		let proposalCtxOK = ProposalContextSummaryBuilder.runSelfTest()
		let ok = rankerOK && dynamicUXOK && visibleOK && proposalCtxOK
		print("[WorkflowActionOrdering] bundled ok=\(ok) ranker=\(rankerOK) dynamic_ux=\(dynamicUXOK) visible_panel=\(visibleOK) proposal_ctx=\(proposalCtxOK)")
		return ok
	}
}
