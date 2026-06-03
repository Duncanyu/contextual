import Foundation

struct ProblemSignal: Sendable, Equatable, Codable {
	let problem: String
	let confidence: Double
	let evidence: [String]
	let focusTerms: [String]
	let repeatedEntities: [String]
	let behaviorTags: [String]

	init(
		problem: String,
		confidence: Double,
		evidence: [String],
		focusTerms: [String],
		repeatedEntities: [String],
		behaviorTags: [String]
	) {
		self.problem = problem
		self.confidence = min(1.0, max(0.0, confidence))
		self.evidence = evidence
		self.focusTerms = focusTerms
		self.repeatedEntities = repeatedEntities
		self.behaviorTags = behaviorTags
	}
}

struct ProblemInferenceInput: Sendable, Equatable {
	let currentEntity: String
	let relatedEntities: [String]
	let activeTerms: [String]
	let evidenceQuality: String
	let activeApplication: String
	let domain: DeterminerSignal.Domain
	let mode: DeterminerSignal.Mode
	let entityType: EntityGrounding.EntityType
	let hasErrorTerms: Bool
	let hasMultipleSources: Bool
	let hasComparisonCandidates: Bool
	let confidenceSeed: Double
	let activeCompartmentLabel: String?
	let activeCompartmentWorkflow: AmbientWorkflowType?
}

enum ProblemInference {
	static func infer(from input: GeneratedActionInput) -> [ProblemSignal] {
		infer(from: ProblemInferenceInput(
			currentEntity: input.currentEntity,
			relatedEntities: input.relatedEntities,
			activeTerms: input.activeTerms,
			evidenceQuality: input.evidenceQuality,
			activeApplication: input.activeApplication,
			domain: input.domain,
			mode: input.mode,
			entityType: input.entityType,
			hasErrorTerms: input.hasErrorTerms,
			hasMultipleSources: input.hasMultipleSources,
			hasComparisonCandidates: input.hasComparisonCandidates,
			confidenceSeed: input.confidenceSeed,
			activeCompartmentLabel: input.activeCompartmentLabel,
			activeCompartmentWorkflow: input.activeCompartmentWorkflow
		))
	}

	static func infer(from input: ProblemInferenceInput) -> [ProblemSignal] {
		let terms = normalizedTerms(input.activeTerms + tokenized(input.currentEntity) + input.relatedEntities.flatMap(tokenized))
		let repeatedEntities = repeated(input.relatedEntities + [input.currentEntity])
		let tags = behaviorTags(from: input, terms: terms, repeatedEntities: repeatedEntities)
		let focus = Array(terms.prefix(6))
		var signals: [ProblemSignal] = []

		if input.hasErrorTerms || tags.contains("debugging_behavior") {
			signals.append(signal(
				problem: "debugging_\(topicName(from: focus, fallback: "logic"))",
				base: 0.62,
				input: input,
				focus: focus,
				repeatedEntities: repeatedEntities,
				tags: tags,
				evidence: evidence(input, tags, focus)
			))
		}

		if input.hasComparisonCandidates || tags.contains("comparison_behavior") {
			signals.append(signal(
				problem: "comparing_\(topicName(from: focus, fallback: "options"))",
				base: 0.66,
				input: input,
				focus: focus,
				repeatedEntities: repeatedEntities,
				tags: tags,
				evidence: evidence(input, tags, focus)
			))
		}

		if tags.contains("reading_behavior") && (input.entityType == .course_material || input.domain == .studying) {
			signals.append(signal(
				problem: "understanding_\(topicName(from: focus, fallback: "material"))",
				base: 0.58,
				input: input,
				focus: focus,
				repeatedEntities: repeatedEntities,
				tags: tags,
				evidence: evidence(input, tags, focus)
			))
		}

		if input.hasMultipleSources || tags.contains("synthesis_behavior") {
			signals.append(signal(
				problem: "synthesizing_\(topicName(from: focus, fallback: "sources"))",
				base: 0.60,
				input: input,
				focus: focus,
				repeatedEntities: repeatedEntities,
				tags: tags,
				evidence: evidence(input, tags, focus)
			))
		}

		if tags.contains("exploration_behavior") {
			signals.append(signal(
				problem: "exploring_\(topicName(from: focus, fallback: "alternatives"))",
				base: 0.54,
				input: input,
				focus: focus,
				repeatedEntities: repeatedEntities,
				tags: tags,
				evidence: evidence(input, tags, focus)
			))
		}

		if signals.isEmpty, let topic = focus.first {
			signals.append(signal(
				problem: "clarifying_\(topic)",
				base: 0.48,
				input: input,
				focus: focus,
				repeatedEntities: repeatedEntities,
				tags: tags,
				evidence: evidence(input, tags, focus)
			))
		}

		let ranked = signals.sorted { $0.confidence > $1.confidence }
		if let top = ranked.first {
			print("[ProblemInference] problem=\(top.problem) confidence=\(String(format: "%.2f", top.confidence)) evidence=[\(top.evidence.joined(separator: "; "))]")
		} else {
			print("[ProblemInference] problem=none confidence=0.00 evidence=[]")
		}
		return Array(ranked.prefix(3))
	}

