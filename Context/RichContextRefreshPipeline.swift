import Foundation

final class RichContextRefreshPipeline {
	static let shared = RichContextRefreshPipeline()

	private let state = State()
	private init() {}

	func refresh(_ request: RichContextRefreshRequest) async -> RichContextRefreshResult {
		let id = UUID()
		let startedAt = Date()

		let generation = await state.beginNewRefresh(id: id, trigger: request.trigger)
		print("[RichContextRefresh] started trigger=\(request.trigger.rawValue) generation=\(generation) requested=\(requestedLabel(request))")

		// Give cancellation/newer refresh a chance to win early (no UI blocking).
		await Task.yield()

		// Self-test only: add a tiny delay so cancellation is observable without permissions.
		if request.trigger == .debugSelfTest {
			try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
		}

		let stillCurrentEarly = await state.isCurrentGeneration(generation)
		if Task.isCancelled || !stillCurrentEarly {
			let finishedAt = Date()
			print("[RichContextRefresh] cancelled reason=newer_refresh generation=\(generation)")
			let result = RichContextRefreshResult(
				id: id,
				startedAt: startedAt,
				finishedAt: finishedAt,
				wasCancelled: true,
				collectedSources: [],
				skippedSources: [:],
				fusedPacket: nil,
				updatedCanonicalState: false,
				debugSummaryMetadata: [
					"generation": "\(generation)",
					"requested": requestedLabel(request),
					"cancelled": "1"
				]
			)
			await state.finish(generation: generation, result: result)
			return result
		}

		var collected: [FusedContextSource] = []
		var skipped: [FusedContextSource: String] = [:]

		// Cheap/metadata-only reads (no monitoring lifecycle changes).
		let typingCtx: TypingActivityContext? = request.includeTypingActivity ? TypingActivitySource.shared.currentContext() : nil
		if request.includeTypingActivity { collected.append(.typingActivity) }

		let pointerCtx: PointerActivityContext? = request.includePointerActivity ? PointerActivitySource.shared.currentContext() : nil
		if request.includePointerActivity { collected.append(.pointerActivity) }

		let canonical = CanonicalContextState.shared.current()
		var requestedCapabilities = Set<ContextCapabilityID>()
		if request.includeAXContent { requestedCapabilities.insert(.axWindowContent) }
		if request.includeWindowSnapshot { requestedCapabilities.insert(.activeWindowSnapshot) }
		if request.includeVisualDescriptor { requestedCapabilities.insert(.visualDescriptor) }
		if request.includeTypingActivity { requestedCapabilities.insert(.typingActivity) }
		if request.includePointerActivity { requestedCapabilities.insert(.cursorActivity) }

		let workflowKey = Self.buildPrivacySafeWorkflowKey(request: request, canonical: canonical, requestedExpensive: requestedCapabilities.intersection([
			.axWindowContent, .activeWindowSnapshot, .visualDescriptor, .screenOCR, .screenVision
		]))

		let adaptiveRequest = AdaptiveSamplingRequest(
			trigger: request.trigger,
			requestedSources: requestedCapabilities,
			currentCanonicalContext: canonical,
			typingActivity: typingCtx,
			pointerActivity: pointerCtx,
			isActionExecuting: request.isActionExecuting,
			currentConfidence: request.currentIntelligenceConfidence,
			workflowKey: workflowKey,
			reason: request.reason,
			allowExpensiveSources: request.allowExpensiveSources
		)
		let adaptive = AdaptiveContextSampler.shared.evaluate(adaptiveRequest)

		// AX content (medium/high privacy): only if requested.
		var axContent: AXWindowContentContext?
		if request.includeAXContent {
			if adaptive.reuseExistingSources.contains(.axWindowContent) {
				skipped[.axText] = "adaptive_reuse"
			} else if adaptive.deniedSources.contains(.axWindowContent) {
				skipped[.axText] = "adaptive_denied"
			} else if adaptive.deferredSources.contains(.axWindowContent) {
				skipped[.axText] = "adaptive_deferred"
			} else if !adaptive.allowedSources.contains(.axWindowContent) {
				skipped[.axText] = "adaptive_denied"
			} else {
				let decision = budgetDecision(
					capability: .axWindowContent,
					trigger: request.trigger,
					reason: request.reason,
					contextModel: request.currentContextModel,
					isActionExecuting: request.isActionExecuting,
					intelligenceConfidence: request.currentIntelligenceConfidence
				)
				if decision.allowed {
					axContent = AXWindowContentSource.shared.extractActiveWindowContent()
					if axContent != nil {
						collected.append(.axText)
						ContextBudgetManager.shared.recordCollection(.axWindowContent)
					} else {
						skipped[.axText] = "collection_failed_or_permission"
					}
				} else if decision.shouldDefer == true {
					skipped[.axText] = "budget_deferred"
				} else {
					skipped[.axText] = "budget_denied"
				}
			}
		}

		// Window snapshot (medium/high privacy): only if requested.
		var snapshot: WindowSnapshotContext?
		if request.includeWindowSnapshot {
			if adaptive.reuseExistingSources.contains(.activeWindowSnapshot) {
				skipped[.activeWindowSnapshot] = "adaptive_reuse"
			} else if adaptive.deniedSources.contains(.activeWindowSnapshot) {
				skipped[.activeWindowSnapshot] = "adaptive_denied"
			} else if adaptive.deferredSources.contains(.activeWindowSnapshot) {
				skipped[.activeWindowSnapshot] = "adaptive_deferred"
			} else if !adaptive.allowedSources.contains(.activeWindowSnapshot) {
				skipped[.activeWindowSnapshot] = "adaptive_denied"
			} else {
				let decision = budgetDecision(
					capability: .activeWindowSnapshot,
					trigger: request.trigger,
					reason: request.reason,
					contextModel: request.currentContextModel,
					isActionExecuting: request.isActionExecuting,
					intelligenceConfidence: request.currentIntelligenceConfidence
				)
				if decision.allowed {
					snapshot = WindowSnapshotSource.shared.captureActiveWindowSnapshot()
					if snapshot != nil {
						collected.append(.activeWindowSnapshot)
						ContextBudgetManager.shared.recordCollection(.activeWindowSnapshot)
					} else {
						skipped[.activeWindowSnapshot] = "collection_failed_or_permission"
					}
				} else if decision.shouldDefer == true {
					skipped[.activeWindowSnapshot] = "budget_deferred"
				} else {
					skipped[.activeWindowSnapshot] = "budget_denied"
				}
			}
		}

		// Visual descriptor: only if requested; requires a snapshot from this refresh.
		var visual: VisualContextDescriptor?
		if request.includeVisualDescriptor {
			if adaptive.reuseExistingSources.contains(.visualDescriptor) {
				skipped[.visualDescriptor] = "adaptive_reuse"
			} else if adaptive.deniedSources.contains(.visualDescriptor) {
				skipped[.visualDescriptor] = "adaptive_denied"
			} else if adaptive.deferredSources.contains(.visualDescriptor) {
				skipped[.visualDescriptor] = "adaptive_deferred"
			} else if !adaptive.allowedSources.contains(.visualDescriptor) {
				skipped[.visualDescriptor] = "adaptive_denied"
			} else if snapshot == nil {
				skipped[.visualDescriptor] = "no_snapshot"
			} else {
				let decision = budgetDecision(
					capability: .visualDescriptor,
					trigger: request.trigger,
					reason: request.reason,
					contextModel: request.currentContextModel,
					isActionExecuting: request.isActionExecuting,
					intelligenceConfidence: request.currentIntelligenceConfidence
				)
				if decision.allowed, let snap = snapshot {
					visual = VisualContextAnalyzer.shared.analyze(snapshot: snap)
					if visual != nil {
						collected.append(.visualDescriptor)
						ContextBudgetManager.shared.recordCollection(.visualDescriptor)
					} else {
						skipped[.visualDescriptor] = "analysis_failed"
					}
				} else if decision.shouldDefer == true {
					skipped[.visualDescriptor] = "budget_deferred"
				} else {
					skipped[.visualDescriptor] = "budget_denied"
				}
			}
		}

		// Cancellation check before fusion.
		let isCurrent = await state.isCurrentGeneration(generation)
		if Task.isCancelled || !isCurrent {
			let finishedAt = Date()
			print("[RichContextRefresh] cancelled reason=newer_refresh generation=\(generation)")
			let result = RichContextRefreshResult(
				id: id,
				startedAt: startedAt,
				finishedAt: finishedAt,
				wasCancelled: true,
				collectedSources: collected,
				skippedSources: skipped,
				fusedPacket: nil,
				updatedCanonicalState: false,
				debugSummaryMetadata: [
					"generation": "\(generation)",
					"requested": requestedLabel(request),
					"cancelled": "1"
				]
			)
			await state.finish(generation: generation, result: result)
			return result
		}

		let priorCanonicalId = CanonicalContextState.shared.current()?.id
		let packet = ContextFusionEngine.shared.fuse(
			contextModel: request.currentContextModel,
			windowSnapshot: snapshot,
			visualDescriptor: visual,
			axContent: axContent,
			typingActivity: typingCtx,
			pointerActivity: pointerCtx
		)
		let updated = (CanonicalContextState.shared.current()?.id != priorCanonicalId)

		let finishedAt = Date()
		print("[RichContextRefresh] completed generation=\(generation) sources=\(collected.map(\.rawValue).joined(separator: ",")) updated=\(updated)")

		var meta: [String: String] = [
			"generation": "\(generation)",
			"requested": requestedLabel(request),
			"updatedCanonical": updated ? "1" : "0",
			"primary": packet.primarySource.rawValue,
			"freshness": String(format: "%.2f", packet.freshnessScore),
			"confidence": String(format: "%.2f", packet.confidence),
			"adaptiveScore": String(format: "%.2f", adaptive.samplingScore)
		]
		if let ax = axContent {
			meta["axFragments"] = "\(ax.visibleTextFragments.count)"
			meta["axTextLen"] = "\(ax.estimatedVisibleTextLength)"
			meta["axKinds"] = "\(ax.visibleControlKinds.count)"
		}
		if let v = visual {
			meta["visualKinds"] = v.visibleUIKinds.map(\.rawValue).joined(separator: ",")
			meta["visualConf"] = String(format: "%.2f", v.confidence)
			meta["visualPanels"] = "\(v.estimatedPanelCount)"
		}

		let result = RichContextRefreshResult(
			id: id,
			startedAt: startedAt,
			finishedAt: finishedAt,
			wasCancelled: false,
			collectedSources: uniquePreserveOrder(collected),
			skippedSources: skipped,
			fusedPacket: packet,
			updatedCanonicalState: updated,
			debugSummaryMetadata: meta
		)

		var recordedCaps = Set<ContextCapabilityID>()
		if collected.contains(.axText) { recordedCaps.insert(.axWindowContent) }
		if collected.contains(.activeWindowSnapshot) { recordedCaps.insert(.activeWindowSnapshot) }
		if collected.contains(.visualDescriptor) { recordedCaps.insert(.visualDescriptor) }
		AdaptiveContextSampler.shared.recordSampling(recordedCaps, workflowKey: workflowKey)

		await state.finish(generation: generation, result: result)
		return result
	}

