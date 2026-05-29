// GoalGeneratorPromptBuilder.swift
import Foundation

/// Prompt builder for the Goal Generator stage (qwen2.5:0.5b).
/// Generates 1–3 natural, highly context-specific goal suggestions based on screen state.
struct GoalGeneratorPromptBuilder {
    static func build(
        snapshot: CanonicalGeneratedExecutionContextSnapshot,
        situational: SituationalContextSnapshot,
        recentTitles: [String],
        referenceTime: Date
    ) -> String {
        let app = compact(situational.activeAppName, 24)
        let title = compactTitle(situational.windowTitle, max: 70)
        let wf = situational.inferredWorkflow.rawValue

        let hasOCR = !(snapshot.recentOCRExcerpt ?? "").isEmpty
        let ocrExcerpt = snapshot.recentOCRExcerpt ?? ""
        let hasAX = snapshot.contextSummary?.contains("ax=") == true
        let axExcerpt = snapshot.contextSummary ?? ""
        let hasSel = !(snapshot.selectedText ?? "").isEmpty
        let selectedText = snapshot.selectedText ?? ""
        let hasClip = !(snapshot.clipboardText ?? "").isEmpty
        let clipboardText = snapshot.clipboardText ?? ""

        var lines: [String] = [
            "Task: Generate 1-3 highly specific, natural language goal suggestions based on the user's screen context.",
            "Suggestions must describe useful, creative assistant tasks grounded in the currently visible content.",
            "DO NOT use generic verbs like 'Extract', 'Summarize', 'Review', or 'Compare' as forced prefixes. Phrase suggestions as a human user would actually state their goal.",
            "Examples of natural suggestions:",
            "- \"Check whether this charger’s ports support simultaneous fast charging\"",
            "- \"Figure out if the 140W claim applies to one port or all ports\"",
            "- \"Find the actual price and delivery constraints\"",
            "- \"Summarize the Reddit thread’s best grilled cheese tips\"",
            "",
            "DO NOT suggest unsafe or destructive actions (buying, purchasing, deleting, checkout).",
            "DO NOT propose internal capability terms (permissions, capability, active permissions, etc.) unless the active window is actually Settings/Permissions.",
            "",
            "Active Context:",
            "- Active App: \(app)",
            "- Window Title: \(title)",
            "- Inferred Workflow: \(wf)"
        ]

        if hasSel {
            lines.append("- Selected Text: \(compact(selectedText, 150))")
        }
        if hasOCR {
            lines.append("- OCR excerpt: \(compact(ocrExcerpt, 250))")
        }
        if hasAX {
            lines.append("- AX excerpt: \(compact(axExcerpt, 180))")
        }
        if hasClip {
            lines.append("- Clipboard: \(compact(clipboardText, 120))")
        }

        return lines.joined(separator: "\n")
    }

    private static func compact(_ s: String, _ limit: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= limit ? t : String(t.prefix(limit))
    }

    private static func compactTitle(_ s: String, max limit: Int) -> String {
        let lower = s.lowercased()
        let stripped = lower.replacingOccurrences(of: #"[\|\-–—•·]+"#, with: " ", options: .regularExpression)
        let collapsed = stripped.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return compact(collapsed, limit)
    }
}
