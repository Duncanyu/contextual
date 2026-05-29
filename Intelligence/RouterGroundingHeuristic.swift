import Foundation

// MARK: - Outcome

/// Result of a single `RouterGroundingHeuristic` evaluation.
struct RouterGroundingDecision: Sendable, Equatable {
	let shouldUpgrade: Bool
	let reason: String
	let entityCount: Int
	let specCount: Int
	let ocrChars: Int
	let hasProductSignal: Bool
}

// MARK: - Heuristic

/// Phase 4R — Router grounding sufficiency upgrade.
///
/// The two-stage router runs phi4-mini and frequently returns
/// `decision=need_more_context` even when the snapshot already carries
/// concrete OCR + a strong page entity + a content-oriented workflow. Those
/// requests are usually for sources that are already present — escalating
/// burns latency and risks planner timeouts.
///
/// This pure heuristic inspects the snapshot/situational signals deterministically
/// and decides whether to upgrade `need_more_context → enough_context` *before*
/// planner escalation. It NEVER bypasses safety; only redundant context requests
/// are short-circuited.
enum RouterGroundingHeuristic {

	/// Minimum OCR length to qualify as a strong grounded page.
	static let minOCRCharsForUpgrade: Int = 200

	/// Minimum number of concrete entities (product/spec/price/rating tokens)
	/// to consider the page grounded.
	static let minEntityCountForUpgrade: Int = 2

	/// Generic product / page-signal tokens. Substring match in OCR + window title.
	/// Intentionally not exhaustive and not website-specific.
	private static let productSignals: [String] = [
		"customer reviews", "out of 5 stars", "out of 5", "in stock", "add to cart",
		"free shipping", "free returns", "price:", "specifications",
		"product details", "manufacturer", "model number",
	]

	/// Currency / price token regex.
	private static let pricePattern: String = #"\$\d+[\d,]*(\.\d{2})?"#
	/// Rating token regex.
	private static let ratingPattern: String = #"\d+(\.\d+)?\s*out of\s*5"#
	/// Spec-like tokens (wattage / mAh / inches / weight / dimensions).
	private static let specPattern: String = #"\b\d{2,4}\s*(w|wh|mah|kwh|gb|tb|mb|mm|cm|inch|in\b|kg|lb|lbs|oz)\b"#

	// MARK: - Evaluate

	/// Decide whether to upgrade the router's `need_more_context` decision.
	///
	/// Returns `shouldUpgrade=true` only when **all** of the following hold:
	///   1. Model decision is `need_more_context` (or equivalent).
	///   2. Requested contexts are EITHER empty OR exclusively redundant
	///      kinds (`ocr`, `visible_ocr`, `visual_descriptor`, `ax_window_text`,
	///      `browser_text`) that the snapshot already satisfies.
	///   3. OCR ≥ `minOCRCharsForUpgrade` chars OR window title contains a
	///      product-page signal.
	///   4. At least `minEntityCountForUpgrade` concrete entities are present
	///      across OCR + selectedText + window title (price / rating / spec
	///      tokens or known product-page phrases).
	///   5. Inferred workflow is content-oriented (browsing / shopping /
	///      reading / research / product / review).
	static func evaluate(
		modelDecision: String,
		requestedContexts: [String],
		windowTitle: String,
		appName: String,
		workflow: String,
		ocrExcerpt: String?,
		selectedText: String?,
		hasVisualDescriptor: Bool,
		hasAXText: Bool
	) -> RouterGroundingDecision {
		let normalizedDecision = modelDecision.lowercased().trimmingCharacters(in: .whitespaces)
		let normalizedRequests = requestedContexts.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty && $0 != "none" }

		// 1. Only consider upgrades when the model said "need more context"
		// OR when it incorrectly quieted because it wanted selected_text but found none.
		var isEligibleForUpgrade = normalizedDecision == "need_more_context" || normalizedDecision == "insufficient_context"
		if normalizedDecision == "quiet" && (normalizedRequests.contains("selected_text") || normalizedRequests.contains("selection")) {
			isEligibleForUpgrade = true
		}

		guard isEligibleForUpgrade else {
			return RouterGroundingDecision(
				shouldUpgrade: false,
				reason: "model_decision_not_need_more_context",
				entityCount: 0,
				specCount: 0,
				ocrChars: ocrExcerpt?.count ?? 0,
				hasProductSignal: false
			)
		}