	func cancelCurrent(reason: String) {
		Task { await state.cancelCurrent(reason: reason) }
	}

	func lastResult() async -> RichContextRefreshResult? {
		await state.lastResult
	}

	func reset() {
		AdaptiveContextSampler.shared.reset()
		Task { await state.reset() }
	}

	// MARK: - Private

	private static func buildPrivacySafeWorkflowKey(
		request: RichContextRefreshRequest,
		canonical: FusedContextPacket?,
		requestedExpensive: Set<ContextCapabilityID>
	) -> String {
		let bundle = request.currentContextModel.activeAppBundleIdentifier ?? "unknown"
		let caps = requestedExpensive.map(\.rawValue).sorted().joined(separator: "+")
		let visualKinds = (canonical?.visualKinds ?? []).map(\.rawValue).sorted().joined(separator: ",")
		let primary = canonical?.primarySource.rawValue ?? "na"
		let inputPref = request.currentContextModel.actionInputSourcePreference.rawValue
		return [bundle, caps, "vk=\(visualKinds)", "primary=\(primary)", "input=\(inputPref)"].joined(separator: "|")
	}

	private func requestedLabel(_ request: RichContextRefreshRequest) -> String {
		var parts: [String] = []
		if request.includeAXContent { parts.append("ax") }
		if request.includeWindowSnapshot { parts.append("windowSnapshot") }
		if request.includeVisualDescriptor { parts.append("visual") }
		if request.includeTypingActivity { parts.append("typing") }
		if request.includePointerActivity { parts.append("pointer") }
		return parts.isEmpty ? "none" : parts.joined(separator: ",")
	}

