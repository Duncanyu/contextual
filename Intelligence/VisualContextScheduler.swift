import Foundation

/// Bounded coordinator for at-most-one active visual context request (explicit async only).
actor VisualContextScheduler {

	private let provider: any BoundedVisualContextProvider
	private let budgetManager: GeneratedExecutionBudgetManager

	private var activeRequestId: UUID?
	private var cancelActiveRequest = false

	init(
		provider: any BoundedVisualContextProvider = NullBoundedVisualContextProvider(),
		budgetManager: GeneratedExecutionBudgetManager = GeneratedExecutionBudgetManager()
	) {
		self.provider = provider
		self.budgetManager = budgetManager
	}

	var hasActiveRequest: Bool {
		activeRequestId != nil
	}

	/// Enforces expiration, single-flight, budget, and `maxWindowSeconds` without polling loops.
	func collect(
		request: BoundedVisualContextRequest,
		budgetSnapshot: GeneratedExecutionBudgetSnapshot = .idle
	) async -> BoundedVisualContextResult {
		if request.isExpired {
			BoundedVisualContextDebug.log(event: "request_expired", requestId: request.id)
			return .fromError(.expired, requestId: request.id)
		}

		if activeRequestId != nil {
			BoundedVisualContextDebug.log(event: "request_rejected_overlap", requestId: request.id)
			return .fromError(.concurrentRequestRejected, requestId: request.id)
		}

		let budgetDecision = await budgetManager.canCollectVisualContext(
			request: request,
			snapshot: budgetSnapshot
		)
		if !budgetDecision.allowed {
			BoundedVisualContextDebug.log(
				event: "request_budget_denied",
				requestId: request.id,
				detail: budgetDecision.reason.rawValue
			)
			return BoundedVisualContextResult(
				requestId: request.id,
				status: .budgetDenied,
				sourceSummary: budgetDecision.reason.rawValue,
				warnings: [budgetDecision.reason.rawValue],
				metadata: ["budgetGate": "1"]
			)
		}

		activeRequestId = request.id
		cancelActiveRequest = false
		BoundedVisualContextDebug.log(event: "request_accepted", requestId: request.id)

		defer {
			activeRequestId = nil
			cancelActiveRequest = false
		}

		let timeoutNs = UInt64(request.maxWindowSeconds * 1_000_000_000)
		let result = await withTaskGroup(of: BoundedVisualContextResult.self) { group in
			group.addTask {
				await self.runProvider(request: request)
			}
			group.addTask {
				try? await Task.sleep(nanoseconds: timeoutNs)
				return BoundedVisualContextResult(
					requestId: request.id,
					status: .timedOut,
					sourceSummary: "timed_out",
					warnings: ["timed_out"]
				)
			}
			let first = await group.next() ?? .fromError(.unavailable, requestId: request.id)
			group.cancelAll()
			return first
		}

		if cancelActiveRequest, result.status != .timedOut {
			BoundedVisualContextDebug.log(event: "request_cancelled", requestId: request.id)
			return .fromError(.cancelled, requestId: request.id)
		}

		if result.status == .timedOut {
			BoundedVisualContextDebug.log(event: "request_timed_out", requestId: request.id)
		}

		return result
	}

	func cancelActive() {
		cancelActiveRequest = true
	}

	private func runProvider(request: BoundedVisualContextRequest) async -> BoundedVisualContextResult {
		if cancelActiveRequest {
			return .fromError(.cancelled, requestId: request.id)
		}
		do {
			return try await provider.collectVisualContext(request: request)
		} catch let error as VisualContextError {
			BoundedVisualContextDebug.log(event: "provider_error", requestId: request.id, detail: error.rawValue)
			return .fromError(error, requestId: request.id)
		} catch {
			return .fromError(.unavailable, requestId: request.id)
		}
	}
}

// MARK: - Self-test

