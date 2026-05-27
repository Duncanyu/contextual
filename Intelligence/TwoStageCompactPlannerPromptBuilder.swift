// TwoStageCompactPlannerPromptBuilder.swift
import Foundation

/// Dedicated prompt builder for the compact planner stage (phi4-mini).
///
/// Output format is enforced by Ollama's schema-constrained decoding (format: {JSON Schema}).
/// The prompt provides BEHAVIORAL guidance only — no JSON template, no code fences,
/// no examples (those add prefill bytes and are redundant with constrained decoding).
///
/// Required output fields (enforced by schema): candidate_action_title, suggested_hooks,
/// confidence, should_surface_softly.
/// Optional output fields (parser has safe defaults): inferred_activity, evidence, required_context.
struct TwoStageCompactPlannerPromptBuilder {
    /// Phase 4Q — when `strict=true` the prompt prepends an explicit runtime
    /// capability fence: enumerated forbidden verbs + allowed intents. Used by
    /// the second planner attempt when the first attempt produced only
    /// out-of-envelope candidates (purchase / wishlist / cart / search-amazon /
    /// navigate). No canned title examples — just vocabulary boundaries.
    static func build(
        snapshot: CanonicalGeneratedExecutionContextSnapshot,
        situational: SituationalContextSnapshot,
        recentTitles: [String],
        history: ProposalHistoryMetadata?,
        referenceTime: Date,
        comparisonHint: String? = nil,
        strict: Bool = false
    ) -> String {
        let app = compact(situational.activeAppName, 28)
        let title = compactTitle(situational.windowTitle, max: 80)
        let recent = recentTitleLine(recentTitles)
        let wf = situational.inferredWorkflow.rawValue
        let cat = situational.appCategory.rawValue

        let hasOCR = snapshot.recentOCRExcerpt != nil && !snapshot.recentOCRExcerpt!.isEmpty
        let hasVisual = snapshot.visualContextAvailability.visualSummaryExcerpt != nil && !snapshot.visualContextAvailability.visualSummaryExcerpt!.isEmpty
        let hasAX = snapshot.contextSummary?.contains("ax=") == true
        let hasSel = snapshot.selectedText != nil && !snapshot.selectedText!.isEmpty
        let hasClip = snapshot.clipboardText != nil && !snapshot.clipboardText!.isEmpty

        let visualExcerpt = snapshot.visualContextAvailability.visualSummaryExcerpt ?? ""
        let visualAgeMs: Int
        if let capturedAt = snapshot.visualContextAvailability.visualCapturedAt {
            visualAgeMs = Int(referenceTime.timeIntervalSince(capturedAt) * 1000)
        } else {
            visualAgeMs = -1
        }
        let visualConf = hasVisual ? 0.95 : 0.0

        let ocrExcerpt = snapshot.recentOCRExcerpt ?? ""
        let ocrAgeMs: Int
        if let capturedAt = snapshot.sourceMetadata.ocrCapturedAt {
            ocrAgeMs = Int(referenceTime.timeIntervalSince(capturedAt) * 1000)
        } else {
            ocrAgeMs = -1
        }
        let ocrConf = hasOCR ? 0.95 : 0.0

        var axExcerpt = ""
        if let summary = snapshot.contextSummary, let range = summary.range(of: "ax=") {
            axExcerpt = String(summary[range.upperBound...])
        }

        var excerptLines: [String] = []
        if hasSel, let sel = snapshot.selectedText, !sel.isEmpty {
            excerptLines.append("selected_text=\(compact(sel, 150))")
        }
        if hasOCR, !ocrExcerpt.isEmpty {
            excerptLines.append("ocr_excerpt=\(compact(ocrExcerpt, 250))")
        }
        if hasVisual, !visualExcerpt.isEmpty {
            excerptLines.append("visual_descriptor_excerpt=\(compact(visualExcerpt, 180))")
        }
        if hasAX, !axExcerpt.isEmpty {
            excerptLines.append("ax_window_excerpt=\(compact(axExcerpt, 180))")
        }
        if hasClip, let clip = snapshot.clipboardText, !clip.isEmpty {
            excerptLines.append("clipboard_excerpt=\(compact(clip, 120))")
        }

        let needCatsAllowed = "context,extract,reason,output,compare,organize,debug,study"

        // Multi-candidate behavioral instructions. Format enforced by JSON schema (actions array).
        // Runtime Capability Package:
        // - Allowed primitives: observe_once, extract_facts, find_on_page, scroll_small, summarize_observation, present_answer
        // - Disallowed: clicks, typing, purchases, navigation, authentication, form filling, destructive actions
        // Constraints:
        // - Proposal title must be naturally phrased, contextually grounded, and executable using only allowed primitives.
        // - Propose active, varied titles. Avoid generic, repetitive phrasing; titles must
        //   be grounded in specific nouns/entities present in the current context.
        // - Inferno/usefulness must be derived naturally from the context and available primitives.
        var lines: [String] = []
        if strict {
            // Phase 4Q — capability envelope fence. No example titles, no JSON
            // templates — vocabulary boundaries only, so the model has to write
            // its own phrasing without being constrained to canned forms.
            lines.append("CAPABILITY ENVELOPE (strict). The assistant can ONLY execute these operations on the currently visible page: inspect, extract, summarize, compare, identify-missing-information, gather-more-visible-evidence (via find_on_page or scroll_small).")
            lines.append("FORBIDDEN verbs and intents (never propose): purchase, buy, order, checkout, cart, basket, wishlist, login, sign in, sign up, install, delete, remove, search-amazon, search-the-web, open-page, navigate, switch-tab, click, type, fill form.")
            lines.append("Titles MUST describe what the assistant will read/extract/compare on THIS visible page. Do not propose actions the user would do themselves elsewhere.")
        }
        lines.append(contentsOf: [
            "Produce 2-3 ranked action candidates for the user's current activity. Best/most-specific first.",
            // Phase 4R — ordering pressure. Even when streaming output truncates,
            // the safe inspect/extract/summarize actions are at the top of the
            // array, so the salvage path always sees them first.
            "Return the safest executable visible-page actions first (inspect/extract/summarize before any other category).",
            "Do NOT copy the window title verbatim as the action title; the title must describe what the assistant will do on the visible context.",
            "Each action: title (≤10 words, user-centric, active operation grounded in current context), caps (from: \(needCatsAllowed)), confidence (0-1), novelty (0-1 how page-specific), requires (data needed).",
            "should_surface_softly=true when context is actionable: product/shopping/search/code/clipboard/OCR.",
        ])

        var ctxParts: [String] = []
        ctxParts.append("app=\(app)")
        ctxParts.append("title=\(title)")
        if !recent.isEmpty { ctxParts.append("recent=\(recent)") }
        if let hint = comparisonHint, !hint.isEmpty { ctxParts.append(hint) }
        ctxParts.append("wf=\(wf)")
        ctxParts.append("cat=\(cat)")
        ctxParts.append("ocr_avail=\(hasOCR ? "yes" : "no")")
        if hasOCR {
            ctxParts.append("ocr_confidence=\(ocrConf)")
            ctxParts.append("ocr_age_ms=\(ocrAgeMs)")
        }
        ctxParts.append("visual_descriptor_available=\(hasVisual ? "yes" : "no")")
        if hasVisual {
            ctxParts.append("visual_descriptor_confidence=\(visualConf)")
            ctxParts.append("visual_descriptor_age_ms=\(visualAgeMs)")
        }
        ctxParts.append("ax_avail=\(hasAX ? "yes" : "no")")
        ctxParts.append("sel=\(hasSel ? "1" : "0")")
        ctxParts.append("clip=\(hasClip ? "1" : "0")")
        lines.append("ctx " + ctxParts.joined(separator: " "))

        for ex in excerptLines { lines.append(ex) }

        return lines.joined(separator: "\n")
    }

    private static func compact(_ s: String, _ limit: Int) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit))
    }

    private static func compactTitle(_ s: String, max: Int) -> String {
        let lower = s.lowercased()
        let trimmed = lower.replacingOccurrences(of: #"[\|\-–—•]+"#, with: " ", options: .regularExpression)
        let collapsed = trimmed.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return compact(collapsed, max)
    }

    private static func recentTitleLine(_ titles: [String]) -> String {
        let joined = titles.prefix(3).map { $0.lowercased() }.joined(separator: "|")
        return compact(joined, 120)
    }
}
