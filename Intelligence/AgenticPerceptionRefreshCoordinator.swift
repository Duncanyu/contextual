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
		debugVisible: Bool = false,
		dryRun: Bool = false
	) async -> AgenticPerceptionRefreshResult {
		let startedAt = Date()
		let snapshotID = UUID()
		print("[PerceptionRefresh] started action=\(controlAction.rawValue) snapshot_id=\(snapshotID.uuidString.prefix(8)) dry_run=\(dryRun) debug_visible=\(debugVisible)")

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

		guard let frame = ScreenCaptureSource.captureSingleFrame() else {
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

		// MARK: OCR
		var freshOCR: String? = nil
		if ocrBudgetRemaining {
			let ocrResult = await OCRProcessor.shared.recognizeText(from: frame.image)
			let text = ocrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
			if !text.isEmpty {
				freshOCR = String(text.prefix(CanonicalGeneratedExecutionContextSnapshot.maxExcerptLength))
			}
			print("[PerceptionRefresh] ocr_chars=\(freshOCR?.count ?? 0) lines=\(ocrResult.lineCount)")
		} else {
			print("[PerceptionRefresh] ocr_skipped reason=budget_exhausted")
		}

		// MARK: AX text
		var freshAXText: String? = nil
		if let ax = AXWindowContentSource.shared.extractActiveWindowContent(),
		   !ax.visibleTextFragments.isEmpty {
			let joined = ax.visibleTextFragments.prefix(20).joined(separator: " ")
			freshAXText = String(joined.prefix(CanonicalGeneratedExecutionContextSnapshot.maxExcerptLength))
		}
		print("[PerceptionRefresh] ax_chars=\(freshAXText?.count ?? 0)")

		// MARK: Build fresh snapshot (replaces stale one)
		let freshSnapshot = buildFreshSnapshot(
			previousSnapshot: previousSnapshot,
			freshOCR: freshOCR,
			freshAXText: freshAXText,
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
			freshSnapshot: freshSnapshot,
			snapshotID: snapshotID,
			previousSnapshotID: previousSnapshotID,
			textHash: textHash,
			freshOCR: freshOCR,
			freshAXText: freshAXText,
			success: true,
			failedStage: nil,
			capturedAt: Date(),
			elapsedMs: elapsed
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
		snapshotID: UUID
	) -> CanonicalGeneratedExecutionContextSnapshot {
		let now = Date()
		let mergedOCR = freshOCR ?? previousSnapshot.recentOCRExcerpt
		let freshnessScore: Double = freshOCR != nil ? 0.90 : 0.65

		return CanonicalGeneratedExecutionContextSnapshot(
			activeApp: previousSnapshot.activeApp,
			windowTitle: previousSnapshot.windowTitle,
			bundleIdentifier: previousSnapshot.bundleIdentifier,
			inferredWorkflow: previousSnapshot.inferredWorkflow,
			inferredIntent: previousSnapshot.inferredIntent,
			selectedText: previousSnapshot.selectedText,
			clipboardText: nil,   // always excluded from agentic runtime
			recentOCRExcerpt: mergedOCR,
			contextSummary: previousSnapshot.contextSummary,
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
			freshSnapshot: dryRunSnapshot,
			snapshotID: snapshotID,
			previousSnapshotID: previousSnapshotID,
			textHash: textHash,
			freshOCR: nil,
			freshAXText: nil,
			success: true,
			failedStage: nil,
			capturedAt: Date(),
			elapsedMs: elapsed
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
			freshSnapshot: previousSnapshot,
			snapshotID: snapshotID,
			previousSnapshotID: previousSnapshotID,
			textHash: Self.computeTextHash(
				ocr: previousSnapshot.recentOCRExcerpt,
				selectedText: previousSnapshot.selectedText
			),
			freshOCR: nil,
			freshAXText: nil,
			success: false,
			failedStage: failedStage,
			capturedAt: Date(),
			elapsedMs: elapsed
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

	/// Computes a world-state delta between two snapshots.
	static func detectDelta(
		previousHash: String?,
		newHash: String?,
		previousOCRChars: Int,
		newOCRChars: Int,
		action: String
	) -> (textChanged: Bool, ocrGrew: Bool, reason: String) {
		let textChanged = previousHash != newHash && !(previousHash == nil && newHash == nil)
		let ocrGrew = newOCRChars > previousOCRChars + 20  // +20 chars threshold to avoid noise
		let reason: String
		if textChanged && ocrGrew {
			reason = "text_changed_ocr_grew"
		} else if textChanged {
			reason = "text_changed"
		} else if ocrGrew {
			reason = "ocr_grew"
		} else {
			reason = "no_change_detected"
		}
		print("[WorldStateDelta] action=\(action) visual_changed=yes text_changed=\(textChanged) ocr_chars_before=\(previousOCRChars) ocr_chars_after=\(newOCRChars) reason=\(reason)")
		return (textChanged, ocrGrew, reason)
	}
}
