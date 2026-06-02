import Foundation

/// Phase 21.2 — Editor-app context fallback.
///
/// When the active app is a code editor and AX selection is unavailable
/// (no focused element), the normal `SelectionSource` path returns nothing.
/// This fallback provides a minimum viable context so Jarvis can still
/// surface a safe, title-grounded coding suggestion.
///
/// Tiers (cheap → expensive, passive refresh uses only tier 1):
///   1. window_title  — app name + window title (always available, zero cost)
///   2. ax_window     — AXWindowContentSource extracts visible editor text
///   3. manual_ocr    — surgical OCR (manual invoke only, never automatic)
///
/// Generic editor detection: no hardcoded app names. Detects editors by:
///   - Window title containing source file extensions or path separators
///   - App name containing "code", "studio", "editor", "pad", "develop", "xcode", "vscode"
///
/// **No AgenticPlan. No HookCompositionPipeline. No DirectAgentLoop.**
public enum EditorContextFallback {

    public struct Result: Sendable, Equatable {
        public let contextText: String?
        public let source: String       // "window_title" | "ax_window" | "manual_ocr" | "none"
        public let available: Bool

        public static let unavailable = Result(contextText: nil, source: "none", available: false)
    }

    // MARK: - Editor detection (generic)

    /// Returns true when the app name suggests a code/text editor.
    /// No hardcoded app identifiers — pattern-based only.
    public static func isEditorApp(_ appName: String) -> Bool {
        let lower = appName.lowercased()
        let editorKeywords = ["code", "studio", "editor", "pad", "develop",
                               "xcode", "vscode", "vim", "emacs", "atom", "sublime",
                               "intellij", "android", "flutter", "cursor"]
        return editorKeywords.contains { lower.contains($0) }
    }

    /// Returns true when the window title looks like a source file or project.
    public static func isEditorTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        let fileExtensions = [".swift", ".py", ".js", ".ts", ".kt", ".java",
                               ".m", ".mm", ".cpp", ".c", ".h", ".rs", ".go",
                               ".rb", ".sh", ".yaml", ".json", ".toml", ".gradle",
                               ".xcodeproj", ".xcworkspace", ".pbxproj", ".storyboard"]
        let editorPhrases = ["untitled", "preview", "appdelegate", "viewcontroller",
                              "main.swift", "index.", "src/", "lib/"]
        return fileExtensions.contains(where: { lower.contains($0) })
            || editorPhrases.contains(where: { lower.contains($0) })
            || lower.contains("/") // path separator
    }

    // MARK: - Extraction (passive-safe tiers 1–2)

    /// Extracts editor context without triggering OCR. Safe for passive refresh.
    public static func extractPassive(
        appName: String,
        windowTitle: String
    ) -> Result {
        guard isEditorApp(appName) || isEditorTitle(windowTitle) else {
            return .unavailable
        }
        print("[EditorContextFallback] started app=\(appName)")

        // Tier 1: window title
        let titleContext = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !titleContext.isEmpty {
            print("[EditorContextFallback] source=window_title context_available=yes")
            return Result(contextText: titleContext, source: "window_title", available: true)
        }

        // Tier 2: AX window content (cheap; no OCR)
        if let axCtx = AXWindowContentSource.shared.extractActiveWindowContent(),
           !axCtx.visibleTextFragments.isEmpty {
            let joined = axCtx.visibleTextFragments.prefix(8).joined(separator: " ")
            print("[EditorContextFallback] source=ax_window context_available=yes chars=\(joined.count)")
            return Result(contextText: joined, source: "ax_window", available: true)
        }

        print("[EditorContextFallback] source=window_title context_available=\(!titleContext.isEmpty ? "yes" : "no")")
        return .unavailable
    }

    /// Extracts editor context including optional surgical OCR. Only for manual invoke.
    /// Automatic refresh MUST NOT call this — it would violate the no-auto-OCR constraint.
    public static func extractManual(
        appName: String,
        windowTitle: String,
        ocrFallback: String?
    ) -> Result {
        // First try passive tiers
        let passive = extractPassive(appName: appName, windowTitle: windowTitle)
        if passive.available { return passive }

        // Tier 3 (manual only): surgical OCR excerpt
        if let ocr = ocrFallback, !ocr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("[EditorContextFallback] source=manual_ocr context_available=yes chars=\(ocr.count)")
            return Result(contextText: ocr, source: "manual_ocr", available: true)
        }

        print("[EditorContextFallback] context_available=no")
        return .unavailable
    }
}
