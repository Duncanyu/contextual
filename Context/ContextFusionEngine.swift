import Foundation

final class ContextFusionEngine {
	static let shared = ContextFusionEngine()

	private init() {}

	/// Centralized default priority for text selection (highest first).
	/// Keep in one place so future tuning is explicit and reviewable.
	static let defaultTextPriority: [FusedTextSource] = [
		.selectedText,
		.axText,
		.screenOCR,
		.clipboardText
	]

	func fuse(
		contextModel: ContextModel,
		windowSnapshot: WindowSnapshotContext? = nil,
		visualDescriptor: VisualContextDescriptor? = nil,
		axContent: AXWindowContentContext? = nil,
		typingActivity: TypingActivityContext? = nil,
		pointerActivity: PointerActivityContext? = nil
	) -> FusedContextPacket {
		let now = Date()

		var available: [ContextCapabilityID] = [.activeApp]
		var stale: [ContextCapabilityID] = []

		let hasSelection = contextModel.selectedTextAvailable && contextModel.selectedTextLength > 0
		let hasClipboard = contextModel.clipboardTextAvailable && contextModel.clipboardTextLength > 0
		let hasOCR = contextModel.screenOCRAvailable && contextModel.screenOCRTextLength > 0
		let hasAX = (axContent != nil) && (axContent?.estimatedVisibleTextLength ?? 0) > 0
		let hasSnapshot = (windowSnapshot != nil)
		let hasVisual = (visualDescriptor != nil)
		let hasTyping = (typingActivity != nil)
		let hasPointer = (pointerActivity != nil)

		if hasSelection { available.append(.selectedText) }
		if hasClipboard { available.append(.clipboardText) }
		if hasOCR { available.append(.screenOCR) }
		if hasAX { available.append(.selectedText) /* AX is selection-adjacent; keep separate via primaryTextSource */ }
		if hasSnapshot { available.append(.activeWindowSnapshot) }
		if hasVisual { available.append(.activeWindowSnapshot) }
		if hasTyping { available.append(.typingActivity) }
		if hasPointer { available.append(.cursorActivity) }

		// Freshness evaluation (metadata-only).
		let selectionFresh = estimateFreshness(
			eventAt: estimateSelectionTimestamp(contextModel),
			now: now,
			window: 15
		)
		let clipboardFresh = estimateFreshness(
			eventAt: estimateClipboardTimestamp(contextModel),
			now: now,
			window: 45
		)
		let ocrFresh = estimateFreshness(
			eventAt: contextModel.screenOCRCapturedAt,
			now: now,
			window: 35
		)
		let axFresh = estimateFreshness(
			eventAt: axContent?.extractedAt,
			now: now,
			window: 15
		)
		let snapshotFresh = estimateFreshness(
			eventAt: windowSnapshot?.capturedAt,
			now: now,
			window: 20
		)
		let visualFresh = estimateFreshness(
			eventAt: visualDescriptor?.generatedAt,
			now: now,
			window: 15
		)
		let typingFresh = estimateFreshness(
			eventAt: typingActivity?.updatedAt,
			now: now,
			window: 6
		)
		let pointerFresh = estimateFreshness(
			eventAt: pointerActivity?.updatedAt,
			now: now,
			window: 6
		)

		if hasOCR, ocrFresh <= 0.10 { stale.append(.screenOCR) }
		if hasSnapshot, snapshotFresh <= 0.10 { stale.append(.activeWindowSnapshot) }
		if hasVisual, visualFresh <= 0.10 { stale.append(.activeWindowSnapshot) }

		// Choose primary text source per explicit priority + freshness.
		let primaryText = choosePrimaryTextSource(
			hasSelection: hasSelection,
			selectionFresh: selectionFresh,
			hasAX: hasAX,
			axFresh: axFresh,
			hasOCR: hasOCR,
			ocrFresh: ocrFresh,
			hasClipboard: hasClipboard,
			clipboardFresh: clipboardFresh
		)

		let (textAvailable, textLength, lineCount) = fusedTextMetadata(
			primaryText: primaryText,
			contextModel: contextModel,
			axContent: axContent
		)

		// Structure hints are lightweight string labels (no content).
		var structureHints: [String] = []
		if let ax = axContent {
			if ax.containsEditorLikeRegion { structureHints.append("ax_editor_like") }
			if ax.containsFormLikeRegion { structureHints.append("ax_form_like") }
			if ax.containsTableLikeRegion { structureHints.append("ax_table_like") }
			if ax.containsScrollableRegion { structureHints.append("ax_scrollable") }
		}
		if let v = visualDescriptor {
			if v.likelyScrollable { structureHints.append("visual_scrollable") }
			if v.containsDialogLikeRegion { structureHints.append("visual_dialog_like") }
			if v.containsToolbarLikeRegion { structureHints.append("visual_toolbar_like") }
			if v.containsLargeImageRegion { structureHints.append("visual_large_image") }
			if v.containsLargeMonospaceRegion { structureHints.append("visual_monospace_region") }
		}

		// Conflict scoring (metadata-only heuristics).
		let conflict = conflictScore(
			hasSelection: hasSelection,
			selectionLength: contextModel.selectedTextLength,
			hasClipboard: hasClipboard,
			clipboardLength: contextModel.clipboardTextLength,
			hasOCR: hasOCR,
			ocrFresh: ocrFresh,
			activeBundle: contextModel.activeAppBundleIdentifier,
			ocrCapturedAt: contextModel.screenOCRCapturedAt,
			recentAppNames: contextModel.recentAppNames
		)

		// Confidence: combine primary text freshness + supporting modalities (capped).
		var confidence: Double = 0.35
		switch primaryText {
		case .selectedText:
			confidence += 0.35 * selectionFresh
		case .axText:
			confidence += 0.28 * axFresh
		case .screenOCR:
			confidence += 0.22 * ocrFresh
		case .clipboardText:
			confidence += 0.18 * clipboardFresh
		case .none:
			break
		}
		if hasVisual { confidence += 0.08 * visualFresh }
		if hasSnapshot { confidence += 0.06 * snapshotFresh }
		if hasTyping { confidence += 0.04 * typingFresh }
		if hasPointer { confidence += 0.04 * pointerFresh }
		if conflict > 0 { confidence -= min(0.18, conflict * 0.18) }
		confidence = clamp01(confidence)

		// Freshness score: max of key modalities.
		let freshness = clamp01(max(selectionFresh, axFresh, ocrFresh, clipboardFresh, visualFresh, snapshotFresh))

		let isStale = freshness < 0.15 && !hasTyping && !hasPointer

		let primarySource: FusedPrimarySource
		switch primaryText {
		case .selectedText: primarySource = .selectedText
		case .axText: primarySource = .axText
		case .screenOCR: primarySource = .screenOCR
		case .clipboardText: primarySource = .clipboardText
		case .none: primarySource = .none
		}

		var debug: [String: String] = [
			"primaryText": primaryText.rawValue,
			"selFresh": String(format: "%.2f", selectionFresh),
			"axFresh": String(format: "%.2f", axFresh),
			"ocrFresh": String(format: "%.2f", ocrFresh),
			"clipFresh": String(format: "%.2f", clipboardFresh),
			"visualFresh": String(format: "%.2f", visualFresh),
			"snapFresh": String(format: "%.2f", snapshotFresh),
			"conflict": String(format: "%.2f", conflict)
		]
		debug["hasSelection"] = hasSelection ? "1" : "0"
		debug["hasAX"] = hasAX ? "1" : "0"
		debug["hasOCR"] = hasOCR ? "1" : "0"
		debug["hasClipboard"] = hasClipboard ? "1" : "0"
		debug["hasVisual"] = hasVisual ? "1" : "0"
		debug["hasSnapshot"] = hasSnapshot ? "1" : "0"
		debug["hasTyping"] = hasTyping ? "1" : "0"
		debug["hasPointer"] = hasPointer ? "1" : "0"

		let packet = FusedContextPacket(
			id: UUID(),
			createdAt: now,
			primarySource: primarySource,
			availableSources: uniquePreserveOrder(available),
			staleSources: uniquePreserveOrder(stale),
			appName: contextModel.activeAppName,
			bundleIdentifier: contextModel.activeAppBundleIdentifier,
			windowTitleAvailable: (contextModel.activeWindowTitle != nil),
			primaryTextSource: primaryText,
			textAvailability: textAvailable,
			textLength: textLength,
			lineCount: lineCount,
			hasSelectedText: hasSelection,
			hasClipboardText: hasClipboard,
			hasOCRText: hasOCR,
			hasAXText: hasAX,
			hasWindowSnapshot: hasSnapshot,
			hasVisualDescriptor: hasVisual,
			hasTypingActivity: hasTyping,
			hasPointerActivity: hasPointer,
			visualKinds: visualDescriptor?.visibleUIKinds ?? [],
			uiStructureHints: structureHints,
			typingState: typingActivity?.typingState,
			pointerState: pointerActivity?.pointerState,
			confidence: confidence,
			freshnessScore: freshness,
			conflictScore: clamp01(conflict),
			isStale: isStale,
			debugSummaryMetadata: debug
		)

		logFusion(packet: packet)
		return packet
	}

