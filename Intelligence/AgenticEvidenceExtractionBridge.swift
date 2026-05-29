import Foundation

// MARK: - Observation Model

enum AgenticEvidenceObservationSource: String, Sendable, Codable, CaseIterable {
	case windowTitle = "window_title"
	case ocr
	case ax
	case screenGraph = "screen_graph"
	case semanticEntity = "semantic_entity"
	case structuredFact = "structured_fact"
	case browsingHistory = "browsing_history"
}

struct AgenticEvidenceObservation: Sendable, Equatable, Codable, Identifiable {
	let id: String
	let kind: AgenticEvidenceKind
	let text: String
	let normalized: String
	let confidence: Double
	let source: AgenticEvidenceObservationSource
	let reason: String

	init(
		id: String,
		kind: AgenticEvidenceKind,
		text: String,
		normalized: String,
		confidence: Double,
		source: AgenticEvidenceObservationSource,
		reason: String
	) {
		self.id = id
		self.kind = kind
		self.text = text
		self.normalized = normalized
		self.confidence = min(1, max(0, confidence))
		self.source = source
		self.reason = reason
	}
}

// MARK: - Bridge

/// Phase 4P — Evidence Extraction Bridge.
///
/// Converts runtime signals (window title, OCR, AX, graph nodes, semantic entities, structured facts,
/// browsing comparison memory) into normalized evidence observations so the evidence assessor can
/// satisfy required slots without needing extra control actions.
enum AgenticEvidenceExtractionBridge {

	static func extract(
		goal: String,
		workflow: String,
		windowTitle: String,
		ocrText: String?,
		axText: String?,
		graph: ScreenStateGraph?,
		semanticEntities: [GroundedSemanticEntity],
		structuredFacts: [StructuredFact],
		comparisonTitles: [String] = []
	) -> [AgenticEvidenceObservation] {
		var observations: [AgenticEvidenceObservation] = []
		let emailContext = isEmailContext(goal: goal, workflow: workflow, windowTitle: windowTitle, bundleHint: nil)

		let cleanedTitle = normalizeWindowTitle(windowTitle)
		if let cleanedTitle {
			let titleEvidence = emailContext
				? extractEmailFromWindowTitle(cleanedTitle)
				: extractFromWindowTitle(cleanedTitle, workflow: workflow)
			observations.append(contentsOf: titleEvidence)
		}

		// Structured facts → evidence (highest priority after semantic entities).
		observations.append(contentsOf: extractFromStructuredFacts(structuredFacts))

		// Semantic entities → evidence (kept to support assessor fallback; already deduped downstream).
		observations.append(contentsOf: extractFromSemanticEntities(semanticEntities))

		// OCR / AX fallback.
			let chromeSupport = GeneratedChromeFilter.GroundingSupport(
				windowTitle: windowTitle,
				axText: axText,
				groundedNodeTexts: graph?.nodes.map { $0.title } ?? [],
				semanticTexts: semanticEntities.map { $0.text } + structuredFacts.map { $0.title }
			)

			if let ocrText {
				let filtered = GeneratedChromeFilter.filter(
					text: ocrText,
					runtimeGoal: goal,
					proposalTitle: nil,
					groundingSupport: chromeSupport
				).filteredText
				if emailContext {
					observations.append(contentsOf: extractEmailSignals(fromText: filtered, source: .ocr))
				} else {
					observations.append(contentsOf: extractSpecsAndSignals(fromText: filtered, source: .ocr))
				}
			}
			if let axText {
				let filtered = GeneratedChromeFilter.filter(
					text: axText,
					runtimeGoal: goal,
					proposalTitle: nil,
					groundingSupport: chromeSupport
				).filteredText
				if emailContext {
					observations.append(contentsOf: extractEmailSignals(fromText: filtered, source: .ax))
				} else {
					observations.append(contentsOf: extractSpecsAndSignals(fromText: filtered, source: .ax))
				}
			}

		// Graph nodes: last resort evidence from node titles/text.
		if let graph {
			observations.append(contentsOf: extractFromGraph(graph, goal: goal))
		}

		// Comparison candidates from browsing history.
		if !comparisonTitles.isEmpty {
			for t in comparisonTitles.prefix(4) {
				let normalized = normalizeText(t)
				guard !normalized.isEmpty else { continue }
				let id = stableId(prefix: "cmp", value: normalized)
				observations.append(
					AgenticEvidenceObservation(
						id: id,
						kind: .comparisonCandidate,
						text: t,
						normalized: normalized,
						confidence: 0.72,
						source: .browsingHistory,
						reason: "distinct_recent_titles"
					)
				)
			}
		}

		// Final filtering + dedupe (by kind+normalized).
			observations = filterChrome(observations, runtimeGoal: goal, chromeSupport: chromeSupport)
			if emailContext {
				observations = applyDomainEvidenceGuard(observations, domain: "email")
			}
			observations = dedupe(observations)

		for o in observations.prefix(24) {
			let conf = String(format: "%.2f", o.confidence)
			print("[EvidenceObservation] kind=\(o.kind.rawValue) source=\(o.source.rawValue) text=\"\(o.text.prefix(80))\" confidence=\(conf)")
		}

		return observations
	}

