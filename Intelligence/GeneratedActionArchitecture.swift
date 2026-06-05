import Foundation

struct GeneratedActionProposal: Sendable, Equatable, Codable {
	let id: String
	let title: String
	let description: String
	let reasoning: String
	let confidence: Double
	let workflow: WorkflowType
	let requiredContext: [ContextRequirementType]
	let primitives: [ExecutionPrimitive]
	let createdAt: Date
	let expiresAt: Date

	init(
		id: String,
		title: String,
		description: String,
		reasoning: String,
		confidence: Double,
		workflow: WorkflowType,
		requiredContext: [ContextRequirementType],
		primitives: [ExecutionPrimitive] = [],
		createdAt: Date = Date(),
		expiresAt: Date? = nil
	) {
		self.id = id
		self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
		self.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
		self.reasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
		self.confidence = min(1.0, max(0.0, confidence))
		self.workflow = workflow
		self.requiredContext = Array(requiredContext.prefix(GeneratedExecutionBounds.maxRequiredContextTypes))
		self.primitives = Array(primitives.prefix(GeneratedExecutionBounds.maxPrimitivesPerPlan))
		self.createdAt = createdAt
		self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(180)
	}

	var primitiveSignature: String {
		primitives.map(\.rawValue).joined(separator: ",")
	}

	func withPrimitives(_ primitives: [ExecutionPrimitive], confidence: Double? = nil) -> GeneratedActionProposal {
		GeneratedActionProposal(
			id: id,
			title: title,
			description: description,
			reasoning: reasoning,
			confidence: confidence ?? self.confidence,
			workflow: workflow,
			requiredContext: requiredContext,
			primitives: primitives,
			createdAt: createdAt,
			expiresAt: expiresAt
		)
	}
}

struct GeneratedActionInput: Sendable, Equatable {
	let currentEntity: String
	let relatedEntities: [String]
	let activeTerms: [String]
	let currentFocusTerms: [String]
	let relatedTerms: [String]
	let backgroundTerms: [String]
	let activeCompartmentLabel: String?
	let activeCompartmentWorkflow: AmbientWorkflowType?
	let evidenceQuality: String
	let activeApplication: String
	let domain: DeterminerSignal.Domain
	let mode: DeterminerSignal.Mode
	let entityType: EntityGrounding.EntityType
	let entityConfidence: Double
	let hasErrorTerms: Bool
	let hasMultipleSources: Bool
	let hasComparisonCandidates: Bool
	let confidenceSeed: Double

	init(
		currentEntity: String,
		relatedEntities: [String],
		activeTerms: [String],
		currentFocusTerms: [String] = [],
		relatedTerms: [String] = [],
		backgroundTerms: [String] = [],
		activeCompartmentLabel: String?,
		activeCompartmentWorkflow: AmbientWorkflowType?,
		evidenceQuality: String,
		activeApplication: String,
		domain: DeterminerSignal.Domain,
		mode: DeterminerSignal.Mode,
		entityType: EntityGrounding.EntityType,
		entityConfidence: Double? = nil,
		hasErrorTerms: Bool,
		hasMultipleSources: Bool,
		hasComparisonCandidates: Bool,
		confidenceSeed: Double
	) {
		self.currentEntity = currentEntity
		self.relatedEntities = relatedEntities
		self.activeTerms = activeTerms
		self.currentFocusTerms = currentFocusTerms
		self.relatedTerms = relatedTerms
		self.backgroundTerms = backgroundTerms
		self.activeCompartmentLabel = activeCompartmentLabel
		self.activeCompartmentWorkflow = activeCompartmentWorkflow
		self.evidenceQuality = evidenceQuality
		self.activeApplication = activeApplication
		self.domain = domain
		self.mode = mode
		self.entityType = entityType
		self.entityConfidence = entityConfidence ?? (entityType == .unknown ? 0.0 : confidenceSeed)
		self.hasErrorTerms = hasErrorTerms
		self.hasMultipleSources = hasMultipleSources
		self.hasComparisonCandidates = hasComparisonCandidates
		self.confidenceSeed = min(1.0, max(0.0, confidenceSeed))
	}
}

enum GeneratedActionGenerator {
	static func generate(input: GeneratedActionInput, referenceTime: Date = Date()) -> [GeneratedActionProposal] {
		let terms = normalizedTerms(input.activeTerms)
		let entity = cleanEntity(input.currentEntity, fallback: input.activeCompartmentLabel)
		let workflow = workflowType(from: input)
		let focus = focusTerms(terms, entity: entity, related: input.relatedEntities)
		let titles = candidateTitles(input: input, workflow: workflow, focus: focus, entity: entity)

		guard !titles.isEmpty else {
			print("[GeneratedAction] skipped reason=no_specific_action")
			return []
		}
		let reason = reasoning(input: input, workflow: workflow, focus: focus, entity: entity)
		let description = description(input: input, workflow: workflow, focus: focus)
		let required = requiredContext(input: input, workflow: workflow)
		let baseConfidence = confidence(input: input, workflow: workflow, focusCount: focus.count)
		let actions = titles.enumerated().map { index, title in
			GeneratedActionProposal(
				id: stableId(title: title, workflow: workflow, entity: entity),
				title: title,
				description: description,
				reasoning: reason,
				confidence: max(0.46, baseConfidence - Double(index) * 0.03),
				workflow: workflow,
				requiredContext: required,
				createdAt: referenceTime
			)
		}
		if isRentalResearchContext(input: input, focus: focus, entity: entity) {
			print("[TextSuggestionFamily] domain=rental_research candidates=\(actions.map(\.id).joined(separator: ",")) selected=\(actions.first?.id ?? "none")")
		}
		for action in actions {
			print("[GeneratedAction] title=\(action.title)")
			print("[GeneratedAction] confidence=\(String(format: "%.2f", action.confidence))")
			print("[GeneratedAction] reasoning=\(action.reasoning)")
		}
		return actions
	}

