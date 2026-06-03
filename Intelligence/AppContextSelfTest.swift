import Foundation

/// Phase 22.1 — AppContextAnalyzer self-test.
///
/// Trigger: CONTEXTUAL_RUN_APP_CONTEXT_SELFTEST=1
///
/// Test cases:
///  1.  Firefox bundle → category=browser, isBrowser=true
///  2.  Preview active, .pdf title → category=pdf
///  3.  Title ending .swift (TextEdit) → category=editor, source=titleExtension
///  4.  Bundle with "mail" token → category=communication
///  5.  VLC media player → category=media, isMedia=true
///  6.  Finder bundle → category=files
///  7.  Chrome bundle → category=browser
///  8.  Xcode bundle → category=editor, supportsProposals=true
///  9.  Spotify → category=media, supportsProposals=false
/// 10.  Unknown bundle, no matching tokens, no code title → category=unknown
/// 11.  Arc → category=browser (unconventional bundle "company.thebrowser.browser")
/// 12.  Title "Notes.txt" → category=unknown (txt not a code extension)
/// 13.  Slack bundle → category=communication
/// 14.  Zed editor → category=editor
enum AppContextSelfTest {

    static func run() -> Bool {
        print("[AppContextSelfTest] starting")
        var failures: [String] = []

        func check(_ name: String, _ ok: Bool) {
            if ok {
                print("[AppContextSelfTest] pass case=\(name)")
            } else {
                print("[AppContextSelfTest] fail case=\(name)")
                failures.append(name)
            }
        }

        // ── Case 1: Firefox ───────────────────────────────────────────────────
        let firefox = AppContextAnalyzer.analyze(
            appName: "Firefox",
            bundleID: "org.mozilla.firefox"
        )
        check("firefox_is_browser", firefox.category == .browser)
        check("firefox_isBrowser_true", firefox.isBrowser == true)
        check("firefox_source_bundle_tokens", firefox.source == .bundleTokens)

        // ── Case 2: Preview with .pdf window title ────────────────────────────
        let preview = AppContextAnalyzer.analyze(
            appName: "Preview",
            bundleID: "com.apple.Preview",
            windowTitle: "lecture_notes.pdf"
        )
        check("preview_is_pdf", preview.category == .pdf)
        check("preview_not_browser", preview.isBrowser == false)
        check("preview_supports_proposals", preview.supportsProposals == true)

        // ── Case 3: TextEdit opening a .swift file ────────────────────────────
        let textEditSwift = AppContextAnalyzer.analyze(
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            windowTitle: "ContentView.swift — MyProject"
        )
        check("textedit_swift_is_editor", textEditSwift.category == .editor)
        check("textedit_swift_source_title", textEditSwift.source == .titleExtension)

        // ── Case 4: Mail.app (communication) ─────────────────────────────────
        let mail = AppContextAnalyzer.analyze(
            appName: "Mail",
            bundleID: "com.apple.mail"
        )
        check("mail_is_communication", mail.category == .communication)
        check("mail_supports_proposals", mail.supportsProposals == true)

        // ── Case 5: VLC ───────────────────────────────────────────────────────
        let vlc = AppContextAnalyzer.analyze(
            appName: "VLC",
            bundleID: "org.videolan.vlc"
        )
        check("vlc_is_media", vlc.category == .media)
        check("vlc_is_media_flag", vlc.isMedia == true)
        check("vlc_no_proposals", vlc.supportsProposals == false)

        // ── Case 6: Finder ────────────────────────────────────────────────────
        let finder = AppContextAnalyzer.analyze(
            appName: "Finder",
            bundleID: "com.apple.finder"
        )
        check("finder_is_files", finder.category == .files)
        check("finder_supports_proposals", finder.supportsProposals == true)

        // ── Case 7: Google Chrome ─────────────────────────────────────────────
        let chrome = AppContextAnalyzer.analyze(
            appName: "Google Chrome",
            bundleID: "com.google.Chrome"
        )
        check("chrome_is_browser", chrome.category == .browser)
        check("chrome_isBrowser_true", chrome.isBrowser == true)

        // ── Case 8: Xcode ─────────────────────────────────────────────────────
        let xcode = AppContextAnalyzer.analyze(
            appName: "Xcode",
            bundleID: "com.apple.dt.Xcode"
        )
        check("xcode_is_editor", xcode.category == .editor)
        check("xcode_not_browser", xcode.isBrowser == false)
        check("xcode_supports_proposals", xcode.supportsProposals == true)

        // ── Case 9: Spotify ───────────────────────────────────────────────────
        let spotify = AppContextAnalyzer.analyze(
            appName: "Spotify",
            bundleID: "com.spotify.client"
        )
        check("spotify_is_media", spotify.category == .media)
        check("spotify_no_proposals", spotify.supportsProposals == false)

        // ── Case 10: Unknown bundle, generic app ──────────────────────────────
        let unknown = AppContextAnalyzer.analyze(
            appName: "MyCustomApp",
            bundleID: "com.example.mycustomapp",
            windowTitle: "Welcome"
        )
        check("unknown_bundle_is_unknown", unknown.category == .unknown)

        // ── Case 11: Arc browser (unconventional bundle) ──────────────────────
        let arc = AppContextAnalyzer.analyze(
            appName: "Arc",
            bundleID: "company.thebrowser.browser"
        )
        check("arc_is_browser", arc.isBrowser == true)

        // ── Case 12: TextEdit opening a .txt file (not a code file) ───────────
        let textEditTxt = AppContextAnalyzer.analyze(
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            windowTitle: "Notes.txt"
        )
        // .txt is not in codeExtensions — should remain unknown
        check("textedit_txt_is_unknown", textEditTxt.category == .unknown)

        // ── Case 13: Slack ────────────────────────────────────────────────────
        let slack = AppContextAnalyzer.analyze(
            appName: "Slack",
            bundleID: "com.tinyspeck.slackmacgap"
        )
        check("slack_is_communication", slack.category == .communication)

        // ── Case 14: Zed editor ───────────────────────────────────────────────
        let zed = AppContextAnalyzer.analyze(
            appName: "Zed",
            bundleID: "dev.zed.Zed"
        )
        check("zed_is_editor", zed.category == .editor)

        let ok = failures.isEmpty
        print("[AppContextSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
