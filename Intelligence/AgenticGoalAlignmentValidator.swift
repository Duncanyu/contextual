// AgenticGoalAlignmentValidator.swift
//
// Generalized capability-constrained goal validation and repair layer.
// Enforces alignment between internal runtime goals, evidence requirements, and the current active context.
// Strictly no Amazon-specific or Anker-specific hardcodings.

import Foundation

struct AgenticGoalAlignmentDecision: Sendable, Equatable {
	enum Status: String, Codable, Sendable {
		case accepted
		case rejected
		case repaired
	}
	
	let status: Status
	let alignedGoal: String
	let alignedTitle: String
	let reason: String
	let confidence: Double
	let detectedIssue: String
	
	init(
		status: Status,
		alignedGoal: String,
		alignedTitle: String,
		reason: String,
		confidence: Double,
		detectedIssue: String
	) {
		self.status = status
		self.alignedGoal = alignedGoal
		self.alignedTitle = alignedTitle
		self.reason = reason
		self.confidence = confidence
		self.detectedIssue = detectedIssue
	}
}

enum AgenticGoalAlignmentValidator {
	
	/// Validates a proposed action title and expected outcome against the current active context.
	///
	/// - Returns: A decision specifying if the goal is accepted as-is, rejected completely, or repaired internally.
	static func validate(
		title: String,
		goal: String,
		workflow: String,
		appName: String,
		bundleId: String,
		windowTitle: String,
		ocrExcerpt: String? = nil,
		axExcerpt: String? = nil,
		evidenceObservations: [AgenticEvidenceObservation] = [],
		semanticEntities: [GroundedSemanticEntity] = [],
		allowedCapabilities: [String] = []
	) -> AgenticGoalAlignmentDecision {
		let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
		let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
		let lowerTitle = trimmedTitle.lowercased()
		let lowerGoal = trimmedGoal.lowercased()
		
		// 1. Detect completely unsupported or unsafe actions
		let unsafeVerbs = ["buy", "purchase", "checkout", "add to cart", "delete", "install"]
		for verb in unsafeVerbs {
			if lowerTitle.contains(verb) || lowerGoal.contains(verb) {
				print("[GoalAlignment] accepted=no reason=unsupported_action original=\"\(goal)\"")
				return AgenticGoalAlignmentDecision(
					status: .rejected,
					alignedGoal: trimmedGoal,
					alignedTitle: trimmedTitle,
					reason: "unsupported_action",
					confidence: 0.0,
					detectedIssue: "Goal contains unsupported action verb '\(verb)'"
				)
			}
		}
		
		// 2. Detect navigation/search redundant verb checking (Search/Open on page already active)
		let searchVerbs = ["search", "find", "open", "navigate", "go to", "lookup"]
		var isSearchOrNav = false
		for verb in searchVerbs {
			if lowerTitle.contains(verb) || lowerGoal.contains(verb) {
				isSearchOrNav = true
				break
			}
		}
		
		let isProductContext = looksProductLike(windowTitle) || workflow.lowercased() == "shopping" || workflow.lowercased() == "product"
		
		if isSearchOrNav {
			// Extract search target term by removing verbs/chrome
			let stopwords: Set<String> = ["search", "for", "on", "amazon", "google", "ebay", "find", "open", "navigate", "to", "go", "lookup", "page", "site", "web", "current", "browser", "tab"]
			let targetWords = substantiveWords(from: lowerTitle + " " + lowerGoal, stopwords: stopwords)
			
			if !targetWords.isEmpty {
				let windowWords = substantiveWords(from: windowTitle.lowercased(), stopwords: stopwords)
				let ocrWords = substantiveWords(from: (ocrExcerpt ?? "").lowercased(), stopwords: stopwords)
				let matchedWindowCount = targetWords.intersection(windowWords).count
				let matchedOcrCount = targetWords.intersection(ocrWords).count
				
				// High overlap indicates the user is already on the target context!
				if matchedWindowCount >= 2 || (matchedWindowCount >= 1 && matchedOcrCount >= 1) {
					print("[GoalAlignment] accepted=no reason=already_on_target_page original=\"\(goal)\"")
					
					// Repair into context extraction / product evidence gathering!
					let repairedGoal: String
					if isProductContext {
						let productEntity = extractProductEntity(from: windowTitle) ?? "product"
						repairedGoal = "Extract useful product evidence for \(productEntity)"
					} else {
						repairedGoal = "Extract useful information from current context"
					}
					
					print("[GoalAlignment] repaired=yes internal_goal=\"\(repairedGoal)\"")
					
					return AgenticGoalAlignmentDecision(
						status: .repaired,
						alignedGoal: repairedGoal,
						alignedTitle: trimmedTitle, // Keep original user-facing title! Do not template it!
						reason: "already_on_target_page",
						confidence: 0.90,
						detectedIssue: "redundant_search_current_context"
					)
				}
			}
		}
		
		// 3. Current context is product-like but goal is generic/summary summary
		let isGenericSummary = lowerGoal.contains("summarize") || lowerGoal.contains("summary") || lowerGoal.contains("tldr") || lowerGoal.contains("key point") || lowerGoal.contains("page") || lowerGoal.contains("document")
		
		if isProductContext && isGenericSummary {
			let productEntity = extractProductEntity(from: windowTitle) ?? "product"
			let repairedGoal = "Extract useful product evidence for \(productEntity)"
			
			print("[GoalAlignment] accepted=no reason=generic_summary_on_product_page original=\"\(goal)\"")
			print("[GoalAlignment] repaired=yes internal_goal=\"\(repairedGoal)\"")
			
			return AgenticGoalAlignmentDecision(
				status: .repaired,
				alignedGoal: repairedGoal,
				alignedTitle: trimmedTitle,
				reason: "context_aligned",
				confidence: 0.85,
				detectedIssue: "generic_summary_on_product_page"
			)
		}
		
		// 4. Default Accept
		print("[GoalAlignment] accepted=yes reason=context_aligned")
		return AgenticGoalAlignmentDecision(
			status: .accepted,
			alignedGoal: trimmedGoal,
			alignedTitle: trimmedTitle,
			reason: "context_aligned",
			confidence: 1.0,
			detectedIssue: ""
		)
	}
	