	// MARK: - Private helpers

	private func choosePrimaryTextSource(
		hasSelection: Bool,
		selectionFresh: Double,
		hasAX: Bool,
		axFresh: Double,
		hasOCR: Bool,
		ocrFresh: Double,
		hasClipboard: Bool,
		clipboardFresh: Double
	) -> FusedTextSource {
		// Apply priority but require minimal freshness; stale sources cannot win.
		for candidate in Self.defaultTextPriority {
			switch candidate {
			case .selectedText:
				if hasSelection && selectionFresh > 0.15 { return .selectedText }
			case .axText:
				if hasAX && axFresh > 0.15 { return .axText }
			case .screenOCR:
				if hasOCR && ocrFresh > 0.15 { return .screenOCR }
			case .clipboardText:
				if hasClipboard && clipboardFresh > 0.10 { return .clipboardText }
			case .none:
				break
			}
		}
		return .none
	}

	private func fusedTextMetadata(
		primaryText: FusedTextSource,
		contextModel: ContextModel,
		axContent: AXWindowContentContext?
	) -> (Bool, Int, Int) {
		switch primaryText {
		case .selectedText:
			return (contextModel.selectedTextAvailable, contextModel.selectedTextLength, 0)
		case .axText:
			return (axContent != nil, axContent?.estimatedVisibleTextLength ?? 0, 0)
		case .screenOCR:
			return (contextModel.screenOCRAvailable, contextModel.screenOCRTextLength, contextModel.screenOCRLineCount)
		case .clipboardText:
			return (contextModel.clipboardTextAvailable, contextModel.clipboardTextLength, 0)
		case .none:
			return (false, 0, 0)
		}
	}

