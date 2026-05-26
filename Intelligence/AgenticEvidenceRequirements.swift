import Foundation

// MARK: - Evidence Kind

/// What kind of evidence a goal needs in order to be answered well.
///
/// Each kind is deliberately generic — no Amazon-specific cases, no app-specific
/// cases. The runtime maps these into already-existing semantic entity types
/// produced by `GroundedSemanticExtractor`.
enum AgenticEvidenceKind: String, Sendable, Hashable, Codable, CaseIterable {
	case productTitle = "product_title"
	case price
	case specs
	case rating
	case reviewCount = "review_count"
	case reviewText = "review_text"
	case comparisonCandidate = "comparison_candidate"
	case pageSummary = "page_summary"
	case codeSnippet = "code_snippet"
	case errorMessage = "error_message"
	case documentKeyPoint = "document_key_point"
	// Phase 4P — Email review evidence (domain-aware; not product-like).
	case inboxContext = "inbox_context"
	case messageList = "message_list"
	case emailSubject = "email_subject"
	case emailSnippet = "email_snippet"
	case emailSender = "email_sender"
	case unreadCount = "unread_count"
	case timestamp
	case unknown
}

// MARK: - Requirement

/// A single evidence requirement attached to an agentic goal.
struct AgenticEvidenceRequirement: Sendable, Hashable, Codable {
	let kind: AgenticEvidenceKind
	/// True when the requirement must be satisfied for a clean success. When
	/// false the requirement is helpful but the goal can still complete partially.
	let required: Bool
	/// Minimum number of distinct entities of this kind needed for satisfaction.
	let minCount: Int
	/// Per-entity confidence threshold (entities below this don't count toward `minCount`).
	let confidenceThreshold: Double
	/// Optional `find_on_page` hints used when this requirement is the active gap.
	/// First element is the preferred query token.
	let searchHints: [String]

	init(
		kind: AgenticEvidenceKind,
		required: Bool = true,
		minCount: Int = 1,
		confidenceThreshold: Double = 0.30,
		searchHints: [String] = []
	) {
		self.kind = kind
		self.required = required
		self.minCount = max(1, minCount)
		self.confidenceThreshold = min(max(0, confidenceThreshold), 1)
		self.searchHints = searchHints
	}
}

// MARK: - State

/// Snapshot of how well the current observations satisfy the goal's evidence.
struct AgenticEvidenceState: Sendable, Equatable, Codable {
	let goal: String
	let requirements: [AgenticEvidenceRequirement]
	/// Required+optional requirements that have been satisfied.
	let satisfied: [AgenticEvidenceKind]
	/// Required requirements that are NOT yet satisfied. Drives "gather more" decisions.
	let missing: [AgenticEvidenceKind]
	/// Optional requirements that are also not yet satisfied (informational only).
	let missingOptional: [AgenticEvidenceKind]
	/// Confidence in 0..1 — fraction of *required* slots satisfied.
	let confidence: Double
	/// True when the runtime should gather more evidence before final extraction.
	let shouldGatherMore: Bool
	/// Hint at the next action to take when shouldGatherMore is true.
	let recommendedAction: RecommendedAction

	enum RecommendedAction: String, Sendable, Equatable, Codable {
		case observe
		case findOnPage = "find_on_page"
		case scrollSmall = "scroll_small"
		case extract
		case summarize
		case present
		case presentPartial = "present_partial"
		case stopMissing = "stop_missing"
	}

	/// The first required missing requirement (if any) — used for `[EvidenceGap]` log.
	var firstMissing: AgenticEvidenceRequirement? {
		guard let kind = missing.first else { return nil }
		return requirements.first(where: { $0.kind == kind })
	}

	/// True when no required slot is unmet.
	var allRequiredSatisfied: Bool { missing.isEmpty }
}

// MARK: - Inferrer

/// Deterministically derives evidence requirements from a goal + workflow.
///
/// Generalized by task family — never inspects website / bundle ids.
enum AgenticEvidenceRequirementsInferrer {

