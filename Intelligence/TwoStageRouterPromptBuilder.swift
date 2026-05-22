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

        // Single-line instruction + schema (compact).
        var lines: [String] = [
            #"JSON only. One object: {"decision":"enough_context","request":[],"reason":"brief","confidence":0.9}"#,
            #"request values: "ocr","visual_descriptor","ax_window_text". If decision=enough_context, request=[]."#,
            "enough_context: app+title are clear, OR selected/ocr/visual/ax is present. need_more_context: browser/media/game with no text. Never request context already present.",
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