		// 2. Requested contexts must be redundant (or empty).
		//
		// IMPORTANT: For strong grounded browsing contexts, `selected_text` is an
		// optional enhancement, not a hard requirement. The router often requests
		// selection even when OCR/title already provide sufficient grounding.
		var hasOutstandingOptionalSelection = false
		var hasOutstandingVisualDescriptorOverride = false

		let ocrChars = ocrExcerpt?.count ?? 0
		let titleLower = windowTitle.lowercased()
		let ocrLower = (ocrExcerpt ?? "").lowercased()
		let combined = titleLower + " " + ocrLower

		let hasProductSignal = productSignals.contains(where: { combined.contains($0) })
		let hasStrongOCR = ocrChars >= minOCRCharsForUpgrade
		let isActionWorthy = FastVisibilityQualityGate.isActionWorthy(title: windowTitle, appName: appName)

		for req in normalizedRequests {
			let satisfied = isRequestSatisfied(
				request: req,
				ocrExcerpt: ocrExcerpt,
				hasVisualDescriptor: hasVisualDescriptor,
				hasAXText: hasAXText,
				selectedText: selectedText
			)
			if !satisfied {
				// FIX 2: Strong OCR/AX/title context satisfies visual descriptor/snapshot and selection requests.
				// Condition: OCR exists (meaningful chars), AX or Product signal exists, and title is ActionWorthy.
				let strongGrounding = (ocrChars >= 100) && (hasAXText || hasProductSignal) && isActionWorthy
				if strongGrounding {
					if req == "selected_text" || req == "selection" {
						hasOutstandingOptionalSelection = true
						continue
					}
					if req == "visual_descriptor" || req == "visual_snapshot" {
						hasOutstandingVisualDescriptorOverride = true
						continue
					}
				}

				return RouterGroundingDecision(
					shouldUpgrade: false,
					reason: "outstanding_request:\(req)",
					entityCount: 0,
					specCount: 0,
					ocrChars: ocrChars,
					hasProductSignal: false
				)
			}
		}

		// 3. Strong OCR or strong page signal

		guard hasStrongOCR || hasProductSignal else {
			return RouterGroundingDecision(
				shouldUpgrade: false,
				reason: "no_strong_ocr_or_product_signal",
				entityCount: 0,
				specCount: 0,
				ocrChars: ocrChars,
				hasProductSignal: false
			)
		}

		// 4. Entity / spec presence
		let priceMatches = countMatches(pattern: pricePattern, in: combined)
		let ratingMatches = countMatches(pattern: ratingPattern, in: combined)
		let specMatches = countMatches(pattern: specPattern, in: combined)
		let productPhraseHits = productSignals.filter { combined.contains($0) }.count

		let entityCount = priceMatches + ratingMatches + specMatches + productPhraseHits
		var proposalRecoveryModeActive = isActionWorthy && hasStrongOCR
		if proposalRecoveryModeActive {
			let isStrong = isStrongActionablePageContext(title: windowTitle, appName: appName, ocrExcerpt: ocrExcerpt)
			if !isStrong {
				proposalRecoveryModeActive = false
				print("[ProposalRecoveryMode] active=no reason=weak_or_mixed_browser_context")
			}
		}

		if proposalRecoveryModeActive {
			print("[ProposalRecoveryMode] active=yes")
		} else {
			guard entityCount >= minEntityCountForUpgrade else {
				return RouterGroundingDecision(
					shouldUpgrade: false,
					reason: "insufficient_entity_count:\(entityCount)",
					entityCount: entityCount,
					specCount: specMatches,
					ocrChars: ocrChars,
					hasProductSignal: hasProductSignal
				)
			}
		}

		// 5. Workflow must be content-oriented
		let wfLower = workflow.lowercased()
		let contentWorkflows: Set<String> = [
			"browsing", "shopping", "reading", "research", "product", "review",
		]
		guard contentWorkflows.contains(wfLower) else {
			return RouterGroundingDecision(
				shouldUpgrade: false,
				reason: "workflow_not_content:\(wfLower)",
				entityCount: entityCount,
				specCount: specMatches,
				ocrChars: ocrChars,
				hasProductSignal: hasProductSignal
			)
		}

		_ = appName // accepted for future signal extension
		let finalReason: String = {
			if hasOutstandingVisualDescriptorOverride {
				return "strong_ocr_ax_title_satisfies_visual_descriptor"
			}
			if hasOutstandingOptionalSelection {
				return "sufficient_grounded_context_ignore_selection"
			}
			return "sufficient_grounded_context"
		}()

