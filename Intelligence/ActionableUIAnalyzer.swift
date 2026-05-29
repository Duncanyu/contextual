import Foundation

public struct ActionableUIElement: Sendable, Equatable {
	public let label: String
	public let type: String // "button", "link", "input", "tab", "other"
	public let source: String // "ocr", "ax", "vlm"
	
	public init(label: String, type: String, source: String) {
		self.label = label
		self.type = type
		self.source = source
	}
}

public struct ActionableUIAnalysis: Sendable {
	public let actionableControls: [ActionableUIElement]
	public let interactionOpportunities: Bool
	public let explorationScore: Double
	
	public init(actionableControls: [ActionableUIElement], interactionOpportunities: Bool, explorationScore: Double) {
		self.actionableControls = actionableControls
		self.interactionOpportunities = interactionOpportunities
		self.explorationScore = explorationScore
	}
}

public struct ActionableUIAnalyzer: Sendable {
	
	public static func analyze(
		ocr: String?,
		contextSummary: String?,
		vlmCaption: String?,
		goal: String
	) -> ActionableUIAnalysis {
		var elements: [ActionableUIElement] = []
		
		let ocrRaw = ocr ?? ""
		let axRaw = contextSummary ?? ""
		let vlmRaw = vlmCaption ?? ""
		
		// Define common actionable keywords
		let actionableKeywords = [
			"next", "continue", "open", "read more", "sign in", "install", 
			"expand", "submit", "apply", "agree", "accept", "download", 
			"learn more", "get started", "show more", "click here",
			"cancel", "close", "save", "yes", "no", "ok", "done", "search", 
			"add to cart", "buy", "checkout", "subscribe", "register", 
			"sign up", "login", "view", "details"
		]
		
		// Helper to check if a string contains any actionable keyword
		func containsActionableKeyword(_ text: String) -> Bool {
			let lowerText = text.lowercased()
			return actionableKeywords.contains { keyword in
				lowerText.contains(keyword)
			}
		}
		
		// 1. Analyze OCR for button-like strings or labels
		let ocrLines = ocrRaw.components(separatedBy: "\n")
		for line in ocrLines {
			let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty && trimmed.count < 60 else { continue }
			
			if containsActionableKeyword(trimmed) {
				var type = "button"
				if trimmed.lowercased().contains("search") || trimmed.lowercased().contains("find") {
					type = "input"
				} else if trimmed.lowercased().contains("link") || trimmed.lowercased().contains("read more") || trimmed.lowercased().contains("learn more") {
					type = "link"
				} else if trimmed.lowercased().contains("tab") {
					type = "tab"
				}
				elements.append(ActionableUIElement(label: trimmed, type: type, source: "ocr"))
			}
		}
		
		// 2. Analyze AX Hierarchy
		let axLines = axRaw.components(separatedBy: "\n")
		for line in axLines {
			let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { continue }
			
			let lowerLine = trimmed.lowercased()
			var detectedType: String? = nil
			
			if lowerLine.contains("button") || lowerLine.contains("axbutton") {
				detectedType = "button"
			} else if lowerLine.contains("link") || lowerLine.contains("axlink") {
				detectedType = "link"
			} else if lowerLine.contains("text field") || lowerLine.contains("textfield") || lowerLine.contains("axtextfield") || lowerLine.contains("search field") || lowerLine.contains("searchfield") || lowerLine.contains("input") {
				detectedType = "input"
			} else if lowerLine.contains("tab") || lowerLine.contains("axtab") {
				detectedType = "tab"
			} else if containsActionableKeyword(trimmed) {
				detectedType = "button"
			}
			
			if let type = detectedType {
				var cleanLabel = trimmed
				if let colonIdx = cleanLabel.firstIndex(of: ":") {
					cleanLabel = String(cleanLabel[cleanLabel.index(after: colonIdx)...])
				}
				
				cleanLabel = cleanLabel
					.replacingOccurrences(of: "AXButton", with: "")
					.replacingOccurrences(of: "AXLink", with: "")
					.replacingOccurrences(of: "AXTextField", with: "")
					.replacingOccurrences(of: "AXStaticText", with: "")
					.replacingOccurrences(of: "button", with: "", options: .caseInsensitive)
					.replacingOccurrences(of: "link", with: "", options: .caseInsensitive)
					.replacingOccurrences(of: "[", with: "")
					.replacingOccurrences(of: "]", with: "")
					.replacingOccurrences(of: "\"", with: "")
					.replacingOccurrences(of: "'", with: "")
					.trimmingCharacters(in: .whitespacesAndNewlines)
				
				if !cleanLabel.isEmpty && cleanLabel.count < 80 {
					elements.append(ActionableUIElement(label: cleanLabel, type: type, source: "ax"))
				}
			}
		}
		
		// 3. Analyze VLM Caption
		let vlmWords = vlmRaw.components(separatedBy: .whitespacesAndNewlines)
		for word in vlmWords {
			let cleaned = word.trimmingCharacters(in: CharacterSet.punctuationCharacters)
			if actionableKeywords.contains(cleaned.lowercased()) && cleaned.count > 2 {
				elements.append(ActionableUIElement(label: cleaned, type: "button", source: "vlm"))
			}
		}
		
		// Deduplicate elements by label
		var uniqueElements: [ActionableUIElement] = []
		var seenLabels = Set<String>()
		for elem in elements {
			let key = elem.label.lowercased()
			if !seenLabels.contains(key) {
				seenLabels.insert(key)
				uniqueElements.append(elem)
			}
		}
		
		let actionableCount = uniqueElements.count
		let interactionOpportunities = actionableCount > 0
		
		var score = Double(actionableCount) * 0.15
		if score > 1.0 { score = 1.0 }
		
		// Telemetry Logs
		print("[ActionableUI] detected count=\(actionableCount)")
		let topControls = uniqueElements.prefix(5).map { $0.label }
		let topControlsStr = topControls.map { "\"\($0)\"" }.joined(separator: ",")
		print("[ActionableUI] top_controls=\(topControlsStr)")
		
		return ActionableUIAnalysis(
			actionableControls: uniqueElements,
			interactionOpportunities: interactionOpportunities,
			explorationScore: score
		)
	}
}