extension VisualContextScheduler {
	static func runSelfTest() async -> Bool {
		let nullScheduler = VisualContextScheduler(provider: NullBoundedVisualContextProvider())
		let nullReq = SelfTestFixtures.request()
		let nullResult = await nullScheduler.collect(request: nullReq)
		guard nullResult.status == .unavailable else { return false }

		let expired = await nullScheduler.collect(request: SelfTestFixtures.expiredRequest())
		guard expired.status == .expired else { return false }

		let overlapScheduler = VisualContextScheduler(provider: SlowVisualContextProvider())
		let slowReq = SelfTestFixtures.request(maxWindowSeconds: 4)
		let slowTask = Task { await overlapScheduler.collect(request: slowReq) }
		try? await Task.sleep(nanoseconds: 50_000_000)
		let overlap = await overlapScheduler.collect(request: SelfTestFixtures.request())
		guard overlap.status == .concurrentRequestRejected else { return false }
		_ = await slowTask.value

		let timeoutScheduler = VisualContextScheduler(provider: SlowVisualContextProvider())
		let timeoutResult = await timeoutScheduler.collect(
			request: SelfTestFixtures.request(maxWindowSeconds: 0.05)
		)
		guard timeoutResult.status == .timedOut else { return false }

		let cancelScheduler = VisualContextScheduler(provider: SlowVisualContextProvider())
		let cancelTask = Task {
			await cancelScheduler.collect(request: SelfTestFixtures.request(maxWindowSeconds: 2))
		}
		try? await Task.sleep(nanoseconds: 30_000_000)
		await cancelScheduler.cancelActive()
		let cancelled = await cancelTask.value
		guard cancelled.status == .cancelled || cancelled.status == .timedOut else { return false }

		let longOCR = String(repeating: "x", count: 5_000)
		let capped: BoundedVisualContextResult
		do {
			capped = try await StubCappedVisualContextProvider(longOCR: longOCR).collectVisualContext(
				request: SelfTestFixtures.request(
					requiresOCR: true,
					requiresVisualDescription: true,
					maxOCRCharacters: 200,
					maxDescriptionCharacters: 120,
					permission: [.screenRecording: true]
				)
			)
		} catch {
			return false
		}
		guard (capped.ocrExcerpt?.count ?? 0) <= 200 else { return false }
		guard (capped.visualSummary?.count ?? 0) <= 120 else { return false }

		let budgetMgr = GeneratedExecutionBudgetManager(
			cpuProvider: StaticCpuBudgetSnapshotProvider(
				snapshot: CpuBudgetSnapshot(systemCPUUsagePercent: 10, thermalStateCode: "nominal")
			)
		)
		guard await budgetMgr.canCollectVisualContext(
			request: SelfTestFixtures.request(requiresOCR: true, budget: ExecutionBudget(allowsOCR: false)),
			snapshot: .idle
		).allowed == false else { return false }

		// MirrorCoding check — result must not expose screenshot fields (compile-time); runtime check tag only
		guard !nullResult.metadata.keys.contains("screenshot") else { return false }

		return true
	}
}

// MARK: - Test doubles

private struct SlowVisualContextProvider: BoundedVisualContextProvider, Sendable {
	func collectVisualContext(request: BoundedVisualContextRequest) async throws -> BoundedVisualContextResult {
		try await Task.sleep(nanoseconds: 500_000_000)
		return BoundedVisualContextResult(
			requestId: request.id,
			status: .completed,
			capturedAt: Date(),
			sourceSummary: "slow_stub"
		)
	}
}

private struct StubCappedVisualContextProvider: BoundedVisualContextProvider, Sendable {
	let longOCR: String

	func collectVisualContext(request: BoundedVisualContextRequest) async throws -> BoundedVisualContextResult {
		let excerpt = longOCR.count > request.maxOCRCharacters
			? String(longOCR.prefix(request.maxOCRCharacters))
			: longOCR
		return BoundedVisualContextResult(
			requestId: request.id,
			status: .completed,
			capturedAt: Date(),
			sourceSummary: "stub",
			ocrExcerpt: excerpt,
			visualSummary: request.requiresVisualDescription
				? String(repeating: "d", count: request.maxDescriptionCharacters + 50)
				: nil,
			visualTags: ["stub"],
			metadata: ["captureWidth": "10", "captureHeight": "10", "captureCount": "1"]
		)
	}
}

private enum SelfTestFixtures {
	static func request(
		requiresOCR: Bool = false,
		requiresVisualDescription: Bool = false,
		maxWindowSeconds: TimeInterval = BoundedVisualContextBounds.defaultMaxWindowSeconds,
		maxOCRCharacters: Int = BoundedVisualContextBounds.defaultMaxOCRCharacters,
		maxDescriptionCharacters: Int = BoundedVisualContextBounds.defaultMaxDescriptionCharacters,
		budget: ExecutionBudget = ExecutionBudget(allowsVision: true, allowsOCR: true),
		permission: [PermissionRequirement: Bool] = [:]
	) -> BoundedVisualContextRequest {
		BoundedVisualContextRequest(
			reason: "self_test",
			workflowType: .debugging,
			intentType: .explain,
			requiresOCR: requiresOCR,
			requiresVisualDescription: requiresVisualDescription,
			maxWindowSeconds: maxWindowSeconds,
			maxOCRCharacters: maxOCRCharacters,
			maxDescriptionCharacters: maxDescriptionCharacters,
			budget: budget,
			permissionAvailability: permission
		)
	}

	static func expiredRequest() -> BoundedVisualContextRequest {
		let created = Date().addingTimeInterval(-30)
		return BoundedVisualContextRequest(
			reason: "expired",
			workflowType: .unknown,
			intentType: .unknown,
			createdAt: created,
			expiresAt: created.addingTimeInterval(1)
		)
	}
}
