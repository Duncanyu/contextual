import Foundation

// MARK: - Observation Quality

/// How much usable page content was captured in one observation.
///
/// Only `selectedText` and `ocrExcerpt` count as real page content.
/// `contextSummary` is pipeline-generated metadata — it describes the *situation*,
/// not the page's actual text. Clipboard is always excluded from agentic runtime
/// observations (transient, potentially sensitive, unrelated to current page).
///
/// Used by `AgenticDecider` to prefer controlled page acquisition
/// (find_on_page / scroll_small) over premature fact extraction when the context
/// is too weak to yield goal-relevant facts.
enum AgenticObservationQuality: String, Sendable, Equatable, Comparable {
	/// Only app/window title — no context summary, no page text.
	case metadata_only
	/// Has a pipeline-generated context summary but no real page text (no OCR, no selected text).
	case weak
	/// Real page text exists (selectedText or ocrExcerpt) but no goal-relevant terms detected.
	case usable
	/// Real page text exists and contains goal-relevant terms.
	case rich

	static func < (lhs: AgenticObservationQuality, rhs: AgenticObservationQuality) -> Bool {
		let order: [AgenticObservationQuality] = [.metadata_only, .weak, .usable, .rich]
		guard let li = order.firstIndex(of: lhs), let ri = order.firstIndex(of: rhs) else { return false }
		return li < ri
	}

	var requiresControlForBrowserGoal: Bool {
		self == .metadata_only || self == .weak
	}
}

// MARK: - Observation

/// A single agentic observation captured at one step of the Phase 4D loop.
///
/// **Clipboard is always excluded.** Clipboard text is transient, potentially sensitive,
/// and usually unrelated to the page being examined. Including it inflated
/// `hasUsableContent`, causing the decider to skip controlled page acquisition
/// and extract facts from irrelevant clipboard data.
///
/// **`contextSummary` is metadata, not page content.** It is stored for reference
/// but does NOT contribute to `hasUsableContent` or `contentLength`.
/// Only `selectedText` and `ocrExcerpt` represent real page content.
struct AgenticObservation: Sendable, Equatable {
	let stepIndex: Int
	let activeApp: String
	let windowTitle: String
	/// Pipeline-generated context summary (metadata — NOT page content).
	let contextSummary: String?
	/// User-selected text on the page (real page content).
	let selectedText: String?
	/// OCR excerpt from the screen (real page content).
	let ocrExcerpt: String?
	let quality: AgenticObservationQuality
	let freshnessScore: Double
	let observedAt: Date
	/// Which snapshot fields contributed content.
	let sources: [String]
	/// True when this observation was forced after a controlled interaction
	/// (scroll_small / find_on_page).
	let isPostControlObservation: Bool

	// MARK: - Identity / World-State Fields (Phase 4E)

	/// Unique ID for this observation event. Each observe step gets a new UUID.
	let snapshotID: UUID
	/// The snapshotID of the preceding observation (nil for the first).
	/// Used to chain observations for delta tracking.
	let previousSnapshotID: UUID?
	/// DJB2 hash of all visible text (OCR + selectedText). nil if no text present.
	/// Compared against the previous observation's hash to detect world-state change.
	let textHash: String?

	/// True only when real page text exists (selectedText or ocrExcerpt).
	/// contextSummary is metadata and does NOT make an observation "usable."
	var hasUsableContent: Bool {
		selectedText != nil || ocrExcerpt != nil
	}

	/// Character count of real page text only.
	var contentLength: Int {
		(selectedText?.count ?? 0) + (ocrExcerpt?.count ?? 0)
	}
}

// MARK: - Observer

/// Bounded observer for the Phase 4D agentic loop.
///
/// Reads from the `CanonicalGeneratedExecutionContextSnapshot` captured at routing time.
///
/// Included sources:
///   - window_title (always)
///   - context_summary (metadata; included for reference but NOT counted as page content)
///   - selected_text (real page content — counts toward quality)
///   - ocr_excerpt (real page content — counts toward quality; budget-gated)
///
/// Excluded:
///   - clipboard (always excluded; transient and unrelated to page being examined)
struct AgenticObserver: Sendable {