	static func generate(
		from inference: TaskInferenceResult,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		referenceTime: Date = Date()
	) -> GeneratedActionProposal? {
		let workflow = WorkflowExecutionMapper.workflowType(from: situational.inferredWorkflow)
		let title = inference.possibleUserGoal.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !title.isEmpty else {
			print("[GeneratedAction] skipped reason=no_model_goal")
			return nil
		}
		let contextTypes = requiredContext(from: inference.neededCapabilityCategories, snapshot: snapshot)
		let reason = inference.whyNow.isEmpty
			? "Task inference produced a grounded action goal from the active context."
			: inference.whyNow
		let action = GeneratedActionProposal(
			id: stableId(title: title, workflow: workflow, entity: situational.windowTitle),
			title: title,
			description: String(situational.situationalSummary.prefix(160)),
			reasoning: reason,
			confidence: inference.confidence,
			workflow: workflow,
			requiredContext: contextTypes,
			createdAt: referenceTime,
			expiresAt: referenceTime.addingTimeInterval(max(30, min(180, inference.expirySeconds)))
		)
		print("[GeneratedAction] title=\(action.title)")
		print("[GeneratedAction] confidence=\(String(format: "%.2f", action.confidence))")
		print("[GeneratedAction] reasoning=\(action.reasoning)")
		return action
	}

	private static func candidateTitles(
		input: GeneratedActionInput,
		workflow: WorkflowType,
		focus: [String],
		entity: String
	) -> [String] {
		let termSet = Set(focus)
		let entityLower = entity.lowercased()
		let appLower = input.activeApplication.lowercased()

		if input.hasErrorTerms || input.mode == .debugging || workflow == .debugging {
			if termSet.contains("collision") || termSet.contains("movement") || entityLower.contains("playermovement") {
				return ["Investigate movement collision failure"]
			}
			if let errorFocus = firstUseful(focus) {
				return ["Investigate \(errorFocus) failure"]
			}
			return []
		}

		if isGameContext(entityLower: entityLower, appLower: appLower, terms: termSet) {
			let phrase = gameFocusPhrase(focus: focus)
			return ["Review \(phrase) before testing"]
		}

		if isCodingContext(input: input, workflow: workflow) {
			return codingTitle(input: input, focus: focus, entity: entity).map { [$0] } ?? []
		}

		if input.domain == .studying || workflow == .studying || input.entityType == .course_material {
			let subject = studyFocusPhrase(focus: focus, entity: entity)
			return ["Create \(subject) practice questions"]
		}

		if isRentalResearchContext(input: input, focus: focus, entity: entity) {
			return rentalTitles(input: input, focus: focus, entity: entity)
		}

		if input.hasComparisonCandidates || input.mode == .comparing || workflow == .comparing {
			if termSet.contains("retrieval") || entityLower.contains("retrieval") {
				return ["Compare authors' conclusions on retrieval quality"]
			}
			let candidates = input.relatedEntities.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
			if candidates.count >= 2 {
				return ["Compare \(short(candidates[0], max: 28)) and \(short(candidates[1], max: 28))"]
			}
			if let topic = firstUseful(focus) {
				return ["Compare the \(topic) tradeoffs"]
			}
			return []
		}

		if input.domain == .researching || workflow == .research {
			if termSet.contains("retrieval") {
				return ["Compare authors' conclusions on retrieval quality"]
			}
			if let topic = firstUseful(focus) {
				return ["Synthesize findings about \(topic)", "Summarize what matters about \(topic)"]
			}
			return []
		}

		if input.mode == .writing || workflow == .writing {
			if let topic = firstUseful(focus) {
				return ["Organize notes about \(topic)"]
			}
			return []
		}

		// Phase 28.3: The old "Review <term> in <entity>" fallback produced garbage like
		// "Review kingstonontario in Room for Rent??" — a rephrased title, not a useful action.
		// Suppress this template entirely. Only specific operation titles survive.
		return []
	}

	private static func rentalTitles(
		input: GeneratedActionInput,
		focus: [String],
		entity: String
	) -> [String] {
		let all = Set(focus + normalizedTerms(input.relatedEntities) + normalizedTerms([entity]))
		var titles: [String] = []
		titles.append("Compare the rental advice from these posts?")
		if all.contains("listing") || all.contains("room") || all.contains("sublet") || all.contains("lease") {
			titles.append("Draft a checklist for your rental ad?")
			titles.append("List missing details for the room posting?")
		}
		if all.contains("rent") || all.contains("price") || all.contains("pricing") || all.contains("utilities") {
			titles.append("Extract pricing guidance from these threads?")
		}
		if all.contains("landlord") || all.contains("tenant") || all.contains("advice") {
			titles.append("Create questions to ask the landlord?")
		}
		titles.append("Summarize what renters say about this search?")
		return Array(NSOrderedSet(array: titles)) as? [String] ?? titles
	}

