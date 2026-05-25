import Foundation

// MARK: - Semantic Grounding

/// Semantic anchors extracted from the current execution context snapshot.
///
/// Used by `AgenticProposalSanityFilter` to reject proposals that are semantically
/// misaligned with the current page context before they become visible to the user.
///
/// Example: Amazon AirPods case page → entities=[AirPods 4, Spigen, silicone],
/// domain=product_shopping, forbidden=[inbox, email, calendar, ide]
struct AgenticSemanticGrounding: Sendable {
    /// Named entities detected in the context (products, brands, apps, people).
    let entities: [String]
    /// The dominant semantic topic derived from context signals.
    let dominantTopic: String
    /// Semantic domains consistent with the current context (used for workflow scoring).
    let allowedDomains: Set<String>
    /// Semantic domains clearly incompatible with the current context (hard penalty).
    let forbiddenDomains: Set<String>
    /// True when product/shopping signals (price, review, buy, cart, specs) are present.
    let isProductPage: Bool
    /// True when a known shopping platform is active (Amazon, BestBuy, Newegg, eBay, etc.).
    let isShoppingPlatform: Bool
    /// Raw keyword terms extracted from title + OCR for semantic overlap computation.
    let contextKeywords: Set<String>
}

// MARK: - Extractor

/// Extracts semantic grounding from a canonical execution context snapshot.
///
/// Reads: `windowTitle`, `recentOCRExcerpt`, `inferredWorkflow`, `bundleIdentifier`, `activeApp`.
/// Does NOT read clipboard (always suppressed in agentic contexts).
/// Does NOT make network calls — all inference is local and stateless.
///
/// Emits: `[IntentGrounding]` log line with entities, domain, workflow, forbidden_domains.
struct AgenticIntentGroundingExtractor: Sendable {

	func extract(from snapshot: CanonicalGeneratedExecutionContextSnapshot) -> AgenticSemanticGrounding {
		let title = snapshot.windowTitle.lowercased()
		let ocr = snapshot.recentOCRExcerpt?.lowercased() ?? ""
		let summary = snapshot.contextSummary?.lowercased() ?? ""
		let workflow = snapshot.inferredWorkflow.rawValue.lowercased()
		let bundleId = (snapshot.bundleIdentifier ?? "").lowercased()
		let app = snapshot.activeApp.lowercased()
		let allText = "\(title) \(ocr) \(summary)"

		// Detect known shopping platforms
		let shoppingPlatformKeys: [String] = ["amazon", "bestbuy", "best buy", "newegg", "ebay",
		                                       "walmart", "target", "etsy", "shopify", "apple store"]
		let isShoppingPlatform = shoppingPlatformKeys.contains {
			bundleId.contains($0) || app.contains($0) || title.contains($0)
		}

		// Detect product/shopping page signals from OCR and title.
		// Use specific multi-word or contextually unambiguous signals only —
		// generic words like "review", "rating", "buy" are excluded to avoid
		// false positives in mail, documents, and other non-shopping contexts.
		let productSignals: [String] = [
			"add to cart", "buy now", "in stock", "sold by", "free shipping",
			"customer reviews", "verified purchase", "return policy", "model number",
			"ships free", "compatible with", "compare models", "warranty included",
			"price:", "list price", "sale price"
		]
		// Require at least one specific multi-word signal, or a $ price pattern with digits
		let hasPricePattern = allText.range(
			of: #"\$\d"#, options: .regularExpression
		) != nil
		let hasProductSignal = productSignals.contains { allText.contains($0) }
		let isProductPage = isShoppingPlatform || hasProductSignal || hasPricePattern

		// Extract named entities from title and OCR
		let entities = extractEntities(from: snapshot)

		// Determine dominant topic
		let dominantTopic = computeDominantTopic(
			workflow: workflow,
			isProductPage: isProductPage,
			isShoppingPlatform: isShoppingPlatform,
			allText: allText
		)

		// Determine allowed / forbidden semantic domains
		let (allowed, forbidden) = computeDomains(
			workflow: workflow,
			isProductPage: isProductPage,
			isShoppingPlatform: isShoppingPlatform,
			bundleId: bundleId,
			app: app
		)

		// Context keywords for overlap scoring (stop-word filtered)
		let contextKeywords = extractKeywords(from: title + " " + ocr)

		let grounding = AgenticSemanticGrounding(
			entities: entities,
			dominantTopic: dominantTopic,
			allowedDomains: allowed,
			forbiddenDomains: forbidden,
			isProductPage: isProductPage,
			isShoppingPlatform: isShoppingPlatform,
			contextKeywords: contextKeywords
		)

		print("[IntentGrounding] entities=\(entities.prefix(5).joined(separator: ",")) domain=\(dominantTopic) workflow=\(workflow) forbidden_domains=\(forbidden.sorted().joined(separator: ",")) product_page=\(isProductPage) shopping_platform=\(isShoppingPlatform) keywords=\(contextKeywords.count)")

		return grounding
	}

