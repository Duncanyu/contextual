import Foundation

/// T18.3.10A self-tests for title quality + logging flags (not wired to app launch).
enum GeneratedProposalTitleSynthesizerSelfTest {

	static func run() -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		check("trace_init_default_off", ProposalLoggingFlags.traceInitEnabled == false)
		check("verbose_logs_default_off", ProposalLoggingFlags.verboseProposalLogsEnabled == false)

		check(
			"needs_repair_reusable_action",
			GeneratedProposalTitleSynthesizer.needsRepair(title: "Reusable action", templateId: "x")
		)
		check(
			"needs_repair_raw_signature",
			GeneratedProposalTitleSynthesizer.needsRepair(
				title: "unknown|structure|summarize_context|none|v1",
				templateId: "unknown|structure|summarize_context|none|v1"
			)
		)

		let browsing = GeneratedProposalTitleSynthesizer.synthesize(
			workflowType: .browsing,
			intentType: .extract,
			primitiveSignature: ExecutionPrimitive.extractActionItems.rawValue,
			requiredContextTypes: [.workflowContext],
			metadata: [:]
		)
		check("browsing_title_human", browsing.title.lowercased().contains("extract"))
		check("browsing_no_signature", !browsing.title.contains("|") && !browsing.title.contains("extract_action_items"))

		let visual = GeneratedProposalTitleSynthesizer.synthesize(
			workflowType: .browsing,
			intentType: .structure,
			primitiveSignature: ExecutionPrimitive.summarizeContext.rawValue,
			requiredContextTypes: [.none],
			metadata: ["requires_visual": "1", "requires_ocr": "1"]
		)
		check("visual_title_matches", visual.title.lowercased().contains("visual"))
		check("visual_no_signature", !visual.title.contains("|") && !visual.title.contains("summarize_context"))

		let unknown = GeneratedProposalTitleSynthesizer.synthesize(
			workflowType: .unknown,
			intentType: .classify,
			primitiveSignature: ExecutionPrimitive.classifyWorkflow.rawValue,
			requiredContextTypes: [.none],
			metadata: [:]
		)
		check("unknown_human_readable", unknown.title.lowercased().contains("workflow"))
		check("unknown_not_prefixed_unknown", !unknown.title.lowercased().hasPrefix("(unknown)"))

		let ok = failures.isEmpty
		let detail = failures.joined(separator: ";")
		print("[GeneratedProposalTitleSynthesizer] selftest ok=\(ok) failures=\(failures.count) detail=\(detail)")
		return ok
	}
}
