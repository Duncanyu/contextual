import Foundation

/// Structured evidence quality model (Phase 4T).
///
/// Contains distinct scores for different dimensions of quality, logged internally for debugging and gating.
struct EvidenceQuality: Sendable, Codable, Equatable {
	let groundedness: Double
	let specificity: Double
	let cleanliness: Double
	let completeness: Double
	let sourceReliability: Double
	let overallScore: Double
	let reasons: [String]
}

/// Core quality assessment and validation gate (Phase 4T).
///
/// Distinguishes weak/noisy/metadata-only evidence from strong live-grounded evidence.
/// Strictly blocks premature `evidence_satisfied` stopping when quality is low.
enum EvidenceQualityGate {

	/// Minimum acceptable overall score for a goal to be considered satisfied cleanly.
	static let overallScoreThreshold = 0.70

	/// Evaluates the quality of evidence collected so far.
	static func evaluate(
		goal: String,
		state: AgenticEvidenceState,
		observations: [AgenticEvidenceObservation],
		entities: [GroundedSemanticEntity],
		facts: [StructuredFact]
	) -> EvidenceQuality {
		var reasons: [String] = []

		// 1. Completeness: derived from the core requirement confidence
		let completenessScore = state.confidence

		// 2. Source Reliability: check live vs stale/history metadata
		let sourceReliabilityScore = calculateSourceReliability(
			state: state,
			observations: observations,
			reasons: &reasons
		)

		// 3. Cleanliness: check for noise, truncations, and mashed tokens
		let cleanlinessScore = calculateCleanliness(
			state: state,
			observations: observations,
			entities: entities,
			facts: facts,
			reasons: &reasons
		)

		// 4. Specificity: check for detailed specs, prices, and ratings
		let specificityScore = calculateSpecificity(
			observations: observations,
			reasons: &reasons
		)

		// 5. Groundedness: check overlap between structured evidence and live perception
		let groundednessScore = calculateGroundedness(
			observations: observations,
			entities: entities,
			facts: facts,
			reasons: &reasons
		)

		// 6. Comparison Validation (if goal is comparative)
		let isCompareGoal = AgenticEvidenceRequirementsInferrer.classifyFamily(goal: goal.lowercased(), workflow: "") == .compare
		var comparisonValid = true
		if isCompareGoal {
			comparisonValid = validateComparisonCandidates(
				observations: observations,
				entities: entities,
				facts: facts,
				reasons: &reasons
			)
		}

		// Calculate overall score
		var overall = (completenessScore * 0.3) + (sourceReliabilityScore * 0.2) + (cleanlinessScore * 0.2) + (specificityScore * 0.15) + (groundednessScore * 0.15)

		// Phase 4U: hard block when groundedness is low AND the only price signal is rough.
		// Prevents premature completion on rough/noisy prices while grounding is weak.
		if groundednessScore < 0.70 && reasons.contains("rough_price_only") {
			overall = min(overall, 0.69)
			reasons.append("rough_price_or_low_grounding")
			print(String(format: "[EvidenceGate] blocked reason=rough_price_or_low_grounding groundedness=%.2f", groundednessScore))
		}

		// Hard gates: if comparison is invalid for comparison goal, or reliability is zero, cap the score
		if isCompareGoal && !comparisonValid {
			overall = min(overall, 0.40)
			reasons.append("invalid_comparison_candidates")
		}
		if sourceReliabilityScore < 0.1 {
			overall = min(overall, 0.20)
			reasons.append("stale_metadata_only")
		}

		let quality = EvidenceQuality(
			groundedness: groundednessScore,
			specificity: specificityScore,
			cleanliness: cleanlinessScore,
			completeness: completenessScore,
			sourceReliability: sourceReliabilityScore,
			overallScore: overall,
			reasons: reasons
		)

		// Print internal telemetry log as required by the specification
		let rString = reasons.isEmpty ? "none" : reasons.joined(separator: ",")
		print(String(format: "[EvidenceQuality] overall=%.2f groundedness=%.2f specificity=%.2f cleanliness=%.2f completeness=%.2f sourceReliability=%.2f reasons=%@",
					 overall, groundednessScore, specificityScore, cleanlinessScore, completenessScore, sourceReliabilityScore, rString))

		return quality
	}

	// MARK: - Dimension Scoring Helpers

