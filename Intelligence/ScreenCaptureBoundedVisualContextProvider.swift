import CoreGraphics
import Foundation

/// Explicit one-shot screen capture + optional OCR (T17.8).
///
/// **Inject only** — not created by default app paths. Never call from UI/`onAppear`.
/// Discards `CGImage` after OCR; logs metadata only via `BoundedVisualContextDebug`.
struct ScreenCaptureBoundedVisualContextProvider: BoundedVisualContextProvider, Sendable {
	private let ocrProcessor: OCRProcessor
	private let captureFrame: @Sendable () -> (image: CGImage, width: Int, height: Int)?

	init(
		ocrProcessor: OCRProcessor = .shared,
		captureFrame: @escaping @Sendable () -> (image: CGImage, width: Int, height: Int)? = {
			ScreenCaptureSource.captureSingleFrame()
		}
	) {
		self.ocrProcessor = ocrProcessor
		self.captureFrame = captureFrame
	}

	func collectVisualContext(request: BoundedVisualContextRequest) async throws -> BoundedVisualContextResult {
		guard request.maxCaptureCount <= 1 else {
			throw VisualContextError.invalidRequest
		}
		guard request.allowedSources.contains(.screenCapture) else {
			return .unavailable(requestId: request.id, detail: "screen_source_not_allowed")
		}
		guard request.permissionGranted(.screenRecording) else {
			BoundedVisualContextDebug.log(event: "capture_permission_denied", requestId: request.id)
			return .fromError(.permissionDenied, requestId: request.id)
		}

		BoundedVisualContextDebug.log(event: "capture_started", requestId: request.id)

		guard let frame = captureFrame() else {
			BoundedVisualContextDebug.log(event: "capture_failed", requestId: request.id)
			return .fromError(.captureFailed, requestId: request.id)
		}

		let capturedAt = Date()
		var warnings: [String] = []
		var metadata: [String: String] = [
			"captureWidth": String(frame.width),
			"captureHeight": String(frame.height),
			"captureCount": "1",
			"provider": "screen_capture",
		]

		var ocrExcerpt: String?
		var visualTags = ["screen_capture"]
		var status: VisualContextStatus = .completed

		if request.requiresOCR, request.allowedSources.contains(.ocr) {
			guard request.budget.allowsOCR else {
				return .fromError(.budgetDenied, requestId: request.id, detail: "ocr_not_allowed")
			}
			BoundedVisualContextDebug.log(event: "ocr_started", requestId: request.id)
			let ocr = await ocrProcessor.recognizeText(from: frame.image)
			let capped = Self.capOCR(ocr.text, max: request.maxOCRCharacters)
			if capped.isEmpty {
				status = .partial
				warnings.append("ocr_empty")
				BoundedVisualContextDebug.log(event: "ocr_failed", requestId: request.id, detail: "empty")
			} else {
				ocrExcerpt = capped
				visualTags.append("ocr")
				metadata["ocrLineCount"] = String(ocr.lineCount)
				metadata["ocrCharBucket"] = Self.charBucket(capped.count)
				BoundedVisualContextDebug.log(event: "ocr_completed", requestId: request.id, detail: metadata["ocrCharBucket"])
			}
		}

		var visualSummary: String?
		if request.requiresVisualDescription {
			guard request.budget.allowsVision else {
				return .fromError(.budgetDenied, requestId: request.id, detail: "vision_not_allowed")
			}
			visualSummary = Self.cap(
				"Screen \(frame.width)x\(frame.height); OCR lines=\(metadata["ocrLineCount"] ?? "0")",
				max: request.maxDescriptionCharacters
			)
			visualTags.append("visual_description")
		}

		BoundedVisualContextDebug.log(event: "capture_completed", requestId: request.id)

		return BoundedVisualContextResult(
			requestId: request.id,
			status: status,
			capturedAt: capturedAt,
			sourceSummary: "screen_capture",
			ocrExcerpt: ocrExcerpt,
			visualSummary: visualSummary,
			visualTags: visualTags,
			warnings: warnings,
			metadata: metadata,
			expiresAt: request.expiresAt
		)
	}

	private static func capOCR(_ text: String, max: Int) -> String {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.count <= max else { return String(trimmed.prefix(max)) }
		return trimmed
	}

	private static func cap(_ text: String, max: Int) -> String {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.count <= max else { return String(trimmed.prefix(max)) }
		return trimmed
	}

	private static func charBucket(_ count: Int) -> String {
		switch count {
		case 0: "0"
		case 1..<200: "1-199"
		case 200..<600: "200-599"
		default: "600+"
		}
	}
}