	private func budgetDecision(
		capability: ContextCapabilityID,
		trigger: RichContextRefreshTrigger,
		reason: String,
		contextModel: ContextModel,
		isActionExecuting: Bool,
		intelligenceConfidence: Double?
	) -> ContextBudgetDecision {
		let req = ContextBudgetRequest(
			requestedCapability: capability,
			triggerSource: trigger.rawValue,
			currentAppName: contextModel.activeAppName,
			currentBundleIdentifier: contextModel.activeAppBundleIdentifier,
			hasSelectedText: contextModel.selectedTextAvailable,
			selectedTextLength: contextModel.selectedTextLength,
			hasClipboardText: contextModel.clipboardTextAvailable,
			clipboardTextLength: contextModel.clipboardTextLength,
			hasRecentOCR: contextModel.screenOCRAvailable,
			hasRecentWindowSnapshot: false,
			isActionExecuting: isActionExecuting,
			recentExpensiveCollectionCount: 0,
			userActivityLevel: activityLevel(trigger: trigger),
			currentIntelligenceConfidence: intelligenceConfidence,
			reason: reason
		)
		return ContextBudgetManager.shared.evaluate(req)
	}

	private func activityLevel(trigger: RichContextRefreshTrigger) -> ContextUserActivityLevel {
		switch trigger {
		case .manual:
			return .light
		case .debugSelfTest:
			return .idle
		case .appChanged, .selectionChanged, .clipboardChanged, .screenOCRCompleted:
			return .active
		}
	}

