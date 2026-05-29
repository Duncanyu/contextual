import CoreGraphics
import Foundation

// MARK: - VisualPerception

/// Unified world-state object for one screen-capture event.
///
/// Combines OCR text, AX affordance skeleton, and visual hash signals into a single
/// representation that replaces the OCR-as-world-model pattern.
///
/// ## Architecture phases
/// - Phase 1 (current): pHash + OCR + AX. No VLM. Zero new model deps.
/// - Phase 2 (future):  VLM semantic pass via local MLX server (semanticCaption, contentCategory).
///
/// ## Delta detection tiers
/// 1. pHash Hamming distance  — catches layout/visual changes even when OCR barely moves.
///    Example: a scroll that shifts the viewport reveals new pixel content but adds only ~30 OCR
///    characters. pHash Hamming distance = 22 → "significant visual change" correctly flagged.
/// 2. Quadrant hash delta     — localises *where* the change occurred (topHalf = navigation,
///    bottomHalf = content scrolled in, full = page transition).
/// 3. OCR text hash           — exact-text fallback for catching pure text edits with stable layout.
///
/// ## Log prefixes
/// `[VisualPerception]`  — capture events
/// `[PerceptionDelta]`   — delta comparisons between successive perceptions
/// `[VLMCaption]`        — VLM semantic pass results (Phase 2)
struct VisualPerception: Sendable {

    // MARK: Provenance
    let screenshotID:       UUID
    let capturedAt:         Date

    // MARK: OCR (auxiliary — exact text retrieval, always budget-gated)
    let ocrText:            String?
    let ocrChars:           Int

    // MARK: AX (free affordance skeleton — no budget cost)
    let axRoles:            [String]    // "button", "link", "textField", etc.
    let axLabels:           [String]    // visible text fragments from AX tree
    let interactableCount:  Int

    // MARK: VLM semantic layer (nil until Phase 2 VLM integration)
    let semanticCaption:    String?     // e.g. "A product detail page showing AirPods..."
    let contentCategory:    VisualContentCategory

    // MARK: Visual delta signals (always populated — cost ≤ 2ms)
    let pHash:              UInt64      // full-image DCT pHash
    let quadrantHashes:     [UInt64]    // 4 values: [topLeft, topRight, bottomLeft, bottomRight]
    let ocrHash:            String?     // DJB2 text hash (legacy compatibility)

    // MARK: Layout hints
    let likelyScrollable:   Bool
    let estimatedPanelCount: Int

    // MARK: Computed helpers

    var hasTextContent: Bool { ocrChars > 20 }

    var logLine: String {
        "id=\(screenshotID.uuidString.prefix(8)) pHash=\(String(format: "%016llx", pHash)) ocr=\(ocrChars) ax=\(interactableCount) category=\(contentCategory.rawValue)"
    }
}

// MARK: - Content category

enum VisualContentCategory: String, Sendable {
    case article
    case productListing
    case searchResults
    case form
    case ide
    case terminal
    case dashboard
    case settings
    case media
    case browser
    case document
    case unknown
}

// MARK: - PerceptionDelta

/// Describes the change between two successive VisualPerception snapshots.
/// Replaces the single `(textChanged, ocrGrew, reason)` tuple with a richer multi-signal view.
struct PerceptionDelta: Sendable {
    let visualChanged:    Bool     // pHash Hamming distance > threshold
    let hammingDistance:  Int      // 0–64; lower = more similar
    let quadrantDelta:    PerceptualHasher.QuadrantDelta
    let textChanged:      Bool     // OCR hash comparison
    let ocrGrew:          Bool     // OCR char count increased by > 20
    let semanticChanged:  Bool     // VLM caption hash (always false in Phase 1)

    /// True if any perception signal detected a meaningful world-state change.
    var anyChanged: Bool { visualChanged || textChanged || ocrGrew }

    /// Compact log line — emitted as `[PerceptionDelta]`.
    var logLine: String {
        "visual=\(visualChanged ? "yes" : "no") hamming=\(hammingDistance) region=\(quadrantDelta.region.rawValue) quads=\(quadrantDelta.description) text=\(textChanged ? "yes" : "no") ocr_grew=\(ocrGrew ? "yes" : "no")"
    }
}

// MARK: - VisualPerceptionEngine