	// MARK: - Window title extraction

	private static func extractFromWindowTitle(_ title: String, workflow: String) -> [AgenticEvidenceObservation] {
		var out: [AgenticEvidenceObservation] = []
		let normalizedTitle = normalizeText(title)
		guard !normalizedTitle.isEmpty else { return [] }

		// Product-like title: use the first chunk before a comma, then fall back to whole title.
		let productCandidate: String = {
			let parts = title.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
			if let first = parts.first, first.count >= 8 { return String(first).trimmingCharacters(in: .whitespacesAndNewlines) }
			return title
		}()
		let productNormalized = normalizeText(productCandidate)
		if !productNormalized.isEmpty && looksProductLike(productCandidate) {
			out.append(
				AgenticEvidenceObservation(
					id: stableId(prefix: "wt_product", value: productNormalized),
					kind: .productTitle,
					text: productCandidate,
					normalized: productNormalized,
					confidence: 0.86,
					source: .windowTitle,
					reason: "window_title_product_like"
				)
			)
		}

		// Specs from the full title.
		out.append(contentsOf: extractSpecsAndSignals(fromText: title, source: .windowTitle))

		// In browsing workflows, title alone can imply "pageSummary" is present.
		if workflow.lowercased().contains("brows") && productNormalized.count > 10 {
			out.append(
				AgenticEvidenceObservation(
					id: stableId(prefix: "wt_summary", value: productNormalized),
					kind: .pageSummary,
					text: "title_present",
					normalized: "title_present",
					confidence: 0.40,
					source: .windowTitle,
					reason: "title_as_page_hint"
				)
			)
		}

		return out
	}

	// MARK: - Email extraction