		return RouterGroundingDecision(
			shouldUpgrade: true,
			reason: finalReason,
			entityCount: entityCount,
			specCount: specMatches,
			ocrChars: ocrChars,
			hasProductSignal: hasProductSignal
		)
	}

	// MARK: - Logging

	/// Standard log emission for a decision. Caller may suppress when the
	/// decision is not interesting (e.g. model already said enough_context).
	static func log(decision: RouterGroundingDecision) {
		let sufficient = decision.shouldUpgrade ? "yes" : "no"
		print("[RouterGrounding] sufficient_context=\(sufficient) reason=\(decision.reason)")
		print("[RouterGrounding] entities=\(decision.entityCount) specs=\(decision.specCount) ocr_chars=\(decision.ocrChars) product_signal=\(decision.hasProductSignal ? "yes" : "no")")
	}

	// MARK: - Internals

	private static func isRequestSatisfied(
		request: String,
		ocrExcerpt: String?,
		hasVisualDescriptor: Bool,
		hasAXText: Bool,
		selectedText: String?
	) -> Bool {
		switch request {
		case "ocr", "visible_ocr":
			return (ocrExcerpt?.isEmpty == false)
		case "visual_descriptor":
			return hasVisualDescriptor
		case "ax_window_text", "browser_text":
			return hasAXText
		case "window_title":
			// Always present in the situational snapshot; never worth escalating for.
			return true
		case "selected_text":
			return (selectedText?.isEmpty == false)
		default:
			// Unknown / non-redundant request → not satisfied (caller bails out).
			return false
		}
	}

	private static func countMatches(pattern: String, in text: String) -> Int {
		guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
			return 0
		}
		let range = NSRange(text.startIndex..<text.endIndex, in: text)
		return regex.numberOfMatches(in: text, options: [], range: range)
	}

	static func isStrongActionablePageContext(title: String, appName: String, ocrExcerpt: String?) -> Bool {
		let lowerTitle = title.lowercased()
		let ocrLower = (ocrExcerpt ?? "").lowercased()
		let combined = lowerTitle + " " + ocrLower

		// 1. Explicitly check Do Not Activate rules
		
		// - user profile pages
		if lowerTitle.contains("user profile") || lowerTitle.contains("profile page") || lowerTitle.contains("/u/") || lowerTitle.contains("reddit.com/user/") {
			return false
		}
		// - generic Reddit home / verification pages
		if lowerTitle.contains("reddit.com/verify") || lowerTitle.contains("verification") || lowerTitle.contains("reddit: the front page") || lowerTitle == "reddit" || lowerTitle.contains("reddit.com/r/all") || lowerTitle.contains("log in to reddit") {
			return false
		}
		// - title-only Reddit pages (e.g. page title contains "reddit" but OCR is < 80 characters)
		if lowerTitle.contains("reddit") {
			let isPostOrThread = lowerTitle.contains("post") || lowerTitle.contains("thread") || lowerTitle.contains("comments")
			if ocrLower.count < 80 && !isPostOrThread {
				return false
			}
		}
		// - mixed tab-strip OCR (e.g. contains both reddit and amazon/anker specs)
		let hasReddit = combined.contains("reddit")
		let hasAnkerOrAmazon = combined.contains("anker") || combined.contains("amazon")
		if hasReddit && hasAnkerOrAmazon {
			return false
		}

		// 2. Identify positive actionable page types
		let hasProductIndicator = combined.contains("amazon") || combined.contains("anker") || combined.contains("charger") || combined.contains("hub") || combined.contains("price:") || combined.contains("customer reviews") || combined.contains("stars") || combined.contains("specs") || combined.contains("specification")
		let hasArticleIndicator = combined.contains("wiki") || combined.contains("article") || combined.contains("document") || combined.contains("pdf") || combined.contains("blog") || combined.contains("news") || combined.contains("post") || combined.contains("thread")
		let hasCodeIndicator = lowerTitle.contains(".swift") || lowerTitle.contains(".py") || lowerTitle.contains(".js") || lowerTitle.contains(".json") || lowerTitle.contains(".md") || combined.contains("github") || combined.contains("xcode") || combined.contains("code") || combined.contains("debug") || combined.contains("repository")
		
		return hasProductIndicator || hasArticleIndicator || hasCodeIndicator
	}
}