	// MARK: - Entity Extraction

	private func extractEntities(from snapshot: CanonicalGeneratedExecutionContextSnapshot) -> [String] {
		var entities: [String] = []

		// Window title: split on delimiters and collect meaningful tokens
		let titleParts = snapshot.windowTitle
			.components(separatedBy: CharacterSet(charactersIn: "|-–—:,()[]"))
		for part in titleParts {
			let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
			if trimmed.count >= 3 && trimmed.count <= 80 {
				entities.append(trimmed)
			}
		}

		// Known brand/product terms detected in title or OCR
		let knownBrands: [String] = [
			"Apple", "Samsung", "Sony", "LG", "Bose", "Beats", "AirPods", "iPhone", "iPad",
			"MacBook", "Dell", "HP", "Lenovo", "Asus", "Microsoft", "Google", "Amazon",
			"Spigen", "Anker", "Belkin", "OtterBox", "JBL", "Sennheiser", "Jabra",
			"Razer", "Logitech", "Corsair", "SteelSeries", "Western Digital", "Seagate",
			"BestBuy", "Newegg", "eBay", "Walmart", "Target"
		]
		let haystack = "\(snapshot.windowTitle) \(snapshot.recentOCRExcerpt ?? "")"
		for brand in knownBrands {
			if haystack.contains(brand) && !entities.contains(brand) {
				entities.append(brand)
			}
		}

		return Array(entities.prefix(10))
	}

	// MARK: - Dominant Topic

	private func computeDominantTopic(
		workflow: String,
		isProductPage: Bool,
		isShoppingPlatform: Bool,
		allText: String
	) -> String {
		if isShoppingPlatform && isProductPage { return "product_shopping" }
		if isProductPage { return "product_review" }
		if allText.contains("inbox") || allText.contains("compose") || allText.contains("unread") { return "email" }
		if allText.contains("calendar") || allText.contains("meeting") || allText.contains("appointment") { return "calendar" }
		switch workflow {
		case "browsing":  return "web_browsing"
		case "research":  return "research"
		case "writing":   return "document_writing"
		case "editing":   return "document_editing"
		case "debugging": return "code_debugging"
		case "reviewing": return "document_reviewing"
		default:          return "general_\(workflow)"
		}
	}

	// MARK: - Domain Classification