	private static func extractEmailFromWindowTitle(_ title: String) -> [AgenticEvidenceObservation] {
		var out: [AgenticEvidenceObservation] = []
		let lower = title.lowercased()
		if lower.contains("gmail") || lower.contains("outlook") || lower.contains("inbox") || lower.contains("mail.google.com") {
			out.append(
				AgenticEvidenceObservation(
					id: stableId(prefix: "wt_inbox", value: "inbox_context"),
					kind: .inboxContext,
					text: "inbox_context",
					normalized: "inbox_context",
					confidence: 0.55,
					source: .windowTitle,
					reason: "email_window_title"
				)
			)
		}

		// If the title looks like a thread subject (not just "Inbox" or account name), treat as subject.
		let cleaned = lower
			.replacingOccurrences(of: " - gmail", with: "")
			.replacingOccurrences(of: " - outlook", with: "")
			.replacingOccurrences(of: "gmail", with: "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		let subjectCandidate = title.trimmingCharacters(in: .whitespacesAndNewlines)
		let isLikelyChrome = cleaned == "inbox" || cleaned.contains("inbox") && cleaned.split(separator: " ").count <= 3
		if !isLikelyChrome, subjectCandidate.count >= 10 {
			let norm = normalizeText(subjectCandidate)
			if !norm.isEmpty {
				out.append(
					AgenticEvidenceObservation(
						id: stableId(prefix: "wt_subject", value: norm),
						kind: .emailSubject,
						text: subjectCandidate,
						normalized: norm,
						confidence: 0.50,
						source: .windowTitle,
						reason: "email_subject_from_title"
					)
				)
			}
		}
		return out
	}

	private static func extractEmailSignals(fromText text: String, source: AgenticEvidenceObservationSource) -> [AgenticEvidenceObservation] {
		var out: [AgenticEvidenceObservation] = []
		let lines = text
			.split(separator: "\n")
			.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }

		for line in lines {
			let lower = line.lowercased()
			// Suppress common email chrome labels.
			let chromeNeedles = ["gmail", "inbox", "starred", "sent", "drafts", "spam", "trash", "compose", "meet", "chat", "mail.google.com"]
			if chromeNeedles.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") }) { continue }
			if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.contains("://") { continue }

			// Email address → sender evidence (optional).
			if lower.contains("@"), lower.contains(".") {
				let norm = normalizeText(line)
				if !norm.isEmpty {
					out.append(
						AgenticEvidenceObservation(
							id: stableId(prefix: "sender", value: "\(source.rawValue)|\(norm)"),
							kind: .emailSender,
							text: line,
							normalized: norm,
							confidence: 0.45,
							source: source,
							reason: "email_address_like"
						)
					)
				}
				continue
			}

			// Timestamp-ish tokens.
			if lower.range(of: #"\b\d{1,2}:\d{2}\b"#, options: .regularExpression) != nil
				|| lower.range(of: #"\b(?:mon|tue|wed|thu|fri|sat|sun)\b"#, options: .regularExpression) != nil {
				let norm = normalizeText(line)
				if !norm.isEmpty {
					out.append(
						AgenticEvidenceObservation(
							id: stableId(prefix: "ts", value: "\(source.rawValue)|\(norm)"),
							kind: .timestamp,
							text: line,
							normalized: norm,
							confidence: 0.40,
							source: source,
							reason: "timestamp_like"
						)
					)
				}
				continue
			}

			// General line that might represent a subject/snippet in a message list.
			if line.count >= 12 {
				let norm = normalizeText(line)
				if !norm.isEmpty {
					out.append(
						AgenticEvidenceObservation(
							id: stableId(prefix: "snippet", value: "\(source.rawValue)|\(norm)"),
							kind: .emailSnippet,
							text: line,
							normalized: norm,
							confidence: 0.42,
							source: source,
							reason: "message_list_line"
						)
					)
					// Treat the same line as subject when we lack a stronger split.
					out.append(
						AgenticEvidenceObservation(
							id: stableId(prefix: "subject", value: "\(source.rawValue)|\(norm)"),
							kind: .emailSubject,
							text: line,
							normalized: norm,
							confidence: 0.40,
							source: source,
							reason: "subject_from_message_line"
						)
					)
				}
			}
		}

		// If we extracted anything email-like, add a message_list marker.
		if out.contains(where: { $0.kind == .emailSnippet || $0.kind == .emailSubject }) {
			out.append(
				AgenticEvidenceObservation(
					id: stableId(prefix: "msg_list", value: "\(source.rawValue)|message_list"),
					kind: .messageList,
					text: "message_list",
					normalized: "message_list",
					confidence: 0.45,
					source: source,
					reason: "derived_from_lines"
				)
			)
		}
		return out
	}

	private static func applyDomainEvidenceGuard(_ observations: [AgenticEvidenceObservation], domain: String) -> [AgenticEvidenceObservation] {
		guard domain == "email" else { return observations }
		let blocked: Set<AgenticEvidenceKind> = [.productTitle, .specs, .price, .rating, .reviewCount, .reviewText, .comparisonCandidate]
		var out: [AgenticEvidenceObservation] = []
		for o in observations {
			if blocked.contains(o.kind) {
				print("[DomainEvidenceGuard] blocked kind=\(o.kind.rawValue) reason=email_context")
				continue
			}
			out.append(o)
		}
		return out
	}

	private static func isEmailContext(
		goal: String,
		workflow: String,
		windowTitle: String,
		bundleHint: String?
	) -> Bool {
		let g = goal.lowercased()
		let wf = workflow.lowercased()
		let t = windowTitle.lowercased()
		let b = (bundleHint ?? "").lowercased()
		let needles = ["gmail", "outlook", "inbox", "mail.google.com"]
		if needles.contains(where: { t.contains($0) }) { return true }
		if needles.contains(where: { g.contains($0) }) { return true }
		if wf.contains("review") && (t.contains("inbox") || g.contains("email") || g.contains("emails")) { return true }
		if b.contains("outlook") { return true }
		return false
	}

	// MARK: - Structured facts / entities

	private static func extractFromStructuredFacts(_ facts: [StructuredFact]) -> [AgenticEvidenceObservation] {
		var out: [AgenticEvidenceObservation] = []
		for f in facts {
			if f.category == "product" {
				let normalized = normalizeText(f.title)
				if !normalized.isEmpty {
					out.append(
						AgenticEvidenceObservation(
							id: stableId(prefix: "fact_product", value: normalized),
							kind: .productTitle,
							text: f.title,
							normalized: normalized,
							confidence: max(0.70, f.confidence),
							source: .structuredFact,
							reason: "structured_product_fact"
						)
					)
				}
				if let specs = f.attributes["specs"] {
					out.append(contentsOf: extractSpecsAndSignals(fromText: specs, source: .structuredFact))
				}
				if let price = f.attributes["price"] {
					// Phase 4U: price evidence must be plausible and normalized; avoid
					// letting placeholders like "$9999" satisfy evidence.
					if let normalized = PriceNormalizer.normalize(rawText: price),
					   normalized.accepted,
					   let numeric = extractNumericPrice(normalized.normalized),
					   numeric > 0,
					   numeric <= 5000 {
						let norm = normalizeText(normalized.normalized)
						if !norm.isEmpty {
							out.append(
								AgenticEvidenceObservation(
									id: stableId(prefix: "fact_price", value: norm),
									kind: .price,
									text: normalized.normalized,
									normalized: norm,
									confidence: max(0.55, normalized.confidence),
									source: .structuredFact,
									reason: "structured_price_normalized"
								)
							)
						}
					}
				}
			}
			if f.category == "spec" || f.category == "feature" {
				let norm = normalizeText(f.title)
				if !norm.isEmpty {
					out.append(
						AgenticEvidenceObservation(
							id: stableId(prefix: "fact_spec", value: norm),
							kind: .specs,
							text: f.title,
							normalized: norm,
							confidence: max(0.55, f.confidence),
							source: .structuredFact,
							reason: "structured_spec_feature"
						)
					)
				}
			}
		}
		return out
	}

	private static func extractFromSemanticEntities(_ entities: [GroundedSemanticEntity]) -> [AgenticEvidenceObservation] {
		var out: [AgenticEvidenceObservation] = []
		for e in entities {
			let norm = normalizeText(e.normalizedValue ?? e.text)
			guard !norm.isEmpty else { continue }
			switch e.type {
			case .productTitle:
				out.append(AgenticEvidenceObservation(
					id: stableId(prefix: "ent_product", value: norm),
					kind: .productTitle,
					text: e.text,
					normalized: norm,
					confidence: e.confidence,
					source: .semanticEntity,
					reason: "semantic_entity_product"
				))
			case .price:
				out.append(AgenticEvidenceObservation(
					id: stableId(prefix: "ent_price", value: norm),
					kind: .price,
					text: e.text,
					normalized: norm,
					confidence: e.confidence,
					source: .semanticEntity,
					reason: "semantic_entity_price"
				))
			case .rating:
				out.append(AgenticEvidenceObservation(
					id: stableId(prefix: "ent_rating", value: norm),
					kind: .rating,
					text: e.text,
					normalized: norm,
					confidence: e.confidence,
					source: .semanticEntity,
					reason: "semantic_entity_rating"
				))
			case .reviewCount:
				out.append(AgenticEvidenceObservation(
					id: stableId(prefix: "ent_reviews", value: norm),
					kind: .reviewCount,
					text: e.text,
					normalized: norm,
					confidence: e.confidence,
					source: .semanticEntity,
					reason: "semantic_entity_review_count"
				))
			case .feature, .specification:
				out.append(AgenticEvidenceObservation(
					id: stableId(prefix: "ent_specs", value: norm),
					kind: .specs,
					text: e.text,
					normalized: norm,
					confidence: e.confidence,
					source: .semanticEntity,
					reason: "semantic_entity_specs"
				))
			default:
				continue
			}
		}
		return out
	}

	// MARK: - Graph extraction

	private static func extractFromGraph(_ graph: ScreenStateGraph, goal: String) -> [AgenticEvidenceObservation] {
		var out: [AgenticEvidenceObservation] = []
		for node in graph.nodes.prefix(80) {
			let text = node.title
			let dynChrome = GeneratedChromeFilter.shouldSuppress(line: text, runtimeGoal: goal)
			if dynChrome.suppressed { continue }
			let norm = normalizeText(text)
			if norm.isEmpty { continue }
			if let price = extractFirstPrice(text) {
				out.append(AgenticEvidenceObservation(
					id: stableId(prefix: "graph_price", value: price.normalized),
					kind: .price,
					text: price.normalized,
					normalized: price.normalized,
					confidence: max(0.40, price.confidence),
					source: .screenGraph,
					reason: "graph_price_pattern:\(price.reason)"
				))
			}
			// Spec-like tokens (wattage, ports, GaN, etc.)
			out.append(contentsOf: extractSpecsAndSignals(fromText: text, source: .screenGraph))
		}
		return out
	}

	// MARK: - Spec extraction

	private static func extractSpecsAndSignals(fromText text: String, source: AgenticEvidenceObservationSource) -> [AgenticEvidenceObservation] {
		let t = text
		var out: [AgenticEvidenceObservation] = []

		let lowered = t.lowercased()

		// Wattage (e.g. 140W / 160 w)
		if let watt = matchFirst(pattern: #"\b(\d{2,3})\s*w\b"#, in: lowered) {
			let w = watt.replacingOccurrences(of: " ", with: "").uppercased()
			out.append(specObservation(text: w, source: source, reason: "wattage"))
		}

		// mAh capacity
		if let cap = matchFirst(pattern: #"\b(\d{2,3}[,]?\d{3})\s*mah\b"#, in: lowered) {
			let cleaned = cap.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
			out.append(specObservation(text: "\(cleaned)mAh", source: source, reason: "capacity"))
		}

		// Port count "4-port", "3 port"
		if let ports = matchFirst(pattern: #"\b(\d)\s*[-]?\s*port\b"#, in: lowered) {
			let cleaned = ports.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "-")
			out.append(specObservation(text: cleaned.capitalized, source: source, reason: "ports"))
		}

		// USB-C / USB C
		if lowered.contains("usb-c") || lowered.contains("usb c") || lowered.contains("type-c") {
			out.append(specObservation(text: "USB-C", source: source, reason: "usb_c"))
		}

		// GaN
		if lowered.contains("gan") {
			out.append(specObservation(text: "GaN", source: source, reason: "gan"))
		}

		// Compatibility keywords (treated as specs/features)
		let compat: [String] = ["macbook", "iphone", "ipad", "samsung", "pixel", "laptop"]
		for c in compat where lowered.contains(c) {
			out.append(specObservation(text: c.capitalized, source: source, reason: "compat"))
		}

		// Rating "4.6 stars"
		if let rating = matchFirst(pattern: #"\b(\d\.\d)\s*stars?\b"#, in: lowered) {
			out.append(
				AgenticEvidenceObservation(
					id: stableId(prefix: "rating", value: rating),
					kind: .rating,
					text: rating,
					normalized: rating,
					confidence: 0.55,
					source: source,
					reason: "rating_pattern"
				)
			)
		}

		// Review count "1,234 reviews"
		if let reviews = matchFirst(pattern: #"\b(\d{1,3}(?:,\d{3})*)\s+reviews?\b"#, in: lowered) {
			let cleaned = reviews.replacingOccurrences(of: " ", with: "")
			out.append(
				AgenticEvidenceObservation(
					id: stableId(prefix: "reviews", value: cleaned),
					kind: .reviewCount,
					text: cleaned,
					normalized: cleaned,
					confidence: 0.55,
					source: source,
					reason: "review_count_pattern"
				)
			)
		}

		// Price "$76" / "76.99"
		if let price = extractFirstPrice(text) {
			out.append(
				AgenticEvidenceObservation(
					id: stableId(prefix: "price", value: price.normalized),
					kind: .price,
					text: price.normalized,
					normalized: price.normalized,
					confidence: price.confidence,
					source: source,
					reason: "price_pattern:\(price.reason)"
				)
			)
		}

		return out
	}

