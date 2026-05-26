import Foundation

struct GroundedTarget: Sendable, Equatable, Codable {
	let nodeId: String
	let title: String
	let role: ScreenStateRole
	let source: GroundingSource
	let confidence: Double
	let score: Double
}

/// Phase 4G: resolves goal/intent into grounded screen targets using `ScreenStateGraph`.
struct GroundedTargetResolver: Sendable {

	func resolveTargets(goal: String, workflow: String, graph: ScreenStateGraph, maxTargets: Int = 8) -> (targets: [GroundedTarget], primary: GroundedTarget?) {
		let tokens = tokenize(goal)
		let wf = workflow.lowercased()
		var scored: [GroundedTarget] = []
		scored.reserveCapacity(min(graph.nodes.count, maxTargets))

		for node in graph.nodes where node.role != .root {
			let base = baseScore(tokens: tokens, workflow: wf, node: node)
			guard base > 0 else { continue }
			let score = min(1, max(0, base))
			scored.append(
				GroundedTarget(
					nodeId: node.stableId,
					title: node.title,
					role: node.role,
					source: node.source,
					confidence: node.confidence,
					score: score
				)
			)
		}

		scored.sort { $0.score > $1.score }
		let targets = Array(scored.prefix(maxTargets))
		let primary = targets.first(where: { $0.score >= 0.35 })
		return (targets, primary)
	}

	// MARK: - Scoring

	private func baseScore(tokens: [String], workflow: String, node: ScreenStateNode) -> Double {
		// Noise penalty: avoid obvious chrome/menu items as primary targets.
		let noisePenalty: Double = {
			switch node.role {
			case .menuItem, .toolbarItem: return 0.35
			default: return 0
			}
		}()

		let text = (node.title + " " + (node.text ?? "")).lowercased()
		let overlap = tokens.isEmpty ? 0 : Double(tokens.filter { text.contains($0) }.count) / Double(tokens.count)

		let roleBonus: Double = roleFitBonus(goalTokens: tokens, workflow: workflow, role: node.role, tags: node.semanticTags)
		let interactBonus: Double = node.interactable ? 0.08 : 0
		let visBonus: Double = node.visible ? 0.05 : -0.05
		let viewportBonus: Double = (node.viewportVisibility - 0.5) * 0.08

		let score =
			(overlap * 0.55) +
			(roleBonus) +
			(interactBonus) +
			(visBonus) +
			(viewportBonus) +
			(node.confidence * 0.18) -
			noisePenalty

		return score
	}

	private func roleFitBonus(goalTokens: [String], workflow: String, role: ScreenStateRole, tags: [String]) -> Double {
		let t = Set(goalTokens)
		let tagSet = Set(tags.map { $0.lowercased() })

		// Browsing/product workflows: price/title/rating matter more.
		if workflow.contains("brows") || workflow.contains("shop") || workflow.contains("product") || workflow.contains("review") {
			if role == .price || tagSet.contains("price") { return 0.18 }
			if role == .rating || tagSet.contains("rating") { return 0.12 }
			if role == .heading || tagSet.contains("title") { return 0.10 }
		}

		// Debugging: headings/body are fine; buttons less important.
		if workflow.contains("debug") {
			if role == .heading { return 0.10 }
			if role == .bodyText { return 0.06 }
		}

		// Token hinting
		if t.contains("price") || t.contains("cost") || t.contains("dollar") { if role == .price { return 0.14 } }
		if t.contains("review") || t.contains("rating") { if role == .rating || role == .reviewCount { return 0.10 } }
		if t.contains("spec") || t.contains("specs") { if tagSet.contains("spec") { return 0.08 } }

		return 0
	}

	private func tokenize(_ s: String) -> [String] {
		s.lowercased()
			.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
			.map { String($0) }
			.filter { $0.count >= 3 }
	}
}

