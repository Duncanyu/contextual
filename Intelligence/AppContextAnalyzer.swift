import Foundation

/// Phase 22.1 — App-aware context analysis (Task G).
///
/// Classifies the active application into a semantic category so that
/// ContextEventProducer can choose the right context-extraction path and
/// EntityGroundingLayer can ground entities without relying on a URL.
///
/// Design constraints:
///   - NO hardcoded app name → behaviour mappings (never `if appName == "Xcode"`)
///   - Uses bundle-ID token patterns + window-title file extensions
///   - Generalises to any app following the naming conventions of each category
///   - Zero model calls; deterministic
///
/// Required log prefix: [AppContext]
enum AppContextAnalyzer {

    // MARK: - Output types

    enum Category: String, Sendable {
        case browser        // Web browser — context comes from BrowserContextExtractor
        case pdf            // PDF / document reader
        case editor         // Code / text editor or IDE
        case communication  // Email or messaging client
        case media          // Music / video player
        case files          // File manager / Finder-like
        case assistant_tool // AI assistant tool (ChatGPT, Claude, etc.)
        case unknown        // Not classifiable from available signals
    }

    struct AppContext {
        let category: Category
        let source: Source
        let appName: String
        let bundleID: String?

        enum Source: String {
            case bundleTokens   // matched via bundle-ID vocabulary
            case titleExtension // matched via window-title file extension
            case unknown
        }

        /// True when this app's context should be fetched via BrowserContextExtractor.
        var isBrowser: Bool { category == .browser }

        /// True when this app is a passive media player (music / video).
        var isMedia: Bool { category == .media }

        /// True when proposals are broadly relevant (not pure entertainment player).
        var supportsProposals: Bool {
            switch category {
            case .pdf, .editor, .communication, .files, .assistant_tool: return true
            case .browser, .unknown: return true    // subject to entity grounding
            case .media: return false
            }
        }
    }

    // MARK: - Vocabulary tables
    //
    // Each table contains *token fragments* extracted by splitting on ".", "-", "_".
    // A match fires when ANY token in the bundle-ID split equals a vocabulary entry.
    // This avoids per-app rules while generalising across naming conventions:
    //   com.apple.Safari      → ["com","apple","safari"]  → browser
    //   org.mozilla.firefox   → ["org","mozilla","firefox"] → browser
    //   com.microsoft.VSCode  → "vscode" after lowercasing → editor
    //   net.sourceforge.skim  → "skim" is a known pdf token → pdf
    //
    // Rules for inclusion:
    //   • Only tokens that strongly imply the category regardless of surrounding context
    //   • No single-letter or stop-word tokens (com, net, org, apple, microsoft, etc.)
    //   • No person names or ambiguous brand names

    private static let browserBundleTokens: Set<String> = [
        "safari", "firefox", "chrome", "chromium", "arc", "brave",
        "opera", "edge", "vivaldi", "waterfox", "librewolf", "tor",
        "webkit", "browser"
    ]

    private static let pdfBundleTokens: Set<String> = [
        "preview", "acrobat", "reader", "skim", "pdf",
        "foxit", "nitro", "evince", "okular", "zathura",
        "pdfexpert", "documents", "goodreader"
    ]

    private static let editorBundleTokens: Set<String> = [
        "xcode", "vscode", "code", "sublime", "atom",
        "textmate", "nova", "bbedit", "coderunner", "emacs", "vim",
        "neovim", "intellij", "jetbrains", "goland", "pycharm", "rider",
        "webstorm", "clion", "fleet", "zed", "cursor", "windsurf",
        "androidstudio", "eclipse", "netbeans"
    ]

    private static let communicationBundleTokens: Set<String> = [
        "mail", "outlook", "gmail", "spark", "airmail",
        "mimestream", "postbox", "thunderbird", "mailmate",
        "slack", "teams", "discord", "telegram", "signal",
        "messages", "imessage", "whatsapp", "skype", "zoom",
        "chime", "webex", "notion"    // notion is often used for comms/notes
    ]

    private static let assistantBundleTokens: Set<String> = [
        "chatgpt", "claude", "perplexity", "poe", "copilot", "gemini"
    ]

    private static let mediaBundleTokens: Set<String> = [
        "music", "itunes", "spotify", "tidal", "deezer",
        "vlc", "iina", "infuse", "plex", "emby",
        "quicktime", "movist", "mpv", "elmedia",
        "podcast", "overcast", "castro", "downcast",
        "vox", "capo", "swinsian", "audirvana"
    ]

    private static let filesBundleTokens: Set<String> = [
        "finder", "pathfinder", "forklift", "transmit",
        "commander", "worker", "filezilla", "cyberduck",
        "mountainduck", "totalfinder"
    ]

