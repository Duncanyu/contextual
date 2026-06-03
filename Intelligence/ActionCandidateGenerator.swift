import Foundation

protocol ActionCandidateLLMGenerating: Sendable {
	func generate(prompt: String, model: String, numPredict: Int, temperature: Double, purpose: String?, schema: [String: Any]?) async throws -> String
}

extension LocalAIClient: ActionCandidateLLMGenerating {}

struct ActionCandidate: Sendable, Equatable, Codable {
	let title: String
	let reasoning: String
	let confidence: Double

	init(title: String, reasoning: String, confidence: Double) {
		self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
		self.reasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
		self.confidence = min(1.0, max(0.0, confidence))
	}
}

struct ActionCandidateRequest: Sendable, Equatable {
	let input: GeneratedActionInput
	let problem: ProblemSignal
	let referenceTime: Date
}

enum ActionCandidateGenerator {
	static let plannerModel = "phi4-mini"

	static func generate(
		request: ActionCandidateRequest,
		llm: any ActionCandidateLLMGenerating = LocalAIClient.shared
	) async -> [ActionCandidate] {
		PlannerStats.recordInvocation()
		let prompt = buildPrompt(request: request)
		print("[ActionCandidateGenerator] source=planner_model problem=\(request.problem.problem) prompt_bytes=\(prompt.utf8.count)")
		do {
			let raw = try await llm.generate(
				prompt: prompt,
				model: plannerModel,
				numPredict: 360,
				temperature: 0.25,
				purpose: "action_candidate_generation",
				schema: schema
			)
			let parsed = parseCandidates(raw)
			PlannerStats.recordReturnedCandidates(parsed.count)
			print("[ActionCandidateGenerator] candidates=\(parsed.count) source=planner_model")
			for candidate in parsed.prefix(5) {
				print("[ActionCandidateGenerator] candidate title=\"\(candidate.title)\" confidence=\(String(format: "%.2f", candidate.confidence)) reasoning=\"\(candidate.reasoning.prefix(120))\"")
			}
			return Array(parsed.prefix(5))
		} catch {
			print("[ActionCandidateGenerator] failed source=planner_model reason=\(error.localizedDescription)")
			PlannerStats.recordReturnedCandidates(0)
			return []
		}
	}

	static func proposals(
		request: ActionCandidateRequest,
		llm: any ActionCandidateLLMGenerating = LocalAIClient.shared
	) async -> [GeneratedActionProposal] {
		let candidates = await generate(request: request, llm: llm)
		return candidates.map { candidate in
			let proposal = GeneratedActionProposal(
				id: stableId(title: candidate.title, problem: request.problem.problem),
				title: candidate.title,
				description: candidate.reasoning,
				reasoning: "problem=\(request.problem.problem) \(candidate.reasoning)",
				confidence: min(candidate.confidence, request.problem.confidence + 0.08),
				workflow: workflowType(from: request.input),
				requiredContext: requiredContext(from: request.problem, input: request.input),
				createdAt: request.referenceTime
			)
			print("[GeneratedAction] title=\(proposal.title)")
			print("[GeneratedAction] confidence=\(String(format: "%.2f", proposal.confidence))")
			print("[GeneratedAction] reasoning=\(proposal.reasoning)")
			return proposal
		}
	}

	static func buildPrompt(request: ActionCandidateRequest) -> String {
		let input = request.input
		print("[ActionCandidateGenerator] current_terms_only=\(input.currentFocusTerms.joined(separator: ","))")
		return """
		You are the local planner for a privacy-first macOS assistant.
		Generate 3 to 5 useful action candidates for the observed problem.

		Do not choose from capability IDs.
		Do not output workflow labels.
		Do not output generic actions like "create next steps", "generate checklist", "review project", "generate quiz", or "improve code".
		The action title must describe the user's likely problem and a concrete helpful next move.
		The model decides usefulness only. Safety/executability will be handled later.

		Return strict JSON:
		{"candidates":[{"title":"...","reasoning":"...","confidence":0.0}]}

		Problem:
		- name: \(request.problem.problem)
		- confidence: \(String(format: "%.2f", request.problem.confidence))
		- evidence: \(request.problem.evidence.joined(separator: " | "))
		- behavior_tags: \(request.problem.behaviorTags.joined(separator: ", "))

		Primary Focus:
		- current_entity: \(input.currentEntity)
		- current_focus_terms: \(input.currentFocusTerms.joined(separator: ", "))
		- app: \(input.activeApplication)

		Secondary Context:
		- related_entities: \(input.relatedEntities.prefix(5).joined(separator: " | "))
		- related_terms: \(input.relatedTerms.prefix(10).joined(separator: ", "))
		- background_terms: \(input.backgroundTerms.prefix(10).joined(separator: ", "))
		- evidence_quality: \(input.evidenceQuality)
		"""
	}

