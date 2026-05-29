import AppKit
import CoreGraphics
import Foundation

// MARK: - Refresh Result

/// Result of a post-control perception refresh pipeline.
///
/// Produced by `AgenticPerceptionRefreshCoordinator.refresh()` after every
/// controlled interaction (scroll_small / find_on_page). The runtime replaces
/// its working snapshot with `freshSnapshot` before the next observe step,
/// eliminating the stale-snapshot-reuse problem diagnosed in Phase 4D logs.
struct AgenticPerceptionRefreshResult: Sendable {
	/// The new (or best-available) snapshot to use for the next observe step.
	let freshSnapshot: CanonicalGeneratedExecutionContextSnapshot
	/// Unique identifier for this refresh event. Used for snapshot identity tracking.
	let snapshotID: UUID
	/// The snapshot ID from before control (for delta comparison).
	let previousSnapshotID: UUID?
	/// DJB2 hash of all visible text (OCR + selectedText). nil if no text captured.
	let textHash: String?
	/// Raw OCR text from the fresh capture. nil if dryRun or permission denied.
	let freshOCR: String?
	/// AX text fragments joined. nil if dryRun or permission denied.
	let freshAXText: String?
	/// True when screenshot + OCR/AX were actually acquired (not dryRun/failed).
	let success: Bool
	/// Which pipeline stage failed ("screenshot" / "ocr" / "ax") if success == false.
	let failedStage: String?
	let capturedAt: Date
	let elapsedMs: Int

	// MARK: Visual delta signals (Phase V1 — pHash-based perception)
	/// Full-image 64-bit DCT perceptual hash. 0 when screenshot was unavailable.
	let pHash: UInt64
	/// Per-quadrant pHashes: [topLeft, topRight, bottomLeft, bottomRight].
	/// Used to localise *where* on screen a visual change occurred.
	let quadrantHashes: [UInt64]

	// MARK: VLM (caption-only, local-only)
	let vlmCaption: String?
	let vlmCategory: String?
	let vlmSemanticHash: UInt32
	let vlmConfidence: Float
}

// MARK: - World-State Entry

/// One entry in the session's world-state history.
struct AgenticWorldStateEntry: Sendable {
	let stepIndex: Int
	let action: String
	let snapshotID: UUID
	let textHash: String?
	let quality: AgenticObservationQuality
	/// Whether the world state changed compared to the previous entry.
	let changedFromPrevious: Bool
	let recordedAt: Date
}

// MARK: - Coordinator

/// Active perception refresh pipeline for Phase 4E.
///
/// Called immediately after every controlled interaction so the runtime can
/// re-acquire the environment before the forced post-control observe step.
///
/// Pipeline:
///   control → settle wait → screenshot → OCR → AX text → new snapshot → delta
///
/// In dryRun mode (self-tests): skips real capture; still returns a new snapshotID
/// and a fresh snapshot so that snapshot identity and delta logic can be tested.
///
/// Logs:
///   [PerceptionRefresh] started action=...
///   [PerceptionRefresh] waiting_for_ui_settle=yes
///   [PerceptionRefresh] stabilization_wait_ms=...
///   [PerceptionRefresh] screenshot_acquired=yes/no
///   [PerceptionRefresh] ocr_chars=...
///   [PerceptionRefresh] ax_chars=...
///   [PerceptionRefresh] freshness_score=...
///   [PerceptionRefresh] snapshot_replaced old=... new=...
///   [PerceptionRefresh] completed
struct AgenticPerceptionRefreshCoordinator: Sendable {
	private struct SendableCGImage: @unchecked Sendable { let image: CGImage }

	// MARK: - VLM integration (Phase 1: caption only)

	static func isVLMPerceptionEnabledForSelfTest() async -> Bool {
		await VLMPerceptionEngine.shared.isEnabled()
	}

	private static let fastBudgetPreferredMs: Int = 500
	private static let fastBudgetAbsoluteMs: Int = 1000

	private static func vlmHotLoopEnabled() -> Bool {
		ProcessInfo.processInfo.environment["CONTEXTUAL_VLM_HOT_LOOP_ENABLED"] == "1"
	}

	private static func detectSelfOCRContamination(_ ocr: String?) -> Bool {
		guard let lower = ocr?.lowercased(), !lower.isEmpty else { return false }
		let needles: [String] = [
			"contextual",
			"context-aware assistant",
			"generated execution",
			"floating suggestion"
		]
		return needles.contains(where: { lower.contains($0) })
	}

	private static func vlmCacheKey(
		bundleIdentifier: String?,
		windowTitle: String,
		pHash: UInt64,
		targetAnchor: TargetWindowAnchor?
	) -> String {
		let bundle = bundleIdentifier ?? "nil"
		let title = String(windowTitle.prefix(80))
		let fp = targetAnchor?.contextFingerprint ?? "no_anchor"
		return "\(bundle)|\(title)|\(String(format: "%016llx", pHash))|\(fp)"
	}

	// MARK: - Settle timings

