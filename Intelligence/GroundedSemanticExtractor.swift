import Foundation

/// Deterministically converts grounded targets + graph nodes into semantic entities.
///
/// Philosophy:
/// - Prefer grounded targets (ranked, goal-relevant).
/// - Use OCR excerpt only as fallback enrichment.
/// - Suppress obvious chrome/menu noise.
struct GroundedSemanticExtractor: Sendable {

	func extract(
		graph: ScreenStateGraph,
		groundedTargets: [GroundedTarget],
		ocrFallback: String?,
		goal: String? = nil,
		windowTitle: String? = nil,
		maxEntities: Int = 24
	) -> [GroundedSemanticEntity] {
		var entities: [GroundedSemanticEntity] = []
		entities.reserveCapacity(min(maxEntities, 12))

		// 1) From grounded targets (primary)
		for t in groundedTargets {
			guard entities.count < maxEntities else { break }
			guard let node = graph.node(id: t.nodeId) else { continue }
			if shouldSuppressChrome(nodeText: node.title, role: node.role, goal: goal) { continue }
			// Phase 4N: also drop nodes whose text echoes the current runtime goal
			// (e.g., the planner-derived title "Processing Search Firefox History…"
			// leaking back into OCR via the assistant panel).
			let dynChrome = GeneratedChromeFilter.shouldSuppress(
				line: node.title,
				runtimeGoal: goal,
				proposalTitle: nil,
				groundingSupport: .init(
					windowTitle: windowTitle,
					axText: nil,
					groundedNodeTexts: groundedTargets.map { $0.title },
					semanticTexts: entities.map { $0.text }
				)
			)
			if dynChrome.suppressed {
				let why = dynChrome.reason ?? "unknown"
				print("[GeneratedChromeFilter] suppressed=\"\(node.title.prefix(40))\" reason=\(why)")
				print("[SemanticEntityFilter] rejected reason=generated_chrome_echo detail=\(why) text=\"\(node.title.prefix(60))\"")
				continue
			}
			entities.append(contentsOf: entitiesFromNode(node: node, scoreHint: t.score, goal: goal))
		}

		// 2) OCR fallback (only if we have very few entities)
		if entities.count < 6, let ocrFallback, !ocrFallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			let ocrGraph = OCRGroundingExtractor().extract(from: ocrFallback)
			for node in ocrGraph.nodes where node.role != .root {
				guard entities.count < maxEntities else { break }
				if shouldSuppressChrome(nodeText: node.title, role: node.role, goal: goal) { continue }
				let dynChrome = GeneratedChromeFilter.shouldSuppress(
					line: node.title,
					runtimeGoal: goal,
					proposalTitle: nil,
					groundingSupport: .init(
						windowTitle: windowTitle,
						axText: nil,
						groundedNodeTexts: groundedTargets.map { $0.title },
						semanticTexts: entities.map { $0.text }
					)
				)
				if dynChrome.suppressed {
					print("[GeneratedChromeFilter] suppressed=\"\(node.title.prefix(40))\" reason=\(dynChrome.reason ?? "unknown")")
					continue
				}
				entities.append(contentsOf: entitiesFromNode(node: node, scoreHint: 0.35, goal: goal))
			}
		}

		// 3) Deduplicate by (type + normalizedValue/text)
		entities = dedupe(entities)

		// 4) Prefer product-ish entities first
		entities.sort {
			if $0.type != $1.type {
				return typePriority($0.type) > typePriority($1.type)
			}
			return $0.confidence > $1.confidence
		}