	private func estimateFreshness(eventAt: Date?, now: Date, window: TimeInterval) -> Double {
		guard let eventAt else { return 0.0 }
		let age = now.timeIntervalSince(eventAt)
		if age <= 0 { return 1.0 }
		if age >= window { return 0.0 }
		return clamp01(1.0 - (age / window))
	}

	private func estimateSelectionTimestamp(_ model: ContextModel) -> Date? {
		// We don't currently keep per-source timestamps for selection; best-effort.
		if model.lastSourceTrigger == .selectedTextChanged { return model.updatedAt }
		return nil
	}

	private func estimateClipboardTimestamp(_ model: ContextModel) -> Date? {
		if model.lastSourceTrigger == .clipboardTextChanged { return model.updatedAt }
		return nil
	}

	private func conflictScore(
		hasSelection: Bool,
		selectionLength: Int,
		hasClipboard: Bool,
		clipboardLength: Int,
		hasOCR: Bool,
		ocrFresh: Double,
		activeBundle: String?,
		ocrCapturedAt: Date?,
		recentAppNames: [String]
	) -> Double {
		var score: Double = 0.0

		// Selection vs clipboard divergence heuristic (no raw text access).
		if hasSelection, hasClipboard, selectionLength >= 30, clipboardLength >= 30 {
			let ratio = Double(min(selectionLength, clipboardLength)) / Double(max(selectionLength, clipboardLength))
			if ratio < 0.45 {
				score += 0.35
			} else if ratio < 0.70 {
				score += 0.18
			}
		}

		// OCR stale after app switch heuristic: if OCR exists but is old-ish.
		if hasOCR, ocrFresh < 0.20, ocrCapturedAt != nil {
			score += 0.15
		}

		// If recent app names suggest rapid switching, prefer lower confidence and higher conflict.
		if let b = activeBundle, !b.isEmpty, recentAppNames.count >= 3 {
			score += 0.05
		}

		return clamp01(score)
	}

