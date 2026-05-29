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
		if AgenticPivot.useDirectAgentRuntime {
			return AgenticGoalAlignmentDecision(
				status: .accepted,
				alignedGoal: goal,
				alignedTitle: title,
				reason: "direct_agent_runtime_bypass",
				confidence: 1.0,
				detectedIssue: ""
			)
		}
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
		
		// Phase 4U — Compare-on-single-product pivot.
		// When the goal is a compare-family goal but the active context has at
		// most one live grounded product candidate, repair to an extract goal.
		// The ComparePivotGate is purely deterministic; it never invents a
		// product title — it transforms whatever the planner already wrote.
		let lowerCompareGoal = lowerGoal
		let isCompareGoal = lowerCompareGoal.contains("compare")
			|| lowerCompareGoal.contains("comparison")
			|| lowerCompareGoal.contains(" vs ")
			|| lowerCompareGoal.contains(" versus ")
		if isCompareGoal {
			// Live grounded candidate count = distinct product-title entities in
			// the supplied evidence + heading entities + non-history observations.
			var distinct = Set<String>()
			for e in semanticEntities where e.type == .productTitle || e.type == .heading {
				let t = e.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
				if !t.isEmpty { distinct.insert(t) }
			}
			for o in evidenceObservations where (o.kind == .productTitle || o.kind == .comparisonCandidate) && o.source != .browsingHistory {
				let t = o.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
				if !t.isEmpty { distinct.insert(t) }
			}
			// Fallback: infer distinct candidates directly from window title / OCR
			// when semantic entities are not available at proposal time.
			if distinct.isEmpty {
				if let entity = extractProductEntity(from: windowTitle) {
					let t = entity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
					if !t.isEmpty { distinct.insert(t) }
				}
				if let ocr = ocrExcerpt {
					for candidate in extractTitleLikeCandidates(from: ocr) {
						let t = candidate.lowercased()
						if !t.isEmpty { distinct.insert(t) }
						if distinct.count >= 3 { break }
					}
				}
			}
			let pivot = ComparePivotGate.evaluate(goal: trimmedGoal, liveGroundedCandidateCount: distinct.count)
			if pivot.shouldPivot {
				ComparePivotGate.log(decision: pivot)
				print("[GoalAlignment] accepted=no reason=compare_single_product_pivot original=\"\(trimmedGoal)\" live_candidates=\(distinct.count)")
				let repairedTitle = ComparePivotGate.repairTitle(originalTitle: trimmedTitle)
				return AgenticGoalAlignmentDecision(
					status: .repaired,
					alignedGoal: pivot.repairedGoal,
					alignedTitle: repairedTitle,
					reason: "compare_to_extract_pivot",
					confidence: 0.92,
					detectedIssue: pivot.reason
				)
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

	/// Extract up to a few title-like candidates from an OCR excerpt.
	///
	/// Conservative: it is used ONLY to decide whether a compare goal has
	/// two or more live candidates. It prefers longer noun-phrase-like lines
	/// and rejects obvious chrome / navigation / call-to-action snippets.
	private static func extractTitleLikeCandidates(from ocr: String) -> [String] {
		let lower = ocr.lowercased()
		let deny: [String] = [
			"add to cart", "buy now", "in stock", "customer reviews",
			"verified purchase", "return policy", "shipping", "checkout",
			"sign in", "log in", "password",
		]
		// Split by newlines first; OCR excerpts usually preserve line structure.
		let rawLines = lower
			.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
			.map { String($0) }
		
		var out: [String] = []
		for raw in rawLines {
			let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
			guard line.count >= 18, line.count <= 140 else { continue }
			if deny.contains(where: { line.contains($0) }) { continue }
			// Require at least 4 substantive tokens to avoid counting “about this item”.
			let tokens = line.split(separator: " ").map(String.init)
			let substantive = tokens.filter { $0.count >= 4 && $0.rangeOfCharacter(from: .letters) != nil }
			guard substantive.count >= 4 else { continue }
			// Prefer the cleaned leading entity from the line.
			let cleaned = extractProductEntity(from: line) ?? line
			let synthesized = ProductTitleSynthesizer.synthesize(raw: cleaned).cleanedTitle
			let candidate = (synthesized ?? cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
			if candidate.isEmpty { continue }
			out.append(candidate)
			if out.count >= 3 { break }
		}
		return out
	}
	
	private static func substantiveWords(from text: String, stopwords: Set<String>) -> Set<String> {
		let words = text.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { $0.count >= 3 }
			.filter { !stopwords.contains($0) }
		return Set(words)
	}
}
