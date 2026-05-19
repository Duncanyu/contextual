import Foundation

/// Point-in-time CPU/thermal snapshot for conservative budget checks (no polling loop).
struct CpuBudgetSnapshot: Equatable, Sendable, Codable {
	/// Nil when sampling is unavailable — budget layer treats as unknown-safe.
	let systemCPUUsagePercent: Double?
	let thermalStateCode: String?
	let sampledAt: Date

	init(systemCPUUsagePercent: Double?, thermalStateCode: String?, sampledAt: Date = Date()) {
		self.systemCPUUsagePercent = systemCPUUsagePercent
		self.thermalStateCode = thermalStateCode
		self.sampledAt = sampledAt
	}
}

/// Event-driven CPU/thermal snapshot source (implementations must be cheap).
protocol CpuBudgetSnapshotProvider: Sendable {
	func currentSnapshot() -> CpuBudgetSnapshot
}

/// Fixed snapshot for tests and deterministic denial paths.
struct StaticCpuBudgetSnapshotProvider: CpuBudgetSnapshotProvider, Sendable {
	let snapshot: CpuBudgetSnapshot

	init(snapshot: CpuBudgetSnapshot) {
		self.snapshot = snapshot
	}

	func currentSnapshot() -> CpuBudgetSnapshot { snapshot }
}

/// Default provider: thermal state only via `ProcessInfo` (no high-frequency CPU polling).
struct ConservativeCpuBudgetSnapshotProvider: CpuBudgetSnapshotProvider, Sendable {
	func currentSnapshot() -> CpuBudgetSnapshot {
		let thermalCode: String?
		if #available(macOS 10.10.3, *) {
			thermalCode = Self.thermalCode(ProcessInfo.processInfo.thermalState)
		} else {
			thermalCode = nil
		}
		return CpuBudgetSnapshot(
			systemCPUUsagePercent: nil,
			thermalStateCode: thermalCode
		)
	}

	private static func thermalCode(_ state: ProcessInfo.ThermalState) -> String {
		switch state {
		case .nominal: "nominal"
		case .fair: "fair"
		case .serious: "serious"
		case .critical: "critical"
		@unknown default: "unknown"
		}
	}
}