	/// Overloaded entry that incorporates context information (window title, observations, entities, category).
	static func infer(
		goal: String,
		workflow: String?,
		windowTitle: String? = nil,
		evidenceObservations: [AgenticEvidenceObservation] = [],
		semanticEntities: [GroundedSemanticEntity] = [],
		contextCategory: String? = nil
	) -> [AgenticEvidenceRequirement] {
		let g = goal.lowercased()
		let wf = (workflow ?? "").lowercased()

		// Domain detection (email vs product vs code). This stays generalized and local-only.
		let isEmailContext: Bool = {
			if wf.contains("review") || wf.contains("brows") || wf.contains("unknown") {
				// window title is the strongest signal here
			}
			let titleLower = (windowTitle ?? "").lowercased()
			let catLower = (contextCategory ?? "").lowercased()
			let needles = ["gmail", "outlook", "inbox", "mail.google.com"]
			if needles.contains(where: { titleLower.contains($0) }) { return true }
			if catLower.contains("outlook") { return true }
			if g.contains("gmail") || g.contains("inbox") || g.contains("emails") || g.contains("email") { return true }
			return false
		}()
		
		// Determine if the current context is product-like.
		let isProductContext: Bool = {
			if isEmailContext { return false }
			if let cat = contextCategory?.lowercased(), cat.contains("amazon") || cat.contains("shopping") || cat.contains("product") {
				return true
			}
			if wf == "shopping" || wf == "product" { return true }
			if let wt = windowTitle?.lowercased() {
				// General product-ish signals: specs/units, currency, review/rating hints.
				if wt.range(of: #"\$\s*\d"#, options: .regularExpression) != nil { return true }
				if wt.range(of: #"\b\d{2,3}\s*w\b"#, options: .regularExpression) != nil { return true }
				if wt.contains("usb") || wt.contains("charger") || wt.contains("case") || wt.contains("gan") { return true }
			}
			return false
		}()

		let family = classifyFamily(goal: g, workflow: wf)

		// Overriding rules when context is product-like but family is generic or page summary.
		let effectiveFamily: Family
		if isEmailContext {
			effectiveFamily = .emailReview
		} else if isProductContext && (family == .generic || family == .summarize) {
			if g.contains("compare") || g.contains("comparison") {
				effectiveFamily = .compare
			} else {
				effectiveFamily = .review
			}
		} else {
			effectiveFamily = family
		}

		let reqs: [AgenticEvidenceRequirement]
		switch effectiveFamily {
		case .compare:
			reqs = [
				AgenticEvidenceRequirement(kind: .productTitle, required: true, minCount: 1, confidenceThreshold: 0.40, searchHints: ["product"]),
				AgenticEvidenceRequirement(kind: .specs, required: true, minCount: 2, confidenceThreshold: 0.30, searchHints: ["specs", "watt", "details"]),
				AgenticEvidenceRequirement(kind: .comparisonCandidate, required: true, minCount: 2, confidenceThreshold: 0.30, searchHints: ["compare", "similar", "related", "alternatives"]),
				AgenticEvidenceRequirement(kind: .price, required: false, minCount: 1, confidenceThreshold: 0.40, searchHints: ["price"]),
				AgenticEvidenceRequirement(kind: .rating, required: false, minCount: 1, confidenceThreshold: 0.30, searchHints: ["rating", "stars"]),
				AgenticEvidenceRequirement(kind: .reviewCount, required: false, minCount: 1, confidenceThreshold: 0.30, searchHints: ["reviews"]),
			]
		case .review:
			reqs = [
				AgenticEvidenceRequirement(kind: .productTitle, required: true, minCount: 1, confidenceThreshold: 0.40, searchHints: ["product"]),
				AgenticEvidenceRequirement(kind: .specs, required: true, minCount: 2, confidenceThreshold: 0.30, searchHints: ["specs", "feature", "details"]),
				AgenticEvidenceRequirement(kind: .price, required: false, minCount: 1, confidenceThreshold: 0.40, searchHints: ["price"]),
				AgenticEvidenceRequirement(kind: .rating, required: false, minCount: 1, confidenceThreshold: 0.30, searchHints: ["rating"]),
				AgenticEvidenceRequirement(kind: .reviewCount, required: false, minCount: 1, confidenceThreshold: 0.30, searchHints: ["reviews"]),
			]
		case .summarize:
			reqs = [
				AgenticEvidenceRequirement(kind: .pageSummary, required: true, minCount: 1, confidenceThreshold: 0.30, searchHints: []),
				AgenticEvidenceRequirement(kind: .documentKeyPoint, required: true, minCount: 2, confidenceThreshold: 0.30, searchHints: []),
			]
		case .emailReview:
			reqs = [
				AgenticEvidenceRequirement(kind: .inboxContext, required: true, minCount: 1, confidenceThreshold: 0.30, searchHints: ["inbox"]),
				AgenticEvidenceRequirement(kind: .messageList, required: false, minCount: 1, confidenceThreshold: 0.30, searchHints: []),
				AgenticEvidenceRequirement(kind: .emailSubject, required: true, minCount: 1, confidenceThreshold: 0.35, searchHints: ["subject"]),
				AgenticEvidenceRequirement(kind: .emailSnippet, required: true, minCount: 1, confidenceThreshold: 0.35, searchHints: ["unread", "new"]),
				AgenticEvidenceRequirement(kind: .emailSender, required: false, minCount: 1, confidenceThreshold: 0.30, searchHints: []),
				AgenticEvidenceRequirement(kind: .timestamp, required: false, minCount: 1, confidenceThreshold: 0.30, searchHints: []),
				AgenticEvidenceRequirement(kind: .unreadCount, required: false, minCount: 1, confidenceThreshold: 0.30, searchHints: []),
			]
		case .reviewsCheck:
			reqs = [
				AgenticEvidenceRequirement(kind: .rating, required: true, minCount: 1, confidenceThreshold: 0.30, searchHints: ["rating", "stars"]),
				AgenticEvidenceRequirement(kind: .reviewCount, required: true, minCount: 1, confidenceThreshold: 0.30, searchHints: ["reviews", "ratings"]),
				AgenticEvidenceRequirement(kind: .reviewText, required: true, minCount: 1, confidenceThreshold: 0.25, searchHints: ["customer", "review"]),
			]
		case .priceCheck:
			reqs = [
				AgenticEvidenceRequirement(kind: .price, required: true, minCount: 1, confidenceThreshold: 0.40, searchHints: ["price", "$"]),
				AgenticEvidenceRequirement(kind: .productTitle, required: false, minCount: 1, confidenceThreshold: 0.40, searchHints: ["product"]),
			]
		case .specsCheck:
			reqs = [
				AgenticEvidenceRequirement(kind: .specs, required: true, minCount: 2, confidenceThreshold: 0.30, searchHints: ["specs", "watt", "details", "weight"]),
				AgenticEvidenceRequirement(kind: .productTitle, required: false, minCount: 1, confidenceThreshold: 0.40, searchHints: ["product"]),
			]
		case .codeAnalyze:
			reqs = [
				AgenticEvidenceRequirement(kind: .codeSnippet, required: true, minCount: 1, confidenceThreshold: 0.30, searchHints: []),
				AgenticEvidenceRequirement(kind: .errorMessage, required: false, minCount: 1, confidenceThreshold: 0.30, searchHints: []),
			]
		case .generic:
			reqs = [
				AgenticEvidenceRequirement(kind: .pageSummary, required: true, minCount: 1, confidenceThreshold: 0.30, searchHints: []),
			]
		}

		let required = reqs.filter { $0.required }.map { $0.kind.rawValue }.joined(separator: ",")
		let optional = reqs.filter { !$0.required }.map { $0.kind.rawValue }.joined(separator: ",")
		let familyTag: String = {
			switch effectiveFamily {
			case .compare: return "product_compare"
			case .review: return "product_detail"
			default: return effectiveFamily.rawValue
			}
		}()
		print("[EvidenceRequirements] source=aligned_context goal_family=\(familyTag) required=\(required) optional=\(optional)")
		
		return reqs
	}

	/// Top-level entry. Goal text + workflow string (lowercased family).
	static func infer(goal: String, workflow: String?) -> [AgenticEvidenceRequirement] {
		let g = goal.lowercased()
		let wf = (workflow ?? "").lowercased()
		let family = classifyFamily(goal: g, workflow: wf)

		switch family {
		case .compare:
			return [
				AgenticEvidenceRequirement(kind: .productTitle, required: true, minCount: 1, confidenceThreshold: 0.40, searchHints: ["product"]),
				AgenticEvidenceRequirement(kind: .specs, required: true, minCount: 2, confidenceThreshold: 0.30, searchHints: ["specs", "watt", "details"]),
				AgenticEvidenceRequirement(kind: .comparisonCandidate, required: true, minCount: 2, confidenceThreshold: 0.30, searchHints: ["compare", "similar", "related", "alternatives"]),
				AgenticEvidenceRequirement(kind: .price, required: false, minCount: 1, confidenceThreshold: 0.40, searchHints: ["price"]),
				AgenticEvidenceRequirement(kind: .rating, required: false, minCount: 1, confidenceThreshold: 0.30, searchHints: ["rating", "stars"]),
				AgenticEvidenceRequirement(kind: .reviewCount, required: false, minCount: 1, confidenceThreshold: 0.30, searchHints: ["reviews"]),
			]
		case .review:
			return [
				AgenticEvidenceRequirement(kind: .productTitle, required: true, minCount: 1, confidenceThreshold: 0.40, searchHints: ["product"]),
				AgenticEvidenceRequirement(kind: .specs, required: true, minCount: 2, confidenceThreshold: 0.30, searchHints: ["specs", "feature", "details"]),
				AgenticEvidenceRequirement(kind: .price, required: false, minCount: 1, confidenceThreshold: 0.40, searchHints: ["price"]),
				AgenticEvidenceRequirement(kind: .rating, required: false, minCount: 1, confidenceThreshold: 0.30, searchHints: ["rating"]),
			]
		case .emailReview:
			return [
				AgenticEvidenceRequirement(kind: .inboxContext, required: true, minCount: 1, confidenceThreshold: 0.30, searchHints: ["inbox"]),
				AgenticEvidenceRequirement(kind: .messageList, required: false, minCount: 1, confidenceThreshold: 0.30, searchHints: []),
				AgenticEvidenceRequirement(kind: .emailSubject, required: true, minCount: 1, confidenceThreshold: 0.35, searchHints: ["subject"]),
				AgenticEvidenceRequirement(kind: .emailSnippet, required: true, minCount: 1, confidenceThreshold: 0.35, searchHints: ["unread", "new"]),
				AgenticEvidenceRequirement(kind: .emailSender, required: false, minCount: 1, confidenceThreshold: 0.30),
				AgenticEvidenceRequirement(kind: .timestamp, required: false, minCount: 1, confidenceThreshold: 0.30),
				AgenticEvidenceRequirement(kind: .unreadCount, required: false, minCount: 1, confidenceThreshold: 0.30),
			]
		case .summarize:
			return [
				AgenticEvidenceRequirement(kind: .pageSummary, required: true, minCount: 1, confidenceThreshold: 0.30, searchHints: []),
				AgenticEvidenceRequirement(kind: .documentKeyPoint, required: true, minCount: 2, confidenceThreshold: 0.30, searchHints: []),
			]
		case .reviewsCheck:
			return [
				AgenticEvidenceRequirement(kind: .rating, required: true, minCount: 1, confidenceThreshold: 0.30, searchHints: ["rating", "stars"]),
				AgenticEvidenceRequirement(kind: .reviewCount, required: true, minCount: 1, confidenceThreshold: 0.30, searchHints: ["reviews", "ratings"]),
				AgenticEvidenceRequirement(kind: .reviewText, required: true, minCount: 1, confidenceThreshold: 0.25, searchHints: ["customer", "review"]),
			]
		case .priceCheck:
			return [
				AgenticEvidenceRequirement(kind: .price, required: true, minCount: 1, confidenceThreshold: 0.40, searchHints: ["price", "$"]),
				AgenticEvidenceRequirement(kind: .productTitle, required: false, minCount: 1, confidenceThreshold: 0.40, searchHints: ["product"]),
			]
		case .specsCheck:
			return [
				AgenticEvidenceRequirement(kind: .specs, required: true, minCount: 2, confidenceThreshold: 0.30, searchHints: ["specs", "watt", "details", "weight"]),
				AgenticEvidenceRequirement(kind: .productTitle, required: false, minCount: 1, confidenceThreshold: 0.40, searchHints: ["product"]),
			]
		case .codeAnalyze:
			return [
				AgenticEvidenceRequirement(kind: .codeSnippet, required: true, minCount: 1, confidenceThreshold: 0.30, searchHints: []),
				AgenticEvidenceRequirement(kind: .errorMessage, required: false, minCount: 1, confidenceThreshold: 0.30, searchHints: []),
			]
		case .generic:
			_ = g
			return [
				AgenticEvidenceRequirement(kind: .pageSummary, required: true, minCount: 1, confidenceThreshold: 0.30, searchHints: []),
			]
		}
	}

	// MARK: - Family classification

	enum Family: String, Sendable {
		case compare
		case review
		case emailReview = "email_review"
		case summarize
		case reviewsCheck
		case priceCheck
		case specsCheck
		case codeAnalyze
		case generic
	}

	static func classifyFamily(goal: String, workflow: String) -> Family {
		// Order matters: more specific intents win.
		if goal.contains("compare") || goal.contains("comparison")
			|| goal.contains(" vs ") || goal.contains(" versus ") {
			return .compare
		}
		if goal.contains("check review") || goal.contains("read review")
			|| goal.contains("customer review") || goal.contains("see review") {
			return .reviewsCheck
		}
		if goal.contains("check price") || goal.contains("price check")
			|| goal.contains("find price") || (goal.contains("price") && !goal.contains("review")) {
			return .priceCheck
		}
		// Email review: must be checked before generic "review" is treated
		// as a product review family.
		if looksLikeEmailGoal(goal) || workflow.contains("email") {
			return .emailReview
		}
		if goal.contains("review") || goal.contains("evaluate this product") {
			return .review
		}
		if goal.contains("spec") || goal.contains("dimension")
			|| goal.contains("measurement") || goal.contains("watt") {
			return .specsCheck
		}
		if goal.contains("summarize") || goal.contains("summarise")
			|| goal.contains("summary") || goal.contains("tldr") || goal.contains("tl;dr") {
			return .summarize
		}
		if goal.contains("code") || goal.contains("function")
			|| goal.contains("error") || goal.contains("stack trace") {
			return .codeAnalyze
		}
		// Workflow hints
		if workflow == "shopping" || workflow == "product" {
			return .review
		}
		if workflow == "research" || workflow == "browsing" || workflow == "reading" {
			return .summarize
		}
		return .generic
	}

	private static func looksLikeEmailGoal(_ g: String) -> Bool {
		let lower = g.lowercased()
		let needles = ["email", "emails", "inbox", "gmail", "outlook", "mail", "messages"]
		return needles.contains(where: { lower.contains($0) })
	}
}

// MARK: - Assessor

/// Scores requirements against a set of `GroundedSemanticEntity` instances and
/// produces an `AgenticEvidenceState`.
enum AgenticEvidenceAssessor {

	/// Build state for the given goal + requirements using the latest entities.
	///
	/// - Parameters:
	///   - goal: original goal text (for logging only).
	///   - requirements: the requirements inferred for this goal.
	///   - entities: deduplicated grounded semantic entities for the latest observation.
	///   - extractedFactsCount: how many `extract_facts` lines have been produced so far.
	///     Used to bias `pageSummary`/`documentKeyPoint` satisfaction for summarize goals.
	///   - hasUsableObservation: whether the runtime has at least one usable observation.
	static func assess(
		goal: String,
		requirements: [AgenticEvidenceRequirement],
		entities: [GroundedSemanticEntity],
		evidenceObservations: [AgenticEvidenceObservation] = [],
		extractedFactsCount: Int = 0,
		hasUsableObservation: Bool = false
	) -> AgenticEvidenceState {
		var satisfied: [AgenticEvidenceKind] = []
		var missing: [AgenticEvidenceKind] = []
		var missingOptional: [AgenticEvidenceKind] = []

		// 1. Quality-aware validation for core evidence kinds
		
		// A. Validate product title
		let rawTitleObs = evidenceObservations.filter { $0.kind == .productTitle }
		let rawTitleEntities = entities.filter { $0.type == .productTitle }
		let rawTitleCount = Set(rawTitleObs.map(\.normalized) + rawTitleEntities.map { $0.normalizedValue ?? $0.text.lowercased() }).count
		
		var validTitles = Set<String>()
		for o in rawTitleObs {
			if isProductTitleValid(o.text, goal: goal) {
				validTitles.insert(o.normalized)
			}
		}
		for e in rawTitleEntities {
			if isProductTitleValid(e.text, goal: goal) {
				validTitles.insert(e.normalizedValue ?? e.text.lowercased())
			}
		}
		let titleSatisfied = validTitles.count >= 1
		print("[EvidenceStateValidation] kind=product_title raw_count=\(rawTitleCount) valid_count=\(validTitles.count) satisfied=\(titleSatisfied ? "yes" : "no")")

		// B. Validate specs
		let rawSpecsObs = evidenceObservations.filter { $0.kind == .specs }
		let rawSpecsEntities = entities.filter { $0.type == .specification || $0.type == .feature }
		let rawSpecsCount = Set(rawSpecsObs.map(\.normalized) + rawSpecsEntities.map { $0.normalizedValue ?? $0.text.lowercased() }).count
		
		var validSpecs = Set<String>()
		for o in rawSpecsObs {
			if isSpecValid(o.text) {
				validSpecs.insert(o.normalized)
			}
		}
		for e in rawSpecsEntities {
			if isSpecValid(e.text) {
				validSpecs.insert(e.normalizedValue ?? e.text.lowercased())
			}
		}
		let specsSatisfied = validSpecs.count >= 1
		print("[EvidenceStateValidation] kind=specs raw_count=\(rawSpecsCount) valid_count=\(validSpecs.count) satisfied=\(specsSatisfied ? "yes" : "no")")

		// C. Validate comparison candidate
		let rawComparisonObs = evidenceObservations.filter { $0.kind == .comparisonCandidate || $0.kind == .productTitle }
		let rawComparisonEntities = entities.filter { ($0.type == .productTitle || $0.type == .heading) }
		let rawComparisonCount = Set(rawComparisonObs.map(\.normalized) + rawComparisonEntities.map { $0.normalizedValue ?? $0.text.lowercased() }).count
		
		var validComparisonGrounded = Set<String>()
		var hasLiveGroundedSecond = false
		
		var primaryNormalizedTitles = Set<String>()
		for o in rawComparisonObs where o.kind == .productTitle {
			if isProductTitleValid(o.text, goal: goal) {
				primaryNormalizedTitles.insert(EvidenceQualityGate.normalizeComparisonTitle(o.text))
			}
		}
		for e in rawComparisonEntities where e.type == .productTitle {
			if isProductTitleValid(e.text, goal: goal) {
				primaryNormalizedTitles.insert(EvidenceQualityGate.normalizeComparisonTitle(e.text))
			}
		}
		
		for o in rawComparisonObs {
			let t = o.text.trimmingCharacters(in: .whitespacesAndNewlines)
			guard isProductTitleValid(t, goal: goal) else { continue }
			
			let normalizedName = EvidenceQualityGate.normalizeComparisonTitle(t)
			validComparisonGrounded.insert(normalizedName)
			if o.source != .browsingHistory {
				if !primaryNormalizedTitles.contains(normalizedName) || o.kind == .comparisonCandidate {
					hasLiveGroundedSecond = true
				}
			}
		}
		
		for e in rawComparisonEntities {
			let t = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
			guard isProductTitleValid(t, goal: goal) else { continue }
			
			let normalizedName = EvidenceQualityGate.normalizeComparisonTitle(t)
			validComparisonGrounded.insert(normalizedName)
			if !primaryNormalizedTitles.contains(normalizedName) || e.type == .heading {
				hasLiveGroundedSecond = true
			}
		}
		
		let isCompareGoal = AgenticEvidenceRequirementsInferrer.classifyFamily(goal: goal.lowercased(), workflow: "") == .compare
		
		var comparisonSatisfied = false
		var comparisonReason = ""
		
		if isCompareGoal {
			if validComparisonGrounded.count < 2 {
				comparisonReason = "insufficient_count"
			} else if !hasLiveGroundedSecond {
				comparisonReason = "history_only"
			} else {
				comparisonSatisfied = true
			}
		} else {
			if validComparisonGrounded.count >= 1 {
				comparisonSatisfied = true
			} else {
				comparisonReason = "no_product"
			}
		}
		print("[EvidenceStateValidation] kind=comparison_candidate raw_count=\(rawComparisonCount) valid_count=\(validComparisonGrounded.count) satisfied=\(comparisonSatisfied ? "yes" : "no")\(comparisonReason.isEmpty ? "" : " reason=" + comparisonReason)")

		// 2. Assess requirements using our validated statuses
		var satisfiedRequired = 0
		var totalRequired = 0

		for req in requirements {
			if req.required { totalRequired += 1 }

			let isSatisfied: Bool
			switch req.kind {
			case .productTitle:
				isSatisfied = titleSatisfied
			case .specs:
				isSatisfied = specsSatisfied
			case .comparisonCandidate:
				isSatisfied = comparisonSatisfied
			default:
				let counted = countMatching(
					kind: req.kind,
					entities: entities,
					evidenceObservations: evidenceObservations,
					threshold: req.confidenceThreshold,
					extractedFactsCount: extractedFactsCount,
					hasUsableObservation: hasUsableObservation
				)
				isSatisfied = counted >= req.minCount
			}

			if isSatisfied {
				satisfied.append(req.kind)
				if req.required { satisfiedRequired += 1 }
			} else if req.required {
				missing.append(req.kind)
			} else {
				missingOptional.append(req.kind)
			}
		}

		// 3. Grounding Ratio check
		var lowPerceptionGrounding = false
		let liveObs = evidenceObservations.filter { $0.source == .ocr || $0.source == .ax || $0.source == .windowTitle }
		if liveObs.isEmpty {
			lowPerceptionGrounding = true
		} else {
			var groundedCount = 0
			let semanticItems = entities.map(\.text)
			if !semanticItems.isEmpty {
				for item in semanticItems {
					let matches = liveObs.contains { o in
						o.text.lowercased().contains(item.lowercased()) || item.lowercased().contains(o.text.lowercased())
					}
					if matches { groundedCount += 1 }
				}
				let ratio = Double(groundedCount) / Double(semanticItems.count)
				if ratio < 0.5 {
					lowPerceptionGrounding = true
				}
			}
		}

		// 4. Quality Feedback Loop into EvidenceState
		if isCompareGoal && !comparisonSatisfied {
			if satisfied.contains(.comparisonCandidate) {
				satisfied.removeAll { $0 == .comparisonCandidate }
				if !missing.contains(.comparisonCandidate) {
					missing.append(.comparisonCandidate)
				}
				print("[EvidenceQualityFeedback] removed_satisfied=comparison_candidate reason=invalid_comparison_candidates")
			}
		}

		// Re-evaluate satisfiedRequired
		satisfiedRequired = 0
		for req in requirements {
			if req.required && satisfied.contains(req.kind) {
				satisfiedRequired += 1
			}
		}

		var confidence: Double
		if totalRequired == 0 {
			confidence = satisfied.isEmpty ? 0.0 : 0.50
		} else {
			confidence = Double(satisfiedRequired) / Double(totalRequired)
		}

		if lowPerceptionGrounding {
			confidence = max(0.10, confidence - 0.30)
			print("[EvidenceQualityFeedback] confidence_reduced reason=low_perception_grounding_ratio new_confidence=\(String(format: "%.2f", confidence))")
		}

		let satisfiedStr = satisfied.map(\.rawValue).joined(separator: ",")
		let missingStr = missing.map(\.rawValue).joined(separator: ",")
		print(String(format: "[EvidenceState] satisfied=%@ missing=%@ confidence=%.2f", satisfiedStr, missingStr, confidence))

		let shouldGather = !missing.isEmpty
		let recommended = recommendedAction(
			missing: missing,
			missingOptional: missingOptional,
			hasUsableObservation: hasUsableObservation,
			extractedFactsCount: extractedFactsCount
		)

		return AgenticEvidenceState(
			goal: goal,
			requirements: requirements,
			satisfied: satisfied,
			missing: missing,
			missingOptional: missingOptional,
			confidence: confidence,
			shouldGatherMore: shouldGather,
			recommendedAction: recommended
		)
	}

	// MARK: - Counting

	/// Count how many entities satisfy a given evidence kind.
	///
	/// `pageSummary` / `documentKeyPoint` are derived from the *presence* of
	/// usable observations + extracted facts because the semantic extractor
	/// does not emit those types directly today.
	private static func countMatching(
		kind: AgenticEvidenceKind,
		entities: [GroundedSemanticEntity],
		evidenceObservations: [AgenticEvidenceObservation],
		threshold: Double,
		extractedFactsCount: Int,
		hasUsableObservation: Bool
	) -> Int {
		// Priority: semantic entities first; then evidence observations (window title, OCR, AX, facts).
		let entityCount: Int = {
			switch kind {
			case .productTitle:
				return entities.filter { $0.type == .productTitle && $0.confidence >= threshold }.count
			case .price:
				return entities.filter { $0.type == .price && $0.confidence >= threshold }.count
			case .specs:
				return entities.filter { ($0.type == .specification || $0.type == .feature) && $0.confidence >= threshold }.count
			case .rating:
				return entities.filter { $0.type == .rating && $0.confidence >= threshold }.count
			case .reviewCount:
				return entities.filter { $0.type == .reviewCount && $0.confidence >= threshold }.count
			case .reviewText:
				return entities.filter {
					($0.type == .body || $0.type == .heading)
						&& $0.confidence >= threshold
						&& looksReviewish($0.text)
				}.count
			case .comparisonCandidate:
				let titles = entities.filter { ($0.type == .productTitle || $0.type == .heading) && $0.confidence >= threshold }
				let normalized = Set(titles.map { $0.normalizedValue ?? $0.text.lowercased() })
				return normalized.count
			case .pageSummary:
				return hasUsableObservation ? 1 : 0
			case .documentKeyPoint:
				return max(0, extractedFactsCount)
			case .codeSnippet:
				return entities.filter { $0.type == .body && $0.confidence >= threshold && looksLikeCode($0.text) }.count
			case .errorMessage:
				return entities.filter { ($0.type == .body || $0.type == .heading) && $0.confidence >= threshold && looksLikeError($0.text) }.count
			case .inboxContext, .messageList, .emailSubject, .emailSnippet, .emailSender, .unreadCount, .timestamp:
				return 0
			case .unknown:
				return 0
			}
		}()

		// If entities already satisfy this kind, return early.
		if entityCount > 0 { return entityCount }

		// Otherwise, count evidence observations.
		let obs = evidenceObservations.filter { $0.kind == kind && $0.confidence >= threshold }
		let normalized = Set(obs.map(\.normalized))
		return normalized.count
	}

	private static func looksReviewish(_ text: String) -> Bool {
		let t = text.lowercased()
		return t.contains("review") || t.contains("rating") || t.contains("star")
			|| t.contains("customer") || t.contains("verified")
	}

	private static func looksLikeCode(_ text: String) -> Bool {
		let t = text
		if t.contains("{") && t.contains("}") { return true }
		if t.contains("def ") || t.contains("func ") || t.contains("class ") { return true }
		if t.contains("=>") || t.contains("->") { return true }
		if t.contains("import ") || t.contains("#include") { return true }
		return false
	}

	private static func looksLikeError(_ text: String) -> Bool {
		let t = text.lowercased()
		return t.contains("error") || t.contains("exception") || t.contains("traceback")
			|| t.contains("failed") || t.contains("crash")
	}

	// MARK: - Recommended action

	private static func recommendedAction(
		missing: [AgenticEvidenceKind],
		missingOptional: [AgenticEvidenceKind],
		hasUsableObservation: Bool,
		extractedFactsCount: Int
	) -> AgenticEvidenceState.RecommendedAction {
		if !hasUsableObservation { return .observe }
		if let first = missing.first {
			// Prefer find_on_page when the kind has a structural anchor (price/rating/specs).
			switch first {
			case .price, .rating, .reviewCount, .reviewText, .specs:
				return .findOnPage
			case .comparisonCandidate, .pageSummary, .documentKeyPoint:
				return .scrollSmall
			case .productTitle, .codeSnippet, .errorMessage:
				return .findOnPage
			case .inboxContext, .messageList, .emailSubject, .emailSnippet, .emailSender, .unreadCount, .timestamp:
				return .observe
			case .unknown:
				return .observe
			}
		}
		if extractedFactsCount == 0 { return .extract }
		return .summarize
	}

	// MARK: - Validation Helpers

	public static func isProductTitleValid(_ text: String, goal: String) -> Bool {
		let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
		let lower = t.lowercased()
		
		// 1. Tab close suffix artifact
		if t.hasSuffix(" X") || t.hasSuffix(" x") {
			print("[SemanticEntityFilter] rejected reason=tab_close_artifact text=\"\(t)\"")
			return false
		}
		
		// 2. Personal/account strings
		if lower.contains("duncan") || (lower.contains("yu") && lower.contains("duncan")) || lower.contains("duncanyu") {
			print("[SemanticEntityFilter] rejected reason=personal_or_account_text text=\"\(t)\"")
			return false
		}
		
		// 3. Generic promo/membership text
		let promoPhrases = [
			"prime members get", "free shipping", "members get free", "sign in", "cart", "account",
			"your account", "orders", "free delivery", "add to cart", "buy now", "prime members"
		]
		for phrase in promoPhrases {
			if lower.contains(phrase) {
				print("[SemanticEntityFilter] rejected reason=promo_text text=\"\(t)\"")
				return false
			}
		}
		
		// 4. Truncation or ellipsis
		if t.contains("...") || t.contains("…") {
			print("[SemanticEntityFilter] rejected reason=truncated_text text=\"\(t)\"")
			return false
		}
		
		// 5. Echo of assistant/proposal goal
		let lowerGoal = goal.lowercased()
		if lower == lowerGoal {
			print("[SemanticEntityFilter] rejected reason=proposal_title_echo text=\"\(t)\"")
			return false
		}
		if lower.hasPrefix("search for ") || lower.hasPrefix("compare ") {
			if lower.count > 12 {
				print("[SemanticEntityFilter] rejected reason=proposal_title_echo text=\"\(t)\"")
				return false
			}
		}
		
		// 6. Mashed or too short/too long generic
		if EvidenceQualityGate.detectMashedWord(t) || EvidenceQualityGate.detectChromeLeak(t) {
			print("[SemanticEntityFilter] rejected reason=mashed_or_chrome text=\"\(t)\"")
			return false
		}
		
		return true
	}

	public static func isSpecValid(_ text: String) -> Bool {
		let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
		let lower = t.lowercased()
		
		// Mashed words
		if EvidenceQualityGate.detectMashedWord(t) {
			return false
		}
		
		// Title fragments that are not specs (e.g. contains browser names or large sentences)
		if t.split(separator: " ").count > 6 {
			return false
		}
		
		// Short valid specs are accepted
		let shortValidSpecs = ["gan", "usb-c", "usb c", "160w", "3-port", "3 port", "pd", "pps", "140w", "100w", "65w", "charger"]
		for spec in shortValidSpecs {
			if lower == spec { return true }
		}
		
		// If it's a general title fragment with no numeric value/wattage/ports, reject
		let containsNumber = lower.range(of: #"\d"#, options: .regularExpression) != nil
		let hasSpecKeywords = lower.contains("gan") || lower.contains("port") || lower.contains("usb") || lower.contains("watt") || lower.contains("volt") || lower.contains("amp") || lower.contains("cable") || lower.contains("fast") || lower.contains("multi") || lower.contains("charger")
		
		if !containsNumber && !hasSpecKeywords {
			return false
		}
		
		return true
	}
}
