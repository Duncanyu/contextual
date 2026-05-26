import Foundation

/// Phase 4I self-test: grounded semantic extraction → structured facts.
///
/// Run with: `CONTEXTUAL_RUN_GROUNDED_SEMANTIC_EXTRACTION_SELFTEST=1`
enum GroundedSemanticExtractionSelfTest {

	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[GroundedSemanticExtractionSelfTest] FAIL \(name)")
			}
		}

		// Construct a graph resembling an Amazon-like product card (grounded).
		let rootId = ScreenStateGraph.makeStableId(source: .ocr, role: .root, text: "root")
		let titleId = ScreenStateGraph.makeStableId(source: .ocr, role: .heading, text: "Anker Prime 140W Charger")
		let priceId = ScreenStateGraph.makeStableId(source: .ocr, role: .price, text: "$76.00")
		let discId = ScreenStateGraph.makeStableId(source: .ocr, role: .bodyText, text: "25% off")
		let ratingId = ScreenStateGraph.makeStableId(source: .ocr, role: .rating, text: "4.6 stars")
		let specId = ScreenStateGraph.makeStableId(source: .ocr, role: .bodyText, text: "140W 4 ports GaN")

		let nodes: [ScreenStateNode] = [
			ScreenStateNode(
				stableId: rootId,
				role: .root,
				title: "Root",
				text: nil,
				frame: nil,
				visible: true,
				interactable: false,
				confidence: 0.8,
				source: .ocr,
				semanticTags: ["root"],
				parentId: nil,
				childIds: [titleId, priceId, discId, ratingId, specId],
				viewportVisibility: 0.6
			),
			ScreenStateNode(stableId: titleId, role: .heading, title: "Anker Prime 140W Charger", text: nil, frame: nil, visible: true, interactable: false, confidence: 0.8, source: .ocr, semanticTags: ["title"], parentId: rootId, childIds: [], viewportVisibility: 0.6),
			ScreenStateNode(stableId: priceId, role: .price, title: "$76.00", text: nil, frame: nil, visible: true, interactable: false, confidence: 0.75, source: .ocr, semanticTags: ["price"], parentId: rootId, childIds: [], viewportVisibility: 0.6),
			ScreenStateNode(stableId: discId, role: .bodyText, title: "25% off", text: nil, frame: nil, visible: true, interactable: false, confidence: 0.7, source: .ocr, semanticTags: [], parentId: rootId, childIds: [], viewportVisibility: 0.6),
			ScreenStateNode(stableId: ratingId, role: .rating, title: "4.6 stars", text: nil, frame: nil, visible: true, interactable: false, confidence: 0.7, source: .ocr, semanticTags: ["rating"], parentId: rootId, childIds: [], viewportVisibility: 0.6),
			ScreenStateNode(stableId: specId, role: .bodyText, title: "140W 4 ports GaN", text: nil, frame: nil, visible: true, interactable: false, confidence: 0.65, source: .ocr, semanticTags: ["spec"], parentId: rootId, childIds: [], viewportVisibility: 0.6),
		]
		let graph = ScreenStateGraph(rootId: rootId, nodes: nodes)

		// Grounded targets prioritize title and price.
		let targets: [GroundedTarget] = [
			GroundedTarget(nodeId: titleId, title: "Anker Prime 140W Charger", role: .heading, source: .ocr, confidence: 0.8, score: 0.9),
			GroundedTarget(nodeId: priceId, title: "$76.00", role: .price, source: .ocr, confidence: 0.75, score: 0.8),
			GroundedTarget(nodeId: discId, title: "25% off", role: .bodyText, source: .ocr, confidence: 0.7, score: 0.7),
			GroundedTarget(nodeId: ratingId, title: "4.6 stars", role: .rating, source: .ocr, confidence: 0.7, score: 0.65),
			GroundedTarget(nodeId: specId, title: "140W 4 ports GaN", role: .bodyText, source: .ocr, confidence: 0.65, score: 0.6),
		]

		let extractor = GroundedSemanticExtractor()
		let entities = extractor.extract(graph: graph, groundedTargets: targets, ocrFallback: nil)
		check("entities_nonempty", !entities.isEmpty)
		check("extracts_price", entities.contains(where: { $0.type == .price }))
		check("extracts_discount", entities.contains(where: { $0.type == .discount }))
		check("extracts_rating", entities.contains(where: { $0.type == .rating }))
		check("extracts_spec", entities.contains(where: { $0.type == .specification }))
		check("extracts_product_title", entities.contains(where: { $0.type == .productTitle || $0.type == .heading }))

		// Duplicate suppression: adding another price node should not double count.
		let dupNodes = nodes + [
			ScreenStateNode(stableId: ScreenStateGraph.makeStableId(source: .ocr, role: .price, text: "$76.00", indexHint: 99), role: .price, title: "$76.00", text: nil, frame: nil, visible: true, interactable: false, confidence: 0.6, source: .ocr, semanticTags: ["price"], parentId: rootId, childIds: [], viewportVisibility: 0.5),
		]
		let dupGraph = ScreenStateGraph(rootId: rootId, nodes: dupNodes)
		let dupEntities = extractor.extract(graph: dupGraph, groundedTargets: targets, ocrFallback: nil)
		check("dedupe_price", dupEntities.filter { $0.type == .price }.count == 1)

		let builder = StructuredFactBuilder()
		let facts = builder.buildFacts(from: entities)
		check("facts_nonempty", !facts.isEmpty)
		check("has_product_fact", facts.contains(where: { $0.category == "product" }))
		if let product = facts.first(where: { $0.category == "product" }) {
			check("product_has_price_attr", product.attributes["price"] != nil)
			check("product_has_discount_attr", product.attributes["discount"] != nil)
		}

		let ok = failures.isEmpty
		print("[GroundedSemanticExtractionSelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}
}