	private static func specObservation(text: String, source: AgenticEvidenceObservationSource, reason: String) -> AgenticEvidenceObservation {
		let norm = normalizeText(text)
		return AgenticEvidenceObservation(
			id: stableId(prefix: "spec", value: "\(source.rawValue)|\(reason)|\(norm)"),
			kind: .specs,
			text: text,
			normalized: norm,
			confidence: 0.82,
			source: source,
			reason: reason
		)
	}

	// MARK: - Filtering / Dedupe

		private static func filterChrome(
			_ observations: [AgenticEvidenceObservation],
			runtimeGoal: String,
			chromeSupport: GeneratedChromeFilter.GroundingSupport
		) -> [AgenticEvidenceObservation] {
			var out: [AgenticEvidenceObservation] = []
			out.reserveCapacity(observations.count)

			for o in observations {
				// Preserve grounded overlap (e.g. product titles) when corroborated by
				// window title / AX / graph sources; suppress only ungrounded assistant echoes.
				let sup = GeneratedChromeFilter.shouldSuppress(
					line: o.text,
					runtimeGoal: runtimeGoal,
					proposalTitle: nil,
					groundingSupport: chromeSupport
				)
				if sup.suppressed {
					print("[EvidenceObservationFilter] rejected reason=generated_chrome text=\"\(o.text.prefix(60))\"")
					continue
				}
			let lowered = o.text.lowercased()
			if lowered.contains("processing") && lowered.contains("product information") {
				print("[EvidenceObservationFilter] rejected reason=assistant_chrome text=\"\(o.text.prefix(60))\"")
				continue
			}
			out.append(o)
		}
		return out
	}

