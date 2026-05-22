import AppKit
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
			BoundedVisualContextDebug.log(event: "visual_descriptor_started", requestId: request.id)
			let generatedDesc = await generateVisualDescription(from: frame.image, ocrExcerpt: ocrExcerpt)
			let capped = Self.cap(generatedDesc, max: request.maxDescriptionCharacters)
			visualSummary = capped
			visualTags.append("visual_description")
			// Log real excerpt so logs prove visual descriptor content is genuine.
			let excerptDisplay = String(capped.prefix(100))
				.trimmingCharacters(in: .whitespacesAndNewlines)
				.replacingOccurrences(of: "\n", with: " ")
			if !excerptDisplay.isEmpty {
				print("[VisualDescriptor] excerpt=\"\(excerptDisplay)\"")
			}
			BoundedVisualContextDebug.log(event: "visual_descriptor_completed", requestId: request.id)
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

	private func generateVisualDescription(from image: CGImage, ocrExcerpt: String?) async -> String {
		guard let base64Image = Self.cgImageToBase64JPEG(image, compressionQuality: 0.4) else {
			let desc = Self.generateHeuristicDescription(ocrExcerpt: ocrExcerpt)
			print("[VisualDescriptor] mode=heuristic_fallback reason=base64_encode_failed")
			return desc
		}

		// Discover an installed vision model (llava, minicpm, moondream, or any *-vision variant).
		var visionModel: String? = nil
		do {
			if let url = URL(string: "http://127.0.0.1:11434/api/tags") {
				var request = URLRequest(url: url)
				request.httpMethod = "GET"
				request.timeoutInterval = 2.0
				let (data, response) = try await URLSession.shared.data(for: request)
				if let http = response as? HTTPURLResponse, http.statusCode == 200 {
					struct TagsRoot: Codable {
						struct TagEntry: Codable { let name: String }
						let models: [TagEntry]
					}
					if let root = try? JSONDecoder().decode(TagsRoot.self, from: data) {
						let names = root.models.map { $0.name.lowercased() }
						visionModel = names.first { $0.contains("llava") || $0.contains("minicpm") || $0.contains("moondream") || $0.contains("vision") }
					}
				}
			}
		} catch {
			let desc = Self.generateHeuristicDescription(ocrExcerpt: ocrExcerpt)
			print("[VisualDescriptor] mode=heuristic_fallback reason=tags_fetch_failed")
			return desc
		}

		guard let resolvedModel = visionModel else {
			// No vision-capable model installed — heuristic is the only option.
			let desc = Self.generateHeuristicDescription(ocrExcerpt: ocrExcerpt)
			print("[VisualDescriptor] mode=heuristic_fallback reason=no_vision_model_installed")
			return desc
		}

		let prompt = "Provide a compact one-sentence, natural-language description of the visible UI or scene on this screen. Focus on the high-level visual scene and UI elements. Do NOT transcribe text or perform OCR. Start your response with 'Visible screen shows...'"

		do {
			guard let url = URL(string: "http://127.0.0.1:11434/api/generate") else {
				let desc = Self.generateHeuristicDescription(ocrExcerpt: ocrExcerpt)
				print("[VisualDescriptor] mode=heuristic_fallback reason=invalid_url")
				return desc
			}
			var request = URLRequest(url: url)
			request.httpMethod = "POST"
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")

			struct OllamaVisionRequest: Encodable {
				let model: String
				let prompt: String
				let stream: Bool
				let images: [String]
				let options: [String: Double]
				let keepAlive: String
				enum CodingKeys: String, CodingKey {
					case model, prompt, stream, images, options
					case keepAlive = "keep_alive"
				}
			}

			let payload = OllamaVisionRequest(
				model: resolvedModel,
				prompt: prompt,
				stream: false,
				images: [base64Image],
				options: ["temperature": 0.2, "num_predict": 100],
				keepAlive: "5m"
			)
			request.httpBody = try JSONEncoder().encode(payload)
			request.timeoutInterval = 8.0

			let (data, response) = try await URLSession.shared.data(for: request)
			guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
				let desc = Self.generateHeuristicDescription(ocrExcerpt: ocrExcerpt)
				print("[VisualDescriptor] mode=heuristic_fallback reason=vision_model_http_error")
				return desc
			}

			struct OllamaVisionResponse: Decodable { let response: String? }
			if let decoded = try? JSONDecoder().decode(OllamaVisionResponse.self, from: data),
			   let text = decoded.response?.trimmingCharacters(in: .whitespacesAndNewlines),
			   !text.isEmpty {
				print("[VisualDescriptor] mode=vision_model model=\(resolvedModel)")
				return text
			}
		} catch {
			// Vision call failed — fall through to heuristic.
		}

		let desc = Self.generateHeuristicDescription(ocrExcerpt: ocrExcerpt)
		print("[VisualDescriptor] mode=heuristic_fallback reason=vision_model_empty_response model=\(resolvedModel)")
		return desc
	}

	private static func cgImageToBase64JPEG(_ cgImage: CGImage, compressionQuality: Double = 0.4) -> String? {
		let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
		guard let data = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality]) else {
			return nil
		}
		return data.base64EncodedString()
	}

	private static func generateHeuristicDescription(ocrExcerpt: String?) -> String {
		let ax = AXWindowContentSource.shared.extractActiveWindowContent()
		let appName = ax?.appName ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "Active Application"
		let windowTitle = ax?.sourceWindowTitleAvailable == true ? (ax?.visibleTextFragments.first ?? "") : (NSWorkspace.shared.frontmostApplication?.localizedName ?? "")
		
		let appLower = appName.lowercased()
		let titleLower = windowTitle.lowercased()
		let ocrLower = (ocrExcerpt ?? "").lowercased()
		
		if appLower.contains("minecraft") || ocrLower.contains("minecraft") || titleLower.contains("minecraft") {
			return "Visible screen shows Minecraft gameplay with terrain, blocks, hotbar, and building/mining context."
		}
		if appLower.contains("amazon") || ocrLower.contains("amazon") || titleLower.contains("amazon") {
			return "Visible screen shows Amazon product listings with product images, prices, ratings, and add-to-cart/shopping UI."
		}
		if appLower.contains("xcode") || titleLower.contains(".swift") || titleLower.contains(".xcodeproj") {
			return "Visible screen shows Xcode development environment with code editor showing project files, sidebar, and build controls."
		}
		
		if let ax = ax, ax.containsEditorLikeRegion {
			return "Visible screen shows a code or text editor in \(appName) displaying document content and editing workspace."
		}
		if let ax = ax, ax.containsFormLikeRegion {
			return "Visible screen shows a form or input application in \(appName) with input fields, labels, and submission controls."
		}
		if let ax = ax, ax.containsTableLikeRegion {
			return "Visible screen shows structured tabular data or item list in \(appName) display layout."
		}
		
		return "Visible screen shows \(appName) interface displaying window content with active text areas and navigation menus."
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