	/// Computes the ratio of live-perception evidence vs stale metadata (like browsing history).
	private static func calculateSourceReliability(
		state: AgenticEvidenceState,
		observations: [AgenticEvidenceObservation],
		reasons: inout [String]
	) -> Double {
		// Identify satisfied required kinds
		let satisfiedRequired = state.satisfied.filter { kind in
			state.requirements.contains(where: { $0.kind == kind && $0.required })
		}
		guard !satisfiedRequired.isEmpty else { return 0.0 }

		var liveCount = 0
		for kind in satisfiedRequired {
			// A requirement is reliably grounded if it has at least one live source observation
			let hasLiveSource = observations.contains { o in
				o.kind == kind && o.source != .browsingHistory
			}
			if hasLiveSource {
				liveCount += 1
			} else {
				reasons.append("required_kind_\(kind.rawValue)_only_browsing_history")
			}
		}

		return Double(liveCount) / Double(satisfiedRequired.count)
	}

	/// Computes cleanliness of the collected evidence, penalizing truncations, mashed words, and chrome.
	private static func calculateCleanliness(
		state: AgenticEvidenceState,
		observations: [AgenticEvidenceObservation],
		entities: [GroundedSemanticEntity],
		facts: [StructuredFact],
		reasons: inout [String]
	) -> Double {
		var penalities = 0.0
		var evaluatedCount = 0

		let texts = Set(
			observations.map(\.text) +
			entities.map(\.text) +
			facts.map(\.title)
		)

		for text in texts {
			evaluatedCount += 1
			let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !t.isEmpty else { continue }

			// 1. Truncation Detection: "Blo X", "Anker Prime X", or "MacBook Pro ..."
			if detectTruncation(t) {
				penalities += 0.5
				reasons.append("truncated_text_fragment:\"\(t.prefix(15))\"")
			}

			// 2. Alphabetic/Alphanumeric Ratio Check
			let alnumCount = t.filter { $0.isLetter || $0.isNumber }.count
			let ratio = Double(alnumCount) / Double(t.count)
			if t.count > 3 && ratio < 0.6 {
				penalities += 0.4
				reasons.append("low_alphanumeric_ratio:\"\(t.prefix(15))\"")
			}

			// 3. Mashed word / noise detection: e.g. "ankercharger"
			if detectMashedWord(t) {
				penalities += 0.4
				reasons.append("mashed_word_noise:\"\(t.prefix(15))\"")
			}

			// 4. Assistant/proposal chrome leakage
			if detectChromeLeak(t) {
				penalities += 0.6
				reasons.append("chrome_leak_detected:\"\(t.prefix(15))\"")
			}

			// 5. Short one-token product title / candidate rejection
			if (t.split(separator: " ").count == 1) && (t.count <= 3) {
				penalities += 0.3
				reasons.append("single_short_token:\"\(t)\"")
			}
		}

		if evaluatedCount == 0 { return 1.0 }
		let score = 1.0 - (penalities / Double(evaluatedCount))
		return max(0.0, score)
	}