	private static func dedupe(_ observations: [AgenticEvidenceObservation]) -> [AgenticEvidenceObservation] {
		var best: [String: AgenticEvidenceObservation] = [:]
		for o in observations {
			let key = "\(o.kind.rawValue)|\(o.normalized)"
			if let prior = best[key] {
				if o.confidence > prior.confidence { best[key] = o }
			} else {
				best[key] = o
			}
		}
		return Array(best.values).sorted { $0.confidence > $1.confidence }
	}

	// MARK: - Title normalization helpers

	private static func normalizeWindowTitle(_ title: String) -> String? {
		var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !t.isEmpty else { return nil }

		// Strip common browser suffixes.
		let browserSuffixes = [" - Firefox", " - Google Chrome", " - Safari", " - Arc", " — Firefox", " — Safari"]
		for suffix in browserSuffixes where t.hasSuffix(suffix) {
			t = String(t.dropLast(suffix.count))
		}

		// Strip store suffixes like ": Amazon.ca: Electronics" (generalized).
		if let range = t.range(of: ": Amazon.", options: [.caseInsensitive]) {
			t = String(t[..<range.lowerBound])
		}

		// Generic suffix stripping: take left side if RHS looks like site name.
		for separator in [" - ", " | ", " – ", " — "] {
			if let range = t.range(of: separator, options: .backwards) {
				let suffix = t[range.upperBound...]
				if suffix.split(separator: " ").count <= 4 {
					t = String(t[..<range.lowerBound])
					break
				}
			}
		}

		t = t.trimmingCharacters(in: .whitespacesAndNewlines)
		if t.count < 8 { return nil }
		return t
	}

