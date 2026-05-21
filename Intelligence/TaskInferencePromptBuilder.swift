import Foundation

/// Builds ultra-compact task inference prompts for the local model hot path.
///
/// Design goals:
/// - Typical prompt ≤ 450 bytes
/// - Hard max ≤ 700 bytes
/// - Schema-only instructions — NO concrete example values that the model can echo
/// - Hook list is context-filtered (4–8 IDs, not all 50+)
/// - need[] field enables model-requested context escalation (Part A)
enum TaskInferencePromptBuilder {
	static let targetPromptBytes = 450
	static let hardMaxPromptBytes = 700

	static func build(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		recentTitles: [String],
		history: ProposalHistoryMetadata?,
		registry: HookCapabilityRegistry = .shared,
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

		let hookIds = contextFilteredHooks(
			situational: situational,
			snapshot: snapshot,
			registry: registry
		)
		let hooksLine = hookIds.joined(separator: ",")

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
		// Keep instructions schema-only and extremely compact; ground outputs in ctx words.
		let needAllowed = "visible_ocr,ax_window_text,browser_text,selected_text,recent_titles,clipboard_if_relevant,visual_descriptor"
		var lines: [String] = [
			"JSON only. No prose.",
			"keys=c,g,a,o,h,q,p,need,needReason",
			"c=1: q/g/o must use ctx words (title/app/sel/ocr).",
			"c=0: stay quiet OR request context via need (subset: [\(needAllowed)]).",
			"h must be JSON array; ids must be in allow_h.",
			"allow_h=[\(hooksLine)]",
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

	// MARK: - Context-filtered hook selection

	/// Returns 4–8 hook IDs relevant to the current context signals.
	private static func contextFilteredHooks(
		situational: SituationalContextSnapshot,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		registry: HookCapabilityRegistry
	) -> [String] {
		var ids: [String] = ["observe_current_context"]

		let cat = situational.appCategory
		let wf = situational.inferredWorkflow
		let hasOCR = situational.ocrSignal.availability == .available
		let hasSel = situational.selectedTextSignal.availability == .available
		let hasText = hasOCR || hasSel
			|| (situational.clipboardSignal.availability == .available && situational.clipboardSignal.canBePrimary)

		// Error / debugging
		let hasErrorSignal = wf == .debugging
			|| (snapshot.recentOCRExcerpt ?? "").lowercased().contains("error")
			|| (snapshot.selectedText ?? "").lowercased().contains("error")
		if hasErrorSignal {
			ids += ["explain_visible_error", "extract_error_messages", "inspect_stacktrace"]
		}

		// Browser / product / research
		let isBrowser = cat == .browser || wf == .browsing || wf == .research
		if isBrowser {
			ids += ["extract_product_attributes", "extract_entities", "compare_items",
					"summarize_context", "synthesize_research_takeaways"]
		}

		// IDE / code
		if cat == .ide {
			ids += ["extract_code_symbols", "extract_error_messages", "summarize_context"]
		}

		// Notes / writing
		if cat == .notes || wf == .writing || wf == .editing {
			ids += ["extract_entities", "structure_key_points", "generate_checklist",
					"summarize_context"]
		}

		// Text present — general text ops
		if hasText && !ids.contains("summarize_context") {
			ids += ["summarize_context", "extract_entities", "structure_key_points"]
		}

		// Visual (OCR available)
		if hasOCR && !ids.contains("run_ocr_once") { ids.append("run_ocr_once") }

		ids.append("present_result")

		var seen: Set<String> = []
		let unique = ids.filter { seen.insert($0).inserted }
		let validated = unique.filter { registry.definition(for: $0) != nil || $0 == "present_result" }
		return Array(validated.prefix(10))
	}

	// MARK: - Retry prompt (strict JSON-only correction)

	/// Ultra-short correction prompt sent once when the model outputs bad values.
	/// STRICT: JSON only — no prose allowed. Low token budget stops generation quickly.
	/// The prompt explicitly names the actual context so the model has words to use.
	static func buildRetryPrompt(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		hookIds: [String],
		retryReason: String,
		invalidFields: [String]
	) -> String {
		let title = compactTitle(situational.windowTitle, max: 60)
		let app = compact(situational.activeAppName, 20)
		let hooksLine = hookIds.prefix(5).joined(separator: ",")

		// Include a short content excerpt so the model has words to use in q.
		var contentHint = ""
		if let sel = snapshot.selectedText, !sel.isEmpty {
			contentHint = " sel=\(compact(sel, 60))"
		} else if let ocr = snapshot.recentOCRExcerpt, !ocr.isEmpty {
			contentHint = " ocr=\(compact(ocr, 80))"
		}

		let invalid = invalidFields.isEmpty ? "q,g,a,o,h" : invalidFields.joined(separator: ",")
		var parts: [String] = [
			"JSON only. No text outside JSON.",
			"Fix invalid fields: [\(invalid)]. reason=\(retryReason).",
			"keys=c,g,a,o,h,q,p,need,needReason",
			"q/g/o must use ctx words: title=\"\(title)\" app=\(app)\(contentHint)",
		]
		if !hooksLine.isEmpty {
			parts.append("h from: [\(hooksLine)]")
		}
		// End with schema reminder only (no examples).
		parts.append("Output JSON object now:")
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