/// Lightweight engine that captures a fresh VisualPerception from the live screen.
///
/// Designed to be invoked after every control action (scroll, click, type, find, press)
/// so the decide() step always reasons over a current world model, not a stale one.
///
/// Backed by:
/// - `ScreenCaptureSource.captureSingleFrame()` for the raw frame
/// - `PerceptualHasher` for pHash + quadrant hashes
/// - `OCRProcessor.shared` for text extraction (budget-gated)
/// - `AXWindowContentSource.shared` for accessibility affordances
struct VisualPerceptionEngine: Sendable {

    // MARK: - Capture

    /// Capture a fresh VisualPerception from the live screen.
    /// In dryRun mode returns deterministic synthetic content for tests.
    func capture(
        previousPerception: VisualPerception? = nil,
        ocrBudgetRemaining: Bool = true,
        dryRun:             Bool = false
    ) async -> VisualPerception {
        let startedAt = Date()
        let id        = UUID()

        if dryRun {
            let p = makeDryRunPerception(id: id)
            print("[VisualPerception] dry_run id=\(id.uuidString.prefix(8))")
            return p
        }

        // MARK: Screenshot
        guard ScreenCaptureSource.isScreenRecordingAuthorized() else {
            print("[VisualPerception] failed reason=no_screen_recording_permission id=\(id.uuidString.prefix(8))")
            return makeFailedPerception(id: id, previous: previousPerception)
        }
        guard let frame = ScreenCaptureSource.captureSingleFrame() else {
            print("[VisualPerception] failed reason=capture_returned_nil id=\(id.uuidString.prefix(8))")
            return makeFailedPerception(id: id, previous: previousPerception)
        }

        // MARK: pHash (fast — < 2ms, no budget cost)
        let pHashStart      = Date()
        let pHashValue      = PerceptualHasher.hash(frame.image) ?? 0
        let quadrantHashes  = PerceptualHasher.quadrantHashes(frame.image)
        let pHashMs         = Int(Date().timeIntervalSince(pHashStart) * 1000)
        print("[VisualPerception] phash=\(String(format: "%016llx", pHashValue)) quads=[\(quadrantHashes.map { String(format: "%016llx", $0) }.joined(separator: ","))] phash_ms=\(pHashMs)")

        // MARK: OCR (budget-gated — may be skipped if budget exhausted)
        var ocrText: String? = nil
        if ocrBudgetRemaining {
            let ocrResult = await OCRProcessor.shared.recognizeText(from: frame.image)
            let text = ocrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                ocrText = String(text.prefix(CanonicalGeneratedExecutionContextSnapshot.maxExcerptLength))
            }
        }
        let ocrHash = AgenticPerceptionRefreshCoordinator.computeTextHash(ocr: ocrText, selectedText: nil)

        // MARK: AX (free — reads accessibility tree, no screen recording needed)
        var axRoles:  [String] = []
        var axLabels: [String] = []
        if let ax = AXWindowContentSource.shared.extractActiveWindowContent(),
           !ax.visibleTextFragments.isEmpty {
            axLabels = Array(ax.visibleTextFragments.prefix(20))
            // Role inference from label heuristics (expanded in Phase 2 with full AX type access)
            axRoles = inferRolesFromLabels(axLabels)
        }

        // MARK: VLM semantic caption (local-only; optional)
        var semanticCaption: String? = nil
        var contentCategory: VisualContentCategory = .unknown
        if await VLMPerceptionEngine.shared.isEnabled() {
            print("[VLMPerception] enabled=yes endpoint=\(await VLMPerceptionEngine.shared.configuredEndpoint())")
            print("[VLMPerception] started screenshot_id=\(id.uuidString.prefix(8))")
            let (app, title) = ScreenCaptureSource.getActiveAppAndTitle()
            if let result = await VLMPerceptionEngine.shared.analyze(
                screenshot: frame.image,
                appName: app,
                windowTitle: title
            ) {
                semanticCaption = result.caption
                let catLower = result.contentCategory.lowercased()
                if catLower.contains("shopping") || catLower.contains("product") { contentCategory = .productListing }
                else if catLower.contains("browser") { contentCategory = .browser }
                else if catLower.contains("document") || catLower.contains("pdf") { contentCategory = .document }
                print("[VLMPerception] category=\(result.contentCategory) confidence=\(String(format: "%.2f", result.confidence)) semantic_hash=\(String(format: "%08x", result.semanticHash))")
            }
        } else {
            print("[VLMPerception] enabled=no")
            print("[VLMPerception] skipped reason=not_configured screenshot_id=\(id.uuidString.prefix(8))")
        }

        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        print("[VisualPerception] captured \(id.uuidString.prefix(8)) ocr=\(ocrText?.count ?? 0) ax=\(axLabels.count) elapsed_ms=\(elapsed)")