	private func uniquePreserveOrder<T: Hashable>(_ arr: [T]) -> [T] {
		var seen = Set<T>()
		var out: [T] = []
		for x in arr where seen.insert(x).inserted {
			out.append(x)
		}
		return out
	}

	private actor State {
		private(set) var currentGeneration: UInt64 = 0
		private(set) var currentId: UUID?
		private(set) var currentTrigger: RichContextRefreshTrigger?
		private(set) var lastResult: RichContextRefreshResult?

		func beginNewRefresh(id: UUID, trigger: RichContextRefreshTrigger) -> UInt64 {
			currentGeneration &+= 1
			currentId = id
			currentTrigger = trigger
			return currentGeneration
		}

		func isCurrentGeneration(_ gen: UInt64) -> Bool {
			gen == currentGeneration
		}

		func finish(generation: UInt64, result: RichContextRefreshResult) {
			guard generation == currentGeneration else { return }
			lastResult = result
		}

		func cancelCurrent(reason: String) {
			guard currentId != nil else { return }
			print("[RichContextRefresh] cancelled reason=\(reason)")
			// Bump generation so in-flight refreshes observe they are stale.
			currentGeneration &+= 1
			currentId = nil
			currentTrigger = nil
		}

		func reset() {
			currentId = nil
			currentTrigger = nil
			lastResult = nil
		}
	}
}