	/// Evaluates specificity of specs, prices, and reviews to reward rich, clean details.
	private static func calculateSpecificity(
		observations: [AgenticEvidenceObservation],
		reasons: inout [String]
	) -> Double {
		var score = 0.0

		// Wattage, port counts, GaN, capacity mAh counts
		let specs = observations.filter { $0.kind == .specs }
		if specs.count >= 2 {
			score += 0.4
		} else if !specs.isEmpty {
			score += 0.2
			reasons.append("insufficient_specs")
		}

		// Decimal price detection e.g. "$129.99" vs raw placeholder
		let prices = observations.filter { $0.kind == .price }
		let hasDecimalPrice = prices.contains { o in
			o.text.contains(".") && o.text.range(of: #"\d+\.\d{2}"#, options: .regularExpression) != nil
		}
		if hasDecimalPrice {
			score += 0.3
		} else if !prices.isEmpty {
			score += 0.15
			reasons.append("rough_price_only")
		}

		// Ratings / Reviews check
		let hasRating = observations.contains { $0.kind == .rating }
		let hasReviews = observations.contains { $0.kind == .reviewCount }
		if hasRating && hasReviews {
			score += 0.3
		} else if hasRating || hasReviews {
			score += 0.15
			reasons.append("incomplete_reviews_metadata")
		}

		return score
	}

	/// Computes grounding ratio: do semantic items match current perception (OCR/AX) observations.
	private static func calculateGroundedness(
		observations: [AgenticEvidenceObservation],
		entities: [GroundedSemanticEntity],
		facts: [StructuredFact],
		reasons: inout [String]
	) -> Double {
		let liveObs = observations.filter { $0.source == .ocr || $0.source == .ax || $0.source == .windowTitle }
		guard !liveObs.isEmpty else {
			reasons.append("no_live_perception_observations")
			return 0.0
		}

		// Check if entities and facts are grounded in live observations
		var groundedCount = 0
		let semanticItems = entities.map(\.text) + facts.map(\.title)
		guard !semanticItems.isEmpty else { return 1.0 }

		for item in semanticItems {
			let loweredItem = item.lowercased()
			let matches = liveObs.contains { o in
				let loweredObs = o.text.lowercased()
				return loweredObs.contains(loweredItem) || loweredItem.contains(loweredObs)
			}
			if matches {
				groundedCount += 1
			}
		}

		let ratio = Double(groundedCount) / Double(semanticItems.count)
		if ratio < 0.5 {
			reasons.append("low_perception_grounding_ratio")
		}
		return ratio
	}

	// MARK: - Validation Heuristics

	/// Detects if a text fragment has trailing truncations like "Blo X", "macbook p", etc.
	public static func detectTruncation(_ text: String) -> Bool {
		let tokens = text.split(separator: " ").map(String.init)
		guard let last = tokens.last else { return false }

		// Ellipsis is a truncation
		if text.contains("...") || text.contains("…") { return true }

		// If the last word is a single letter (and total text is longer than a single char), it's highly likely a truncation fragment.
		if last.count == 1 && text.count > 3 {
			// Ignore common single-letter digits/modifiers (like "V", "A", or numbers)
			let c = last.lowercased()
			if c >= "a" && c <= "z" && c != "a" && c != "i" {
				return true
			}
		}
		
		// If last word is 2 letters and the text is cut off (highly specific but generalized check)
		// e.g. "macbook pr"
		if last.count == 2 && last.lowercased() == "pr" && text.count > 10 {
			return true
		}

		return false
	}

	/// Detects mashed words with no spaces e.g. "ankercharger", "chargingport".
	public static func detectMashedWord(_ text: String) -> Bool {
		let lower = text.lowercased()
		// Simple generalized heuristic: long words containing combinations of known roots
		let roots = ["charger", "powerbank", "adapter", "battery", "cables", "charging"]
		for r in roots {
			if lower.contains(r) && lower != r && lower.count > r.count + 3 {
				// If it is a mashed compound without spaces e.g. "ankercharger" vs "anker charger"
				if !lower.contains(" ") && !lower.contains("-") && !lower.contains("/") {
					return true
				}
			}
		}
		return false
	}

	/// Detects assistant proposal chrome button leakage.
	public static func detectChromeLeak(_ text: String) -> Bool {
		let lower = text.lowercased()
		if lower.contains("processing") { return true }
		if lower.contains("controlled interactions") { return true }
		if lower == "open" || lower == "execute" || lower == "chime in" { return true }
		return false
	}

	// MARK: - Comparison Validator

	/// Validates that comparison goals have at least two distinct, clean, live-grounded candidates.
	public static func validateComparisonCandidates(
		observations: [AgenticEvidenceObservation],
		entities: [GroundedSemanticEntity],
		facts: [StructuredFact],
		reasons: inout [String]
	) -> Bool {
		// Extract all candidate strings
		let candidateObs = observations.filter { $0.kind == .comparisonCandidate || $0.kind == .productTitle }
		
		var distinctGrounded = Set<String>()

		for o in candidateObs {
			// Must originate from live source (not browsing history or metadata only)
			guard o.source != .browsingHistory else { continue }

			let t = o.text.trimmingCharacters(in: .whitespacesAndNewlines)
			
			// Must pass cleanliness heuristics
			if detectTruncation(t) || detectMashedWord(t) || detectChromeLeak(t) { continue }
			if t.split(separator: " ").count == 1 && t.count <= 3 { continue }

			distinctGrounded.insert(normalizeComparisonTitle(t))
		}

		// Check semantic entities of type productTitle as well
		let liveEntities = entities.filter { $0.type == .productTitle && $0.confidence >= 0.35 }
		for e in liveEntities {
			let t = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
			if detectTruncation(t) || detectMashedWord(t) || detectChromeLeak(t) { continue }
			distinctGrounded.insert(normalizeComparisonTitle(t))
		}

		// Deduplicate and count
		let count = distinctGrounded.count
		if count >= 2 {
			return true
		} else {
			reasons.append("insufficient_comparison_candidates_count:\(count)")
			return false
		}
	}

	internal static func normalizeComparisonTitle(_ text: String) -> String {
		// Clean typical brand name variations and minor specs to deduplicate safely
		let lower = text.lowercased()
		let cleaned = lower.filter { $0.isLetter || $0.isNumber || $0 == " " }
		return String(cleaned).split(separator: " ").prefix(4).joined(separator: " ")
	}
}
