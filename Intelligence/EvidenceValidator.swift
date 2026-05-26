import Foundation

/// Result of final answer/evidence validation (Phase 4T).
struct EvidenceValidationResult: Sendable, Codable, Equatable {
	let isValid: Bool
	let reason: String
	let missingElements: [String]
	let validatedCandidates: [String]
}

/// Structured validation layer executed before answer presentation (Phase 4T).
///
/// Prevents presenting low-quality or malformed results to the user.
enum EvidenceValidator {

	/// Validates gathered facts and entities before they are presented as a complete answer.
	static func validate(
		goal: String,
		state: AgenticEvidenceState?,
		observations: [AgenticEvidenceObservation],
		entities: [GroundedSemanticEntity],
		facts: [StructuredFact]
	) -> EvidenceValidationResult {
		guard let state else {
			return EvidenceValidationResult(isValid: false, reason: "missing_evidence_state", missingElements: ["evidence_state"], validatedCandidates: [])
		}

		let isCompareGoal = AgenticEvidenceRequirementsInferrer.classifyFamily(goal: goal.lowercased(), workflow: "") == .compare
		if isCompareGoal {
			return ComparisonEvidenceValidator.validate(state: state, observations: observations, entities: entities, facts: facts)
		}

		// Non-comparison tasks: require at least one reliable live-grounded product title or summary
		var missing: [String] = []
		
		// 1. Required kind satisfaction check
		for reqKind in state.missing {
			missing.append("missing_required_\(reqKind.rawValue)")
		}

		// 2. Reject assistant/generated chrome leakage
		for o in observations {
			if EvidenceQualityGate.detectChromeLeak(o.text) {
				return EvidenceValidationResult(
					isValid: false,
					reason: "assistant_chrome_leakage_detected",
					missingElements: ["clean_evidence"],
					validatedCandidates: []
				)
			}
		}

		// 3. Reject malformed / single token products
		let titles = observations.filter { $0.kind == .productTitle }
		let invalidTitles = titles.filter { o in
			EvidenceQualityGate.detectTruncation(o.text) || (o.text.split(separator: " ").count == 1 && o.text.count <= 3)
		}
		if !titles.isEmpty && invalidTitles.count == titles.count {
			return EvidenceValidationResult(
				isValid: false,
				reason: "all_extracted_product_titles_malformed",
				missingElements: ["valid_product_title"],
				validatedCandidates: []
			)
		}

		let isValid = missing.isEmpty
		let reason = isValid ? "evidence_validation_passed" : "missing_required_evidence"

		return EvidenceValidationResult(
			isValid: isValid,
			reason: reason,
			missingElements: missing,
			validatedCandidates: titles.map(\.text)
		)
	}
}

/// Validation layer specific to comparative goals (Phase 4T).
enum ComparisonEvidenceValidator {

	/// Validates that comparative goals have sufficient, high-quality distinct live grounded candidates.
	static func validate(
		state: AgenticEvidenceState,
		observations: [AgenticEvidenceObservation],
		entities: [GroundedSemanticEntity],
		facts: [StructuredFact]
	) -> EvidenceValidationResult {
		var missing: [String] = []

		// 1. Core comparison candidate check
		var distinctCandidates = Set<String>()
		var rawCandidates: [String] = []

		// Read comparison candidate observations and entities
		let candidateObs = observations.filter { $0.kind == .comparisonCandidate || $0.kind == .productTitle }
		for o in candidateObs {
			// Reject browser history only candidates
			guard o.source != .browsingHistory else { continue }

			let t = o.text.trimmingCharacters(in: .whitespacesAndNewlines)
			if EvidenceQualityGate.detectTruncation(t) || EvidenceQualityGate.detectMashedWord(t) || EvidenceQualityGate.detectChromeLeak(t) {
				continue
			}
			if t.split(separator: " ").count == 1 && t.count <= 3 { continue }

			distinctCandidates.insert(normalize(t))
			rawCandidates.append(t)
		}

		let liveEntities = entities.filter { $0.type == .productTitle && $0.confidence >= 0.35 }
		for e in liveEntities {
			let t = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
			if EvidenceQualityGate.detectTruncation(t) || EvidenceQualityGate.detectMashedWord(t) || EvidenceQualityGate.detectChromeLeak(t) {
				continue
			}
			distinctCandidates.insert(normalize(t))
			rawCandidates.append(t)
		}

		if distinctCandidates.count < 2 {
			missing.append("second_valid_comparison_candidate")
		}

		// 2. Specs validation
		let specs = observations.filter { $0.kind == .specs }
		if specs.isEmpty {
			missing.append("specs_evidence")
		}

		let isValid = missing.isEmpty
		let reason = isValid ? "comparison_validation_passed" : "insufficient_distinct_comparison_candidates"

		return EvidenceValidationResult(
			isValid: isValid,
			reason: reason,
			missingElements: missing,
			validatedCandidates: Array(distinctCandidates)
		)
	}

	private static func normalize(_ text: String) -> String {
		let lower = text.lowercased()
		let cleaned = lower.filter { $0.isLetter || $0.isNumber || $0 == " " }
		return String(cleaned).split(separator: " ").prefix(4).joined(separator: " ")
	}
}