// MARK: - Semantic Readiness Self-Test

enum SemanticReadinessSelfTest {
	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[SemanticReadinessSelfTest] FAIL \(name)")
			}
		}

		let extractor = GroundedSemanticExtractor()
		let builder = StructuredFactBuilder()

		// 1. URL never becomes product title
		let urlNodeId = ScreenStateGraph.makeStableId(source: .ocr, role: .heading, text: "https://www.amazon.ca/dp/B0C3R8QNLV")
		let urlNode = ScreenStateNode(stableId: urlNodeId, role: .heading, title: "https://www.amazon.ca/dp/B0C3R8QNLV", text: nil, frame: nil, visible: true, interactable: false, confidence: 0.9, source: .ocr, semanticTags: ["title"], parentId: nil, childIds: [], viewportVisibility: 1.0)
		let graph1 = ScreenStateGraph(rootId: urlNodeId, nodes: [urlNode])
		let targets1 = [GroundedTarget(nodeId: urlNodeId, title: "https://www.amazon.ca/dp/B0C3R8QNLV", role: .heading, source: .ocr, confidence: 0.9, score: 0.9)]
		let entities1 = extractor.extract(graph: graph1, groundedTargets: targets1, ocrFallback: nil)
		let facts1 = builder.buildFacts(from: entities1)
		check("url_rejected_as_product_title", !facts1.contains(where: { $0.category == "product" }))

		// 2 & 3. Amazon title produces clean product title & Amazon suffix stripped correctly
		let amzTitle = "Anker Prime 140W Charger: Amazon.ca: Electronics"
		let amzNodeId = ScreenStateGraph.makeStableId(source: .ocr, role: .heading, text: amzTitle)
		let amzNode = ScreenStateNode(stableId: amzNodeId, role: .heading, title: amzTitle, text: nil, frame: nil, visible: true, interactable: false, confidence: 0.9, source: .ocr, semanticTags: ["title"], parentId: nil, childIds: [], viewportVisibility: 1.0)
		let graph2 = ScreenStateGraph(rootId: amzNodeId, nodes: [amzNode])
		let targets2 = [GroundedTarget(nodeId: amzNodeId, title: amzTitle, role: .heading, source: .ocr, confidence: 0.9, score: 0.9)]
		let entities2 = extractor.extract(graph: graph2, groundedTargets: targets2, ocrFallback: nil)
		let facts2 = builder.buildFacts(from: entities2)
		if let pf2 = facts2.first(where: { $0.category == "product" }) {
			check("amazon_suffix_stripped", pf2.title == "Anker Prime 140W Charger")
		} else {
			check("amazon_suffix_stripped_present", false)
		}

		// 4. Malformed price rejected/low-confidence
		if let malformed = PriceNormalizer.normalize(rawText: "$1819") {
			check("malformed_price_low_confidence", malformed.confidence <= 0.3)
			check("malformed_price_unaccepted", !malformed.accepted)
		} else {
			check("malformed_price_normalizer_failed", false)
		}

		// 5. Normal price accepted
		let prices = ["$76", "$76.00", "$76 00"]
		for p in prices {
			if let normalized = PriceNormalizer.normalize(rawText: p) {
				check("price_normalized_correctly_\(p)", normalized.normalized == "$76.00")
				check("price_accepted_\(p)", normalized.accepted)
			} else {
				check("price_failed_to_normalize_\(p)", false)
			}
		}

		// 6. Wattage specs normalized and deduped
		let spec1 = SpecNormalizer.normalize(rawText: "140w")
		let spec2 = SpecNormalizer.normalize(rawText: "140 watts")
		check("spec_normalized_1", spec1?.normalized == "140W")
		check("spec_normalized_2", spec2?.normalized == "140W")
		
		let specNode1Id = ScreenStateGraph.makeStableId(source: .ocr, role: .bodyText, text: "140w")
		let specNode2Id = ScreenStateGraph.makeStableId(source: .ocr, role: .bodyText, text: "140 watts")
		let titleNodeId = ScreenStateGraph.makeStableId(source: .ocr, role: .heading, text: "Anker Prime Charger")
		
		let specNodes = [
			ScreenStateNode(stableId: titleNodeId, role: .heading, title: "Anker Prime Charger", text: nil, frame: nil, visible: true, interactable: false, confidence: 0.9, source: .ocr, semanticTags: ["title"], parentId: nil, childIds: [], viewportVisibility: 1.0),
			ScreenStateNode(stableId: specNode1Id, role: .bodyText, title: "140w", text: nil, frame: nil, visible: true, interactable: false, confidence: 0.8, source: .ocr, semanticTags: ["spec"], parentId: nil, childIds: [], viewportVisibility: 1.0),
			ScreenStateNode(stableId: specNode2Id, role: .bodyText, title: "140 watts", text: nil, frame: nil, visible: true, interactable: false, confidence: 0.8, source: .ocr, semanticTags: ["spec"], parentId: nil, childIds: [], viewportVisibility: 1.0)
		]
		let graphSpecs = ScreenStateGraph(rootId: titleNodeId, nodes: specNodes)
		let targetsSpecs = [
			GroundedTarget(nodeId: titleNodeId, title: "Anker Prime Charger", role: .heading, source: .ocr, confidence: 0.9, score: 0.9),
			GroundedTarget(nodeId: specNode1Id, title: "140w", role: .bodyText, source: .ocr, confidence: 0.8, score: 0.8),
			GroundedTarget(nodeId: specNode2Id, title: "140 watts", role: .bodyText, source: .ocr, confidence: 0.8, score: 0.8)
		]
		let entitiesSpecs = extractor.extract(graph: graphSpecs, groundedTargets: targetsSpecs, ocrFallback: nil)
		check("specs_deduped", entitiesSpecs.filter { $0.type == .specification }.count == 1)

		// 7. Goal echo rejected
		let echoTitle = "Compare Anker Prime Charger"
		let goal = "Compare Anker Prime Charger"
		let echoNodeId = ScreenStateGraph.makeStableId(source: .ocr, role: .heading, text: echoTitle)
		let echoNode = ScreenStateNode(stableId: echoNodeId, role: .heading, title: echoTitle, text: nil, frame: nil, visible: true, interactable: false, confidence: 0.9, source: .ocr, semanticTags: ["title"], parentId: nil, childIds: [], viewportVisibility: 1.0)
		let graphEcho = ScreenStateGraph(rootId: echoNodeId, nodes: [echoNode])
		let targetsEcho = [GroundedTarget(nodeId: echoNodeId, title: echoTitle, role: .heading, source: .ocr, confidence: 0.9, score: 0.9)]
		let entitiesEcho = extractor.extract(graph: graphEcho, groundedTargets: targetsEcho, ocrFallback: nil, goal: goal)
		let factsEcho = builder.buildFacts(from: entitiesEcho, goal: goal)
		check("goal_echo_rejected", !factsEcho.contains(where: { $0.category == "product" }))

		// 8. Semantic readiness FALSE when evidence weak
		let weakReadiness = SemanticReadinessEvaluator.evaluate(facts: [], entities: [], goal: "Find specs for Anker Prime")
		check("weak_readiness_is_false", !weakReadiness.readyForFinalAnswer)

		// 9. Semantic readiness TRUE when title + useful specs exist
		let productFact = StructuredFact(id: "pf", category: "product", title: "Anker Prime Charger", attributes: ["price": "$76.00"], confidence: 0.9, sourceEntityIds: ["1"])
		let specEntity = GroundedSemanticEntity(id: "se1", type: .specification, text: "140W", normalizedValue: "140W", confidence: 0.8, sourceNodeId: "node1", role: .bodyText, tags: ["spec"])
		let featureEntity = GroundedSemanticEntity(id: "se2", type: .feature, text: "GaN Tech", normalizedValue: "GaN Tech", confidence: 0.8, sourceNodeId: "node2", role: .bodyText, tags: ["feature"])
		let priceEntity = GroundedSemanticEntity(id: "se3", type: .price, text: "$76.00", normalizedValue: "$76.00", confidence: 0.8, sourceNodeId: "node3", role: .price, tags: ["price"])
		
		let strongReadiness = SemanticReadinessEvaluator.evaluate(
			facts: [productFact],
			entities: [specEntity, featureEntity, priceEntity],
			goal: "Find specs for Anker Prime"
		)
		check("strong_readiness_is_true", strongReadiness.readyForFinalAnswer)

		// 10. Low readiness prevents success-style final answer when more perception actions remain
		let decider = AgenticDecider()
		let decision = await decider.decide(
			goal: "Compare Anker Prime Charger",
			observations: [],
			extractedFacts: ["Product: Anker Prime Charger"],
			stepIndex: 2,
			maxSteps: 5,
			llmCallsUsed: 0,
			llmCallsBudget: 5,
			ocrCallsUsed: 0,
			ocrCallsBudget: 2,
			legalActions: [.find_on_page, .scroll_small, .present_answer],
			forceObserveNext: false,
			semanticReadiness: SemanticReadiness(
				hasReliableProductTitle: true,
				hasUsefulAttributes: false,
				hasReliablePrice: false,
				hasComparisonEvidence: false,
				semanticConfidence: 0.4,
				reason: "Missing specs",
				readyForFinalAnswer: false
			)
		)
		check("low_readiness_triggers_perception", decision.nextAction == .find_on_page || decision.nextAction == .scroll_small)

		let ok = failures.isEmpty
		print("[SemanticReadinessSelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}
}
