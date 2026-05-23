import Foundation

/// Builds ultra-compact task inference prompts for the local model hot path.
///
/// Design goals:
/// - Typical prompt ≤ 450 bytes
/// - Hard max ≤ 700 bytes
/// - Schema-only instructions — NO concrete example values that the model can echo
/// - need[] field enables model-requested context escalation (Part A)
enum TaskInferencePromptBuilder {
	static let targetPromptBytes = 450
	static let hardMaxPromptBytes = 700

	static func build(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		recentTitles: [String],
		history: ProposalHistoryMetadata?,
		referenceTime: Date = Date()
	) -> String {
		let app = compact(situational.activeAppName, 28)
		let title = compactTitle(situational.windowTitle, max: 80)
		let recent = recentTitleLine(recentTitles)
		let wf = situational.inferredWorkflow.rawValue
		let cat = situational.appCategory.rawValue

		let hasOCR = situational.ocrSignal.availability == .available
		let hasSel = situational.selectedTextSignal.availability == .available
		let hasClip = situational.clipboardSignal.availability == .available && situational.clipboardSignal.canBePrimary

		let ocrFlag = hasOCR ? "1" : "0"
		let selFlag = hasSel ? "1" : "0"
		let clipFlag = hasClip ? "1" : "0"

		// Content excerpts (only when present — no placeholders)
		var excerptLines: [String] = []
		if hasSel, let sel = snapshot.selectedText, !sel.isEmpty {
			excerptLines.append("sel=\(compact(sel, 100))")
		} else if hasOCR, let ocr = snapshot.recentOCRExcerpt, !ocr.isEmpty {
			excerptLines.append("ocr=\(compact(ocr, 120))")
		}
		// AX window text excerpt, if present in the snapshot summary (context escalation).
		if let summary = snapshot.contextSummary,
		   let r = summary.range(of: "ax=")
		{
			let after = String(summary[r.upperBound...])
			if !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				excerptLines.append("ax=\(compact(after, 180))")
			}
		}
		if hasClip, let clip = snapshot.clipboardText, !clip.isEmpty,
		   situational.clipboardSignal.relevance == .high
		{
			excerptLines.append("clip=\(compact(clip, 80))")
		}

		// Recent proposals (avoid repeating same task)
		let recentProps = history?.recentProposalTitles
			.prefix(3)
			.map { compact($0, 40) }
			.joined(separator: "|") ?? ""

		// IMPORTANT: Never include concrete example values (specific goals/questions).
		// Concrete examples cause small models to copy them verbatim (example leakage).
		//
		// Contract: qwen outputs ONLY goal + capability categories (no hook IDs).
		let needAllowed = "visible_ocr,ax_window_text,browser_text,selected_text,recent_titles,clipboard_if_relevant,visual_descriptor"
		let needCatsAllowed = "context,extract,reason,output,compare,organize,debug,study"
		var lines: [String] = [
			"Task: Infer the user's current goal based on context.",
			"c=1 if goal can be inferred; c=0 if context is noisy/unclear.",
			"If c=1, goal must use exact words from context (title/app/sel/ocr).",
			"Available needCats: [\(needCatsAllowed)].",
			"If c=0, optionally request more context using 'need' from: [\(needAllowed)].",
		]

		// Single-line feature packet (real values only; no placeholders).
		var ctxParts: [String] = []
		ctxParts.append("app=\(app)")
		ctxParts.append("title=\(title)")
		if !recent.isEmpty { ctxParts.append("recent=\(recent)") }
		ctxParts.append("wf=\(wf)")
		ctxParts.append("cat=\(cat)")
		ctxParts.append("ocr=\(ocrFlag)")
		ctxParts.append("sel=\(selFlag)")
		ctxParts.append("clip=\(clipFlag)")
		if !recentProps.isEmpty { ctxParts.append("prev=\(recentProps)") }
		lines.append("ctx " + ctxParts.joined(separator: " "))

		// Optional bounded content hints (only when present; never placeholders).
		for ex in excerptLines { lines.append(ex) }

		let prompt = lines.joined(separator: "\n")

		if prompt.utf8.count <= hardMaxPromptBytes { return prompt }
		return String(prompt.prefix(hardMaxPromptBytes))
	}

	// MARK: - Retry prompt (strict JSON-only correction)

	/// Ultra-short correction prompt sent once when the model outputs bad values.
	/// STRICT: JSON only — no prose allowed. Low token budget stops generation quickly.
	/// The prompt explicitly names the actual context so the model has words to use.
	static func buildRetryPrompt(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		retryReason: String,
		invalidFields: [String]
	) -> String {
		let title = compactTitle(situational.windowTitle, max: 60)
		let app = compact(situational.activeAppName, 20)
		// Include a short content excerpt so the model has words to use in q.
		var contentHint = ""
		if let sel = snapshot.selectedText, !sel.isEmpty {
			contentHint = " sel=\(compact(sel, 60))"
		} else if let ocr = snapshot.recentOCRExcerpt, !ocr.isEmpty {
			contentHint = " ocr=\(compact(ocr, 80))"
		}

		let invalid = invalidFields.isEmpty ? "g,needCats" : invalidFields.joined(separator: ",")
		var parts: [String] = [
			"Task: Fix the invalid fields: [\(invalid)]. reason=\(retryReason).",
			"The goal (g) must use words from: title=\"\(title)\" app=\(app)\(contentHint)"
		]
		return parts.joined(separator: "\n")
	}

	// MARK: - Text helpers

	private static func compact(_ s: String, _ max: Int) -> String {
		let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
		if t.isEmpty { return "" }
		let single = t.replacingOccurrences(of: "\n", with: " ")
		let collapsed = single.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
		return String(collapsed.prefix(max))
	}

	private static func compactTitle(_ s: String, max: Int) -> String {
		var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
		for suffix in [" - Google Chrome", " - Safari", " - Firefox", " — Mozilla Firefox"] {
			if t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
		}
		return compact(t, max)
	}

	private static func recentTitleLine(_ titles: [String]) -> String {
		let normalized = titles
			.suffix(4)
			.map { compact($0, 40) }
			.filter { !$0.isEmpty }
		return normalized.joined(separator: "|")
	}
}