	/// Milliseconds to wait for UI to settle before capturing.
	/// Stacks ON TOP OF the sleep already in executeScrollSmall/executeFindOnPage.
	static func settleWaitMs(for action: AgenticNextAction, debugVisible: Bool) -> Int {
		switch action {
		case .scroll_small:  return debugVisible ? 800 : 200
		case .find_on_page:  return debugVisible ? 1000 : 350
		default:             return 150
		}
	}

	// MARK: - Main entry

	func refresh(
		after controlAction: AgenticNextAction,
		previousSnapshot: CanonicalGeneratedExecutionContextSnapshot,
		previousSnapshotID: UUID?,
		ocrBudgetRemaining: Bool,
		targetAnchor: TargetWindowAnchor? = nil,
		requireTargetAnchor: Bool = false,
		debugVisible: Bool = false,
		dryRun: Bool = false
	) async -> AgenticPerceptionRefreshResult {
		let startedAt = Date()
		let snapshotID = UUID()
		print("[PerceptionRefresh] started action=\(controlAction.rawValue) snapshot_id=\(snapshotID.uuidString.prefix(8)) dry_run=\(dryRun) debug_visible=\(debugVisible)")
		if let anchor = targetAnchor {
			print("[TargetAnchorTrace] stage=perception_refresh anchor_nil=no")
			print("[TargetAnchorTrace] bundle=\(anchor.bundleIdentifier)")
			print("[TargetAnchorTrace] title=\"\(anchor.windowTitle.prefix(80))\"")
		} else {
			print("[TargetAnchorTrace] stage=perception_refresh anchor_nil=yes")
		}
		if requireTargetAnchor && targetAnchor == nil {
			print("[DirectAgentRuntime] blocked reason=missing_target_window_anchor")
			return buildFailedResult(
				snapshotID: snapshotID,
				previousSnapshotID: previousSnapshotID,
				previousSnapshot: previousSnapshot,
				failedStage: "screenshot",
				startedAt: startedAt
			)
		}
		let vlmEnabled = await VLMPerceptionEngine.shared.isEnabled()
		let vlmHotLoop = Self.vlmHotLoopEnabled()
		if !vlmHotLoop {
			print("[PerceptionTier] vlm_hot_loop=disabled reason=performance_default")
		}
		if !vlmEnabled {
			print("[VLMPerception] disabled reason=user_or_env")
		}

		let settleMs = Self.settleWaitMs(for: controlAction, debugVisible: debugVisible)
		print("[PerceptionRefresh] waiting_for_ui_settle=yes stabilization_wait_ms=\(settleMs)")
		try? await Task.sleep(nanoseconds: UInt64(settleMs) * 1_000_000)

		if dryRun {
			return buildDryRunResult(
				snapshotID: snapshotID,
				previousSnapshotID: previousSnapshotID,
				previousSnapshot: previousSnapshot,
				startedAt: startedAt
			)
		}

		// MARK: Screenshot
		guard ScreenCaptureSource.isScreenRecordingAuthorized() else {
			print("[PerceptionRefresh] failed stage=screenshot reason=no_screen_recording_permission")
			return buildFailedResult(
				snapshotID: snapshotID,
				previousSnapshotID: previousSnapshotID,
				previousSnapshot: previousSnapshot,
				failedStage: "screenshot",
				startedAt: startedAt
			)
		}

		guard let frame = ScreenCaptureSource.captureSingleFrame(targetAnchor: targetAnchor) else {
			print("[PerceptionRefresh] failed stage=screenshot reason=capture_returned_nil")
			return buildFailedResult(
				snapshotID: snapshotID,
				previousSnapshotID: previousSnapshotID,
				previousSnapshot: previousSnapshot,
				failedStage: "screenshot",
				startedAt: startedAt
			)
		}
		print("[PerceptionRefresh] screenshot_acquired=yes size=\(frame.width)x\(frame.height)")
		let fastTierStartedAt = Date()

		// MARK: pHash (< 2ms — tier-1 visual delta signal, no budget cost)
		let freshPHash         = PerceptualHasher.hash(frame.image) ?? 0
		let freshQuadrantHashes = PerceptualHasher.quadrantHashes(frame.image)
		print("[PerceptionRefresh] phash=\(String(format: "%016llx", freshPHash))")

		// MARK: OCR
		var freshOCR: String? = nil
		if ocrBudgetRemaining {
			let elapsed = Int(Date().timeIntervalSince(fastTierStartedAt) * 1000)
			if elapsed >= Self.fastBudgetPreferredMs {
				print("[PerceptionBudget] skipped component=ocr reason=budget_exceeded")
			} else {
				let ocrResult = await OCRProcessor.shared.recognizeText(from: frame.image)
				let text = ocrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
				if !text.isEmpty {
					freshOCR = String(text.prefix(CanonicalGeneratedExecutionContextSnapshot.maxExcerptLength))
				}
				print("[PerceptionRefresh] ocr_chars=\(freshOCR?.count ?? 0) lines=\(ocrResult.lineCount)")
			}
		} else {
			print("[PerceptionRefresh] ocr_skipped reason=budget_exhausted")
		}
		if Self.detectSelfOCRContamination(freshOCR) {
			print("[SelfWindowExclusion] warning=self_ocr_contamination")
		}

		// MARK: AX text
		var freshAXText: String? = nil
		do {
			let elapsed = Int(Date().timeIntervalSince(fastTierStartedAt) * 1000)
			if elapsed >= Self.fastBudgetPreferredMs {
				print("[PerceptionBudget] skipped component=ax reason=budget_exceeded")
			} else if let ax = AXWindowContentSource.shared.extractActiveWindowContent(),
			          !ax.visibleTextFragments.isEmpty {
				let joined = ax.visibleTextFragments.prefix(20).joined(separator: " ")
				freshAXText = String(joined.prefix(CanonicalGeneratedExecutionContextSnapshot.maxExcerptLength))
			}
		}
		print("[PerceptionRefresh] ax_chars=\(freshAXText?.count ?? 0)")

		// MARK: Perception tier timings
		let fastElapsed = Int(Date().timeIntervalSince(fastTierStartedAt) * 1000)
		print("[PerceptionBudget] tier=fast budget_ms=\(Self.fastBudgetPreferredMs) elapsed_ms=\(fastElapsed)")
		print("[PerceptionTier] tier=fast loop_blocked=\(fastElapsed > Self.fastBudgetAbsoluteMs ? "yes" : "no") elapsed_ms=\(fastElapsed)")

		// MARK: VLM semantic caption (performance-first)
		// Default: VLM is async enrichment only; hot-loop VLM is opt-in via env.
		var vlmCaption: String? = nil
		var vlmCategory: String? = nil
		var vlmSemanticHash: UInt32 = 0
		var vlmConfidence: Float = 0
		let cacheKey = Self.vlmCacheKey(
			bundleIdentifier: previousSnapshot.bundleIdentifier,
			windowTitle: previousSnapshot.windowTitle,
			pHash: freshPHash,
			targetAnchor: targetAnchor
		)
		if let cached = await VLMPerceptionEngine.shared.cachedCaption(cacheKey: cacheKey) {
			print("[VLMCache] hit=yes")
			print("[VLMCache] reused_for_fast_loop=yes")
			vlmCaption = cached.caption
			vlmCategory = cached.contentCategory
			vlmSemanticHash = cached.semanticHash
			vlmConfidence = cached.confidence
		} else if vlmEnabled {
			if !vlmHotLoop {
				print("[PerceptionBudget] skipped component=vlm reason=hot_loop_disabled")
			} else if let base64 = VLMPerceptionEngine.base64PNG(from: frame.image) {
				let fastStart = Date()
				let fastResult = await VLMPerceptionEngine.shared.analyzeFast(
					imageBase64: base64,
					appName: previousSnapshot.activeApp,
					windowTitle: previousSnapshot.windowTitle
				)
				let fastMs = Int(Date().timeIntervalSince(fastStart) * 1000)
				print("[PerceptionTier] tier=fast_vlm elapsed_ms=\(fastMs)")
				if let result = fastResult {
					vlmCaption = result.caption
					vlmCategory = result.contentCategory
					vlmSemanticHash = result.semanticHash
					vlmConfidence = result.confidence
					await VLMPerceptionEngine.shared.storeCaption(cacheKey: cacheKey, result: result)
					print("[VLMCache] stored=yes")
				}
			}

			// Slow tier: async enrichment (never awaited in hot loop).
			let reserved = await VLMPerceptionEngine.shared.beginAsyncEnrichment(cacheKey: cacheKey)
			if reserved {
				print("[VLMAsync] enqueue=yes reason=slow_enrichment")
				let appName = previousSnapshot.activeApp
				let windowTitle = previousSnapshot.windowTitle
				let image = SendableCGImage(image: frame.image)
				Task.detached { [cacheKey, appName, windowTitle, image] in
					let slowStart = Date()
					let base64 = VLMPerceptionEngine.base64PNG(from: image.image)
					let slowResult = base64 == nil ? nil : await VLMPerceptionEngine.shared.analyze(
						imageBase64: base64!,
						appName: appName,
						windowTitle: windowTitle
					)
					let slowMs = Int(Date().timeIntervalSince(slowStart) * 1000)
					print("[VLMAsync] completed caption_chars=\(slowResult?.caption.count ?? 0) elapsed_ms=\(slowMs)")
					if let slowResult {
						await VLMPerceptionEngine.shared.storeCaption(cacheKey: cacheKey, result: slowResult)
						print("[VLMCache] stored=yes")
					}
					await VLMPerceptionEngine.shared.endAsyncEnrichment(cacheKey: cacheKey)
				}
			} else {
				print("[VLMAsync] skipped reason=already_running_for_window")
			}
		}

		// MARK: Build fresh snapshot (replaces stale one)
		let freshSnapshot = buildFreshSnapshot(
			previousSnapshot: previousSnapshot,
			freshOCR: freshOCR,
			freshAXText: freshAXText,
			vlmCaption: vlmCaption,
			vlmCategory: vlmCategory,
			snapshotID: snapshotID
		)
		let textHash = Self.computeTextHash(
			ocr: freshOCR,
			selectedText: freshSnapshot.selectedText
		)
		let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)