	private static func behaviorTags(from input: ProblemInferenceInput, terms: [String], repeatedEntities: [String]) -> [String] {
		var tags: Set<String> = []
		if input.relatedEntities.count >= 2 || repeatedEntities.count >= 2 {
			tags.insert("repeated_entities")
		}
		if input.hasComparisonCandidates || input.mode == .comparing || input.domain == .shopping {
			tags.insert("comparison_behavior")
		}
		if input.hasErrorTerms || input.mode == .debugging {
			tags.insert("debugging_behavior")
		}
		if input.domain == .studying || input.mode == .reading || input.entityType == .course_material {
			tags.insert("reading_behavior")
		}
		if input.hasMultipleSources || input.evidenceQuality == "browser_tabs" || input.domain == .researching {
			tags.insert("synthesis_behavior")
		}
		if input.relatedEntities.count >= 3 || input.mode == .browsing || terms.contains("options") {
			tags.insert("exploration_behavior")
		}
		if input.confidenceSeed < 0.55 && !terms.isEmpty {
			tags.insert("stalled_activity")
		}
		if input.activeApplication.lowercased().contains("mail") || input.activeApplication.lowercased().contains("messages") {
			tags.insert("communication_behavior")
		}
		return tags.sorted()
	}

	private static func signal(
		problem: String,
		base: Double,
		input: ProblemInferenceInput,
		focus: [String],
		repeatedEntities: [String],
		tags: [String],
		evidence: [String]
	) -> ProblemSignal {
		var confidence = max(base, input.confidenceSeed)
		if !focus.isEmpty { confidence += 0.05 }
		if repeatedEntities.count >= 2 { confidence += 0.06 }
		if input.evidenceQuality == "ax_content" || input.evidenceQuality == "browser_tabs" || input.evidenceQuality == "selection" {
			confidence += 0.06
		}
		if tags.contains("stalled_activity") { confidence += 0.04 }
		return ProblemSignal(
			problem: problem,
			confidence: confidence,
			evidence: evidence,
			focusTerms: focus,
			repeatedEntities: repeatedEntities,
			behaviorTags: tags
		)
	}

	private static func evidence(_ input: ProblemInferenceInput, _ tags: [String], _ focus: [String]) -> [String] {
		var evidence: [String] = []
		if !input.currentEntity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			evidence.append("current_entity=\(short(input.currentEntity))")
		}
		if !input.relatedEntities.isEmpty {
			evidence.append("related_entities=\(input.relatedEntities.prefix(3).map(short).joined(separator: ","))")
		}
		if !focus.isEmpty {
			evidence.append("focus_terms=\(focus.prefix(5).joined(separator: ","))")
		}
		evidence.append("evidence_quality=\(input.evidenceQuality)")
		if !tags.isEmpty {
			evidence.append("patterns=\(tags.joined(separator: ","))")
		}
		return evidence
	}

	private static func repeated(_ values: [String]) -> [String] {
		let cleaned = values
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		var seen: Set<String> = []
		return cleaned.filter { seen.insert($0.lowercased()).inserted }.prefix(5).map { $0 }
	}

	private static func normalizedTerms(_ terms: [String]) -> [String] {
		let stop: Set<String> = ["this", "that", "current", "project", "page", "context", "with", "from", "about", "file", "title"]
		var seen: Set<String> = []
		return terms
			.map { $0.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
			.filter { $0.count >= 3 && !stop.contains($0) }
			.filter { seen.insert($0).inserted }
			.prefix(10)
			.map { $0 }
	}

	private static func tokenized(_ text: String) -> [String] {
		text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
	}

	private static func topicName(from terms: [String], fallback: String) -> String {
		let selected = terms.first { !["lecture", "assignment", "paper", "notes"].contains($0) } ?? terms.first ?? fallback
		return selected.replacingOccurrences(of: "-", with: "_")
	}

	private static func short(_ text: String) -> String {
		String(text.prefix(64)).replacingOccurrences(of: "\n", with: " ")
	}
}