	private static let schema: [String: Any] = [
		"type": "object",
		"properties": [
			"candidates": [
				"type": "array",
				"minItems": 1,
				"maxItems": 5,
				"items": [
					"type": "object",
					"properties": [
						"title": ["type": "string"],
						"reasoning": ["type": "string"],
						"confidence": ["type": "number"]
					],
					"required": ["title", "reasoning", "confidence"]
				]
			]
		],
		"required": ["candidates"]
	]

	private static func parseCandidates(_ raw: String) -> [ActionCandidate] {
		guard let data = extractJSONObject(raw).data(using: .utf8),
		      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
		      let rows = root["candidates"] as? [[String: Any]] else {
			return []
		}
		return rows.compactMap { row in
			guard let title = row["title"] as? String else { return nil }
			let reasoning = row["reasoning"] as? String ?? ""
			let confidence = (row["confidence"] as? Double) ?? ((row["confidence"] as? NSNumber)?.doubleValue ?? 0.0)
			guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
			return ActionCandidate(title: title, reasoning: reasoning, confidence: confidence)
		}
	}

	private static func extractJSONObject(_ raw: String) -> String {
		guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start <= end else {
			return raw
		}
		return String(raw[start...end])
	}

	private static func workflowType(from input: GeneratedActionInput) -> WorkflowType {
		if input.hasErrorTerms || input.mode == .debugging { return .debugging }
		if input.hasComparisonCandidates || input.mode == .comparing { return .comparing }
		if input.domain == .studying || input.entityType == .course_material { return .studying }
		if input.domain == .researching || input.hasMultipleSources { return .research }
		if input.mode == .writing || input.mode == .communicating { return .writing }
		return .unknown
	}

	private static func requiredContext(from problem: ProblemSignal, input: GeneratedActionInput) -> [ContextRequirementType] {
		var required: Set<ContextRequirementType> = [.textSnippet]
		if input.hasMultipleSources || input.hasComparisonCandidates || problem.behaviorTags.contains("synthesis_behavior") {
			required.insert(.multiSource)
		}
		if input.hasErrorTerms || problem.behaviorTags.contains("debugging_behavior") {
			required.insert(.errorContext)
		}
		if input.entityType == .course_material || problem.behaviorTags.contains("reading_behavior") {
			required.insert(.notesContext)
		}
		if input.activeCompartmentWorkflow != nil {
			required.insert(.workflowContext)
		}
		return Array(required).sorted(by: { $0.rawValue < $1.rawValue })
	}

	private static func stableId(title: String, problem: String) -> String {
		let raw = "\(problem)|\(title.lowercased())"
		return "candidate:\(String(UInt64(bitPattern: Int64(raw.hashValue)), radix: 16))"
	}
}

enum PlannerStats {
	private nonisolated(unsafe) static var totalTicks = 0
	private nonisolated(unsafe) static var plannerInvocations = 0
	private nonisolated(unsafe) static var plannerReturnedCandidates = 0
	private nonisolated(unsafe) static var plannerAcceptedCandidates = 0
	private nonisolated(unsafe) static var plannerRejectedCandidates = 0
	private nonisolated(unsafe) static var plannerSuppressedContexts = 0
	private nonisolated(unsafe) static var cognitiveShown = 0
	private nonisolated(unsafe) static var environmentShown = 0
	private nonisolated(unsafe) static var totalSuppressed = 0

