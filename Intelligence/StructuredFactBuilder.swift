import Foundation

struct StructuredFact: Sendable, Equatable, Codable, Identifiable {
	let id: String
	let category: String
	let title: String
	let attributes: [String: String]
	let confidence: Double
	let sourceEntityIds: [String]
}

/// Converts semantic entities into structured facts suitable for runtime reasoning and answer synthesis.
struct StructuredFactBuilder: Sendable {

	func buildFacts(from entities: [GroundedSemanticEntity], goal: String? = nil, windowTitle: String? = nil, maxFacts: Int = 12) -> [StructuredFact] {
		var facts: [StructuredFact] = []

		let product = buildProductFact(from: entities, goal: goal, windowTitle: windowTitle)
		if let product { facts.append(product) }

		let attributes = buildAttributeFacts(from: entities, goal: goal)
		facts.append(contentsOf: attributes)

		// Deduplicate by (category+title)
		var best: [String: StructuredFact] = [:]
		for f in facts {
			let key = "\(f.category)|\(f.title.lowercased())"
			if let prior = best[key] {
				if f.confidence > prior.confidence { best[key] = f }
			} else {
				best[key] = f
			}
		}
		let merged = Array(best.values).sorted { $0.confidence > $1.confidence }
		return Array(merged.prefix(maxFacts))
	}

	func renderFactsForRuntime(_ facts: [StructuredFact]) -> [String] {
		guard !facts.isEmpty else { return ["No structured facts could be extracted from grounded content."] }

		var lines: [String] = []
		for f in facts {
			if f.category == "product" {
				lines.append("Product: \(f.title)")
				for (k, v) in f.attributes.sorted(by: { $0.key < $1.key }) {
					lines.append("- \(k): \(v)")
				}
				continue
			}
			if !f.attributes.isEmpty {
				let attrs = f.attributes.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
				lines.append("\(f.title) (\(attrs))")
			} else {
				lines.append(f.title)
			}
		}
		return lines
	}

	// MARK: - Builders

	private func buildProductFact(from entities: [GroundedSemanticEntity], goal: String?, windowTitle: String?) -> StructuredFact? {
		var windowTitleCandidate: String? = nil
		if let wt = windowTitle {
			windowTitleCandidate = cleanWindowTitle(wt)
		}

		let validTitles = entities.filter { e in
			(e.type == .productTitle || e.type == .heading) &&
			!Self.isURL(e.text) &&
			!Self.isChromeOrAssistant(e.text) &&
			!Self.isGoalEchoText(e.text, goal: goal)
		}.sorted { $0.confidence > $1.confidence }

		var bestTitle = ""
		var bestConf = 0.0
		var sourceIds: [String] = []

		if let top = validTitles.first {
			bestTitle = cleanProductTitle(top.text)
			bestConf = top.confidence
			sourceIds.append(top.id)
		}

		if let wtCandidate = windowTitleCandidate {
			let cleanedWT = cleanProductTitle(wtCandidate)
			if bestTitle.isEmpty || bestConf < 0.65 || bestTitle.contains("...") || bestTitle.contains("…") {
				bestTitle = cleanedWT
				bestConf = max(bestConf, 0.85)
			}
		}

		guard !bestTitle.isEmpty else { return nil }

		var attrs: [String: String] = [:]
		// Filter out prices with confidence < 0.5 to reject low-confidence/malformed ones
		if let price = entities.filter({ $0.type == .price }).sorted(by: { $0.confidence > $1.confidence }).first, price.confidence >= 0.5 {
			attrs["price"] = price.text
		}
		if let disc = entities.filter({ $0.type == .discount }).sorted(by: { $0.confidence > $1.confidence }).first {
			attrs["discount"] = disc.text
		}
		if let rating = entities.filter({ $0.type == .rating }).sorted(by: { $0.confidence > $1.confidence }).first {
			attrs["rating"] = rating.text
		}
		if let reviews = entities.filter({ $0.type == .reviewCount }).sorted(by: { $0.confidence > $1.confidence }).first {
			attrs["reviews"] = reviews.text
		}

		// Specs: pick a few high-confidence unique ones
		let specs = entities.filter { $0.type == .specification }.sorted { $0.confidence > $1.confidence }
		if !specs.isEmpty {
			let unique = Array(Set(specs.map { $0.normalizedValue ?? $0.text })).prefix(4)
			attrs["specs"] = unique.joined(separator: ", ")
		}

		let id = "fact_product_" + stableHash(bestTitle.lowercased())
		let sourceIdsCombined = sourceIds + (entities.prefix(8).map(\.id))
		return StructuredFact(
			id: id,
			category: "product",
			title: bestTitle,
			attributes: attrs,
			confidence: bestConf,
			sourceEntityIds: Array(Set(sourceIdsCombined))
		)
	}

