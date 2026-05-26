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
		// 1. Only consider upgrades when the model said "need more context"
		let normalizedDecision = modelDecision.lowercased().trimmingCharacters(in: .whitespaces)
		guard normalizedDecision == "need_more_context" || normalizedDecision == "insufficient_context" else {
			return RouterGroundingDecision(
				shouldUpgrade: false,
				reason: "model_decision_not_need_more_context",
				entityCount: 0,
				specCount: 0,
				ocrChars: ocrExcerpt?.count ?? 0,
				hasProductSignal: false
			)
		}

		// 2. Requested contexts must be redundant (or empty)
		let normalizedRequests = requestedContexts.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty && $0 != "none" }
		for req in normalizedRequests {
			let satisfied = isRequestSatisfied(
				request: req,
				ocrExcerpt: ocrExcerpt,
				hasVisualDescriptor: hasVisualDescriptor,
				hasAXText: hasAXText,
				selectedText: selectedText
			)
			if !satisfied {
				return RouterGroundingDecision(
					shouldUpgrade: false,
					reason: "outstanding_request:\(req)",
					entityCount: 0,
					specCount: 0,
					ocrChars: ocrExcerpt?.count ?? 0,
					hasProductSignal: false
				)
			}
		}

		// 3. Strong OCR or strong page signal
		let ocrChars = ocrExcerpt?.count ?? 0
		let titleLower = windowTitle.lowercased()
		let ocrLower = (ocrExcerpt ?? "").lowercased()
		let combined = titleLower + " " + ocrLower

		let hasProductSignal = productSignals.contains(where: { combined.contains($0) })
		let hasStrongOCR = ocrChars >= minOCRCharsForUpgrade

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
		return RouterGroundingDecision(
			shouldUpgrade: true,
			reason: "sufficient_grounded_context",
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
}