	static func recordTick() {
		totalTicks += 1
	}

	static func recordInvocation() {
		plannerInvocations += 1
		logIfNeeded(force: plannerInvocations == 1 || plannerInvocations % 5 == 0)
	}

	static func recordReturnedCandidates(_ count: Int) {
		plannerReturnedCandidates += count
		logIfNeeded()
	}

	static func recordAcceptedCandidate() {
		plannerAcceptedCandidates += 1
		logIfNeeded(force: true)
	}

	static func recordRejectedCandidate() {
		plannerRejectedCandidates += 1
		logIfNeeded()
	}

	static func recordSuppressedContext() {
		plannerSuppressedContexts += 1
		logIfNeeded(force: true)
	}

	static func recordProposalShown(kind: AmbientSuggestionKind) {
		if kind == .cognitive_action {
			cognitiveShown += 1
		} else if kind == .comfort_action {
			environmentShown += 1
		}
		logSurfaceStats()
	}

	static func recordTotalSuppression() {
		totalSuppressed += 1
		logSurfaceStats()
	}

	static func resetForTests() {
		totalTicks = 0
		plannerInvocations = 0
		plannerReturnedCandidates = 0
		plannerAcceptedCandidates = 0
		plannerRejectedCandidates = 0
		plannerSuppressedContexts = 0
		cognitiveShown = 0
		environmentShown = 0
		totalSuppressed = 0
	}

	private static func logIfNeeded(force: Bool = false) {
		guard force || plannerInvocations % 5 == 0 else { return }
		print("[PlannerStats] invocations=\(plannerInvocations) returned=\(plannerReturnedCandidates) accepted=\(plannerAcceptedCandidates) rejected=\(plannerRejectedCandidates) suppressed=\(plannerSuppressedContexts)")
	}

	private static func logSurfaceStats() {
		// Log every tick for visibility during Phase 25.2
		print("[JarvisSurfaceStats] ticks=\(totalTicks) cognitive_shown=\(cognitiveShown) environment_shown=\(environmentShown) suppressed=\(totalSuppressed)")
	}
}

enum GeneratedContextSuppressionGate {
	static func allow(_ input: GeneratedActionInput) -> Bool {
		if input.entityType == .website && input.entityConfidence < 0.50 {
			print("[ContextSuppression] generic_website")
			return false
		}

		let threshold: Double?
		switch input.entityType {
		case .website:
			threshold = 0.60
		case .document:
			threshold = 0.45
		case .code_project:
			threshold = 0.40
		case .product:
			threshold = 0.50
		default:
			threshold = nil
		}

		if let threshold, input.entityConfidence < threshold {
			print("[ContextSuppression] entity_confidence_below_threshold type=\(input.entityType.rawValue) confidence=\(String(format: "%.2f", input.entityConfidence)) threshold=\(String(format: "%.2f", threshold))")
			return false
		}
		return true
	}
}

enum GeneratedProposalQualityFilter {
	private static let weakLeadingVerbs: Set<String> = ["review", "explain", "analyze", "inspect", "check"]
	private static let weakContextTerms: Set<String> = ["first", "second", "third", "page", "website", "reddit", "google", "dexter"]
	private static let stopwords: Set<String> = [
		"a", "an", "and", "are", "as", "at", "before", "for", "from", "in", "into", "is", "it", "of", "on", "or", "the", "this", "to", "with",
		"review", "explain", "analyze", "inspect", "check", "first", "second", "third", "page", "website", "reddit", "google"
	]

	static func accept(_ proposal: GeneratedActionProposal) -> Bool {
		let title = proposal.title.trimmingCharacters(in: .whitespacesAndNewlines)
		let tokens = words(in: title)
		let lowerTokens = tokens.map { $0.lowercased() }

		if let first = lowerTokens.first,
		   weakLeadingVerbs.contains(first),
		   proposal.confidence < 0.72,
		   lowerTokens.contains(where: { weakContextTerms.contains($0) }) {
			return reject(title)
		}

		if hasDuplicatedEntityPattern(tokens) {
			return reject(title)
		}

		let meaningful = lowerTokens.filter { $0.count >= 3 && !stopwords.contains($0) }
		if meaningful.count < 2 {
			return reject(title)
		}

		return true
	}