enum ProblemInferenceSelfTest {
	static func run() -> Bool {
		print("[ProblemInferenceSelfTest] starting")
		var failures: [String] = []
		func check(_ name: String, _ condition: Bool) {
			if condition {
				print("[ProblemInferenceSelfTest] pass case=\(name)")
			} else {
				print("[ProblemInferenceSelfTest] fail case=\(name)")
				failures.append(name)
			}
		}

		let coding = ProblemInference.infer(from: GeneratedActionInput(
			currentEntity: "PlayerMovement collision handler",
			relatedEntities: ["Physics docs", "PlayerMovement.swift"],
			activeTerms: ["collision", "velocity", "bug"],
			activeCompartmentLabel: "Collision debug",
			activeCompartmentWorkflow: .debugging,
			evidenceQuality: "ax_content",
			activeApplication: "Xcode",
			domain: .coding,
			mode: .debugging,
			entityType: .code_project,
			hasErrorTerms: true,
			hasMultipleSources: true,
			hasComparisonCandidates: false,
			confidenceSeed: 0.70
		))
		check("coding_problem_debugging", coding.first?.problem.hasPrefix("debugging_") == true)

		let studying = ProblemInference.infer(from: GeneratedActionInput(
			currentEntity: "Lecture notes on recursion and tree traversal",
			relatedEntities: ["Assignment 2 prompt", "Recursion lecture notes"],
			activeTerms: ["recursion", "tree", "assignment"],
			activeCompartmentLabel: "Recursion lecture",
			activeCompartmentWorkflow: .studying,
			evidenceQuality: "ax_content",
			activeApplication: "Notes",
			domain: .studying,
			mode: .reading,
			entityType: .course_material,
			hasErrorTerms: false,
			hasMultipleSources: false,
			hasComparisonCandidates: false,
			confidenceSeed: 0.68
		))
		check("studying_problem_understanding", studying.first?.problem.hasPrefix("understanding_") == true)

		let shopping = ProblemInference.infer(from: GeneratedActionInput(
			currentEntity: "portable power station",
			relatedEntities: ["Power station A battery capacity", "Power station B runtime"],
			activeTerms: ["battery", "runtime", "capacity"],
			activeCompartmentLabel: "Power stations",
			activeCompartmentWorkflow: .shopping,
			evidenceQuality: "browser_tabs",
			activeApplication: "Safari",
			domain: .shopping,
			mode: .comparing,
			entityType: .product,
			hasErrorTerms: false,
			hasMultipleSources: true,
			hasComparisonCandidates: true,
			confidenceSeed: 0.80
		))
		check("shopping_problem_comparison", shopping.first?.problem.hasPrefix("comparing_") == true)

		let research = ProblemInference.infer(from: GeneratedActionInput(
			currentEntity: "retrieval quality papers",
			relatedEntities: ["BM25 evaluation tab", "RAG retrieval benchmark tab", "Hybrid retrieval notes"],
			activeTerms: ["retrieval", "quality", "benchmark"],
			activeCompartmentLabel: "Retrieval research",
			activeCompartmentWorkflow: .researching,
			evidenceQuality: "browser_tabs",
			activeApplication: "Safari",
			domain: .researching,
			mode: .reading,
			entityType: .website,
			hasErrorTerms: false,
			hasMultipleSources: true,
			hasComparisonCandidates: false,
			confidenceSeed: 0.73
		))
		check("research_problem_synthesis", research.first?.problem.hasPrefix("synthesizing_") == true)

		let communication = ProblemInference.infer(from: GeneratedActionInput(
			currentEntity: "Client email thread",
			relatedEntities: ["Draft reply", "Meeting notes"],
			activeTerms: ["deadline", "scope", "reply"],
			activeCompartmentLabel: "Client reply",
			activeCompartmentWorkflow: .writing,
			evidenceQuality: "selection",
			activeApplication: "Mail",
			domain: .working,
			mode: .writing,
			entityType: .email_thread,
			hasErrorTerms: false,
			hasMultipleSources: true,
			hasComparisonCandidates: false,
			confidenceSeed: 0.66
		))
		check("communication_problem_detected", communication.first?.behaviorTags.contains("communication_behavior") == true)

		let ok = failures.isEmpty
		print("[ProblemInferenceSelfTest] completed ok=\(ok) failures=\(failures.count)")
		return ok
	}
}
