import Foundation

/// Converts bounded AX window content context into `ScreenStateGraph` nodes.
///
/// NOTE: Current `AXWindowContentContext` is a lightweight summary (fragments + kind counts),
/// not a full AX tree. This extractor preserves what we have in a deterministic way and
/// is resilient to browsers exposing very limited AX.
struct AccessibilityGroundingExtractor: Sendable {

	func extract(from ax: AXWindowContentContext) -> ScreenStateGraph {
		let rootId = ScreenStateGraph.makeStableId(source: .accessibility, role: .root, text: "ax_root")
		var nodes: [ScreenStateNode] = []

		// Root
		nodes.append(
			ScreenStateNode(
				stableId: rootId,
				role: .root,
				title: "AX Root",
				text: nil,
				frame: nil,
				visible: true,
				interactable: false,
				confidence: min(1, max(0, ax.extractionConfidence)),
				source: .accessibility,
				semanticTags: ["ax"],
				parentId: nil,
				childIds: [],
				viewportVisibility: 0.6
			)
		)

		// Visible text fragments
		var childIds: [String] = []
		for (idx, frag) in ax.visibleTextFragments.enumerated() {
			let trimmed = frag.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { continue }
			let role: ScreenStateRole = .bodyText
			let id = ScreenStateGraph.makeStableId(source: .accessibility, role: role, text: trimmed, indexHint: idx)
			childIds.append(id)
			nodes.append(
				ScreenStateNode(
					stableId: id,
					role: role,
					title: trimmed,
					text: nil,
					frame: nil,
					visible: true,
					interactable: false,
					confidence: min(1, max(0.15, ax.extractionConfidence)),
					source: .accessibility,
					semanticTags: ["ax_text"],
					parentId: rootId,
					childIds: [],
					viewportVisibility: 0.55
				)
			)
		}

		// Control kind hints (no labels, but we can emit a coarse node)
		if ax.estimatedInteractiveElementCount > 0 {
			let id = ScreenStateGraph.makeStableId(source: .accessibility, role: .region, text: "interactive_elements")
			childIds.append(id)
			nodes.append(
				ScreenStateNode(
					stableId: id,
					role: .region,
					title: "Interactive elements",
					text: nil,
					frame: nil,
					visible: true,
					interactable: true,
					confidence: min(1, max(0.2, ax.extractionConfidence)),
					source: .accessibility,
					semanticTags: ["interactive", "ax_controls"],
					parentId: rootId,
					childIds: [],
					viewportVisibility: 0.6
				)
			)
		}

		// Patch root child links (root node is always first)
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
}