	private static func reject(_ title: String) -> Bool {
		print("[ProposalQualityFilter] rejected title=\(title)")
		return false
	}

	private static func words(in title: String) -> [String] {
		title
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { !$0.isEmpty }
	}

	private static func hasDuplicatedEntityPattern(_ tokens: [String]) -> Bool {
		guard tokens.count >= 4 else { return false }
		let lower = tokens.map { $0.lowercased() }
		for index in 1..<(lower.count - 1) {
			if lower[index + 1] == "in", index + 2 < lower.count, lower[index] == lower[index + 2] {
				return true
			}
		}
		return false
	}
}

enum ActionCandidateValidator {
	private nonisolated(unsafe) static var recentTitles: [String] = []

	static func validate(_ action: GeneratedActionProposal) -> ActionValidationResult {
		let base = ActionValidator.validate(action)
		guard base.accepted else { return base }

		let lower = action.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		let lazyPhrases = [
			"review project", "improve code", "continue studying", "generate quiz",
			"generate checklist", "create checklist", "create next steps",
			"compare products", "summarize context"
		]
		if lazyPhrases.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") }) {
			return rejected("lazy_candidate")
		}

		if lower.contains("capability") || lower.contains("workflow") {
			return rejected("capability_or_workflow_language")
		}

		if recentTitles.contains(lower) {
			return rejected("duplicate_candidate")
		}
		recentTitles.append(lower)
		recentTitles = Array(recentTitles.suffix(12))

		print("[ActionValidation] accepted=true rejected=false reason=none")
		return ActionValidationResult(accepted: true, rejectedReason: nil)
	}

	static func resetRecentActionsForTests() {
		recentTitles.removeAll()
		ActionValidator.resetRecentActionsForTests()
	}

	private static func rejected(_ reason: String) -> ActionValidationResult {
		print("[ActionValidation] accepted=false rejected=true reason=\(reason)")
		return ActionValidationResult(accepted: false, rejectedReason: reason)
	}
}

