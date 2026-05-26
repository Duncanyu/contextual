import CoreGraphics
import Foundation

// MARK: - Sources / Roles

enum GroundingSource: String, Sendable, Equatable, Codable, CaseIterable {
	case accessibility
	case ocr
	case metadata
}

enum ScreenStateRole: String, Sendable, Equatable, Codable, CaseIterable {
	case root
	case region
	case heading
	case bodyText = "body_text"
	case price
	case rating
	case reviewCount = "review_count"
	case button
	case link
	case tab
	case input
	case menuItem = "menu_item"
	case toolbarItem = "toolbar_item"
	case unknown
}

// MARK: - Node

struct ScreenStateNode: Sendable, Equatable, Codable, Identifiable {
	let stableId: String
	var id: String { stableId }

	let role: ScreenStateRole
	let title: String
	let text: String?
	let frame: CGRect?
	let visible: Bool
	let interactable: Bool
	let confidence: Double
	let source: GroundingSource
	let semanticTags: [String]

	let parentId: String?
	let childIds: [String]

	/// Heuristic 0–1 estimate of being in the user’s viewport; unknown defaults to 0.5.
	let viewportVisibility: Double
}

// MARK: - Graph

struct ScreenStateGraph: Sendable, Equatable, Codable {
	let rootId: String
	let nodes: [ScreenStateNode]

	private let byId: [String: ScreenStateNode]

	init(rootId: String, nodes: [ScreenStateNode]) {
		self.rootId = rootId
		self.nodes = nodes
		self.byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.stableId, $0) })
	}

	func node(id: String) -> ScreenStateNode? { byId[id] }

	func nodes(where predicate: (ScreenStateNode) -> Bool) -> [ScreenStateNode] {
		nodes.filter(predicate)
	}

	func nodes(withRole role: ScreenStateRole) -> [ScreenStateNode] {
		nodes.filter { $0.role == role }
	}

	func visibleNodes() -> [ScreenStateNode] { nodes.filter(\.visible) }

	func interactableNodes() -> [ScreenStateNode] { nodes.filter { $0.visible && $0.interactable } }

	func matchingText(_ query: String) -> [ScreenStateNode] {
		let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		guard !q.isEmpty else { return [] }
		return nodes.filter { n in
			let hay = (n.title + " " + (n.text ?? "")).lowercased()
			return hay.contains(q)
		}
	}

	func matchingTags(_ tags: [String]) -> [ScreenStateNode] {
		let wanted = Set(tags.map { $0.lowercased() }.filter { !$0.isEmpty })
		guard !wanted.isEmpty else { return [] }
		return nodes.filter { !wanted.intersection($0.semanticTags.map { $0.lowercased() }).isEmpty }
	}

	/// Deterministic bounded traversal from a start node.
	func traverse(from startId: String, maxNodes: Int = 30) -> [ScreenStateNode] {
		guard maxNodes > 0 else { return [] }
		guard let start = byId[startId] else { return [] }

		var result: [ScreenStateNode] = []
		var queue: [ScreenStateNode] = [start]
		var seen: Set<String> = [start.stableId]

		while !queue.isEmpty && result.count < maxNodes {
			let node = queue.removeFirst()
			result.append(node)
			for childId in node.childIds {
				guard result.count + queue.count < maxNodes else { break }
				guard !seen.contains(childId), let child = byId[childId] else { continue }
				seen.insert(childId)
				queue.append(child)
			}
		}

		return result
	}

	// MARK: - Stable IDs

	static func makeStableId(source: GroundingSource, role: ScreenStateRole, text: String, indexHint: Int? = nil) -> String {
		let normalized = text
			.lowercased()
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
		let suffix = indexHint != nil ? "|i=\(indexHint!)" : ""
		let material = "\(source.rawValue)|\(role.rawValue)|\(normalized)\(suffix)"
		return "ssg_" + stableHash(material)
	}

	private static func stableHash(_ s: String) -> String {
		// Deterministic, stable, non-crypto hash (FNV-1a 64-bit) for IDs.
		var hash: UInt64 = 14695981039346656037
		for b in s.utf8 {
			hash ^= UInt64(b)
			hash &*= 1099511628211
		}
		return String(format: "%016llx", hash)
	}
}