	private static func looksProductLike(_ s: String) -> Bool {
		let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
		if t.count < 10 { return false }
		let lower = t.lowercased()
		// Hard guard: email clients / inbox pages are never product pages.
		if lower.contains("gmail") || lower.contains("outlook") || lower.contains("inbox") || lower.contains("mail.google.com") {
			return false
		}
		// Product-like pages commonly include spec tokens in title.
		if lower.contains("usb") || lower.contains("charger") || lower.contains("case") || lower.contains("gan") { return true }
		if lower.range(of: #"\b\d{2,3}\s*w\b"#, options: .regularExpression) != nil { return true }
		if lower.range(of: #"\$\s*\d"#, options: .regularExpression) != nil { return true }
		if lower.contains("reviews") || lower.contains("ratings") { return true }
		return false
	}

	private static func normalizeText(_ s: String) -> String {
		let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty { return "" }
		// Lowercased, alnum/space only.
		let lowered = trimmed.lowercased()
		let cleaned = lowered.map { ch -> Character in
			if ch.isLetter || ch.isNumber { return ch }
			if ch == " " { return ch }
			return " "
		}
		return String(cleaned).split(separator: " ").prefix(12).joined(separator: " ")
	}

	private static func stableId(prefix: String, value: String) -> String {
		let v = value.lowercased()
		var hash: UInt64 = 5381
		for b in v.utf8 { hash = ((hash << 5) &+ hash) &+ UInt64(b) }
		return "\(prefix)_\(String(hash, radix: 16))"
	}

	private static func matchFirst(pattern: String, in text: String) -> String? {
		guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
		let range = NSRange(text.startIndex..<text.endIndex, in: text)
		guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
		guard let r = Range(match.range(at: 0), in: text) else { return nil }
		return String(text[r])
	}

	private static func extractNumericPrice(_ normalized: String) -> Double? {
		let stripped = normalized.unicodeScalars
			.filter { CharacterSet(charactersIn: "0123456789.").contains($0) }
			.map(String.init)
			.joined()
		return Double(stripped)
	}

	private static func extractFirstPrice(_ text: String) -> (normalized: String, confidence: Double, reason: String)? {
		let t = text
		// $76 or $76.99
		guard let raw = matchFirst(pattern: #"\$\s*\d{1,5}(?:\.\d{2})?"#, in: t) else {
			return nil
		}
		let compact = raw.replacingOccurrences(of: " ", with: "")
		guard let norm = PriceNormalizer.normalize(rawText: compact) else {
			return nil
		}
		// Reject ambiguous/rough large numbers and normalization failures.
		guard norm.accepted else { return nil }
		// Clamp to a sane upper bound to avoid OCR misreads like "$9999" satisfying evidence.
		let numeric = extractNumericPrice(norm.normalized) ?? 0
		guard numeric > 0, numeric <= 5000 else { return nil }
		return (normalized: norm.normalized, confidence: norm.confidence, reason: norm.reason)
	}
}