	private func computeDomains(
		workflow: String,
		isProductPage: Bool,
		isShoppingPlatform: Bool,
		bundleId: String,
		app: String
	) -> (allowed: Set<String>, forbidden: Set<String>) {
		var allowed: Set<String> = []
		var forbidden: Set<String> = []

		let isBrowserApp = bundleId.contains("safari") || bundleId.contains("chrome") ||
		                   bundleId.contains("firefox") || bundleId.contains("arc") ||
		                   app.contains("browser")
		let isIDE = bundleId.contains("xcode") || app.contains("xcode") ||
		            bundleId.contains("vscode") || workflow == "debugging"
		let isMailApp = bundleId.contains("mail") || app.contains("mail") || app.contains("gmail") ||
		                bundleId.contains("outlook")
		let isCalendarApp = bundleId.contains("calendar") || app.contains("calendar")
		let isDocApp = bundleId.contains("pages") || bundleId.contains("word") ||
		               bundleId.contains("docs") || bundleId.contains("notes")

		// Product/shopping context — only apply when NOT a dedicated productivity/mail/IDE app.
		// Product page signals in mail subjects or IDE comments must not pollute domain classification.
		if (isShoppingPlatform || isProductPage) && !isMailApp && !isCalendarApp && !isIDE && !isDocApp {
			allowed.formUnion(["shopping", "product_comparison", "product_review",
			                   "specs", "compatibility", "pricing", "browsing", "research"])
			forbidden.formUnion(["email", "inbox", "calendar", "messaging",
			                     "documents", "ide", "code_editing", "debugging"])
		}

		// Browser context
		if isBrowserApp {
			allowed.formUnion(["browsing", "research", "reading", "summarization"])
			forbidden.formUnion(["ide", "code_editing", "debugging"])
		}

		// IDE context
		if isIDE {
			allowed.formUnion(["debugging", "code_review", "code_editing", "documentation", "research"])
			forbidden.formUnion(["shopping", "email", "inbox", "calendar", "messaging"])
		}

		// Mail context
		if isMailApp {
			allowed.formUnion(["email", "inbox", "messaging", "summarization"])
			forbidden.formUnion(["shopping", "ide", "debugging"])
		}

		// Calendar context
		if isCalendarApp {
			allowed.formUnion(["calendar", "scheduling", "planning"])
			forbidden.formUnion(["shopping", "ide", "debugging"])
		}

		// Document editing context
		if isDocApp {
			allowed.formUnion(["writing", "editing", "summarization", "research"])
			forbidden.formUnion(["shopping", "ide", "debugging"])
		}

		// Workflow-level additions (additive, not overriding)
		switch workflow {
		case "browsing", "research":
			allowed.formUnion(["browsing", "research", "reading", "summarization"])
		case "writing", "editing":
			allowed.formUnion(["writing", "editing", "summarization"])
		case "debugging":
			allowed.formUnion(["debugging", "code_review", "research"])
			forbidden.formUnion(["shopping", "inbox", "calendar"])
		case "reviewing":
			allowed.formUnion(["reviewing", "summarization", "research"])
		default:
			break
		}

		return (allowed, forbidden)
	}

	// MARK: - Keyword Extraction

	private func extractKeywords(from text: String) -> Set<String> {
		let stopWords: Set<String> = [
			"the", "a", "an", "and", "or", "of", "in", "on", "at", "to", "for",
			"is", "are", "was", "be", "with", "by", "from", "this", "that", "it",
			"its", "as", "not", "but", "if", "so", "do", "did", "has", "have",
			"had", "will", "can", "get", "out", "up", "my", "your", "you", "we",
			"they", "he", "she", "our", "their", "all", "one", "two", "three"
		]
		let words = text.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { $0.count >= 3 && !stopWords.contains($0) }
		return Set(words.prefix(150))
	}
}

// MARK: - Proposal Sanity Filter

/// Evaluates proposal semantic relevance against context grounding.
///
/// Rejects proposals with:
/// - Low semantic overlap with context keywords/entities
/// - Workflow/domain mismatch (e.g. inbox proposal on a shopping page)
/// - References to unavailable context (clipboard when suppressed)
/// - High hallucination risk (forbidden domain keywords in proposal text)
///
/// Emits `[ProposalSanity]` per-proposal and `[ProposalRejection]` when rejected.
struct AgenticProposalSanityFilter: Sendable {

	/// Proposals scoring below this threshold are rejected.
	static let rejectionThreshold: Double = 0.35

	// MARK: - Component Scores

	/// 0..1 — semantic overlap between proposal text and context keywords + entity names.
	func semanticOverlapScore(
		proposal: ValidatedDynamicGeneratedProposal,
		grounding: AgenticSemanticGrounding
	) -> Double {
		guard !grounding.contextKeywords.isEmpty else { return 0.5 }

		let proposalText = "\(proposal.title) \(proposal.description)".lowercased()
		let proposalWords = Set(
			proposalText
				.components(separatedBy: CharacterSet.alphanumerics.inverted)
				.filter { $0.count >= 3 }
		)

		let overlap = proposalWords.intersection(grounding.contextKeywords)
		let overlapRatio = Double(overlap.count) / Double(max(proposalWords.count, 1))

		// Bonus for named entity matches in proposal text
		let entityMatchCount = grounding.entities.filter { entity in
			proposalText.contains(entity.lowercased())
		}.count
		let entityBonus = min(Double(entityMatchCount) * 0.15, 0.30)

		return min(overlapRatio * 2.0 + entityBonus, 1.0)
	}