        return VisualPerception(
            screenshotID:        id,
            capturedAt:          startedAt,
            ocrText:             ocrText,
            ocrChars:            ocrText?.count ?? 0,
            axRoles:             axRoles,
            axLabels:            axLabels,
            interactableCount:   axLabels.count,
            semanticCaption:     semanticCaption,
            contentCategory:     contentCategory,
            pHash:               pHashValue,
            quadrantHashes:      quadrantHashes,
            ocrHash:             ocrHash,
            likelyScrollable:    false,        // Phase 2 VisualContextAnalyzer
            estimatedPanelCount: 1
        )
    }

    // MARK: - Delta computation

    /// Compute a multi-signal PerceptionDelta between two successive perceptions.
    /// pHash is the tier-1 signal; OCR hash is the tier-2 fallback.
    static func delta(
        from previous: VisualPerception,
        to   current:  VisualPerception,
        pHashThreshold: Int = 12
    ) -> PerceptionDelta {
        let hamming       = PerceptualHasher.hammingDistance(previous.pHash, current.pHash)
        let visualChanged = hamming > pHashThreshold
        let quadrantDelta = PerceptualHasher.classifyQuadrantDelta(
            previous:  previous.quadrantHashes,
            current:   current.quadrantHashes,
            threshold: pHashThreshold
        )
        let textChanged   = previous.ocrHash != current.ocrHash &&
                            !(previous.ocrHash == nil && current.ocrHash == nil)
        let ocrGrew       = current.ocrChars > previous.ocrChars + 20

        let d = PerceptionDelta(
            visualChanged:   visualChanged,
            hammingDistance: hamming,
            quadrantDelta:   quadrantDelta,
            textChanged:     textChanged,
            ocrGrew:         ocrGrew,
            semanticChanged: false    // Phase 2
        )
        print("[PerceptionDelta] \(d.logLine)")
        return d
    }

    // MARK: - Private helpers

    /// Minimal role inference from label text patterns.
    /// Phase 2 will replace this with full AX element type access.
    private func inferRolesFromLabels(_ labels: [String]) -> [String] {
        labels.compactMap { label -> String? in
            let l = label.lowercased()
            if l.hasPrefix("http") || l.contains("://")   { return "link" }
            if l.hasSuffix("...") || l.hasSuffix("…")     { return "button" }
            if l.count < 20 && !l.contains(" ")           { return "label" }
            return nil
        }
    }

    // MARK: - Stubs

    private func makeDryRunPerception(id: UUID) -> VisualPerception {
        VisualPerception(
            screenshotID:        id,
            capturedAt:          Date(),
            ocrText:             "dry_run_content: page text sample for testing",
            ocrChars:            44,
            axRoles:             ["button", "link"],
            axLabels:            ["OK", "Cancel"],
            interactableCount:   2,
            semanticCaption:     nil,
            contentCategory:     .unknown,
            pHash:               0xDEAD_BEEF_CAFE_BABE,
            quadrantHashes:      [0xA1B2C3D4, 0xE5F60718, 0x293A4B5C, 0x6D7E8F90],
            ocrHash:             "dryhash_00",
            likelyScrollable:    false,
            estimatedPanelCount: 1
        )
    }

    private func makeFailedPerception(id: UUID, previous: VisualPerception?) -> VisualPerception {
        // Re-use the previous perception's signals — caller will see "no change"
        // which is conservative (better than false positives).
        VisualPerception(
            screenshotID:        id,
            capturedAt:          Date(),
            ocrText:             previous?.ocrText,
            ocrChars:            previous?.ocrChars ?? 0,
            axRoles:             previous?.axRoles ?? [],
            axLabels:            previous?.axLabels ?? [],
            interactableCount:   previous?.interactableCount ?? 0,
            semanticCaption:     nil,
            contentCategory:     .unknown,
            pHash:               previous?.pHash ?? 0,
            quadrantHashes:      previous?.quadrantHashes ?? [0, 0, 0, 0],
            ocrHash:             previous?.ocrHash,
            likelyScrollable:    false,
            estimatedPanelCount: 1
        )
    }
}
