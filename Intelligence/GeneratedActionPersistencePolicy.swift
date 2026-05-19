import Foundation

/// Conservative defaults for reusable generated action persistence (T17.6).
struct GeneratedActionPersistencePolicy: Equatable, Sendable, Codable {
	var maxStoredRecords: Int
	var expirationInterval: TimeInterval
	var minAcceptedCountForReuse: Int
	var minExecutionSuccessRate: Double
	var minUsefulnessScore: Double
	var maxFailuresBeforeSuppression: Int
	var usefulnessDecayPerDay: Double
	var failedActionsReusable: Bool
	var dismissedLowersUsefulness: Bool
	var dismissedPenalty: Double

	static let production = GeneratedActionPersistencePolicy(
		maxStoredRecords: 40,
		expirationInterval: 14 * 24 * 60 * 60,
		minAcceptedCountForReuse: 1,
		minExecutionSuccessRate: 0.55,
		minUsefulnessScore: 0.52,
		maxFailuresBeforeSuppression: 4,
		usefulnessDecayPerDay: 0.015,
		failedActionsReusable: false,
		dismissedLowersUsefulness: true,
		dismissedPenalty: 0.08
	)

	static let strictTest = GeneratedActionPersistencePolicy(
		maxStoredRecords: 5,
		expirationInterval: 60,
		minAcceptedCountForReuse: 1,
		minExecutionSuccessRate: 0.6,
		minUsefulnessScore: 0.5,
		maxFailuresBeforeSuppression: 2,
		usefulnessDecayPerDay: 0.05,
		failedActionsReusable: false,
		dismissedLowersUsefulness: true,
		dismissedPenalty: 0.1
	)
}