	private func buildAttributeFacts(from entities: [GroundedSemanticEntity], goal: String?) -> [StructuredFact] {
		var facts: [StructuredFact] = []

		for e in entities where e.type == .feature || e.type == .specification {
			let title = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
			if Self.isURL(title) || Self.isChromeOrAssistant(title) || Self.isGoalEchoText(title, goal: goal) {
				continue
			}
			if title.hasPrefix("Summary:") || title.hasPrefix("Product:") || title.hasPrefix("Answer:") || title.hasPrefix("Context only:") || title.hasPrefix("Partial:") {
				continue
			}
			let id = "fact_attr_" + stableHash("\(e.type.rawValue)|\(title.lowercased())")
			let category = e.type == .specification ? "spec" : "feature"
			facts.append(
				StructuredFact(
					id: id,
					category: category,
					title: title,
					attributes: [:],
					confidence: e.confidence,
					sourceEntityIds: [e.id]
				)
			)
		}

		return facts
	}

	// MARK: - Cleaning Helpers

	private func cleanStoreSuffixes(_ s: String) -> String {
		var t = s
		let patterns = [
			#":\s*Amazon\.[a-zA-Z.]+(?::\s*[a-zA-Z\s&,]+)?"#,
			#"\s*[-:|]\s*Amazon\.[a-zA-Z.]+\s*"#,
			#"\s*[-:|]\s*Amazon\b\s*"#,
			#"\s*[-:|]\s*Best\s*Buy\b\s*"#
		]
		for pat in patterns {
			if let regex = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) {
				let range = NSRange(t.startIndex..<t.endIndex, in: t)
				t = regex.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: "")
			}
		}
		t = t.replacingOccurrences(of: "...", with: "")
		t = t.replacingOccurrences(of: "…", with: "")
		return t.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private func cleanWindowTitle(_ title: String) -> String? {
		var t = title
		let browserSuffixes = [" - Firefox", " - Google Chrome", " - Safari", " - Arc"]
		for suffix in browserSuffixes {
			if t.hasSuffix(suffix) {
				t = String(t.dropLast(suffix.count))
			}
		}
		t = cleanStoreSuffixes(t)
		t = t.trimmingCharacters(in: .whitespacesAndNewlines)
		if Self.isURL(t) || t.count < 10 || Self.isChromeOrAssistant(t) {
			return nil
		}
		return t
	}

	private func cleanProductTitle(_ title: String) -> String {
		return cleanStoreSuffixes(title)
	}

	private static func isURL(_ s: String) -> Bool {
		let t = s.lowercased()
		return t.contains("://") || t.contains("www.") || t.hasSuffix(".com") || t.hasSuffix(".ca") || t.contains(".ca/") || t.contains(".com/")
	}

	private static func isChromeOrAssistant(_ s: String) -> Bool {
		let t = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		if t.isEmpty { return true }
		let chromeList = [
			"file", "edit", "view", "history", "bookmarks", "profiles", "tools", "window", "help",
			"tabs", "tab", "back", "forward", "reload", "home", "view site information", "processing ...",
			"firefox", "google chrome", "safari", "arc", "new tab"
		]
		if chromeList.contains(t) { return true }

		let assistantKeywords = [
			"generated", "want me to help", "runtime phase", "actions taken", "processing ...",
			"contextual", "proposal", "prepare execution", "execute", "eligible=yes", "allows_float"
		]
		for keyword in assistantKeywords {
			if t.contains(keyword) { return true }
		}
		return false
	}

	private static func isGoalEchoText(_ text: String, goal: String?) -> Bool {
		guard let goal = goal else { return false }
		let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		let g = goal.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		if t == g { return true }
		if g.hasPrefix("compare ") && t.hasPrefix("compare ") { return true }
		if g.contains(t) && g.count - t.count < 15 { return true }
		return false
	}

	private func stableHash(_ s: String) -> String {
		var hash: UInt64 = 14695981039346656037
		for b in s.utf8 {
			hash ^= UInt64(b)
			hash &*= 1099511628211
		}
		return String(format: "%016llx", hash)
	}
}