	/// 0..1 — proposal's workflow type is consistent with the current context.
	func workflowConsistencyScore(
		proposal: ValidatedDynamicGeneratedProposal,
		grounding: AgenticSemanticGrounding,
		snapshot: CanonicalGeneratedExecutionContextSnapshot
	) -> Double {
		let proposalWorkflow = proposal.workflowType.rawValue.lowercased()
		let contextWorkflow = snapshot.inferredWorkflow.rawValue.lowercased()
		let proposalText = "\(proposal.title) \(proposal.description)".lowercased()

		// Hard override: if proposal text references a forbidden domain's keywords,
		// return 0 regardless of the workflowType field.
		// This catches proposals that claim workflow="browsing" but are actually
		// about email/calendar/IDE — a common LLM hallucination pattern.
		let forbiddenContentSignals: [(domains: Set<String>, keywords: [String])] = [
			(["email", "inbox"],
			 ["inbox", "email", "unread", "compose", "send email", "reply to"]),
			(["calendar"],
			 ["calendar", "meeting", "schedule", "appointment", "reminder", "event"]),
			(["ide", "code_editing", "debugging"],
			 ["compile", "build error", "debug console", "breakpoint", "stack trace"]),
			(["documents"],
			 ["spreadsheet", "presentation", "slide deck", "word document"]),
		]
		for (domains, keywords) in forbiddenContentSignals {
			if !domains.isDisjoint(with: grounding.forbiddenDomains) {
				if keywords.contains(where: { proposalText.contains($0) }) {
					return 0.0
				}
			}
		}

		if proposalWorkflow == contextWorkflow { return 1.0 }
		if grounding.allowedDomains.contains(proposalWorkflow) { return 0.80 }
		if grounding.forbiddenDomains.contains(proposalWorkflow) { return 0.0 }

		// Workflow family affinity
		let browsingFamily: Set<String> = ["browsing", "research", "reading"]
		let writingFamily: Set<String> = ["writing", "editing", "reviewing"]
		let codeFamily: Set<String> = ["debugging", "reviewing"]

		if browsingFamily.contains(proposalWorkflow) && browsingFamily.contains(contextWorkflow) { return 0.85 }
		if writingFamily.contains(proposalWorkflow) && writingFamily.contains(contextWorkflow) { return 0.85 }
		if codeFamily.contains(proposalWorkflow) && codeFamily.contains(contextWorkflow) { return 0.85 }

		return 0.4
	}

	/// 0..1 — proposal's required context types are actually available in the snapshot.
	/// Clipboard is always treated as unavailable (agentic runtime suppression).
	func contextAvailabilityScore(
		proposal: ValidatedDynamicGeneratedProposal,
		snapshot: CanonicalGeneratedExecutionContextSnapshot
	) -> Double {
		let required = proposal.requiredContextTypes
		guard !required.isEmpty else { return 1.0 }

		var satisfied = 0
		for req in required {
			switch req {
			case .selectedText:
				if snapshot.selectedText != nil { satisfied += 1 }
			case .screenCapture, .fusedVisual:
				if snapshot.recentOCRExcerpt != nil { satisfied += 1 }
			case .none, .workflowContext, .textSnippet, .multiSource,
			     .errorContext, .notesContext:
				satisfied += 1   // conservative: assume other types are available
			}
		}
		return Double(satisfied) / Double(required.count)
	}