enum ActionCandidateGeneratorSelfTest {
	static func run() async -> Bool {
		print("[ActionCandidateGeneratorSelfTest] starting")
		let llm = StubActionCandidateLLM()
		PlannerStats.resetForTests()
		var failures: [String] = []
		func check(_ name: String, _ condition: Bool) {
			if condition {
				print("[ActionCandidateGeneratorSelfTest] pass case=\(name)")
			} else {
				print("[ActionCandidateGeneratorSelfTest] fail case=\(name)")
				failures.append(name)
			}
		}

		let cases: [(String, GeneratedActionInput, String)] = [
			("scratch", sampleInput(entity: "TurboWarp projectile collision game", terms: ["scratch", "projectile", "collision", "testing"], domain: .coding, mode: .debugging, type: .code_project, hasError: true), "Identify projectile collision test gaps before playtesting"),
			("coding", sampleInput(entity: "CollisionController.swift", terms: ["collision", "edge", "bug"], domain: .coding, mode: .debugging, type: .code_project, hasError: true), "Identify likely collision edge cases before testing"),
			("studying", sampleInput(entity: "Assignment 2 and recursion lecture", terms: ["recursion", "assignment", "tree"], domain: .studying, mode: .reading, type: .course_material), "Extract concepts likely needed for Assignment 2"),
			("shopping", sampleInput(entity: "portable power stations", terms: ["battery", "runtime", "capacity"], domain: .shopping, mode: .comparing, type: .product, multi: true, comparing: true), "Compare battery-runtime tradeoffs across the active products"),
			("research", sampleInput(entity: "retrieval papers", terms: ["retrieval", "quality", "sources"], domain: .researching, mode: .reading, type: .website, multi: true), "Synthesize disagreements between the active research sources"),
			("communication", sampleInput(entity: "client scope email", terms: ["scope", "deadline", "reply"], domain: .communicating, mode: .communicating, type: .email_thread, multi: true), "Extract reply action items for the scope ambiguity")
		]

		for (name, input, expectedTitle) in cases {
			ActionCandidateValidator.resetRecentActionsForTests()
			guard let problem = ProblemInference.infer(from: input).first else {
				check("\(name)_problem", false)
				continue
			}
			llm.nextResponse = #"{"candidates":[{"title":"\#(expectedTitle)","reasoning":"Problem evidence indicates this would help now.","confidence":0.83},{"title":"Generate checklist","reasoning":"lazy","confidence":0.90}]}"#
			let request = ActionCandidateRequest(input: input, problem: problem, referenceTime: Date())
			let proposals = await ActionCandidateGenerator.proposals(request: request, llm: llm)
			let accepted = proposals.filter { ActionCandidateValidator.validate($0).accepted }
			check("\(name)_candidate_from_planner", accepted.first?.title == expectedTitle)
			if let action = accepted.first, let composition = PrimitiveComposer.compose(action) {
				print("[PrimitiveComposition] primitives=\(composition.primitives.map(\.rawValue).joined(separator: ",")) confidence=\(String(format: "%.2f", composition.confidence))")
				print("[ProposalReasoning] selected_title=\"\(composition.action.title)\" problem=\(problem.problem) reasoning=\"\(composition.action.reasoning)\"")
				JarvisSuggestionGenerator.logGeneratedActionSource(composition.action)
				check("\(name)_candidate_composed", !composition.primitives.isEmpty)
			} else {
				check("\(name)_candidate_composed", false)
			}
		}

		ActionCandidateValidator.resetRecentActionsForTests()
		llm.nextResponse = #"{"candidates":[{"title":"Identify collision checks before playtesting","reasoning":"Specific debugging support.","confidence":0.83}]}"#
		let pipelineAccepted = await GeneratedActionPipeline.firstAction(
			input: sampleInput(entity: "TurboWarp collision bug", terms: ["collision", "testing"], domain: .coding, mode: .debugging, type: .code_project, hasError: true),
			llm: llm
		)
		check("pipeline_accepts_specific_candidate", pipelineAccepted?.title == "Identify collision checks before playtesting")

		ActionCandidateValidator.resetRecentActionsForTests()
		llm.nextResponse = #"{"candidates":[{"title":"Review dexter in Dexter","reasoning":"Weak duplicated entity.","confidence":0.60}]}"#
		let pipelineRejected = await GeneratedActionPipeline.firstAction(
			input: sampleInput(entity: "Dexter page", terms: ["dexter", "page"], domain: .working, mode: .reading, type: .document, entityConfidence: 0.70),
			llm: llm
		)
		check("pipeline_rejects_duplicate_entity_title", pipelineRejected == nil)

		ActionCandidateValidator.resetRecentActionsForTests()
		llm.nextResponse = #"{"candidates":[]}"#
		let emptyInput = sampleInput(
			entity: "Reddit homepage",
			terms: ["reddit", "page"],
			domain: .browsing,
			mode: .browsing,
			type: .website,
			multi: false,
			entityConfidence: 0.80
		)
		let emptyAction = await GeneratedActionPipeline.firstAction(input: emptyInput, llm: llm)
		check("zero_candidates_suppressed", emptyAction == nil)

		let lowConfidenceWebsite = sampleInput(
			entity: "Reddit homepage",
			terms: ["reddit", "page"],
			domain: .browsing,
			mode: .browsing,
			type: .website,
			multi: false,
			entityConfidence: 0.30
		)
		llm.nextResponse = #"{"candidates":[{"title":"Analyze reddit page","reasoning":"weak","confidence":0.80}]}"#
		let genericWebsiteAction = await GeneratedActionPipeline.firstAction(input: lowConfidenceWebsite, llm: llm)
		check("generic_website_suppressed", genericWebsiteAction == nil)

		let ok = failures.isEmpty
		print("[ActionCandidateGeneratorSelfTest] completed ok=\(ok) failures=\(failures.count)")
		return ok
	}

