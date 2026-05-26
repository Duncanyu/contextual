import Foundation

enum AgenticEvidenceExtractionBridgeSelfTest {

	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ condition: @autoclosure () -> Bool) {
			if !condition() {
				print("[AgenticEvidenceExtractionBridgeSelfTest] FAIL \(name)")
				failures.append(name)
			}
		}

		let goal = "Compare this charger with other options"
		let workflow = "browsing"
		let title = "Anker Laptop Charger, 140W MAX USB C Charger, 4-Port, GaN : Amazon.ca: Electronics - Firefox"
		let ocr = "Anker Laptop Charger 140W MAX USB C Charger 4-Port GaN Compatible with MacBook iPhone Samsung Pixel"
		let assistantChrome = "Processing Compare Anker Laptop Charger"

		let observations = AgenticEvidenceExtractionBridge.extract(
			goal: goal,
			workflow: workflow,
			windowTitle: title,
			ocrText: ocr + "\n" + assistantChrome,
			axText: nil,
			graph: nil,
			semanticEntities: [],
			structuredFacts: [],
			comparisonTitles: ["anker laptop charger 140w", "anker prime usb c charger block 160w"]
		)

		let productObs = observations.filter { $0.kind == .productTitle }
		check("window_title_product_title_present", !productObs.isEmpty)
		check("product_title_not_assistant_chrome", !(productObs.first?.text.lowercased().contains("processing") ?? false))

		let specs = observations.filter { $0.kind == .specs }.map { $0.text.lowercased() }
		check("specs_contains_140w", specs.contains(where: { $0.contains("140w") }))
		check("specs_contains_4_port", specs.contains(where: { $0.contains("4") && $0.contains("port") }))
		check("specs_contains_gan", specs.contains(where: { $0.contains("gan") }))
		check("specs_contains_usb_c", specs.contains(where: { $0.contains("usb") }))

		let reqs = AgenticEvidenceRequirementsInferrer.infer(goal: goal, workflow: workflow)
		let state = AgenticEvidenceAssessor.assess(
			goal: goal,
			requirements: reqs,
			entities: [],
			evidenceObservations: observations,
			extractedFactsCount: 0,
			hasUsableObservation: true
		)

		check("evidence_satisfies_product_title", state.satisfied.contains(.productTitle))
		check("evidence_satisfies_specs", state.satisfied.contains(.specs))

		// Comparison candidates from history should satisfy comparison_candidate (>=2 distinct).
		check("evidence_satisfies_comparison_candidate", state.satisfied.contains(.comparisonCandidate))

		// Ensure default query selection avoids generic "product" when evidence exists.
		let decider = AgenticDecider()
		let decision = await decider.decide(
			goal: goal,
			workflow: workflow,
			observations: [],
			extractedFacts: [],
			stepIndex: 1,
			maxSteps: 5,
			llmCallsUsed: 0,
			llmCallsBudget: 0,
			ocrCallsUsed: 0,
			ocrCallsBudget: 2,
			legalActions: [.find_on_page, .observe_once, .extract_facts, .present_answer, .stop_missing_context, .stop_success, .summarize_observation, .scroll_small],
			forceObserveNext: false,
			semanticReadiness: nil,
			evidenceState: state,
			evidenceObservations: observations
		)
		// Since required evidence is satisfied, decider should not force find_on_page with query=product.
		check("decider_not_forcing_find_product", decision.findQuery != "product")

		let ok = failures.isEmpty
		print("[AgenticEvidenceExtractionBridgeSelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}
}