	private static func isRentalResearchContext(
		input: GeneratedActionInput,
		focus: [String],
		entity: String
	) -> Bool {
		let markers: Set<String> = ["rent", "rental", "room", "rooms", "lease", "landlord", "tenant", "listing", "housing", "apartment", "sublet", "roommate", "utilities", "deposit"]
		let all = Set(focus + normalizedTerms(input.relatedEntities) + normalizedTerms([entity]))
		return !all.intersection(markers).isEmpty
	}

	private static func description(
		input: GeneratedActionInput,
		workflow: WorkflowType,
		focus: [String]
	) -> String {
		let focusText = focus.prefix(4).joined(separator: ", ")
		if focusText.isEmpty {
			return "The active context has enough structure for a focused action."
		}
		return "Active \(workflow.rawValue) context includes \(focusText)."
	}

	private static func reasoning(
		input: GeneratedActionInput,
		workflow: WorkflowType,
		focus: [String],
		entity: String
	) -> String {
		var parts: [String] = []
		if !entity.isEmpty { parts.append("entity=\(short(entity, max: 48))") }
		parts.append("workflow=\(workflow.rawValue)")
		parts.append("evidence=\(input.evidenceQuality)")
		if input.hasErrorTerms { parts.append("error_terms=yes") }
		if input.hasMultipleSources { parts.append("multiple_sources=yes") }
		if !focus.isEmpty { parts.append("terms=\(focus.prefix(5).joined(separator: ","))") }
		return parts.joined(separator: " ")
	}

	// Phase 28.3: Generated action confidence reflects actual quality, not template inflation.
	// Old max was 0.92 which PrimitiveComposer boosted to 0.95 — this let garbage "Review X in Y"
	// beat portfolio candidates with real scores of 0.360. Cap at 0.72 so generated actions must
	// genuinely be better to win.
	private static func confidence(input: GeneratedActionInput, workflow: WorkflowType, focusCount: Int) -> Double {
		var value = max(input.confidenceSeed, 0.38)
		if workflow != .unknown { value += 0.08 }
		if focusCount >= 2 { value += 0.06 }
		if input.evidenceQuality == "ax_content" || input.evidenceQuality == "browser_context" || input.evidenceQuality == "browser_tabs" || input.evidenceQuality == "editor_context" { value += 0.05 }
		if input.hasErrorTerms || input.hasComparisonCandidates { value += 0.06 }
		return min(0.72, value)
	}

	private static func requiredContext(input: GeneratedActionInput, workflow: WorkflowType) -> [ContextRequirementType] {
		var required: Set<ContextRequirementType> = [.textSnippet]
		if input.hasMultipleSources || input.hasComparisonCandidates { required.insert(.multiSource) }
		if input.hasErrorTerms || workflow == .debugging { required.insert(.errorContext) }
		if workflow == .studying || input.entityType == .course_material { required.insert(.notesContext) }
		if workflow != .unknown { required.insert(.workflowContext) }
		return Array(required).sorted(by: { $0.rawValue < $1.rawValue })
	}

	private static func requiredContext(
		from categories: [String],
		snapshot: CanonicalGeneratedExecutionContextSnapshot
	) -> [ContextRequirementType] {
		var required: Set<ContextRequirementType> = [.textSnippet]
		let cats = Set(categories.map { $0.lowercased() })
		if cats.contains("compare") { required.insert(.multiSource) }
		if cats.contains("debug") { required.insert(.errorContext) }
		if cats.contains("study") || cats.contains("organize") { required.insert(.notesContext) }
		if snapshot.inferredWorkflow != .unknown { required.insert(.workflowContext) }
		return Array(required).sorted(by: { $0.rawValue < $1.rawValue })
	}

	private static func workflowType(from input: GeneratedActionInput) -> WorkflowType {
		switch input.domain {
		case .coding, .creative_coding:
			return input.mode == .debugging || input.hasErrorTerms ? .debugging : .editing
		case .studying:
			return .studying
		case .researching:
			return input.hasComparisonCandidates ? .comparing : .research
		case .shopping:
			return .comparing
		default:
			break
		}

		switch input.activeCompartmentWorkflow {
		case .debugging?: return .debugging
		case .coding?: return .editing
		case .studying?, .reading?: return .studying
		case .researching?: return .research
		case .shopping?, .comparing?: return .comparing
		case .writing?: return .writing
		default: return .unknown
		}
	}

	private static func normalizedTerms(_ terms: [String]) -> [String] {
		var seen: Set<String> = []
		let stop: Set<String> = ["this", "that", "current", "project", "page", "context", "with", "from", "about", "file"]
		return terms
			.flatMap { $0.components(separatedBy: CharacterSet.alphanumerics.inverted) }
			.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { $0.count >= 3 && !stop.contains($0) }
			.filter { seen.insert($0).inserted }
			.prefix(10)
			.map { $0 }
	}

