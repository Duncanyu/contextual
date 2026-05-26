import Foundation

/// Structured "thinking between steps" for stateful agentic execution (Phase 4S).
/// Tracks internal reasoning, candidates, and expected outcomes, logged internally without exposing to the user.
struct AgenticStepThought: Sendable {
	let stepIndex: Int
	let goal: String
	let currentEvidenceSummary: String
	let missingEvidence: [String]
	let currentScreenSummary: String
	let candidateActions: [String]
	let chosenAction: String
	let reason: String
	let expectedObservationChange: String
	let confidence: Double

	func log() {
		let missing = missingEvidence.isEmpty ? "none" : missingEvidence.joined(separator: ",")
		let candidates = candidateActions.joined(separator: ",")
		let expChange = expectedObservationChange.isEmpty ? "none" : expectedObservationChange
		print("[AgenticThought] step=\(stepIndex) missing=\(missing) candidates=\(candidates) chosen=\(chosenAction) reason=\(reason) expected_change=\(expChange)")
	}
}
