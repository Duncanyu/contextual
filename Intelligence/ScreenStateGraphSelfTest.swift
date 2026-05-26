import Foundation

/// Phase 4G self-tests for ScreenStateGraph + extractors + grounded target resolution.
///
/// Run with: `CONTEXTUAL_RUN_SCREEN_STATE_SELFTEST=1`
enum ScreenStateGraphSelfTest {

	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[ScreenStateGraphSelfTest] FAIL \(name)")
			}
		}

		// MARK: 1 — Stable ID determinism

		let id1 = ScreenStateGraph.makeStableId(source: .ocr, role: .heading, text: "Anker Laptop Power Bank")
		let id2 = ScreenStateGraph.makeStableId(source: .ocr, role: .heading, text: "Anker Laptop Power Bank")
		check("stable_id_deterministic", id1 == id2)

		let id3 = ScreenStateGraph.makeStableId(source: .ocr, role: .heading, text: "Anker Laptop Power Bank", indexHint: 1)
		check("stable_id_index_hint_changes", id1 != id3)

		// MARK: 2 — OCR extraction produces role-tagged nodes

		let ocrText = """
		Spigen Rugged Armor Designed for AirPods 4 Case - Matte Black
		$19.99
		Rating 4.6 stars
		1,234 reviews
		Compatible with AirPods 4
		"""
		let ocrGraph = OCRGroundingExtractor().extract(from: ocrText)
		check("ocr_graph_has_root", ocrGraph.node(id: ocrGraph.rootId) != nil)
		check("ocr_graph_has_nodes", ocrGraph.nodes.count >= 4)
		check("ocr_has_price_node", !ocrGraph.nodes(withRole: .price).isEmpty)
		check("ocr_has_rating_node", !ocrGraph.nodes(withRole: .rating).isEmpty)

		// MARK: 3 — AX extraction yields nodes even with fragments-only context

		let ax = AXWindowContentContext(
			id: UUID(),
			extractedAt: Date(),
			appName: "Firefox",
			bundleIdentifier: "org.mozilla.firefox",
			sourceWindowTitleAvailable: true,
			visibleTextFragments: ["Add to cart", "AirPods 4 Case", "Price", "Reviews"],
			visibleControlKinds: [.button, .staticText, .toolbar],
			estimatedVisibleTextLength: 40,
			estimatedInteractiveElementCount: 3,
			containsScrollableRegion: true,
			containsEditorLikeRegion: false,
			containsFormLikeRegion: false,
			containsTableLikeRegion: false,
			hierarchyDepthEstimate: 3,
			extractionConfidence: 0.55
		)
		let axGraph = AccessibilityGroundingExtractor().extract(from: ax)
		check("ax_graph_has_nodes", axGraph.nodes.count >= 3)

		// MARK: 4 — Graph filtering (visible/interactable/role)

		check("visible_nodes_nonempty", !ocrGraph.visibleNodes().isEmpty)
		check("role_filter_heading", !ocrGraph.nodes(withRole: .heading).isEmpty)
		// AX graph should include an interactable region node when estimatedInteractiveElementCount > 0
		check("ax_interactable_nodes_present", !axGraph.interactableNodes().isEmpty)

		// MARK: 5 — Text matching + tag matching

		check("text_match_airpods", !ocrGraph.matchingText("airpods").isEmpty)
		check("tag_match_price", !ocrGraph.matchingTags(["price"]).isEmpty)

		// MARK: 6 — Target resolution prefers product content over generic text

		let merged = ScreenStateGraph(
			rootId: ScreenStateGraph.makeStableId(source: .metadata, role: .root, text: "merged"),
			nodes: {
				var nodes = [ScreenStateNode(
					stableId: ScreenStateGraph.makeStableId(source: .metadata, role: .root, text: "merged"),
					role: .root,
					title: "Root",
					text: nil,
					frame: nil,
					visible: true,
					interactable: false,
					confidence: 0.7,
					source: .metadata,
					semanticTags: ["merged"],
					parentId: nil,
					childIds: [],
					viewportVisibility: 0.6
				)]
				nodes.append(contentsOf: ocrGraph.nodes)
				nodes.append(contentsOf: axGraph.nodes)
				return nodes
			}()
		)

		let resolver = GroundedTargetResolver()
		let resolved = resolver.resolveTargets(goal: "compare price and rating", workflow: "browsing", graph: merged, maxTargets: 6)
		check("resolver_returns_targets", !resolved.targets.isEmpty)
		// Expect primary target to exist and usually be price/rating/heading
		check("resolver_primary_exists", resolved.primary != nil)
		if let primary = resolved.primary {
			check("resolver_primary_role_reasonable", primary.role == .price || primary.role == .rating || primary.role == .heading || primary.role == .bodyText)
		}

		// MARK: 7 — Empty graph handling is graceful

		let emptyGraph = ScreenStateGraph(
			rootId: ScreenStateGraph.makeStableId(source: .metadata, role: .root, text: "empty"),
			nodes: [
				ScreenStateNode(
					stableId: ScreenStateGraph.makeStableId(source: .metadata, role: .root, text: "empty"),
					role: .root,
					title: "Root",
					text: nil,
					frame: nil,
					visible: true,
					interactable: false,
					confidence: 0.5,
					source: .metadata,
					semanticTags: [],
					parentId: nil,
					childIds: [],
					viewportVisibility: 0.5
				)
			]
		)
		let emptyResolved = resolver.resolveTargets(goal: "find price", workflow: "browsing", graph: emptyGraph)
		check("empty_graph_returns_no_targets", emptyResolved.targets.isEmpty)

		let ok = failures.isEmpty
		print("[ScreenStateGraphSelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}
}