		return Array(entities.prefix(maxEntities))
	}

	// MARK: - Node conversion

	private func entitiesFromNode(node: ScreenStateNode, scoreHint: Double, goal: String?) -> [GroundedSemanticEntity] {
		let text = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return [] }

		let baseConf = min(1, max(0.15, (node.confidence * 0.65) + (scoreHint * 0.35)))

		// Headings / product titles should survive even if they contain spec-like tokens (e.g., "140W").
		// Emit a title entity first, then allow additional spec entities as secondary.
		var out: [GroundedSemanticEntity] = []
		if node.role == .heading || node.semanticTags.map({ $0.lowercased() }).contains("title") {
			let typ: SemanticEntityType = looksLikeProductTitle(text, goal: goal) ? .productTitle : .heading
			out.append(
				GroundedSemanticEntity(
					id: makeEntityId(type: typ, sourceNodeId: node.stableId, normalized: normalizeFreeform(text)),
					type: typ,
					text: text,
					normalizedValue: normalizeFreeform(text),
					confidence: min(1, baseConf + 0.10),
					sourceNodeId: node.stableId,
					role: node.role,
					tags: node.semanticTags + (typ == .productTitle ? ["product"] : ["heading"])
				)
			)
			// Continue to allow spec extraction as secondary signal.
		}

		// Price
		if let priceResult = PriceNormalizer.normalize(rawText: text) {
			return out + [
				GroundedSemanticEntity(
					id: makeEntityId(type: .price, sourceNodeId: node.stableId, normalized: priceResult.normalized),
					type: .price,
					text: text,
					normalizedValue: priceResult.normalized,
					confidence: priceResult.confidence,
					sourceNodeId: node.stableId,
					role: node.role,
					tags: node.semanticTags + ["price"]
				),
			]
		}

		// Discount
		if let disc = parseDiscount(text) {
			return out + [
				GroundedSemanticEntity(
					id: makeEntityId(type: .discount, sourceNodeId: node.stableId, normalized: disc.normalized),
					type: .discount,
					text: disc.raw,
					normalizedValue: disc.normalized,
					confidence: min(1, baseConf + 0.12),
					sourceNodeId: node.stableId,
					role: node.role,
					tags: node.semanticTags + ["discount"]
				),
			]
		}

		// Rating
		if let rating = parseRating(text) {
			return out + [
				GroundedSemanticEntity(
					id: makeEntityId(type: .rating, sourceNodeId: node.stableId, normalized: rating.normalized),
					type: .rating,
					text: rating.raw,
					normalizedValue: rating.normalized,
					confidence: min(1, baseConf + 0.10),
					sourceNodeId: node.stableId,
					role: node.role,
					tags: node.semanticTags + ["rating"]
				),
			]
		}

		// Review count
		if let reviews = parseReviewCount(text) {
			return out + [
				GroundedSemanticEntity(
					id: makeEntityId(type: .reviewCount, sourceNodeId: node.stableId, normalized: reviews.normalized),
					type: .reviewCount,
					text: reviews.raw,
					normalizedValue: reviews.normalized,
					confidence: min(1, baseConf + 0.08),
					sourceNodeId: node.stableId,
					role: node.role,
					tags: node.semanticTags + ["reviews"]
				),
			]
		}

		// Specification (e.g., "140W", "10,000mAh", "USB-C")
		if let specResult = SpecNormalizer.normalize(rawText: text) {
			var tags = node.semanticTags + ["spec"]
			if let role = specResult.role {
				tags.append(role)
			}
			return out + [
				GroundedSemanticEntity(
					id: makeEntityId(type: .specification, sourceNodeId: node.stableId, normalized: specResult.normalized),
					type: .specification,
					text: text,
					normalizedValue: specResult.normalized,
					confidence: min(1, baseConf + 0.06),
					sourceNodeId: node.stableId,
					role: node.role,
					tags: tags
				),
			]
		}

		// Feature/body fallback
		let typ: SemanticEntityType = node.role == .bodyText ? .feature : .unknown
		return out + [
			GroundedSemanticEntity(
				id: makeEntityId(type: typ, sourceNodeId: node.stableId, normalized: normalizeFreeform(text)),
				type: typ,
				text: text,
				normalizedValue: normalizeFreeform(text),
				confidence: baseConf,
				sourceNodeId: node.stableId,
				role: node.role,
				tags: node.semanticTags + (typ == .feature ? ["feature"] : [])
			),
		]
	}

	// MARK: - Chrome suppression

	private func shouldSuppressChrome(nodeText: String, role: ScreenStateRole, goal: String? = nil) -> Bool {
		if role == .menuItem || role == .toolbarItem { return true }
		let t = nodeText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		if t.isEmpty { return true }

		let chromeWords: Set<String> = [
			"file", "edit", "view", "history", "bookmarks", "profiles", "tools", "window", "help",
			"tabs", "tab", "back", "forward", "reload", "home", "view site information", "processing ...",
			"firefox", "google chrome", "safari", "arc", "new tab"
		]
		if chromeWords.contains(t) { return true }

		// URLs
		if t.hasPrefix("http://") || t.hasPrefix("https://") || t.contains("://") || t.contains("www.") || t.hasSuffix(".com") || t.hasSuffix(".ca") {
			return true
		}

		// Assistant / Contextual proposal text
		let assistantKeywords = [
			"generated", "want me to help", "runtime phase", "actions taken", "processing ...",
			"contextual", "proposal", "prepare execution", "execute", "eligible=yes", "allows_float"
		]
		for keyword in assistantKeywords {
			if t.contains(keyword) { return true }
		}

		// Goal echo
		if let goal = goal {
			let g = goal.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
			if t == g || (g.hasPrefix("compare ") && t.hasPrefix("compare ")) || (g.contains(t) && g.count - t.count < 15) {
				return true
			}
		}

		// Very short tokens are usually chrome.
		if t.count <= 2 { return true }
		return false
	}

	// MARK: - Parsers

	private struct ParsedValue { let raw: String; let normalized: String }

	private func parseDiscount(_ text: String) -> ParsedValue? {
		let matches = findRegex(#"([0-9]{1,2})\s*%(\s*off)?"#, in: text.lowercased())
		if let m = matches.first, let pct = m.groups.first {
			return ParsedValue(raw: pct + "%", normalized: pct)
		}
		return nil
	}

	private func parseRating(_ text: String) -> ParsedValue? {
		let matches = findRegex(#"([0-5]\.[0-9])\s*(?:stars|out of\s*5)?"#, in: text.lowercased())
		if let m = matches.first, let val = m.groups.first {
			return ParsedValue(raw: val, normalized: val)
		}
		return nil
	}

	private func parseReviewCount(_ text: String) -> ParsedValue? {
		let matches = findRegex(#"([0-9][0-9,]{2,})\s*(?:reviews|ratings)"#, in: text.lowercased())
		if let m = matches.first, let num = m.groups.first {
			let normalized = num.replacingOccurrences(of: ",", with: "")
			return ParsedValue(raw: num, normalized: normalized)
		}
		return nil
	}

	private func looksLikeProductTitle(_ text: String, goal: String? = nil) -> Bool {
		let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard t.count >= 18 else { return false }

		if shouldSuppressChrome(nodeText: t, role: .root, goal: goal) { return false }

		let lower = t.lowercased()
		// Domain guard: email/inbox chrome should never be treated as a product title.
		if lower.contains("gmail") || lower.contains("outlook") || lower.contains("inbox") || lower.contains("mail.google.com") {
			print("[SemanticEntityFilter] rejected reason=email_chrome_not_product text=\"\(t.prefix(60))\"")
			return false
		}
		if lower.contains("review") || lower.contains("ratings") { return false }
		let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
		return Double(letters) / Double(max(1, t.count)) >= 0.55
	}

	private func normalizeFreeform(_ s: String) -> String {
		s.lowercased()
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
	}

	private struct RegexMatch {
		let groups: [String]
	}

	private func findRegex(_ pattern: String, in text: String) -> [RegexMatch] {
		guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
		let range = NSRange(text.startIndex..<text.endIndex, in: text)
		let ms = re.matches(in: text, options: [], range: range)
		return ms.map { m in
			var groups: [String] = []
			if m.numberOfRanges > 1 {
				for i in 1..<m.numberOfRanges {
					let r = m.range(at: i)
					if let rr = Range(r, in: text) {
						groups.append(String(text[rr]))
					}
				}
			}
			return RegexMatch(groups: groups)
		}
	}

	// MARK: - Dedupe / sorting

	private func dedupe(_ entities: [GroundedSemanticEntity]) -> [GroundedSemanticEntity] {
		var bestByKey: [String: GroundedSemanticEntity] = [:]
		for e in entities {
			let key = "\(e.type.rawValue)|" + (e.normalizedValue ?? e.text.lowercased())
			if let prior = bestByKey[key] {
				if e.confidence > prior.confidence { bestByKey[key] = e }
			} else {
				bestByKey[key] = e
			}
		}
		return Array(bestByKey.values)
	}

	private func typePriority(_ t: SemanticEntityType) -> Int {
		switch t {
		case .productTitle: return 100
		case .price: return 90
		case .discount: return 85
		case .rating: return 80
		case .reviewCount: return 75
		case .specification: return 70
		case .feature: return 60
		case .heading: return 50
		case .body: return 40
		default: return 10
		}
	}

	private func makeEntityId(type: SemanticEntityType, sourceNodeId: String, normalized: String) -> String {
		let material = "\(type.rawValue)|\(sourceNodeId)|\(normalized)"
		return "se_" + stableHash(material)
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

// MARK: - Normalizers

struct PriceNormalizer: Sendable {
	struct NormalizationResult: Sendable {
		let raw: String
		let normalized: String
		let confidence: Double
		let accepted: Bool
		let reason: String
	}

	static func normalize(rawText: String) -> NormalizationResult? {
		let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty { return nil }

		// Match currency symbol followed by numbers, separator (dot, comma, space) and 2-digit cents
		// Or match just numbers that look like price
		let pattern = #"^\s*(?:\$|USD|CAD|£|€)?\s*([0-9]{1,5})(?:\s*([.,\s])\s*([0-9]{2}))?\s*$"#
		guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
		let nsString = trimmed as NSString
		let results = regex.matches(in: trimmed, options: [], range: NSRange(location: 0, length: nsString.length))

		guard let match = results.first else { return nil }

		let hasSymbol = trimmed.contains("$") || trimmed.lowercased().contains("usd") || trimmed.lowercased().contains("cad")
		let dollarRange = match.range(at: 1)
		guard dollarRange.location != NSNotFound else { return nil }
		let dollars = nsString.substring(with: dollarRange)

		var cents: String? = nil
		var separator: String? = nil

		if match.numberOfRanges >= 3 {
			let sepRange = match.range(at: 2)
			if sepRange.location != NSNotFound {
				separator = nsString.substring(with: sepRange)
			}
		}
		if match.numberOfRanges >= 4 {
			let centsRange = match.range(at: 3)
			if centsRange.location != NSNotFound {
				cents = nsString.substring(with: centsRange)
			}
		}

		var normalizedVal = ""
		var confidence = hasSymbol ? 0.90 : 0.60
		var accepted = true
		var reason = "Standard price format detected"

		if let c = cents {
			normalizedVal = "\(dollars).\(c)"
			if separator == " " {
				reason = "Space separator normalized to decimal point"
				confidence = min(confidence, 0.75)
			}
		} else {
			if dollars.count >= 4 {
				normalizedVal = "\(dollars).00"
				confidence = 0.25
				accepted = false
				reason = "Ambiguous large 4-digit price without decimal separator"
			} else {
				normalizedVal = "\(dollars).00"
				reason = "Integer price normalized with .00 cents"
			}
		}

		// Adjust confidence by length and letter composition
		let lettersCount = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
		if lettersCount > 5 {
			confidence -= 0.2
			if confidence < 0.4 {
				accepted = false
				reason = "Too many non-price letters in text"
			}
		}

		let finalConf = min(1.0, max(0.0, confidence))
		let acceptedStr = accepted ? "yes" : "no"
		print("[PriceNormalization] raw=\(trimmed) normalized=\(normalizedVal) confidence=\(String(format: "%.2f", finalConf)) accepted=\(acceptedStr) reason=\(reason)")

		return NormalizationResult(
			raw: trimmed,
			normalized: "$" + normalizedVal,
			confidence: finalConf,
			accepted: accepted,
			reason: reason
		)
	}
}

struct SpecNormalizer: Sendable {
	struct SpecResult: Sendable {
		let raw: String
		let normalized: String
		let role: String?
	}

	static func normalize(rawText: String) -> SpecResult? {
		let lower = rawText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		if lower.isEmpty { return nil }

		// 1) Wattage: E.g., "160w", "160 w", "160 watt", "160-watts"
		let wattPattern = #"\b([0-9]{2,4})\s*(?:w|watt|watts)\b"#
		if let regex = try? NSRegularExpression(pattern: wattPattern, options: []),
		   let match = regex.firstMatch(in: lower, options: [], range: NSRange(lower.startIndex..<lower.endIndex, in: lower)),
		   let valRange = Range(match.range(at: 1), in: lower) {
			let watts = String(lower[valRange])
			let normalized = "\(watts)W"

			// Check for nearby evidence for roles
			var role: String? = nil
			if lower.contains("max") || lower.contains("maximum") {
				if lower.contains("single") || lower.contains("one") {
					role = "single-port max"
				} else if lower.contains("total") || lower.contains("all") {
					role = "total output"
				} else {
					role = "max output"
				}
			}
			return SpecResult(raw: rawText, normalized: normalized, role: role)
		}

		// 2) mAh: E.g., "10,000mah", "20000 mah"
		let mahPattern = #"\b([0-9][0-9,]{2,5})\s*(?:mah)\b"#
		if let regex = try? NSRegularExpression(pattern: mahPattern, options: []),
		   let match = regex.firstMatch(in: lower, options: [], range: NSRange(lower.startIndex..<lower.endIndex, in: lower)),
		   let valRange = Range(match.range(at: 1), in: lower) {
			let mah = String(lower[valRange]).replacingOccurrences(of: ",", with: "")
			return SpecResult(raw: rawText, normalized: "\(mah)mAh", role: nil)
		}

		// 3) Ports: E.g., "4 ports", "3-port"
		let portPattern = #"\b([0-9]{1,2})\s*(?:ports?|port)\b"#
		if let regex = try? NSRegularExpression(pattern: portPattern, options: []),
		   let match = regex.firstMatch(in: lower, options: [], range: NSRange(lower.startIndex..<lower.endIndex, in: lower)),
		   let valRange = Range(match.range(at: 1), in: lower) {
			let ports = String(lower[valRange])
			return SpecResult(raw: rawText, normalized: "\(ports) ports", role: nil)
		}

		return nil
	}
}
