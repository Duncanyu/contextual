import Foundation

/// Converts OCR text (no bounding boxes in current pipeline) into `ScreenStateGraph` nodes.
///
/// Heuristics are general and lightweight:
/// - price-like lines -> `.price`
/// - rating-like lines -> `.rating` / `.reviewCount`
/// - title/headline-ish lines -> `.heading` (long-ish, high alpha ratio)
/// - otherwise -> `.bodyText`
struct OCRGroundingExtractor: Sendable {

	func extract(from ocrText: String) -> ScreenStateGraph {
		let rootId = ScreenStateGraph.makeStableId(source: .ocr, role: .root, text: "ocr_root")
		var nodes: [ScreenStateNode] = []
		nodes.append(
			ScreenStateNode(
				stableId: rootId,
				role: .root,
				title: "OCR Root",
				text: nil,
				frame: nil,
				visible: true,
				interactable: false,
				confidence: 0.75,
				source: .ocr,
				semanticTags: ["ocr"],
				parentId: nil,
				childIds: [],
				viewportVisibility: 0.6
			)
		)

		let lines = ocrText
			.split(separator: "\n")
			.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }

		var childIds: [String] = []
		for (idx, line) in lines.enumerated() {
			let role = classifyRole(for: line)
			let tags = semanticTags(for: line, role: role)
			let id = ScreenStateGraph.makeStableId(source: .ocr, role: role, text: line, indexHint: idx)
			childIds.append(id)
			nodes.append(
				ScreenStateNode(
					stableId: id,
					role: role,
					title: line,
					text: nil,
					frame: nil,
					visible: true,
					interactable: false,
					confidence: 0.65,
					source: .ocr,
					semanticTags: tags,
					parentId: rootId,
					childIds: [],
					viewportVisibility: 0.55
				)
			)
		}

		if var root = nodes.first {
			root = ScreenStateNode(
				stableId: root.stableId,
				role: root.role,
				title: root.title,
				text: root.text,
				frame: root.frame,
				visible: root.visible,
				interactable: root.interactable,
				confidence: root.confidence,
				source: root.source,
				semanticTags: root.semanticTags,
				parentId: root.parentId,
				childIds: childIds,
				viewportVisibility: root.viewportVisibility
			)
			nodes[0] = root
		}

		return ScreenStateGraph(rootId: rootId, nodes: nodes)
	}

	// MARK: - Heuristics

	private func classifyRole(for line: String) -> ScreenStateRole {
		let l = line.lowercased()
		if isPrice(l) { return .price }
		if isRating(l) { return .rating }
		if isReviewCount(l) { return .reviewCount }
		if looksLikeHeading(line) { return .heading }
		return .bodyText
	}

	private func semanticTags(for line: String, role: ScreenStateRole) -> [String] {
		var tags: [String] = []
		switch role {
		case .price: tags.append("price")
		case .rating: tags.append("rating")
		case .reviewCount: tags.append("reviews")
		case .heading: tags.append("title")
		default: break
		}
		let l = line.lowercased()
		if l.contains("spec") || l.contains("inch") || l.contains("mah") || l.contains("watt") { tags.append("spec") }
		if l.contains("compatible") { tags.append("compatibility") }
		return tags
	}

	private func isPrice(_ lower: String) -> Bool {
		// e.g. "$19.99", "19.99", "USD 19.99"
		if lower.contains("$") { return true }
		if lower.contains("usd") || lower.contains("cad") || lower.contains("eur") { return true }
		// numeric with decimal
		return lower.range(of: #"(^|[^0-9])[0-9]{1,4}\.[0-9]{2}([^0-9]|$)"#, options: .regularExpression) != nil
	}

	private func isRating(_ lower: String) -> Bool {
		// "4.6 stars", "4.6 out of 5"
		if lower.contains("star") { return true }
		return lower.range(of: #"[0-5]\.[0-9]\s*(out of\s*5)?"#, options: .regularExpression) != nil
	}

	private func isReviewCount(_ lower: String) -> Bool {
		// "1,234 reviews"
		return lower.contains("review") && lower.range(of: #"[0-9][0-9,]{1,}"#, options: .regularExpression) != nil
	}

	private func looksLikeHeading(_ line: String) -> Bool {
		// A “heading” is generally longer, mostly letters, not too punctuation-heavy.
		let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.count >= 18 else { return false }
		let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
		let ratio = Double(letters) / Double(max(1, trimmed.count))
		return ratio >= 0.55
	}
}

