// TwoStageRouterPromptBuilder.swift
import Foundation

/// Dedicated prompt builder for the cheap router stage (qwen2.5:0.5b).
///
/// Kept aggressively compact (<700 bytes target) to minimize model prefill time.
/// The router only decides whether enough context exists for the planner —
/// it does NOT process content, does NOT see excerpts, does NOT run inference on page text.
///
/// Output schema (one JSON object):
/// {"decision":"enough_context","request":[],"reason":"brief","confidence":0.9}
struct TwoStageRouterPromptBuilder {
    static func build(
        snapshot: CanonicalGeneratedExecutionContextSnapshot,
        situational: SituationalContextSnapshot,
        recentTitles: [String],
        history: ProposalHistoryMetadata?,
        referenceTime: Date
    ) -> String {
        let app = compact(situational.activeAppName, 24)
        let title = compactTitle(situational.windowTitle, max: 60)
        let wf = situational.inferredWorkflow.rawValue

        let hasOCR = !(snapshot.recentOCRExcerpt ?? "").isEmpty
        let hasVisual = !(snapshot.visualContextAvailability.visualSummaryExcerpt ?? "").isEmpty
        let hasAX = snapshot.contextSummary?.contains("ax=") == true
        let hasSel = !(snapshot.selectedText ?? "").isEmpty
        let selLen = (snapshot.selectedText ?? "").count
        let hasClip = !(snapshot.clipboardText ?? "").isEmpty
        let clipLen = (snapshot.clipboardText ?? "").count

        // Compact task instruction
        var lines: [String] = [
            "Task: Decide if the provided context is sufficient to classify the user's intent.",
            "If app/title is clear, or ocr/visual/ax/sel is present -> enough_context.",
            "If blank browser/media/game with no text -> need_more_context.",
            "If need_more_context, you may request: ocr, visual_descriptor, ax_window_text.",
        ]

        // Compact context packet — flags only, no excerpts.
        var ctx: [String] = [
            "app=\(app)",
            "title=\(title)",
            "wf=\(wf)",
            "ocr=\(hasOCR ? "yes" : "no")",
            "visual=\(hasVisual ? "yes" : "no")",
            "ax=\(hasAX ? "yes" : "no")",
        ]
        if hasSel { ctx.append("sel_len=\(selLen)") } else { ctx.append("sel=no") }
        if hasClip { ctx.append("clip_len=\(clipLen)") } else { ctx.append("clip=no") }

        lines.append("ctx " + ctx.joined(separator: " "))
        return lines.joined(separator: "\n")
    }

    private static func compact(_ s: String, _ limit: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= limit ? t : String(t.prefix(limit))
    }

    private static func compactTitle(_ s: String, max limit: Int) -> String {
        // Lowercase, strip separators, collapse whitespace, cap.
        let lower = s.lowercased()
        let stripped = lower.replacingOccurrences(of: #"[\|\-–—•·]+"#, with: " ", options: .regularExpression)
        let collapsed = stripped.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return compact(collapsed, limit)
    }
}
