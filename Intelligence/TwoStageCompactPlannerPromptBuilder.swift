// TwoStageCompactPlannerPromptBuilder.swift
import Foundation

/// Dedicated prompt builder for the compact planner stage (qwen2.5:1.5b).
/// Outputs the exact requested semantic structure:
/// {
///   "inferred_activity": "activity name",
///   "confidence": 0.95,
///   "evidence": "brief evidence description",
///   "candidate_action_title": "Compare products",
///   "suggested_hooks": "context,extract,output",
///   "should_surface_softly": true,
///   "required_context": ["ocr", "title"]
/// }
struct TwoStageCompactPlannerPromptBuilder {
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

        var lines: [String] = [
            "JSON only. No prose. Output EXACTLY this JSON schema:",
            "{",
            "  \"inferred_activity\": \"inferred user activity\",",
            "  \"confidence\": 0.95,",
            "  \"evidence\": \"brief explanation of signals/reasons\",",
            "  \"candidate_action_title\": \"short user-centric title (max 6 words)\",",
            "  \"suggested_hooks\": \"comma-separated capability categories from [\(needCatsAllowed)]\",",
            "  \"should_surface_softly\": true,",
            "  \"required_context\": [\"ocr\", \"title\", \"visual\", \"text\"]",
            "}",
            "",
            "CRITICAL INSTRUCTIONS FOR ACTIONABILITY:",
            "- The goal is to infer what the user is doing and produce a candidate workflow action when plausible. It is NOT to decide whether the situation is 'interrupt-worthy'.",
            "- For the common active contexts listed below, you MUST prefer producing a low-risk candidate action (set should_surface_softly: true) instead of quiet (should_surface_softly: false). Do NOT be conservative.",
            "- Common active contexts include:",
            "  * product browsing & shopping (e.g., 'Summarize product details', 'Compare product specs')",
            "  * product comparison (e.g., 'Compare products')",
            "  * search results pages (e.g., 'Compare search results', 'Analyze results')",
            "  * orders/tracking pages (e.g., 'Track package details')",
            "  * job posts/careers (e.g., 'Summarize job requirements', 'Tailor resume')",
            "  * code/Xcode development (e.g., 'Explain code', 'Find likely issue', 'Summarize file')",
            "  * copied/clipboard text (e.g., 'Analyze clipboard text')",
            "  * visible OCR text over 500 characters (e.g., 'Extract text details')",
            "  * forms/applications/checkouts (e.g., 'Auto-fill form details')",
            "- In these contexts, formulate a helpful, low-risk, contextual title and set should_surface_softly: true.",
            "",
            "Example:",
            "{\"inferred_activity\":\"shopping\",\"confidence\":0.95,\"evidence\":\"amazon product page visible in title\",\"candidate_action_title\":\"Compare products\",\"suggested_hooks\":\"context,extract,output\",\"should_surface_softly\":true,\"required_context\":[\"ocr\",\"title\"]}"
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