	func observe(
		stepIndex: Int,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		ocrCallsUsed: Int,
		ocrCallsBudget: Int,
		isPostControl: Bool = false,
		goal: String = "",
		previousSnapshotID: UUID? = nil
	) -> AgenticObservation {
		print("[AgenticObserve] started step=\(stepIndex) app=\(snapshot.activeApp.prefix(30)) freshness=\(String(format: "%.2f", snapshot.freshnessScore)) post_control=\(isPostControl)")

		if isPostControl {
			print("[AgenticObserve] fresh_capture_requested=yes stale_snapshot_reuse=yes reason=fresh_capture_not_implemented_in_phase_4D")
		}

		var sources: [String] = ["window_title"]

		// Context summary: metadata only — included for reference, NOT page content
		let contextSummary = snapshot.contextSummary
		if contextSummary != nil { sources.append("context_summary") }

		// Selected text: real page content
		let selectedText = snapshot.selectedText
		if selectedText != nil { sources.append("selected_text") }

		// Clipboard: ALWAYS excluded from agentic runtime observations
		if snapshot.clipboardText != nil {
			print("[AgenticObserve] clipboard_ignored=yes reason=agentic_runtime_transient_suppression")
		}

		// OCR: real page content — budget-gated
		let ocrExcerpt: String?
		if ocrCallsUsed < ocrCallsBudget, let ocr = snapshot.recentOCRExcerpt, !ocr.isEmpty {
			ocrExcerpt = ocr
			sources.append("ocr_excerpt")
			print("[AgenticObserve] ocr_used step=\(stepIndex) calls_used=\(ocrCallsUsed + 1)/\(ocrCallsBudget) chars=\(ocr.count)")
		} else if ocrCallsUsed >= ocrCallsBudget {
			ocrExcerpt = nil
			print("[AgenticObserve] ocr_skipped reason=budget_exhausted step=\(stepIndex) used=\(ocrCallsUsed)/\(ocrCallsBudget)")
		} else {
			ocrExcerpt = nil
			print("[AgenticObserve] ocr_skipped reason=no_ocr_in_snapshot step=\(stepIndex)")
		}

		// Compute quality based only on real page content
		let quality = computeQuality(
			selectedText: selectedText,
			ocrExcerpt: ocrExcerpt,
			contextSummary: contextSummary,
			goal: goal
		)

		// Phase 4E: snapshot identity and text hash for world-state delta tracking
		let snapshotID = UUID()
		let textHash = AgenticPerceptionRefreshCoordinator.computeTextHash(
			ocr: ocrExcerpt,
			selectedText: selectedText
		)

		let obs = AgenticObservation(
			stepIndex: stepIndex,
			activeApp: snapshot.activeApp,
			windowTitle: snapshot.windowTitle,
			contextSummary: contextSummary,
			selectedText: selectedText,
			ocrExcerpt: ocrExcerpt,
			quality: quality,
			freshnessScore: snapshot.freshnessScore,
			observedAt: Date(),
			sources: sources,
			isPostControlObservation: isPostControl,
			snapshotID: snapshotID,
			previousSnapshotID: previousSnapshotID,
			textHash: textHash
		)

		print("[AgenticObserve] quality=\(quality.rawValue) reason=\(qualityReason(obs)) completed step=\(stepIndex) sources=\(sources.joined(separator: ",")) content_chars=\(obs.contentLength) has_usable=\(obs.hasUsableContent) snapshot_id=\(snapshotID.uuidString.prefix(8)) text_hash=\(textHash?.prefix(8) ?? "nil")")

		// Phase 4E: log quality transitions for post-control observations
		if isPostControl {
			print("[ObservationQuality] post_control quality=\(quality.rawValue)")
		}

		return obs
	}

	// MARK: - Quality Computation

	private func computeQuality(
		selectedText: String?,
		ocrExcerpt: String?,
		contextSummary: String?,
		goal: String
	) -> AgenticObservationQuality {
		let pageText = [selectedText, ocrExcerpt].compactMap { $0 }.joined(separator: " ")

		guard !pageText.isEmpty else {
			// No real page content at all
			return contextSummary != nil ? .weak : .metadata_only
		}

		// Real page text exists — check if goal-relevant
		let g = goal.lowercased()
		let relevantTerms: [String] = [
			"review", "rating", "star", "price", "cost", "$",
			"spec", "dimension", "compat", "battery", "feature",
			"warranty", "issue", "complaint", "color", "material", "weight"
		]
		let hasRelevantTerm = !g.isEmpty && relevantTerms.contains { pageText.lowercased().contains($0) || g.contains($0) && pageText.lowercased().contains($0.prefix(4)) }

		return hasRelevantTerm ? .rich : .usable
	}

	private func qualityReason(_ obs: AgenticObservation) -> String {
		switch obs.quality {
		case .metadata_only:
			return "no_page_text_no_context_summary"
		case .weak:
			return "context_summary_only_no_page_text"
		case .usable:
			return "page_text_exists_not_goal_relevant"
		case .rich:
			return "page_text_contains_goal_relevant_terms"
		}
	}
}
