import Foundation

/// Phase 22.1 — ContextSourcePriority + AppContextAnalyzer self-test.
///
/// Trigger: CONTEXTUAL_RUN_CONTEXT_SOURCE_PRIORITY_SELFTEST=1
///
/// Test cases:
///  1. Firefox (bundle "org.mozilla.firefox") → category=browser, isBrowser=true
///  2. Preview  (bundle "com.apple.Preview")  → category=pdf,     isBrowser=false
///  3. Title "ContentView.swift"             → category=editor   (title fallback)
///  4. VSCode  (bundle "com.microsoft.VSCode") → category=editor, isBrowser=false
///  5. Spotify (bundle "com.spotify.client")   → category=media,  isMedia=true
///  6. Spark   (bundle "com.readdle.smartemail.spark") → category=communication
///  7. Finder  (bundle "com.apple.finder")     → category=files
///  8. Browser category → BrowserContextExtractor should run (isBrowser guard)
///  9. Non-browser → browser is skipped (isBrowser=false)
/// 10. Unknown bundle with .swift title → editor via title extension
enum ContextSourcePrioritySelfTest {

    static func run() -> Bool {
        print("[ContextSourcePrioritySelfTest] starting")
        var failures: [String] = []

        func check(_ name: String, _ ok: Bool) {
            if ok {
                print("[ContextSourcePrioritySelfTest] pass case=\(name)")
            } else {
                print("[ContextSourcePrioritySelfTest] fail case=\(name)")
                failures.append(name)
            }
        }

        // ── Case 1: Firefox → browser ─────────────────────────────────────────
        let firefox = AppContextAnalyzer.analyze(
            appName: "Firefox",
            bundleID: "org.mozilla.firefox"
        )
        check("firefox_category_is_browser", firefox.category == .browser)
        check("firefox_is_browser", firefox.isBrowser == true)
        check("firefox_source_is_bundle_tokens", firefox.source == .bundleTokens)

        // ── Case 2: Preview (PDF reader) → pdf ────────────────────────────────
        let preview = AppContextAnalyzer.analyze(
            appName: "Preview",
            bundleID: "com.apple.Preview"
        )
        check("preview_category_is_pdf", preview.category == .pdf)
        check("preview_is_not_browser", preview.isBrowser == false)

        // ── Case 3: Generic app with .swift window title → editor (title fallback)
        let textEditSwift = AppContextAnalyzer.analyze(
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            windowTitle: "ContentView.swift — MyProject"
        )
        check("textedit_swift_title_category_is_editor",
              textEditSwift.category == .editor)
        check("textedit_swift_title_source_is_title_extension",
              textEditSwift.source == .titleExtension)

        // ── Case 4: VSCode → editor ───────────────────────────────────────────
        let vscode = AppContextAnalyzer.analyze(
            appName: "Visual Studio Code",
            bundleID: "com.microsoft.VSCode"
        )
        check("vscode_category_is_editor", vscode.category == .editor)
        check("vscode_is_not_browser", vscode.isBrowser == false)
        check("vscode_supports_proposals", vscode.supportsProposals == true)

        // ── Case 5: Spotify → media ───────────────────────────────────────────
        let spotify = AppContextAnalyzer.analyze(
            appName: "Spotify",
            bundleID: "com.spotify.client"
        )
        check("spotify_category_is_media", spotify.category == .media)
        check("spotify_is_media", spotify.isMedia == true)
        check("spotify_does_not_support_proposals", spotify.supportsProposals == false)

        // ── Case 6: Spark (email) → communication ─────────────────────────────
        let spark = AppContextAnalyzer.analyze(
            appName: "Spark",
            bundleID: "com.readdle.smartemail.spark"
        )
        check("spark_category_is_communication", spark.category == .communication)
        check("spark_supports_proposals", spark.supportsProposals == true)

        // ── Case 7: Finder → files ────────────────────────────────────────────
        let finder = AppContextAnalyzer.analyze(
            appName: "Finder",
            bundleID: "com.apple.finder"
        )
        check("finder_category_is_files", finder.category == .files)
        check("finder_supports_proposals", finder.supportsProposals == true)

        // ── Case 8: Browser app → isBrowser=true (used by ContextEventProducer) ─
        let safari = AppContextAnalyzer.analyze(
            appName: "Safari",
            bundleID: "com.apple.Safari"
        )
        check("safari_is_browser", safari.isBrowser == true)

        // ── Case 9: Non-browser app → isBrowser=false ─────────────────────────
        let xcode = AppContextAnalyzer.analyze(
            appName: "Xcode",
            bundleID: "com.apple.dt.Xcode"
        )
        check("xcode_is_not_browser", xcode.isBrowser == false)
        check("xcode_category_is_editor", xcode.category == .editor)

        // ── Case 10: Unknown bundle + .swift title → editor ───────────────────
        let unknownEditor = AppContextAnalyzer.analyze(
            appName: "SomeEditor",
            bundleID: "com.unknown.someeditor",
            windowTitle: "main.swift"
        )
        check("unknown_bundle_swift_title_is_editor",
              unknownEditor.category == .editor)

        // ── Cross-check: Arc → browser ────────────────────────────────────────
        let arc = AppContextAnalyzer.analyze(
            appName: "Arc",
            bundleID: "company.thebrowser.browser"
        )
        check("arc_is_browser", arc.isBrowser == true)

        // ── Cross-check: IINA (video player) → media ──────────────────────────
        let iina = AppContextAnalyzer.analyze(
            appName: "IINA",
            bundleID: "com.colliderli.iina"
        )
        check("iina_category_is_media", iina.category == .media)

        let ok = failures.isEmpty
        print("[ContextSourcePrioritySelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