	private static func sampleInput(
		entity: String,
		terms: [String],
		domain: DeterminerSignal.Domain,
		mode: DeterminerSignal.Mode,
		type: EntityGrounding.EntityType,
		hasError: Bool = false,
		multi: Bool = false,
		comparing: Bool = false,
		entityConfidence: Double? = nil
	) -> GeneratedActionInput {
		GeneratedActionInput(
			currentEntity: entity,
			relatedEntities: multi ? ["related source one", "related source two"] : [],
			activeTerms: terms,
			activeCompartmentLabel: entity,
			activeCompartmentWorkflow: nil,
			evidenceQuality: multi ? "browser_tabs" : "ax_content",
			activeApplication: domain == .communicating ? "Mail" : "Safari",
			domain: domain,
			mode: mode,
			entityType: type,
			entityConfidence: entityConfidence,
			hasErrorTerms: hasError,
			hasMultipleSources: multi,
			hasComparisonCandidates: comparing,
			confidenceSeed: 0.72
		)
	}
}

enum ActionValidationSelfTestV24 {
	static func run() -> Bool {
		print("[ActionValidationSelfTestV24] starting")
		ActionCandidateValidator.resetRecentActionsForTests()
		var failures: [String] = []
		func check(_ name: String, _ condition: Bool) {
			if condition {
				print("[ActionValidationSelfTestV24] pass case=\(name)")
			} else {
				print("[ActionValidationSelfTestV24] fail case=\(name)")
				failures.append(name)
			}
		}

		let useful = GeneratedActionProposal(id: "candidate:1", title: "Identify likely collision edge cases before testing", description: "", reasoning: "problem=debugging_collision", confidence: 0.80, workflow: .debugging, requiredContext: [.textSnippet, .errorContext])
		check("useful_accepted", ActionCandidateValidator.validate(useful).accepted)
		let lazy = GeneratedActionProposal(id: "candidate:2", title: "Generate checklist", description: "", reasoning: "", confidence: 0.90, workflow: .editing, requiredContext: [.textSnippet])
		check("lazy_rejected", ActionCandidateValidator.validate(lazy).rejectedReason != nil)
		let capability = GeneratedActionProposal(id: "candidate:3", title: "Generate quiz", description: "", reasoning: "", confidence: 0.90, workflow: .studying, requiredContext: [.textSnippet])
		check("capability_label_rejected", ActionCandidateValidator.validate(capability).rejectedReason != nil)
		let duplicateEntity = GeneratedActionProposal(id: "candidate:4", title: "Review dexter in Dexter", description: "", reasoning: "", confidence: 0.60, workflow: .unknown, requiredContext: [.textSnippet])
		check("duplicate_entity_quality_rejected", !GeneratedProposalQualityFilter.accept(duplicateEntity))
		let weakReddit = GeneratedActionProposal(id: "candidate:5", title: "Analyze reddit page", description: "", reasoning: "", confidence: 0.60, workflow: .unknown, requiredContext: [.textSnippet])
		check("weak_reddit_quality_rejected", !GeneratedProposalQualityFilter.accept(weakReddit))
		let tooShort = GeneratedActionProposal(id: "candidate:6", title: "Check page", description: "", reasoning: "", confidence: 0.80, workflow: .unknown, requiredContext: [.textSnippet])
		check("too_short_quality_rejected", !GeneratedProposalQualityFilter.accept(tooShort))
		let good = GeneratedActionProposal(id: "candidate:7", title: "Compare battery-runtime tradeoffs across active products", description: "", reasoning: "", confidence: 0.80, workflow: .comparing, requiredContext: [.textSnippet])
		check("quality_accepts_specific", GeneratedProposalQualityFilter.accept(good))

		let ok = failures.isEmpty
		print("[ActionValidationSelfTestV24] completed ok=\(ok) failures=\(failures.count)")
		return ok
	}
}

private final class StubActionCandidateLLM: ActionCandidateLLMGenerating, @unchecked Sendable {
	var nextResponse = #"{"candidates":[]}"#
	func generate(prompt: String, model: String, numPredict: Int, temperature: Double, purpose: String?, schema: [String: Any]?) async throws -> String {
		nextResponse
	}
}