	private static func focusTerms(_ terms: [String], entity: String, related: [String]) -> [String] {
		var combined = terms
		combined += normalizedTerms([entity])
		combined += normalizedTerms(related)
		var seen: Set<String> = []
		return combined.filter { seen.insert($0).inserted }.prefix(8).map { $0 }
	}

	private static func cleanEntity(_ value: String, fallback: String?) -> String {
		let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
		if !raw.isEmpty && raw.lowercased() != "unknown" { return raw }
		return fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
	}

	private static func isGameContext(entityLower: String, appLower: String, terms: Set<String>) -> Bool {
		if appLower.contains("turbowarp") || entityLower.contains("turbowarp") { return true }
		let gameTerms: Set<String> = ["tank", "projectile", "enemy", "spawn", "spawning", "collision", "gameplay"]
		return !terms.intersection(gameTerms).isEmpty && (entityLower.contains("game") || entityLower.contains("shooter"))
	}

	private static func gameFocusPhrase(focus: [String]) -> String {
		let set = Set(focus)
		if set.contains("projectile") && (set.contains("collision") || set.contains("collisions")) && (set.contains("enemy") || set.contains("spawning") || set.contains("spawn")) {
			return "projectile collisions and enemy spawning"
		}
		if set.contains("projectile") && (set.contains("collision") || set.contains("collisions")) {
			return "projectile collisions"
		}
		if set.contains("enemy") || set.contains("spawning") || set.contains("spawn") {
			return "enemy spawning"
		}
		return focus.prefix(3).isEmpty ? "gameplay behavior" : focus.prefix(3).joined(separator: ", ")
	}

	private static func studyFocusPhrase(focus: [String], entity: String) -> String {
		let set = Set(focus)
		if set.contains("recursion") && (set.contains("tree") || set.contains("traversal")) {
			return "recursion and tree traversal"
		}
		if set.contains("recursion") { return "recursion" }
		if let first = firstUseful(focus) { return first }
		let cleaned = short(entity, max: 32)
		return cleaned.isEmpty ? "focused" : cleaned
	}

	private static func isCodingContext(input: GeneratedActionInput, workflow: WorkflowType) -> Bool {
		if input.domain == .coding || input.domain == .creative_coding { return true }
		if input.activeCompartmentWorkflow == .coding { return true }
		if workflow == .editing && input.entityType == .code_project { return true }
		return false
	}

	private static func codingTitle(input: GeneratedActionInput, focus: [String], entity: String) -> String? {
		let project = input.activeCompartmentLabel ?? entity
		let shortProject = short(project, max: 36)

		if input.relatedEntities.count >= 2 {
			let component = firstUseful(focus) ?? shortProject
			return "Review the architecture around \(component)"
		}

		if input.activeCompartmentLabel != nil && !focus.isEmpty {
			let topic = firstUseful(focus) ?? shortProject
			return "Plan the next steps for \(topic)"
		}

		if focus.count >= 2 {
			let terms = focus.prefix(2).joined(separator: " and ")
			return "Look for patterns in \(terms)"
		}

		if !shortProject.isEmpty {
			return "Outline the approach for \(shortProject)"
		}

		return nil
	}

	private static func firstUseful(_ focus: [String]) -> String? {
		let banned: Set<String> = ["google", "chrome", "safari", "xcode", "swift", "notes"]
		return focus.first { !banned.contains($0) }
	}

	private static func short(_ value: String, max: Int) -> String {
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.count <= max { return trimmed }
		return String(trimmed.prefix(max))
	}

	private static func stableId(title: String, workflow: WorkflowType, entity: String) -> String {
		let basis = "\(workflow.rawValue)|\(title.lowercased())|\(entity.lowercased())"
		return "generated:\(String(fnv1a64(basis), radix: 16))"
	}

	private static func fnv1a64(_ text: String) -> UInt64 {
		var hash: UInt64 = 14_695_981_039_346_656_037
		for byte in text.utf8 {
			hash ^= UInt64(byte)
			hash &*= 1_099_511_628_211
		}
		return hash
	}
}

struct ActionValidationResult: Sendable, Equatable {
	let accepted: Bool
	let rejectedReason: String?
}

enum ActionValidator {
	private static let minimumConfidence = 0.46
	private static let genericTitles: Set<String> = [
		"create next steps",
		"generate checklist",
		"create checklist",
		"explain code",
		"help with this",
		"continue working",
		"summarize sources",
		"summarize context"
	]
	private static let unsupportedRequirements: Set<ContextRequirementType> = [.screenCapture, .fusedVisual]
	private static let lock = NSLock()
	private nonisolated(unsafe) static var recentTitles: [String] = []

	static func validate(
		_ action: GeneratedActionProposal,
		recentActionTitles: [String] = []
	) -> ActionValidationResult {
		let lower = normalizeTitle(action.title)
		let reason: String?

		if action.confidence < minimumConfidence {
			reason = "low_confidence"
		} else if lower.isEmpty || genericTitles.contains(lower) || isGeneric(lower) {
			reason = "generic"
		} else if recentActionTitles.map(normalizeTitle).contains(lower) || recordedRecently(lower) {
			reason = "duplicate_recent_action"
		} else if !Set(action.requiredContext).intersection(unsupportedRequirements).isEmpty {
			reason = "unsupported_execution_requirement"
		} else {
			reason = nil
		}

		let accepted = reason == nil
		if accepted { record(lower) }
		print("[ActionValidation] accepted=\(accepted ? "yes" : "no")")
		print("[ActionValidation] rejected_reason=\(reason ?? "none")")
		return ActionValidationResult(accepted: accepted, rejectedReason: reason)
	}