	/// 0..1 — risk that the proposal is hallucinated (forbidden-domain keywords present).
	/// Higher score = MORE hallucination risk (subtractive in combined score).
	func hallucinationRiskScore(
		proposal: ValidatedDynamicGeneratedProposal,
		grounding: AgenticSemanticGrounding
	) -> Double {
		let proposalText = "\(proposal.title) \(proposal.description)".lowercased()

		// Each entry: the forbidden domains that trigger it, and the keywords to look for
		let riskSignals: [(domains: Set<String>, keywords: [String])] = [
			(["email", "inbox"],
			 ["inbox", "email", "unread", "compose", "send email", "reply", "draft"]),
			(["calendar"],
			 ["calendar", "meeting", "schedule", "event", "appointment", "reminder"]),
			(["shopping"],
			 ["buy now", "add to cart", "checkout", "purchase", "order", "place order"]),
			(["ide", "code_editing", "debugging"],
			 ["compile", "build error", "debug console", "breakpoint", "stack trace"]),
			(["documents"],
			 ["spreadsheet", "presentation", "slide deck", "word document"]),
		]

		var riskScore = 0.0
		for (domains, keywords) in riskSignals {
			let domainForbidden = !domains.isDisjoint(with: grounding.forbiddenDomains)
			if domainForbidden && keywords.contains(where: { proposalText.contains($0) }) {
				riskScore += 0.40
			}
		}

		// Additional risk when no allowed domain signal appears in the proposal
		if !grounding.allowedDomains.isEmpty {
			let hasAllowedSignal = grounding.allowedDomains.contains { proposalText.contains($0) }
			if !hasAllowedSignal { riskScore += 0.20 }
		}

		return min(riskScore, 1.0)
	}

	// MARK: - Combined Score

	/// Weighted combined grounding score. Below `rejectionThreshold` → reject.
	///
	/// Weights:
	/// - Workflow consistency: 0.40 (domain alignment is the strongest signal)
	/// - Semantic overlap:     0.35 (keyword/entity co-occurrence)
	/// - Context availability: 0.15 (can the proposal actually execute?)
	/// - Hallucination risk:  -0.20 (penalty for forbidden-domain keywords)
	func groundedProposalScore(
		proposal: ValidatedDynamicGeneratedProposal,
		grounding: AgenticSemanticGrounding,
		snapshot: CanonicalGeneratedExecutionContextSnapshot
	) -> Double {
		let semantic = semanticOverlapScore(proposal: proposal, grounding: grounding)
		let workflow = workflowConsistencyScore(proposal: proposal, grounding: grounding, snapshot: snapshot)
		let availability = contextAvailabilityScore(proposal: proposal, snapshot: snapshot)
		let hallucinationRisk = hallucinationRiskScore(proposal: proposal, grounding: grounding)

		let raw = (semantic * 0.35) + (workflow * 0.40) + (availability * 0.15) - (hallucinationRisk * 0.20)
		return max(0.0, min(raw, 1.0))
	}

	// MARK: - Filter Pipeline

	/// Filters proposals, rejecting those below the grounding threshold.
	/// Logs `[ProposalSanity]` per candidate and `[ProposalRejection]` for rejections.
	func filter(
		proposals: [ValidatedDynamicGeneratedProposal],
		grounding: AgenticSemanticGrounding,
		snapshot: CanonicalGeneratedExecutionContextSnapshot
	) -> [ValidatedDynamicGeneratedProposal] {
		proposals.filter { proposal in
			let score      = groundedProposalScore(proposal: proposal, grounding: grounding, snapshot: snapshot)
			let semantic   = semanticOverlapScore(proposal: proposal, grounding: grounding)
			let workflow   = workflowConsistencyScore(proposal: proposal, grounding: grounding, snapshot: snapshot)
			let hRisk      = hallucinationRiskScore(proposal: proposal, grounding: grounding)
			let accepted   = score >= Self.rejectionThreshold
			let fmt        = { (v: Double) in String(format: "%.2f", v) }
			let reason     = accepted ? "score_above_threshold" :
			                 "score_\(fmt(score))_below_threshold_\(fmt(Self.rejectionThreshold))"

			print("[ProposalSanity] candidate=\(proposal.title.prefix(60)) semantic_overlap=\(fmt(semantic)) workflow_match=\(fmt(workflow)) hallucination_risk=\(fmt(hRisk)) grounded_score=\(fmt(score)) accepted=\(accepted) reason=\(reason)")

			if !accepted {
				print("[ProposalRejection] reason=grounded_score_below_threshold candidate=\(proposal.title.prefix(60)) score=\(fmt(score))")
			}

			return accepted
		}
	}
}
