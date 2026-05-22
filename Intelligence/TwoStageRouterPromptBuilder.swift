// TwoStageRouterPromptBuilder.swift
import Foundation

/// Dedicated prompt builder for the cheap router stage (qwen2.5:0.5b).
/// Outputs the exact requested schema:
/// {"decision":"need_more_context/enough_context","request":["ocr","visual_descriptor"],"reason":"brief explanation","confidence":0.9}
struct TwoStageRouterPromptBuilder {
    static func build(
        snapshot: CanonicalGeneratedExecutionContextSnapshot,
        situational: SituationalContextSnapshot,
        recentTitles: [String],
        history: ProposalHistoryMetadata?,
        referenceTime: Date
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
            excerptLines.append("selected_text=\(compact(sel, 100))")
        }
        if hasOCR, !ocrExcerpt.isEmpty {
            excerptLines.append("ocr_excerpt=\(compact(ocrExcerpt, 180))")
        }
        if hasVisual, !visualExcerpt.isEmpty {
            excerptLines.append("visual_descriptor_excerpt=\(compact(visualExcerpt, 180))")
        }
        if hasAX, !axExcerpt.isEmpty {
            excerptLines.append("ax_window_excerpt=\(compact(axExcerpt, 180))")
        }

        var lines: [String] = [
            "JSON only. No prose. Output EXACTLY this JSON schema:",
            "{",
            "  \"decision\": \"need_more_context\" or \"enough_context\",",
            "  \"request\": [\"ocr\", \"visual_descriptor\", \"ax_window_text\"],",
            "  \"reason\": \"brief explanation\",",
            "  \"confidence\": 0.9",
            "}",
            "",
            "Rules for 'decision':",
            "  - Set to \"enough_context\" if we have enough stable semantic context to infer what the user is doing (e.g. active app with non-empty window title, or copied text/selection present). The goal is NOT to decide if it's worth interrupting the user, but simply whether we have enough details to run the planner.",
            "  - NEVER request context that is already marked as present (e.g. do not request \"ocr\" if ocr_avail is yes; do not request \"visual_descriptor\" if visual_descriptor_available is yes; do not request \"ax_window_text\" if ax_avail is yes).",
            "  - If ocr_avail=yes or visual_descriptor_available=yes, decide enough_context unless the packet is truly empty.",
            "  - Do not loop on need_more_context. If any rich context is already present, transition to \"enough_context\".",
            "  - Set to \"need_more_context\" only if the active app is a browser, editor, shopping site, game, or search engine but we lack detailed text/OCR/visual context to classify the user's specific workflow. In this case, add the required context sources to the 'request' array (e.g. \"ocr\", \"visual_descriptor\", \"ax_window_text\").",
            "",
            "Allowed values in 'request' array: \"ocr\", \"visual_descriptor\", \"ax_window_text\".",
            "If decision is \"enough_context\", the 'request' array MUST be empty [].",
            "",
            "Examples:",
            "- Example 1 (Browser lacks detailed text):",
            "{\"decision\":\"need_more_context\",\"request\":[\"ocr\",\"visual_descriptor\"],\"reason\":\"browser context lacks semantic detail\",\"confidence\":0.85}",
            "- Example 2 (Enough context):",
            "{\"decision\":\"enough_context\",\"request\":[],\"reason\":\"sufficient semantic context for planning\",\"confidence\":0.95}"
        ]

        var ctxParts: [String] = []
        ctxParts.append("app=\(app)")
        ctxParts.append("title=\(title)")
        if !recent.isEmpty { ctxParts.append("recent=\(recent)") }
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