	private func logFusion(packet: FusedContextPacket) {
		let sources = packet.availableSources.map(\.rawValue).joined(separator: ",")
		let stale = packet.staleSources.map(\.rawValue).joined(separator: ",")
		let visual = packet.visualKinds.map(\.rawValue).joined(separator: ",")
		let conf = String(format: "%.2f", packet.confidence)
		let fresh = String(format: "%.2f", packet.freshnessScore)
		let conflict = String(format: "%.2f", packet.conflictScore)
		print("[ContextFusion] fused primary=\(packet.primaryTextSource.rawValue) sources=\(sources) stale=\(stale.isEmpty ? "none" : stale) visual=\(visual.isEmpty ? "none" : visual) confidence=\(conf) freshness=\(fresh) conflict=\(conflict)")
	}

	private func uniquePreserveOrder<T: Hashable>(_ values: [T]) -> [T] {
		var seen = Set<T>()
		var out: [T] = []
		out.reserveCapacity(values.count)
		for v in values where seen.insert(v).inserted {
			out.append(v)
		}
		return out
	}

	private func clamp01(_ x: Double) -> Double {
		max(0.0, min(1.0, x))
	}
}

extension ContextFusionEngine {
	/// DEBUG-only synthetic self-test. Call via env var in AppDelegate.
	func _selfTest() -> Bool {
		print("[ContextFusion] selftest starting")

		func makeModel(
			selectionLen: Int,
			clipboardLen: Int,
			ocrLen: Int,
			ocrAgeSeconds: TimeInterval
		) -> ContextModel {
			var m = ContextModel()
			m.activeAppName = "TestApp"
			m.activeAppBundleIdentifier = "com.example.testapp"
			m.selectedTextAvailable = selectionLen > 0
			m.selectedTextLength = selectionLen
			m.clipboardTextAvailable = clipboardLen > 0
			m.clipboardTextLength = clipboardLen
			m.screenOCRAvailable = ocrLen > 0
			m.screenOCRTextLength = ocrLen
			m.screenOCRLineCount = ocrLen > 0 ? 12 : 0
			m.screenOCRCapturedAt = Date().addingTimeInterval(-ocrAgeSeconds)
			m.updatedAt = Date()
			m.lastSourceTrigger = selectionLen > 0 ? .selectedTextChanged : (clipboardLen > 0 ? .clipboardTextChanged : .screenOCRCompleted)
			return m
		}

		// Case 1: selected beats clipboard.
		let m1 = makeModel(selectionLen: 120, clipboardLen: 900, ocrLen: 0, ocrAgeSeconds: 0)
		let p1 = fuse(contextModel: m1)
		print("[ContextFusion] selftest case=sel_vs_clip primary=\(p1.primaryTextSource.rawValue) conflict=\(String(format: "%.2f", p1.conflictScore))")

		// Case 2: AX beats OCR when selection absent.
		let ax = AXWindowContentContext(
			id: UUID(),
			extractedAt: Date(),
			appName: "TestApp",
			bundleIdentifier: "com.example.testapp",
			sourceWindowTitleAvailable: true,
			visibleTextFragments: ["X", "Y"],
			visibleControlKinds: [.staticText, .toolbar],
			estimatedVisibleTextLength: 420,
			estimatedInteractiveElementCount: 4,
			containsScrollableRegion: true,
			containsEditorLikeRegion: false,
			containsFormLikeRegion: false,
			containsTableLikeRegion: false,
			hierarchyDepthEstimate: 4,
			extractionConfidence: 0.80
		)
		let m2 = makeModel(selectionLen: 0, clipboardLen: 0, ocrLen: 600, ocrAgeSeconds: 5)
		let p2 = fuse(contextModel: m2, axContent: ax)
		print("[ContextFusion] selftest case=ax_vs_ocr primary=\(p2.primaryTextSource.rawValue)")

		// Case 3: OCR beats clipboard when AX absent.
		let m3 = makeModel(selectionLen: 0, clipboardLen: 200, ocrLen: 800, ocrAgeSeconds: 4)
		let p3 = fuse(contextModel: m3)
		print("[ContextFusion] selftest case=ocr_vs_clip primary=\(p3.primaryTextSource.rawValue)")

		// Case 4: stale OCR goes to staleSources.
		let m4 = makeModel(selectionLen: 0, clipboardLen: 0, ocrLen: 800, ocrAgeSeconds: 120)
		let p4 = fuse(contextModel: m4)
		let staleLabel = p4.staleSources.map(\.rawValue).joined(separator: ",")
		print("[ContextFusion] selftest case=stale_ocr stale=\(staleLabel.isEmpty ? "none" : staleLabel)")

		// Case 5: multimodal metadata flows through.
		let typing = TypingActivityContext(
			id: UUID(),
			updatedAt: Date(),
			appName: "TestApp",
			bundleIdentifier: "com.example.testapp",
			isTypingActive: true,
			typingState: .burst,
			recentEventCount: 14,
			burstIntensity: .high,
			sessionDuration: 12,
			idleDuration: 0.2,
			estimatedEditingActivity: 1.0
		)
		let pointer = PointerActivityContext(
			id: UUID(),
			updatedAt: Date(),
			appName: "TestApp",
			bundleIdentifier: "com.example.testapp",
			isPointerActive: true,
			pointerState: .interacting,
			recentMoveEventCount: 25,
			recentClickEventCount: 5,
			movementBurstIntensity: .medium,
			clickBurstIntensity: .low,
			sessionDuration: 20,
			idleDuration: 0.4,
			estimatedFocusIntensity: 0.8
		)
		let visual = VisualContextDescriptor(
			generatedAt: Date(),
			sourceSnapshotID: UUID(),
			confidence: 0.82,
			visibleUIKinds: [.editor, .terminal],
			estimatedTextDensity: 0.6,
			estimatedVisualDensity: 0.2,
			estimatedPanelCount: 2,
			likelyScrollable: true,
			dominantLayoutStyle: .columns,
			containsLargeMonospaceRegion: true,
			containsLargeImageRegion: false,
			containsDialogLikeRegion: false,
			containsToolbarLikeRegion: true,
			isStale: false,
			metadata: nil,
			sourceAppHints: nil
		)
		let m5 = makeModel(selectionLen: 80, clipboardLen: 0, ocrLen: 0, ocrAgeSeconds: 0)
		let p5 = fuse(contextModel: m5, visualDescriptor: visual, typingActivity: typing, pointerActivity: pointer)
		let visualLabel = p5.visualKinds.map(\.rawValue).joined(separator: ",")
		let typingLabel = p5.typingState?.rawValue ?? "nil"
		let pointerLabel = p5.pointerState?.rawValue ?? "nil"
		print("[ContextFusion] selftest case=multimodal visual=\(visualLabel) typing=\(typingLabel) pointer=\(pointerLabel)")

		print("[ContextFusion] selftest finished")
		return true
	}
}