	static func resetRecentActionsForTests() {
		lock.lock()
		recentTitles.removeAll()
		lock.unlock()
	}

	private static func normalizeTitle(_ title: String) -> String {
		title.lowercased()
			.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private static func isGeneric(_ lower: String) -> Bool {
		let tokens = lower.split(separator: " ").map(String.init)
		if tokens.count <= 2 { return true }
		if lower.hasPrefix("help ") { return true }
		if lower.hasPrefix("create ") && tokens.count <= 3 { return true }
		if lower.hasPrefix("generate ") && tokens.count <= 3 { return true }
		return false
	}

	private static func recordedRecently(_ lower: String) -> Bool {
		lock.lock()
		let contains = recentTitles.contains(lower)
		lock.unlock()
		return contains
	}

	private static func record(_ lower: String) {
		lock.lock()
		recentTitles.insert(lower, at: 0)
		recentTitles = Array(recentTitles.prefix(12))
		lock.unlock()
	}
}

struct PrimitiveCompositionResult: Sendable, Equatable {
	let action: GeneratedActionProposal
	let primitives: [ExecutionPrimitive]
	let confidence: Double
	let intentType: IntentType
}

enum PrimitiveComposer {
	static func compose(_ action: GeneratedActionProposal) -> PrimitiveCompositionResult? {
		let lower = "\(action.title) \(action.description) \(action.reasoning)".lowercased()
		var primitives: [ExecutionPrimitive] = []

		if action.workflow == .debugging || containsAny(lower, ["error", "failure", "bug", "collision", "crash"]) {
			primitives.append(.explainError)
			primitives.append(.generateChecklist)
		} else if containsAny(lower, ["compare", "tradeoff", "authors", "conclusions"]) || action.workflow == .comparing {
			primitives.append(.compareContexts)
			primitives.append(.synthesizeResearchSummary)
		} else if containsAny(lower, ["practice", "questions", "study", "recursion"]) || action.workflow == .studying {
			primitives.append(.generateStudyNotes)
			primitives.append(.answerFromContext)
		} else if containsAny(lower, ["review", "check", "testing", "before testing"]) {
			primitives.append(.generateChecklist)
			primitives.append(.answerFromContext)
		} else if containsAny(lower, ["architecture", "patterns", "plan the next", "outline the approach"]) {
			primitives.append(.generateChecklist)
			primitives.append(.answerFromContext)
		} else if containsAny(lower, ["organize", "structure", "outline", "notes"]) {
			primitives.append(.structureNotes)
			primitives.append(.organizeInformation)
		} else if containsAny(lower, ["extract", "action items", "todos"]) {
			primitives.append(.extractActionItems)
		} else if containsAny(lower, ["synthesize", "findings", "research"]) {
			primitives.append(.synthesizeResearchSummary)
		} else if containsAny(lower, ["explain", "investigate"]) {
			primitives.append(.answerFromContext)
		}

		primitives = dedupe(primitives)
		guard !primitives.isEmpty else {
			print("[PrimitiveComposer] primitives=")
			print("[PrimitiveComposer] confidence=0.00")
			return nil
		}

		let confidence = min(0.95, action.confidence + (primitives.count > 1 ? 0.03 : 0))
		let composed = action.withPrimitives(primitives, confidence: confidence)
		let intent = intentType(from: primitives)
		print("[PrimitiveComposer] primitives=\(primitives.map(\.rawValue).joined(separator: ","))")
		print("[PrimitiveComposer] confidence=\(String(format: "%.2f", confidence))")
		return PrimitiveCompositionResult(
			action: composed,
			primitives: primitives,
			confidence: confidence,
			intentType: intent
		)
	}

	private static func containsAny(_ text: String, _ terms: [String]) -> Bool {
		terms.contains { text.contains($0) }
	}

	private static func dedupe(_ primitives: [ExecutionPrimitive]) -> [ExecutionPrimitive] {
		var seen: Set<ExecutionPrimitive> = []
		return primitives.filter { seen.insert($0).inserted }
	}

	static func intentType(from primitives: [ExecutionPrimitive]) -> IntentType {
		if primitives.contains(.compareContexts) { return .compare }
		if primitives.contains(.explainError) { return .explain }
		if primitives.contains(.extractActionItems) { return .extract }
		if primitives.contains(.organizeInformation) { return .organize }
		if primitives.contains(.synthesizeResearchSummary) { return .synthesize }
		if primitives.contains(.structureNotes) { return .structure }
		if primitives.contains(.classifyWorkflow) { return .classify }
		if primitives.contains(.answerFromContext) { return .answer }
		if primitives.contains(.summarizeContext) { return .summarize }
		return .unknown
	}
}

enum GeneratedActionCapabilityAdapter {
	static func capability(from action: GeneratedActionProposal) -> CognitiveCapability {
		CognitiveCapability(
			id: action.id,
			label: action.title,
			inputRequirements: action.requiredContext.map(\.rawValue),
			outputType: outputType(from: action.primitives),
			evidenceThreshold: action.requiredContext.contains(.multiSource) ? "multi_source" : "title_only",
			privacyLevel: .local,
			riskLevel: .read_only,
			requiresConfirmation: false,
			executionMode: .preview_only
		)
	}