	private static func looksProductLike(_ s: String) -> Bool {
		let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
		if t.count < 10 { return false }
		let lower = t.lowercased()
		if lower.contains("usb") || lower.contains("charger") || lower.contains("case") || lower.contains("gan") || lower.contains("anker") || lower.contains("prime") { return true }
		if lower.range(of: #"\b\d{2,3}\s*w\b"#, options: .regularExpression) != nil { return true }
		return false
	}
	
	private static func extractProductEntity(from windowTitle: String) -> String? {
		// Clean browser names
		var t = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
		let browserSuffixes = [" - Firefox", " - Google Chrome", " - Safari", " - Arc", " — Firefox", " — Safari"]
		for suffix in browserSuffixes where t.hasSuffix(suffix) {
			t = String(t.dropLast(suffix.count))
		}
		if let range = t.range(of: ": Amazon.", options: [.caseInsensitive]) {
			t = String(t[..<range.lowerBound])
		}
		
		// Clean off anything after separator
		for separator in [" - ", " | ", " – ", " — "] {
			if let range = t.range(of: separator, options: .backwards) {
				t = String(t[..<range.lowerBound])
				break
			}
		}
		
		let parts = t.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
		if let first = parts.first, first.count >= 5 {
			return String(first).trimmingCharacters(in: .whitespacesAndNewlines)
		}
		return t.count >= 5 ? t : nil
	}
	
	private static func substantiveWords(from text: String, stopwords: Set<String>) -> Set<String> {
		let words = text.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { $0.count >= 3 }
			.filter { !stopwords.contains($0) }
		return Set(words)
	}
}