		print("[PerceptionRefresh] freshness_score=\(String(format: "%.2f", freshSnapshot.freshnessScore))")
		print("[PerceptionRefresh] snapshot_replaced old=\(previousSnapshotID?.uuidString.prefix(8) ?? "nil") new=\(snapshotID.uuidString.prefix(8))")
		print("[PerceptionRefresh] completed elapsed_ms=\(elapsed) ocr_acquired=\(freshOCR != nil ? "yes" : "no")")

		return AgenticPerceptionRefreshResult(
			freshSnapshot:   freshSnapshot,
			snapshotID:      snapshotID,
			previousSnapshotID: previousSnapshotID,
			textHash:        textHash,
			freshOCR:        freshOCR,
			freshAXText:     freshAXText,
			success:         true,
			failedStage:     nil,
			capturedAt:      Date(),
			elapsedMs:       elapsed,
			pHash:           freshPHash,
			quadrantHashes:  freshQuadrantHashes,
			vlmCaption:      vlmCaption,
			vlmCategory:     vlmCategory,
			vlmSemanticHash: vlmSemanticHash,
			vlmConfidence:   vlmConfidence
		)
	}

	// MARK: - Phase 4H: Initial capture / priming

	/// Phase 4H: Live OCR/AX priming at execution start.
	///
	/// Called before step 1 when the proposal snapshot has no usable OCR.
	///
	/// Logs:
	///   [PerceptionRefresh] initial_capture started ...
	///   [PerceptionRefresh] initial_capture screenshot_acquired=yes/no
	///   [PerceptionRefresh] initial_capture ocr_chars=...
	///   [PerceptionRefresh] initial_capture ax_chars=...
	///   [PerceptionRefresh] initial_capture completed ...
	func initialCapture(
		previousSnapshot: CanonicalGeneratedExecutionContextSnapshot,
		previousSnapshotID: UUID?,
		ocrBudgetRemaining: Bool,
		targetAnchor: TargetWindowAnchor? = nil,
		requireTargetAnchor: Bool = false,
		dryRun: Bool = false
	) async -> AgenticPerceptionRefreshResult {
		let startedAt = Date()
		let snapshotID = UUID()
		print("[PerceptionRefresh] initial_capture started snapshot_id=\(snapshotID.uuidString.prefix(8)) dry_run=\(dryRun)")
		if let anchor = targetAnchor {
			print("[TargetAnchorTrace] stage=perception_initial_capture anchor_nil=no")
			print("[TargetAnchorTrace] bundle=\(anchor.bundleIdentifier)")
			print("[TargetAnchorTrace] title=\"\(anchor.windowTitle.prefix(80))\"")
		} else {
			print("[TargetAnchorTrace] stage=perception_initial_capture anchor_nil=yes")
		}
		if requireTargetAnchor && targetAnchor == nil {
			print("[DirectAgentRuntime] blocked reason=missing_target_window_anchor")
			return buildFailedResult(
				snapshotID: snapshotID,
				previousSnapshotID: previousSnapshotID,
				previousSnapshot: previousSnapshot,
				failedStage: "screenshot",
				startedAt: startedAt
			)
		}
		let vlmEnabled = await VLMPerceptionEngine.shared.isEnabled()
		let vlmHotLoop = Self.vlmHotLoopEnabled()
		if !vlmHotLoop {
			print("[PerceptionTier] vlm_hot_loop=disabled reason=performance_default")
		}
		if !vlmEnabled {
			print("[VLMPerception] disabled reason=user_or_env")
		}

		if dryRun {
			// Deterministic dry-run: inject synthetic OCR/AX so runtime can exercise the priming path
			// without requiring screen recording permission.
			let syntheticOCR = previousSnapshot.recentOCRExcerpt ?? "dry_run_ocr: product price rating"
			let syntheticAX = "dry_run_ax: button link heading"
			let provisional = buildFreshSnapshot(
				previousSnapshot: previousSnapshot,
				freshOCR: syntheticOCR,
				freshAXText: syntheticAX,
				vlmCaption: nil,
				vlmCategory: nil,
				snapshotID: snapshotID
			)
			let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
			print("[PerceptionRefresh] initial_capture screenshot_acquired=no reason=dry_run")
			print("[PerceptionRefresh] initial_capture ocr_chars=\(syntheticOCR.count)")
			print("[PerceptionRefresh] initial_capture ax_chars=\(syntheticAX.count)")
			print("[PerceptionRefresh] initial_capture completed elapsed_ms=\(elapsed) ocr_acquired=yes ax_acquired=yes")
			return AgenticPerceptionRefreshResult(
				freshSnapshot:   provisional,
				snapshotID:      snapshotID,
				previousSnapshotID: previousSnapshotID,
				textHash:        Self.computeTextHash(ocr: syntheticOCR, selectedText: provisional.selectedText),
				freshOCR:        syntheticOCR,
				freshAXText:     syntheticAX,
				success:         true,
				failedStage:     nil,
				capturedAt:      Date(),
				elapsedMs:       elapsed,
				pHash:           0xDEAD_BEEF_CAFE_BABE,   // deterministic dry-run sentinel
				quadrantHashes:  [0xA1B2, 0xC3D4, 0xE5F6, 0x0718],
				vlmCaption:      nil,
				vlmCategory:     nil,
				vlmSemanticHash: 0,
				vlmConfidence:   0
			)
		}

		guard ScreenCaptureSource.isScreenRecordingAuthorized() else {
			print("[PerceptionRefresh] initial_capture failed stage=screenshot reason=no_screen_recording_permission")
			return buildFailedResult(
				snapshotID: snapshotID,
				previousSnapshotID: previousSnapshotID,
				previousSnapshot: previousSnapshot,
				failedStage: "screenshot",
				startedAt: startedAt
			)
		}

		guard let frame = ScreenCaptureSource.captureSingleFrame(targetAnchor: targetAnchor) else {
			print("[PerceptionRefresh] initial_capture failed stage=screenshot reason=capture_returned_nil")
			return buildFailedResult(
				snapshotID: snapshotID,
				previousSnapshotID: previousSnapshotID,
				previousSnapshot: previousSnapshot,
				failedStage: "screenshot",
				startedAt: startedAt
			)
		}
		print("[PerceptionRefresh] initial_capture screenshot_acquired=yes size=\(frame.width)x\(frame.height)")
		let fastTierStartedAt = Date()

		// pHash — computed immediately after screenshot, before OCR (no budget cost)
		let primePHash         = PerceptualHasher.hash(frame.image) ?? 0
		let primeQuadrantHashes = PerceptualHasher.quadrantHashes(frame.image)
		print("[PerceptionRefresh] initial_capture phash=\(String(format: "%016llx", primePHash))")

		var freshOCR: String? = nil
		if ocrBudgetRemaining {
			let elapsed = Int(Date().timeIntervalSince(fastTierStartedAt) * 1000)
			if elapsed >= Self.fastBudgetPreferredMs {
				print("[PerceptionBudget] skipped component=ocr reason=budget_exceeded")
			} else {
				let ocrResult = await OCRProcessor.shared.recognizeText(from: frame.image)
				let text = ocrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
				if !text.isEmpty {
					freshOCR = String(text.prefix(CanonicalGeneratedExecutionContextSnapshot.maxExcerptLength))
				}
				print("[PerceptionRefresh] initial_capture ocr_chars=\(freshOCR?.count ?? 0) lines=\(ocrResult.lineCount)")
			}
		} else {
			print("[PerceptionRefresh] initial_capture ocr_skipped reason=budget_exhausted")
		}
		if Self.detectSelfOCRContamination(freshOCR) {
			print("[SelfWindowExclusion] warning=self_ocr_contamination")
		}

		var freshAXText: String? = nil
		let axElapsed = Int(Date().timeIntervalSince(fastTierStartedAt) * 1000)
		if axElapsed >= Self.fastBudgetPreferredMs {
			print("[PerceptionBudget] skipped component=ax reason=budget_exceeded")
		} else {
			let activeAX = AXWindowContentSource.shared.extractActiveWindowContent()
			if let activeAX, !activeAX.visibleTextFragments.isEmpty {
				// If a target anchor is provided and the active AX window is the assistant,
				// skip AX text so we don't ground against assistant UI.
				let assistantBundle = Bundle.main.bundleIdentifier
				if let targetAnchor,
				   let assistantBundle,
				   activeAX.bundleIdentifier == assistantBundle,
				   targetAnchor.bundleIdentifier != assistantBundle {
					print("[TargetWindowCapture] exact_window_capture=no fallback=screen_only reason=ax_frontmost_is_assistant target_bundle=\(targetAnchor.bundleIdentifier)")
				} else {
					let joined = activeAX.visibleTextFragments.prefix(20).joined(separator: " ")
					freshAXText = String(joined.prefix(CanonicalGeneratedExecutionContextSnapshot.maxExcerptLength))
				}
			}
		}
		print("[PerceptionRefresh] initial_capture ax_chars=\(freshAXText?.count ?? 0)")

		let fastElapsed = Int(Date().timeIntervalSince(fastTierStartedAt) * 1000)
		print("[PerceptionBudget] tier=fast budget_ms=\(Self.fastBudgetPreferredMs) elapsed_ms=\(fastElapsed)")
		print("[PerceptionTier] tier=fast loop_blocked=\(fastElapsed > Self.fastBudgetAbsoluteMs ? "yes" : "no") elapsed_ms=\(fastElapsed)")

		// VLM semantic caption (performance-first)
		// Default: VLM is async enrichment only; hot-loop VLM is opt-in via env.
		var vlmCaption: String? = nil
		var vlmCategory: String? = nil
		var vlmSemanticHash: UInt32 = 0
		var vlmConfidence: Float = 0
		let cacheKey = Self.vlmCacheKey(
			bundleIdentifier: previousSnapshot.bundleIdentifier,
			windowTitle: previousSnapshot.windowTitle,
			pHash: primePHash,
			targetAnchor: targetAnchor
		)
		if let cached = await VLMPerceptionEngine.shared.cachedCaption(cacheKey: cacheKey) {
			print("[VLMCache] hit=yes")
			print("[VLMCache] reused_for_fast_loop=yes")
			vlmCaption = cached.caption
			vlmCategory = cached.contentCategory
			vlmSemanticHash = cached.semanticHash
			vlmConfidence = cached.confidence
		} else if vlmEnabled {
			let vlmHotLoop = Self.vlmHotLoopEnabled()
			if !vlmHotLoop {
				print("[PerceptionBudget] skipped component=vlm reason=hot_loop_disabled")
			} else if let base64 = VLMPerceptionEngine.base64PNG(from: frame.image) {
				let fastStart = Date()
				let fastResult = await VLMPerceptionEngine.shared.analyzeFast(
					imageBase64: base64,
					appName: previousSnapshot.activeApp,
					windowTitle: previousSnapshot.windowTitle
				)
				let fastMs = Int(Date().timeIntervalSince(fastStart) * 1000)
				print("[PerceptionTier] tier=fast_vlm elapsed_ms=\(fastMs)")
				if let result = fastResult {
					vlmCaption = result.caption
					vlmCategory = result.contentCategory
					vlmSemanticHash = result.semanticHash
					vlmConfidence = result.confidence
					await VLMPerceptionEngine.shared.storeCaption(cacheKey: cacheKey, result: result)
					print("[VLMCache] stored=yes")
				}
			}

			let reserved = await VLMPerceptionEngine.shared.beginAsyncEnrichment(cacheKey: cacheKey)
			if reserved {
				print("[VLMAsync] enqueue=yes reason=slow_enrichment")
				let appName = previousSnapshot.activeApp
				let windowTitle = previousSnapshot.windowTitle
				let image = SendableCGImage(image: frame.image)
				Task.detached { [cacheKey, appName, windowTitle, image] in
					let slowStart = Date()
					let base64 = VLMPerceptionEngine.base64PNG(from: image.image)
					let slowResult = base64 == nil ? nil : await VLMPerceptionEngine.shared.analyze(
						imageBase64: base64!,
						appName: appName,
						windowTitle: windowTitle
					)
					let slowMs = Int(Date().timeIntervalSince(slowStart) * 1000)
					print("[VLMAsync] completed caption_chars=\(slowResult?.caption.count ?? 0) elapsed_ms=\(slowMs)")
					if let slowResult {
						await VLMPerceptionEngine.shared.storeCaption(cacheKey: cacheKey, result: slowResult)
						print("[VLMCache] stored=yes")
					}
					await VLMPerceptionEngine.shared.endAsyncEnrichment(cacheKey: cacheKey)
				}
			} else {
				print("[VLMAsync] skipped reason=already_running_for_window")
			}
		}

		let freshSnapshot = buildFreshSnapshot(
			previousSnapshot: previousSnapshot,
			freshOCR: freshOCR,
			freshAXText: freshAXText,
			vlmCaption: vlmCaption,
			vlmCategory: vlmCategory,
			snapshotID: snapshotID
		)
		let textHash = Self.computeTextHash(ocr: freshOCR, selectedText: freshSnapshot.selectedText)
		let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
		print("[PerceptionRefresh] initial_capture completed elapsed_ms=\(elapsed) ocr_acquired=\(freshOCR != nil ? "yes" : "no") ax_acquired=\(freshAXText != nil ? "yes" : "no")")

		return AgenticPerceptionRefreshResult(
			freshSnapshot:   freshSnapshot,
			snapshotID:      snapshotID,
			previousSnapshotID: previousSnapshotID,
			textHash:        textHash,
			freshOCR:        freshOCR,
			freshAXText:     freshAXText,
			success:         freshOCR != nil || freshAXText != nil,
			failedStage:     nil,
			capturedAt:      Date(),
			elapsedMs:       elapsed,
			pHash:           primePHash,
			quadrantHashes:  primeQuadrantHashes,
			vlmCaption:      vlmCaption,
			vlmCategory:     vlmCategory,
			vlmSemanticHash: vlmSemanticHash,
			vlmConfidence:   vlmConfidence
		)
	}

	// MARK: - Snapshot builder

	/// Builds a fresh snapshot from the previous one, replacing stale OCR with
	/// freshly captured content. All other fields (app, workflow, permissions) are
	/// preserved because they haven't changed from the control action.
	private func buildFreshSnapshot(
		previousSnapshot: CanonicalGeneratedExecutionContextSnapshot,
		freshOCR: String?,
		freshAXText: String?,
		vlmCaption: String?,
		vlmCategory: String?,
		snapshotID: UUID
	) -> CanonicalGeneratedExecutionContextSnapshot {
		let now = Date()
		let mergedOCR = freshOCR ?? previousSnapshot.recentOCRExcerpt
		let freshnessScore: Double = freshOCR != nil ? 0.90 : 0.65
		let mergedAX: String? = {
			let base = freshAXText ?? previousSnapshot.contextSummary
			guard let base else { return nil }
			let lines = base
				.components(separatedBy: .newlines)
				.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("vlm_caption:") }
			let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
			return joined.isEmpty ? nil : joined
		}()
		let vlmLine: String? = {
			guard let caption = vlmCaption?.trimmingCharacters(in: .whitespacesAndNewlines),
			      !caption.isEmpty else { return nil }
			let category = (vlmCategory ?? "unknown").trimmingCharacters(in: .whitespacesAndNewlines)
			return "vlm_caption: \(caption.prefix(260)) (category=\(category.prefix(32)))"
		}()
		let mergedSummary: String? = {
			var parts: [String] = []
			if let ax = mergedAX?.trimmingCharacters(in: .whitespacesAndNewlines), !ax.isEmpty {
				parts.append(ax)
			}
			if let vlmLine {
				parts.append(vlmLine)
			}
			guard !parts.isEmpty else { return nil }
			return parts.joined(separator: "\n")
		}()

		let provisional = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: previousSnapshot.activeApp,
			windowTitle: previousSnapshot.windowTitle,
			bundleIdentifier: previousSnapshot.bundleIdentifier,
			inferredWorkflow: previousSnapshot.inferredWorkflow,
			inferredIntent: previousSnapshot.inferredIntent,
			selectedText: previousSnapshot.selectedText,
			clipboardText: nil,   // always excluded from agentic runtime
			recentOCRExcerpt: mergedOCR,
			contextSummary: mergedSummary,
			workflowConfidence: previousSnapshot.workflowConfidence,
			availableContextTypes: previousSnapshot.availableContextTypes,
			visualContextAvailability: previousSnapshot.visualContextAvailability,
			permissionAvailability: previousSnapshot.permissionAvailability,
			generatedAt: now,
			freshnessScore: freshnessScore,
			sourceMetadata: CanonicalExecutionSourceMetadata(
				selectedTextCapturedAt: previousSnapshot.sourceMetadata.selectedTextCapturedAt,
				ocrCapturedAt: freshOCR != nil ? now : previousSnapshot.sourceMetadata.ocrCapturedAt,
				contextUpdatedAt: now,
				fusedConfidence: previousSnapshot.sourceMetadata.fusedConfidence,
				sessionContinuityScore: previousSnapshot.sourceMetadata.sessionContinuityScore,
				sessionDominantWorkflow: previousSnapshot.sourceMetadata.sessionDominantWorkflow
			),
			fusedPacketId: snapshotID,  // snapshotID tracked as packet ID for identity
			packetIsStale: false
		)
		if let freshAXText, !freshAXText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return provisional.merging(axWindowTextExcerpt: freshAXText, referenceTime: now)
		}
		return provisional
	}

	// MARK: - Dry run

	private func buildDryRunResult(
		snapshotID: UUID,
		previousSnapshotID: UUID?,
		previousSnapshot: CanonicalGeneratedExecutionContextSnapshot,
		startedAt: Date
	) -> AgenticPerceptionRefreshResult {
		// Dry run: generate a new snapshotID to prove identity tracking works,
		// but don't capture real content. Same OCR as before (no page change in tests).
		let dryRunSnapshot = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: previousSnapshot.activeApp,
			windowTitle: previousSnapshot.windowTitle,
			bundleIdentifier: previousSnapshot.bundleIdentifier,
			inferredWorkflow: previousSnapshot.inferredWorkflow,
			inferredIntent: previousSnapshot.inferredIntent,
			selectedText: previousSnapshot.selectedText,
			clipboardText: nil,
			recentOCRExcerpt: previousSnapshot.recentOCRExcerpt,
			contextSummary: previousSnapshot.contextSummary,
			workflowConfidence: previousSnapshot.workflowConfidence,
			availableContextTypes: previousSnapshot.availableContextTypes,
			visualContextAvailability: previousSnapshot.visualContextAvailability,
			permissionAvailability: previousSnapshot.permissionAvailability,
			generatedAt: Date(),
			freshnessScore: 0.70,
			sourceMetadata: previousSnapshot.sourceMetadata,
			fusedPacketId: snapshotID,
			packetIsStale: false
		)
		let textHash = Self.computeTextHash(
			ocr: dryRunSnapshot.recentOCRExcerpt,
			selectedText: dryRunSnapshot.selectedText
		)
		let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
		print("[PerceptionRefresh] dry_run=yes snapshot_replaced old=\(previousSnapshotID?.uuidString.prefix(8) ?? "nil") new=\(snapshotID.uuidString.prefix(8)) elapsed_ms=\(elapsed)")
		print("[PerceptionRefresh] completed elapsed_ms=\(elapsed)")
		return AgenticPerceptionRefreshResult(
			freshSnapshot:  dryRunSnapshot,
			snapshotID:     snapshotID,
			previousSnapshotID: previousSnapshotID,
			textHash:       textHash,
			freshOCR:       nil,
			freshAXText:    nil,
			success:        true,
			failedStage:    nil,
			capturedAt:     Date(),
			elapsedMs:      elapsed,
			pHash:          0xDEAD_BEEF_CAFE_BABE,   // deterministic dry-run sentinel
			quadrantHashes: [0xA1B2, 0xC3D4, 0xE5F6, 0x0718],
			vlmCaption:     nil,
			vlmCategory:    nil,
			vlmSemanticHash: 0,
			vlmConfidence:  0
		)
	}

	// MARK: - Failure result

	private func buildFailedResult(
		snapshotID: UUID,
		previousSnapshotID: UUID?,
		previousSnapshot: CanonicalGeneratedExecutionContextSnapshot,
		failedStage: String,
		startedAt: Date
	) -> AgenticPerceptionRefreshResult {
		let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
		print("[PerceptionRefresh] failed stage=\(failedStage) elapsed_ms=\(elapsed)")
		return AgenticPerceptionRefreshResult(
			freshSnapshot:  previousSnapshot,
			snapshotID:     snapshotID,
			previousSnapshotID: previousSnapshotID,
			textHash:       Self.computeTextHash(
				ocr: previousSnapshot.recentOCRExcerpt,
				selectedText: previousSnapshot.selectedText
			),
			freshOCR:       nil,
			freshAXText:    nil,
			success:        false,
			failedStage:    failedStage,
			capturedAt:     Date(),
			elapsedMs:      elapsed,
			pHash:          0,   // no image available — caller treats as "unknown, assume changed"
			quadrantHashes: [0, 0, 0, 0],
			vlmCaption:     nil,
			vlmCategory:    nil,
			vlmSemanticHash: 0,
			vlmConfidence:  0
		)
	}

	// MARK: - Text hash

	/// Lightweight DJB2-style hash of all visible text (OCR + selectedText).
	/// Not cryptographic — only used for change detection between observations.
	static func computeTextHash(ocr: String?, selectedText: String?) -> String? {
		let combined = [ocr, selectedText].compactMap { $0 }.joined(separator: "|")
		guard !combined.isEmpty else { return nil }
		var hash: UInt64 = 5381
		for scalar in combined.unicodeScalars {
			hash = hash &* 33 &+ UInt64(scalar.value)
		}
		return String(format: "%016llx", hash)
	}

	// MARK: - Delta detection

	/// Multi-signal world-state delta between two refresh events.
	///
	/// Signal priority (tier-1 → tier-3):
	/// 1. pHash Hamming distance — visual/layout change, catches scroll even when OCR barely moves
	/// 2. Quadrant hash map      — localises *where* on screen the change occurred
	/// 3. OCR text hash          — exact-text fallback for pure text edits with stable layout
	///
	/// The returned tuple preserves the existing `(textChanged, ocrGrew, reason)` signature for
	/// backward compatibility with all call sites in `runDirectAgentLoop`. The `reason` string
	/// now encodes the tier that fired (e.g. "phash_changed", "phash_bottom_half_text_changed").
	static func detectDelta(
		previousHash:      String?,
		newHash:           String?,
		previousOCRChars:  Int,
		newOCRChars:       Int,
		action:            String,
		previousPHash:     UInt64 = 0,
		newPHash:          UInt64 = 0,
		previousQuadrants: [UInt64] = [],
		newQuadrants:      [UInt64] = [],
		previousSemanticHash: UInt32 = 0,
		newSemanticHash:      UInt32 = 0
	) -> (textChanged: Bool, ocrGrew: Bool, semanticChanged: Bool, reason: String) {

		// Tier-1: pHash visual delta (primary signal)
		let hasPHash        = previousPHash != 0 || newPHash != 0
		let pHashDistance   = hasPHash ? PerceptualHasher.hammingDistance(previousPHash, newPHash) : 0
		let visualChanged   = hasPHash && pHashDistance > 12

		// Tier-2: Quadrant localisation
		let quadrantDelta   = previousQuadrants.count == 4 && newQuadrants.count == 4
			? PerceptualHasher.classifyQuadrantDelta(previous: previousQuadrants, current: newQuadrants)
			: PerceptualHasher.QuadrantDelta(changedQuadrants: [], region: .unknown, anyChanged: false)

		// Tier-3: OCR text hash (legacy, now fallback only)
		let textChanged     = previousHash != newHash && !(previousHash == nil && newHash == nil)
		let ocrGrew         = newOCRChars > previousOCRChars + 20
		let semanticChanged = (previousSemanticHash != 0 || newSemanticHash != 0)
			&& previousSemanticHash != newSemanticHash

		// Compose reason string for log/stale-detection
		var reasonParts: [String] = []
		if visualChanged   { reasonParts.append("phash_\(quadrantDelta.region.rawValue)_hamming\(pHashDistance)") }
		if textChanged     { reasonParts.append("text_changed") }
		if ocrGrew         { reasonParts.append("ocr_grew") }
		if semanticChanged { reasonParts.append("semantic_changed") }
		let reason = reasonParts.isEmpty ? "no_change_detected" : reasonParts.joined(separator: "+")

		print("[WorldStateDelta] action=\(action) visual=\(visualChanged ? "yes" : "no") semantic=\(semanticChanged ? "yes" : "no") hamming=\(pHashDistance) region=\(quadrantDelta.region.rawValue) text=\(textChanged ? "yes" : "no") ocr_before=\(previousOCRChars) ocr_after=\(newOCRChars) reason=\(reason)")

		// Backward-compat: textChanged absorbs pHash result so existing callers see correct "changed" signal
		return (textChanged || visualChanged, ocrGrew, semanticChanged, reason)
	}
}