	static func actionFromArtifact(
		title: String,
		description: String,
		artifactType: String,
		confidence: Double,
		evidenceQuality: String,
		workflow: WorkflowType = .unknown,
		referenceTime: Date = Date()
	) -> GeneratedActionProposal {
		let primitives = primitives(fromArtifactType: artifactType)
		return GeneratedActionProposal(
			id: "generated:\(abs(title.hashValue))",
			title: title,
			description: description,
			reasoning: "artifact_type=\(artifactType) evidence=\(evidenceQuality)",
			confidence: confidence,
			workflow: workflow,
			requiredContext: [.textSnippet],
			primitives: primitives,
			createdAt: referenceTime
		)
	}

	static func outputType(from primitives: [ExecutionPrimitive]) -> String {
		if primitives.contains(.compareContexts) { return "comparison" }
		if primitives.contains(.generateChecklist) { return "checklist" }
		if primitives.contains(.structureNotes) || primitives.contains(.organizeInformation) { return "outline" }
		if primitives.contains(.explainError) || primitives.contains(.answerFromContext) { return "explanation" }
		if primitives.contains(.generateStudyNotes) { return "study_notes" }
		if primitives.contains(.extractActionItems) { return "action_items" }
		if primitives.contains(.synthesizeResearchSummary) { return "summary" }
		return "preview"
	}

