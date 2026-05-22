import CoreGraphics
import Foundation
import Vision

struct OCRResult: Equatable {
	let text: String
	let lineCount: Int
	let confidenceAverage: Float?
	let timestamp: Date
}

final class OCRProcessor: @unchecked Sendable {
	static let shared = OCRProcessor()
	private init() {}

	func recognizeText(from image: CGImage) async -> OCRResult {
		print("[OCR] started")

		return await Task.detached(priority: .utility) {
			let request = VNRecognizeTextRequest()
			request.recognitionLevel = .fast
			request.usesLanguageCorrection = false

			let handler = VNImageRequestHandler(cgImage: image, options: [:])
			do {
				try handler.perform([request])
			} catch {
				print("[OCR] failed reason=\(error.localizedDescription)")
				return OCRResult(text: "", lineCount: 0, confidenceAverage: nil, timestamp: Date())
			}

			let observations = (request.results as? [VNRecognizedTextObservation]) ?? []

			var lines: [String] = []
			lines.reserveCapacity(observations.count)

			var confSum: Float = 0
			var confCount: Int = 0

			for obs in observations {
				guard let top = obs.topCandidates(1).first else { continue }
				lines.append(top.string)
				confSum += top.confidence
				confCount += 1
			}

			let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
			let lineCount = lines.count
			let avg = confCount > 0 ? (confSum / Float(confCount)) : nil

			let chars = text.utf8.count
			// Log a real excerpt so logs prove OCR content is genuine (not fabricated).
			let rawExcerpt = String(text.prefix(100))
				.trimmingCharacters(in: .whitespacesAndNewlines)
				.replacingOccurrences(of: "\n", with: " ")
			let excerptDisplay = rawExcerpt.isEmpty ? "(empty)" : rawExcerpt
			print("[OCR] completed chars=\(chars) lines=\(lineCount)")
			print("[OCR] excerpt=\"\(excerptDisplay)\"")
			return OCRResult(text: text, lineCount: lineCount, confidenceAverage: avg, timestamp: Date())
		}.value
	}
}