    // Source-code file extensions that indicate an editor is in use even when
    // the bundle ID is ambiguous (e.g. a generic "TextEdit" opening a .swift file).
    private static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "c", "cpp", "h", "hpp",
        "py", "rb", "go", "rs", "kt", "java", "scala",
        "ts", "tsx", "js", "jsx", "vue", "svelte",
        "cs", "fs", "fsx", "lua", "dart",
        "sh", "bash", "zsh", "fish",
        "html", "css", "scss", "sass", "less",
        "sql", "graphql", "proto", "tf", "yaml", "yml",
        "toml", "cargo", "gradle", "cmake", "makefile",
        "xcodeproj", "xcworkspace"
    ]

    // MARK: - Analysis entry point

    /// Classify the active application into a semantic category.
    ///
    /// - Parameters:
    ///   - appName:     Localised display name of the active application (e.g. "Firefox").
    ///   - bundleID:    CFBundleIdentifier, if available (e.g. "org.mozilla.firefox").
    ///   - windowTitle: Title of the frontmost window, used for file-extension fallback.
    /// - Returns: An `AppContext` describing the category and how it was derived.
    static func analyze(
        appName: String,
        bundleID: String?,
        windowTitle: String? = nil
    ) -> AppContext {

        // 1. Split bundle ID into lowercase tokens for vocabulary matching.
        let bundleTokens: [String]
        if let bid = bundleID {
            bundleTokens = bid
                .lowercased()
                .components(separatedBy: CharacterSet(charactersIn: ".-_"))
                .filter { $0.count > 2 }    // skip short tokens like "com","net","org"
        } else {
            // Fall back to splitting the display name when no bundle ID is available.
            bundleTokens = appName
                .lowercased()
                .components(separatedBy: CharacterSet(charactersIn: " .-_"))
                .filter { $0.count > 2 }
        }
        let tokenSet = Set(bundleTokens)

        // 2. Category probes in priority order.
        //    Two-pass matching: exact token match first, then prefix match for
        //    compound bundle tokens like "slackmacgap" (prefix "slack") or
        //    "chromehelper" (prefix "chrome").  Prefix match requires vocab
        //    term length ≥ 4 to avoid false positives on short stems.
        if tokenMatches(tokenSet, browserBundleTokens) {
            return result(.browser, source: .bundleTokens, appName: appName, bundleID: bundleID)
        }
        if tokenMatches(tokenSet, editorBundleTokens) {
            return result(.editor, source: .bundleTokens, appName: appName, bundleID: bundleID)
        }
        if tokenMatches(tokenSet, assistantBundleTokens) {
            return result(.assistant_tool, source: .bundleTokens, appName: appName, bundleID: bundleID)
        }
        if tokenMatches(tokenSet, pdfBundleTokens) {
            return result(.pdf, source: .bundleTokens, appName: appName, bundleID: bundleID)
        }
        if tokenMatches(tokenSet, communicationBundleTokens) {
            return result(.communication, source: .bundleTokens, appName: appName, bundleID: bundleID)
        }
        if tokenMatches(tokenSet, mediaBundleTokens) {
            return result(.media, source: .bundleTokens, appName: appName, bundleID: bundleID)
        }
        if tokenMatches(tokenSet, filesBundleTokens) {
            return result(.files, source: .bundleTokens, appName: appName, bundleID: bundleID)
        }

        // 3. Title-based extension fallback — catches generic text editors that
        //    happen to have a code file open (e.g. TextEdit opening a .swift file).
        if let title = windowTitle {
            if let ext = titleExtension(title) {
                if codeExtensions.contains(ext) {
                    return result(.editor, source: .titleExtension, appName: appName, bundleID: bundleID)
                }
                if ext == "pdf" {
                    return result(.pdf, source: .titleExtension, appName: appName, bundleID: bundleID)
                }
            }
        }

        return result(.unknown, source: .unknown, appName: appName, bundleID: bundleID)
    }

    // MARK: - Private helpers

    /// Returns true when any token in `tokenSet` exactly matches a vocab entry,
    /// OR when a token has a vocab entry as its prefix (e.g. "slackmacgap" → "slack").
    /// Prefix vocab terms must be ≥ 4 chars to avoid false positives.
    private static func tokenMatches(_ tokenSet: Set<String>, _ vocab: Set<String>) -> Bool {
        // Fast path: exact intersection
        if !vocab.isDisjoint(with: tokenSet) { return true }
        // Prefix path: any token starts with a known vocab term of 4+ chars
        for token in tokenSet {
            for term in vocab where term.count >= 4 {
                if token.hasPrefix(term) { return true }
            }
        }
        return false
    }

    private static func result(
        _ category: Category,
        source: AppContext.Source,
        appName: String,
        bundleID: String?
    ) -> AppContext {
        let ctx = AppContext(category: category, source: source, appName: appName, bundleID: bundleID)
        log(ctx)
        return ctx
    }

    /// Extract a lowercase file extension from a window title, e.g.
    /// "ContentView.swift — MyProject" → "swift".
    /// Returns nil if no extension is recognisable.
    private static func titleExtension(_ title: String) -> String? {
        // Take the first path component (before space, dash, em-dash, —).
        let separators = CharacterSet(charactersIn: " —–-·|")
        let firstSegment = title.components(separatedBy: separators).first ?? title
        let lower = firstSegment.lowercased()
        guard let dotRange = lower.range(of: ".", options: .backwards) else { return nil }
        let ext = String(lower[dotRange.upperBound...])
        guard !ext.isEmpty, ext.count <= 12 else { return nil }
        return ext
    }

    // MARK: - Required logging

    private static func log(_ ctx: AppContext) {
        print("[AppContext] category=\(ctx.category.rawValue)"
            + " source=\(ctx.source.rawValue)"
            + " app=\"\(ctx.appName)\""
            + " isBrowser=\(ctx.isBrowser)"
            + " supportsProposals=\(ctx.supportsProposals)")
    }
}