	private static func primitives(fromArtifactType type: String) -> [ExecutionPrimitive] {
		let lower = type.lowercased()
		if lower.contains("comparison") || lower.contains("matrix") { return [.compareContexts] }
		if lower.contains("checklist") { return [.generateChecklist] }
		if lower.contains("outline") || lower.contains("notes") { return [.structureNotes] }
		if lower.contains("clarification") || lower.contains("explanation") { return [.answerFromContext] }
		if lower.contains("summary") { return [.summarizeContext] }
		return [.answerFromContext]
	}
}

enum GeneratedActionPipeline {
	static func firstAction(
		input: GeneratedActionInput,
		referenceTime: Date = Date(),
		llm: any ActionCandidateLLMGenerating = LocalAIClient.shared
	) async -> GeneratedActionProposal? {
		guard GeneratedContextSuppressionGate.allow(input) else {
			PlannerStats.recordSuppressedContext()
			return nil
		}

		let problems = ProblemInference.infer(from: input)
		for problem in problems {
			let request = ActionCandidateRequest(input: input, problem: problem, referenceTime: referenceTime)
			let proposals = await ActionCandidateGenerator.proposals(request: request, llm: llm)
			guard !proposals.isEmpty else {
				print("[GeneratedAction] suppress reason=no_candidates")
				PlannerStats.recordSuppressedContext()
				return nil
			}
			for action in proposals {
				let validation = ActionCandidateValidator.validate(action)
				guard validation.accepted else {
					PlannerStats.recordRejectedCandidate()
					continue
				}
				guard GeneratedProposalQualityFilter.accept(action) else {
					PlannerStats.recordRejectedCandidate()
					continue
				}
				guard let composition = PrimitiveComposer.compose(action) else { continue }
				print("[PrimitiveComposition] primitives=\(composition.primitives.map(\.rawValue).joined(separator: ",")) confidence=\(String(format: "%.2f", composition.confidence))")
				print("[ProposalReasoning] selected_title=\"\(composition.action.title)\" problem=\(problem.problem) reasoning=\"\(composition.action.reasoning)\"")
				PlannerStats.recordAcceptedCandidate()
				return composition.action
			}
		}

		print("[GeneratedAction] suppress reason=no_candidates")
		PlannerStats.recordSuppressedContext()
		return nil
	}
}

enum GeneratedActionSelfTest {
	static func run() -> Bool {
		print("[GeneratedActionSelfTest] starting")
		ActionValidator.resetRecentActionsForTests()
		var failures: [String] = []
		func check(_ name: String, _ condition: Bool) {
			if condition {
				print("[GeneratedActionSelfTest] pass case=\(name)")
			} else {
				print("[GeneratedActionSelfTest] fail case=\(name)")
				failures.append(name)
			}
		}

		let lecture = GeneratedActionInput(
			currentEntity: "Lecture 5 recursion examples",
			relatedEntities: [],
			activeTerms: ["recursion", "tree", "traversal"],
			activeCompartmentLabel: "Lecture 5",
			activeCompartmentWorkflow: .studying,
			evidenceQuality: "ax_content",
			activeApplication: "Preview",
			domain: .studying,
			mode: .reading,
			entityType: .course_material,
			hasErrorTerms: false,
			hasMultipleSources: false,
			hasComparisonCandidates: false,
			confidenceSeed: 0.62
		)
		let lectureAction = GeneratedActionGenerator.generate(input: lecture).first
		check("lecture_action_specific", lectureAction?.title == "Create recursion and tree traversal practice questions")
		check("lecture_no_static_label", lectureAction?.title != "Generate Quiz")
		if let lectureAction, let composed = PrimitiveComposer.compose(lectureAction)?.action {
			JarvisSuggestionGenerator.logGeneratedActionSource(composed)
		}

		let game = GeneratedActionInput(
			currentEntity: "Realistic Tank Shooter",
			relatedEntities: [],
			activeTerms: ["projectile", "collision", "enemy", "spawning"],
			activeCompartmentLabel: nil,
			activeCompartmentWorkflow: .coding,
			evidenceQuality: "title_only",
			activeApplication: "TurboWarp",
			domain: .creative_coding,
			mode: .building,
			entityType: .code_project,
			hasErrorTerms: false,
			hasMultipleSources: false,
			hasComparisonCandidates: false,
			confidenceSeed: 0.64
		)
		let gameAction = GeneratedActionGenerator.generate(input: game).first
		check("game_action_specific", gameAction?.title == "Review projectile collisions and enemy spawning before testing")
		check("game_no_static_label", gameAction?.title != "Create Game Design Checklist")
		if let gameAction, let composed = PrimitiveComposer.compose(gameAction)?.action {
			JarvisSuggestionGenerator.logGeneratedActionSource(composed)
		}

		let code = GeneratedActionInput(
			currentEntity: "PlayerMovement.swift",
			relatedEntities: [],
			activeTerms: ["compiler", "error", "collision", "velocity", "player"],
			activeCompartmentLabel: nil,
			activeCompartmentWorkflow: .debugging,
			evidenceQuality: "title_only",
			activeApplication: "Xcode",
			domain: .coding,
			mode: .debugging,
			entityType: .code_project,
			hasErrorTerms: true,
			hasMultipleSources: false,
			hasComparisonCandidates: false,
			confidenceSeed: 0.66
		)
		let codeAction = GeneratedActionGenerator.generate(input: code).first
		check("code_action_specific", codeAction?.title == "Investigate movement collision failure")
		check("code_no_static_label", codeAction?.title != "Explain Code")
		if let codeAction, let composed = PrimitiveComposer.compose(codeAction)?.action {
			JarvisSuggestionGenerator.logGeneratedActionSource(composed)
		}

		let research = GeneratedActionInput(
			currentEntity: "Dense retrieval evaluation",
			relatedEntities: ["Paper A: retrieval quality", "Paper B: reranking evaluation"],
			activeTerms: ["retrieval", "quality", "authors", "conclusions"],
			activeCompartmentLabel: "Research tabs",
			activeCompartmentWorkflow: .researching,
			evidenceQuality: "browser_tabs",
			activeApplication: "Safari",
			domain: .researching,
			mode: .comparing,
			entityType: .website,
			hasErrorTerms: false,
			hasMultipleSources: true,
			hasComparisonCandidates: true,
			confidenceSeed: 0.66
		)
		let researchAction = GeneratedActionGenerator.generate(input: research).first
		check("research_action_specific", researchAction?.title == "Compare authors' conclusions on retrieval quality")
		check("research_no_static_label", researchAction?.title != "Synthesize Sources")
		if let researchAction, let composed = PrimitiveComposer.compose(researchAction)?.action {
			JarvisSuggestionGenerator.logGeneratedActionSource(composed)
		}

		// ── Coding context: multiple related entities → architecture review ──
		let codingArch = GeneratedActionInput(
			currentEntity: "ContextEventProducer.swift",
			relatedEntities: ["OpportunityEngine.swift", "ActionPortfolioEngine.swift"],
			activeTerms: ["context", "opportunity", "portfolio"],
			activeCompartmentLabel: "Contextual coding",
			activeCompartmentWorkflow: .coding,
			evidenceQuality: "editor_context",
			activeApplication: "Xcode",
			domain: .coding,
			mode: .building,
			entityType: .code_project,
			hasErrorTerms: false,
			hasMultipleSources: false,
			hasComparisonCandidates: false,
			confidenceSeed: 0.62
		)
		let codingArchAction = GeneratedActionGenerator.generate(input: codingArch).first
		check("coding_architecture_review", codingArchAction?.title == "Review the architecture around opportunity")
		if let a = codingArchAction, let c = PrimitiveComposer.compose(a)?.action {
			JarvisSuggestionGenerator.logGeneratedActionSource(c)
		}

		// ── Coding context: compartment but few related → plan next steps ──
		let codingPlan = GeneratedActionInput(
			currentEntity: "AppDelegate.swift",
			relatedEntities: [],
			activeTerms: ["delegate", "lifecycle", "startup"],
			activeCompartmentLabel: "Contextual coding",
			activeCompartmentWorkflow: .coding,
			evidenceQuality: "editor_context",
			activeApplication: "Xcode",
			domain: .coding,
			mode: .building,
			entityType: .code_project,
			hasErrorTerms: false,
			hasMultipleSources: false,
			hasComparisonCandidates: false,
			confidenceSeed: 0.58
		)
		let codingPlanAction = GeneratedActionGenerator.generate(input: codingPlan).first
		check("coding_plan_next_steps", codingPlanAction?.title == "Plan the next steps for delegate")

		// ── Coding context: no compartment label, 2+ focus terms → patterns ──
		let codingPattern = GeneratedActionInput(
			currentEntity: "FrictionEngine.swift",
			relatedEntities: [],
			activeTerms: ["friction", "oscillation"],
			activeCompartmentLabel: nil,
			activeCompartmentWorkflow: .coding,
			evidenceQuality: "editor_context",
			activeApplication: "Xcode",
			domain: .coding,
			mode: .building,
			entityType: .code_project,
			hasErrorTerms: false,
			hasMultipleSources: false,
			hasComparisonCandidates: false,
			confidenceSeed: 0.55
		)
		let codingPatternAction = GeneratedActionGenerator.generate(input: codingPattern).first
		check("coding_look_for_patterns", codingPatternAction?.title == "Look for patterns in friction and oscillation")

		let ok = failures.isEmpty
		print("[GeneratedActionSelfTest] completed ok=\(ok) failures=\(failures.count)")
		return ok
	}
}

enum ActionValidationSelfTest {
	static func run() -> Bool {
		print("[ActionValidationSelfTest] starting")
		ActionValidator.resetRecentActionsForTests()
		var failures: [String] = []
		func check(_ name: String, _ condition: Bool) {
			if condition {
				print("[ActionValidationSelfTest] pass case=\(name)")
			} else {
				print("[ActionValidationSelfTest] fail case=\(name)")
				failures.append(name)
			}
		}

		let valid = GeneratedActionProposal(
			id: "test:valid",
			title: "Review projectile collisions before testing",
			description: "Gameplay terms are active.",
			reasoning: "terms=projectile,collision workflow=editing",
			confidence: 0.74,
			workflow: .editing,
			requiredContext: [.textSnippet]
		)
		check("specific_accepted", ActionValidator.validate(valid).accepted)
		check("duplicate_rejected", !ActionValidator.validate(valid).accepted)

		let generic = GeneratedActionProposal(
			id: "test:generic",
			title: "Create Next Steps",
			description: "",
			reasoning: "",
			confidence: 0.80,
			workflow: .unknown,
			requiredContext: [.textSnippet]
		)
		check("generic_rejected", ActionValidator.validate(generic).rejectedReason == "generic")

		let low = GeneratedActionProposal(
			id: "test:low",
			title: "Compare authors' conclusions on retrieval quality",
			description: "",
			reasoning: "",
			confidence: 0.20,
			workflow: .research,
			requiredContext: [.textSnippet]
		)
		check("low_confidence_rejected", ActionValidator.validate(low).rejectedReason == "low_confidence")

		let unsupported = GeneratedActionProposal(
			id: "test:unsupported",
			title: "Review visible chart details",
			description: "",
			reasoning: "",
			confidence: 0.70,
			workflow: .reviewing,
			requiredContext: [.screenCapture]
		)
		check("unsupported_rejected", ActionValidator.validate(unsupported).rejectedReason == "unsupported_execution_requirement")

		let ok = failures.isEmpty
		print("[ActionValidationSelfTest] completed ok=\(ok) failures=\(failures.count)")
		return ok
	}
}

enum PrimitiveComposerSelfTest {
	static func run() -> Bool {
		print("[PrimitiveComposerSelfTest] starting")
		var failures: [String] = []
		func check(_ name: String, _ condition: Bool) {
			if condition {
				print("[PrimitiveComposerSelfTest] pass case=\(name)")
			} else {
				print("[PrimitiveComposerSelfTest] fail case=\(name)")
				failures.append(name)
			}
		}

		let debug = GeneratedActionProposal(
			id: "test:debug",
			title: "Investigate movement collision failure",
			description: "Compiler error and collision terms are active.",
			reasoning: "workflow=debugging error_terms=yes",
			confidence: 0.78,
			workflow: .debugging,
			requiredContext: [.textSnippet, .errorContext]
		)
		let debugComposition = PrimitiveComposer.compose(debug)
		check("debug_uses_existing_primitives", debugComposition?.primitives == [.explainError, .generateChecklist])

		let study = GeneratedActionProposal(
			id: "test:study",
			title: "Create recursion practice questions",
			description: "Lecture context is active.",
			reasoning: "workflow=studying terms=recursion",
			confidence: 0.74,
			workflow: .studying,
			requiredContext: [.textSnippet, .notesContext]
		)
		let studyComposition = PrimitiveComposer.compose(study)
		check("study_composes_without_quiz_capability", studyComposition?.primitives == [.generateStudyNotes, .answerFromContext])

		let research = GeneratedActionProposal(
			id: "test:research",
			title: "Compare authors' conclusions on retrieval quality",
			description: "Research tabs are active.",
			reasoning: "workflow=research multiple_sources=yes",
			confidence: 0.80,
			workflow: .research,
			requiredContext: [.textSnippet, .multiSource]
		)
		let researchComposition = PrimitiveComposer.compose(research)
		check("research_compare_primitives", researchComposition?.primitives == [.compareContexts, .synthesizeResearchSummary])

		let ok = failures.isEmpty
		print("[PrimitiveComposerSelfTest] completed ok=\(ok) failures=\(failures.count)")
		return ok
	}
}
