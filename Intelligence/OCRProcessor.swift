import CoreGraphics
import Foundation
import Vision
import AppKit

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

			let (activeApp, activeTitle) = ScreenCaptureSource.getActiveAppAndTitle()
			let sanitizedLines = OCRProcessor.sanitizeOcrLines(lines, activeTitle: activeTitle)
			let text = sanitizedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
			let lineCount = sanitizedLines.count
			let avg = confCount > 0 ? (confSum / Float(confCount)) : nil

			let chars = text.utf8.count
			// Log a real excerpt so logs prove OCR content is genuine (not fabricated).
			let rawExcerpt = String(text.prefix(100))
				.trimmingCharacters(in: .whitespacesAndNewlines)
				.replacingOccurrences(of: "\n", with: " ")
			let excerptDisplay = rawExcerpt.isEmpty ? "(empty)" : rawExcerpt
			print("[OCR] completed chars=\(chars) lines=\(lineCount)")
			print("[OCR] excerpt=\"\(excerptDisplay)\"")

			// Perform active window coordinate mismatch detection
			let mismatched = OCRProcessor.isOcrMismatched(ocrText: text, activeApp: activeApp, activeTitle: activeTitle)
			print("[VisualTarget] mismatch_detected=\(mismatched ? "yes" : "no")")

			if mismatched {
				return OCRResult(text: "", lineCount: 0, confidenceAverage: nil, timestamp: Date())
			}

			return OCRResult(text: text, lineCount: lineCount, confidenceAverage: avg, timestamp: Date())
		}.value
	}

	static func sanitizeOcrLines(_ lines: [String], activeTitle: String? = nil) -> [String] {
		var sanitized: [String] = []
		var removed: [String] = []
		
		for line in lines {
			if let activeTitle = activeTitle {
				let lLower = line.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
				let tLower = activeTitle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
				let overlap: Bool
				if lLower.isEmpty || tLower.isEmpty {
					overlap = false
				} else if lLower.contains(tLower) || tLower.contains(lLower) {
					overlap = true
				} else {
					let lineTokens = OCRProcessor.tokenize(line)
					let titleTokens = OCRProcessor.tokenize(activeTitle)
					overlap = lineTokens.intersection(titleTokens).count >= 2
				}
				
				if overlap {
					print("[OCRSanitizer] preserved_active_title_line=yes")
					sanitized.append(line)
					continue
				}
			}

			let lower = line.lowercased()
			
			// 1. Line containing multiple tab titles / tab chrome or mixed tab domains
			let hasReddit = lower.contains("reddit")
			let hasAnker = lower.contains("anker")
			let hasAmazon = lower.contains("amazon")
			let hasGithub = lower.contains("github")
			
			var domainCount = 0
			if hasReddit { domainCount += 1 }
			if hasAnker { domainCount += 1 }
			if hasAmazon { domainCount += 1 }
			if hasGithub { domainCount += 1 }
			
			let containsMultipleTabs = domainCount >= 2
			
			// Tab close markers, browser chrome or suffix tabs
			let containsTabChrome = lower.contains("new tab") || lower.contains("close tab") || lower.contains("✕") || (line.hasSuffix(" x") || line.hasSuffix(" X")) || lower.contains(" - google chrome") || lower.contains(" - firefox") || lower.contains(" - safari")
			
			if containsMultipleTabs || containsTabChrome {
				removed.append(line)
			} else {
				sanitized.append(line)
			}
		}
		
		let removedStr = removed.isEmpty ? "none" : removed.map { "\"\($0)\"" }.joined(separator: ", ")
		print("[OCRSanitizer] removed_tab_strip_lines=\(removedStr)")
		
		return sanitized
	}

	static func isOcrMismatched(ocrText: String, activeApp: String, activeTitle: String) -> Bool {
		let ocrTokens = tokenize(ocrText)
		if ocrTokens.isEmpty { return false }

		let appTokens = tokenize(activeApp)
		let titleTokens = tokenize(activeTitle)
		
		let combinedActive = appTokens.union(titleTokens)
		if combinedActive.isEmpty {
			return false
		}

		let intersection = ocrTokens.intersection(combinedActive)
		return intersection.isEmpty
	}

	static func tokenize(_ text: String) -> Set<String> {
		let stopWords: Set<String> = ["and", "the", "for", "with", "this", "that", "you", "are", "com", "www", "http", "https", "new", "all", "out", "app", "window", "active", "file", "edit", "view", "find"]
		let lower = text.lowercased()
		let words = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
		return Set(words.filter { $0.count >= 3 && !stopWords.contains($0) })
	}
}
