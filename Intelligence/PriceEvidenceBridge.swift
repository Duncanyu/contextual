import Foundation

/// Phase 4U — PriceEvidenceBridge
///
/// Wires `AnchoredPriceResolver` into the runtime evidence path so:
/// - noisy/rough prices do NOT satisfy evidence
/// - anchored page prices win over fees/discounts/placeholders
///
/// Deterministic, local-only. Never invents a price.
enum PriceEvidenceBridge {

	static func applyAnchoredPriceSelection(
		goal: String,
		workflow: String,
		observations: [AgenticEvidenceObservation],
		semanticEntities: [GroundedSemanticEntity],
		graph: ScreenStateGraph?
	) -> (observations: [AgenticEvidenceObservation], semanticEntities: [GroundedSemanticEntity]) {
		let priceObservations = observations.filter { $0.kind == .price }
		let priceEntities = semanticEntities.filter { $0.type == .price }

		guard !priceObservations.isEmpty || !priceEntities.isEmpty else {
			return (observations, semanticEntities)
		}

		var occurrence: [String: Int] = [:]
		for e in priceEntities {
			let key = priceKey(e.normalizedValue ?? e.text)
			if !key.isEmpty { occurrence[key, default: 0] += 1 }
		}
		for o in priceObservations {
			let key = priceKey(o.normalized.isEmpty ? o.text : o.normalized)
			if !key.isEmpty { occurrence[key, default: 0] += 1 }
		}

		var candidates: [AnchoredPriceCandidate] = []

		for e in priceEntities {
			guard let normalized = normalizePrice(e.text), normalized.accepted else { continue }
			let normalizedKey = priceKey(e.normalizedValue ?? e.text)
			let node = graph?.node(id: e.sourceNodeId)
			let anchor = anchorContext(for: node, graph: graph, fallback: node?.text)
			candidates.append(
				AnchoredPriceCandidate(
					rawText: normalized.normalized,
					anchorContext: anchor,
					confidence: normalized.confidence,
					occurrenceCount: occurrence[normalizedKey].map { max(1, $0) } ?? 1,
					source: node?.source.rawValue ?? "semantic_entity"
				)
			)
		}

		for o in priceObservations {
			guard let normalized = normalizePrice(o.text), normalized.accepted else { continue }
			let normalizedKey = priceKey(normalized.normalized)
			let node = bestNodeContainingPrice(normalized.normalized, graph: graph)
			let anchor = anchorContext(for: node, graph: graph, fallback: o.reason)
			candidates.append(
				AnchoredPriceCandidate(
					rawText: normalized.normalized,
					anchorContext: anchor,
					confidence: o.confidence,
					occurrenceCount: occurrence[normalizedKey].map { max(1, $0) } ?? 1,
					source: o.source.rawValue
				)
			)
		}

		// De-dupe by rawText+source.
		var seen: Set<String> = []
		var unique: [AnchoredPriceCandidate] = []
		for c in candidates {
			let key = "\(c.rawText.lowercased())|\(c.source)"
			if seen.contains(key) { continue }
			seen.insert(key)
			unique.append(c)
		}

		guard !unique.isEmpty else {
			return (
				observations.filter { $0.kind != .price },
				semanticEntities.filter { $0.type != .price }
			)
		}

		let decision = AnchoredPriceResolver.resolve(candidates: unique)
		guard let selected = decision.selected else {
			return (
				observations.filter { $0.kind != .price },
				semanticEntities.filter { $0.type != .price }
			)
		}

		let topAnchor = decision.allScores.first?.anchorScore ?? 0.0
		let selectedIsDecimal = selected.rawText.range(of: #"\d+\.\d{2}"#, options: .regularExpression) != nil
		// Treat non-decimal prices as rough unless strongly anchored (>=2 anchor hits).
		let reliable = selectedIsDecimal || topAnchor >= 0.85
		if !reliable {
			return (
				observations.filter { $0.kind != .price },
				semanticEntities.filter { $0.type != .price }
			)
		}

		let selectedKey = priceKey(selected.rawText)
		let filteredObs = observations.filter { o in
			guard o.kind == .price else { return true }
			return priceKey(o.normalized.isEmpty ? o.text : o.normalized) == selectedKey
		}
		let filteredEntities = semanticEntities.filter { e in
			guard e.type == .price else { return true }
			return priceKey(e.normalizedValue ?? e.text) == selectedKey
		}

		return (filteredObs, filteredEntities)
	}

	// MARK: - Helpers

	private static func priceKey(_ s: String) -> String {
		let stripped = s.unicodeScalars
			.filter { CharacterSet(charactersIn: "0123456789.").contains($0) }
			.map(String.init)
			.joined()
		return stripped
	}

	private static func normalizePrice(_ raw: String) -> PriceNormalizer.NormalizationResult? {
		guard let result = PriceNormalizer.normalize(rawText: raw) else { return nil }
		let numeric = numericValue(of: result.normalized)
		if let numeric, (numeric <= 0 || numeric > 5000) {
			return PriceNormalizer.NormalizationResult(
				raw: result.raw,
				normalized: result.normalized,
				confidence: result.confidence,
				accepted: false,
				reason: "implausible_value"
			)
		}
		return result
	}

	private static func numericValue(of raw: String) -> Double? {
		let stripped = raw.unicodeScalars
			.filter { CharacterSet(charactersIn: "0123456789.").contains($0) }
			.map(String.init)
			.joined()
		return Double(stripped)
	}

	private static func bestNodeContainingPrice(_ price: String, graph: ScreenStateGraph?) -> ScreenStateNode? {
		guard let graph else { return nil }
		let needle = priceKey(price)
		guard !needle.isEmpty else { return nil }
		return graph.nodes.first { node in
			let hay = priceKey(node.title + " " + (node.text ?? ""))
			return hay.contains(needle)
		}
	}

	private static func anchorContext(for node: ScreenStateNode?, graph: ScreenStateGraph?, fallback: String?) -> String {
		var parts: [String] = []
		if let node {
			parts.append(node.title)
			if let t = node.text { parts.append(t) }
			if !node.semanticTags.isEmpty { parts.append(node.semanticTags.joined(separator: " ")) }
			if let parentId = node.parentId, let parent = graph?.node(id: parentId) {
				parts.append(parent.title)
				if let pt = parent.text { parts.append(pt) }
			}
			for childId in node.childIds.prefix(3) {
				if let child = graph?.node(id: childId) {
					parts.append(child.title)
					if let ct = child.text { parts.append(ct) }
				}
			}
		}
		if parts.isEmpty, let fallback, !fallback.isEmpty {
			parts.append(fallback)
		}
		return String(parts.joined(separator: " ").prefix(180))
	}
}

