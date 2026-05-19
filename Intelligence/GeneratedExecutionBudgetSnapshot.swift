import Foundation

/// Caller-supplied runtime view for budget checks (metadata-only).
struct GeneratedExecutionBudgetSnapshot: Equatable, Sendable, Codable {
	let activeExecutionCount: Int
	let runtimeState: ExecutionState
	/// Permission codes the caller reports as satisfied (empty = conservative for expensive ops).
	let permissionAvailability: [String: Bool]
	/// True when the upcoming gather would trigger active sampling (OCR/vision refresh).
	let activeSamplingRequested: Bool

	init(
		activeExecutionCount: Int,
		runtimeState: ExecutionState,
		permissionAvailability: [PermissionRequirement: Bool] = [:],
		activeSamplingRequested: Bool = false
	) {
		self.activeExecutionCount = max(0, activeExecutionCount)
		self.runtimeState = runtimeState
		self.permissionAvailability = Dictionary(
			uniqueKeysWithValues: permissionAvailability.map { ($0.key.rawValue, $0.value) }
		)
		self.activeSamplingRequested = activeSamplingRequested
	}

	func permissionGranted(_ requirement: PermissionRequirement) -> Bool {
		permissionAvailability[requirement.rawValue] ?? false
	}

	static let idle = GeneratedExecutionBudgetSnapshot(
		activeExecutionCount: 0,
		runtimeState: .idle
	)
}
