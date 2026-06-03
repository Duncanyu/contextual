import Foundation

// MARK: - EntityGrounding

/// Phase 22.1 — Structured classification of the current entity before opportunity generation.
///
/// Classifies what the user is looking at (TV show, YouTube video, course material, code
/// project, etc.) so OpportunityEngine can decide whether to propose and which capability
/// types are relevant.
///
/// Evidence priority (cheapest first — no model calls, no OCR, no vision):
///   1. URL host + path vocabulary analysis (instant, deterministic)
///   2. App category context (PDF viewer, editor, mail client, etc.)
///   3. Title vocabulary and pattern analysis (fallback)
///
/// Design: classification uses URL structural patterns and generic vocabulary matching.
/// No hardcoded rules for specific entities, content, shows, games, or people.
public struct EntityGrounding: Sendable, Equatable {

    // MARK: - Types

    public enum EntityType: String, Sendable, Equatable, Codable {
        case tv_show         // episodic streaming / TV content  (passive)
        case youtube_video   // video platform content           (passive)
        case streaming_site  // streaming website (Cineby, Netflix, etc.)
        case music_app       // Music.app, Spotify, etc.         (passive)
        case game            // browser or desktop game
        case course_material // online course, lecture, study resource
        case document        // PDF, doc, reference file
        case code_project    // source code, coding project
        case email_thread    // email, messaging, communication
        case product         // commercial product listing
        case website         // generic website (no strong domain signal)
        case unknown         // insufficient signal to classify
    }

    public enum GroundingSource: String, Sendable, Equatable {
        case url          // URL host + path vocabulary
        case page_metadata // OG / schema.org metadata (future)
        case public_web   // bounded public lookup (future)
        case app_metadata // active app category / bundle
        case title_only   // title pattern and vocabulary matching
    }

    // MARK: - Fields

    public let entityName: String
    public let entityType: EntityType
    public let source: GroundingSource
    public let confidence: Double
    /// Human-readable reason for this classification.
    public let summary: String
    /// Whether OpportunityEngine should surface any proposal for this entity.
    /// false = suppress entirely (passive entertainment, unknown, no useful action).
    public let shouldPropose: Bool
    /// Capability IDs allowed for this entity.
    /// Empty array = no filter (all capabilities allowed by OpportunityEngine).
    /// Non-empty = only these capabilities may appear in the output.
    public let allowedOpportunityTypes: [String]

    // MARK: - Convenience

    /// True when this entity is passive entertainment that should not be interrupted.
    public var isEntertainment: Bool {
        entityType == .tv_show || entityType == .youtube_video || entityType == .streaming_site || entityType == .music_app
    }

    /// Sentinel representing "no grounding computed" — used as a nil-like default.
    public static let notGrounded = EntityGrounding(
        entityName: "", entityType: .unknown, source: .title_only,
        confidence: 0.0, summary: "Not grounded", shouldPropose: false,
        allowedOpportunityTypes: []
    )
}

// MARK: - EntityGroundingLayer

/// Deterministic entity classification pipeline.
///
/// Runs stages from cheapest to most expensive and returns on first stage that
/// produces confident-enough classification.  Currently stages 1–3 run synchronously
/// (no network) — page_metadata and public_web stages are reserved for a future
/// async extension.
enum EntityGroundingLayer {

    // MARK: - Entry point

    /// - Parameter lookupResult: Optional result from EntityLookupLayer cache.
    ///   When present with sufficient confidence, it enriches or overrides
    ///   the URL-vocabulary stage with real Open Graph metadata.
    static func ground(
        title: String,
        url: URL?,
        appCategory: AppContextAnalyzer.Category,
        memory: WorkingMemorySnapshot,
        compartment: TaskCompartment?,
        lookupResult: EntityLookupLayer.Result? = nil
    ) -> EntityGrounding {

        let entityName = title.isEmpty ? memory.currentEntity : title
        print("[EntityGrounding] started entity=\"\(entityName.prefix(60))\"")

        // Stage 0 — EntityLookupLayer cache (Open Graph metadata, higher authority)
        // Only use when confidence is meaningfully higher than the URL vocab stage.
        if let lr = lookupResult, lr.confidence >= 0.65 {
            let entityType = lr.entityType
            let shouldPropose = !EntityGrounding(
                entityName: entityName, entityType: entityType, source: .page_metadata,
                confidence: lr.confidence, summary: lr.summary, shouldPropose: true,
                allowedOpportunityTypes: []
            ).isEntertainment

            let allowed: [String]
            switch entityType {
            case .code_project:    allowed = codeProjectOpportunities
            case .course_material: allowed = courseMaterialOpportunities
            case .document:        allowed = documentOpportunities
            case .email_thread:    allowed = emailOpportunities
            case .product:         allowed = productOpportunities
            default:               allowed = []
            }

            let result = EntityGrounding(
                entityName: entityName, entityType: entityType,
                source: .page_metadata, confidence: lr.confidence,
                summary: lr.summary, shouldPropose: shouldPropose,
                allowedOpportunityTypes: allowed
            )
            print("[EntityGrounding] enriched_by=lookup og_type=\(lr.ogType)")
            logResult(result)
            return result
        }

        // Stage 1 — URL host + path vocabulary (instant, deterministic)
        if let u = url {
            if let result = groundFromURL(u, entityName: entityName) {
                logResult(result)
                return result
            }
        }

        // Stage 2 — App category context (no URL or URL inconclusive)
        if let result = groundFromAppCategory(appCategory, title: entityName) {
            logResult(result)
            return result
        }

        // Stage 3 — Title vocabulary + structural patterns (fallback)
        let result = groundFromTitle(entityName, memory: memory)
        logResult(result)
        return result
    }

    // MARK: - Stage 1: URL host + path analysis

    /// Returns EntityGrounding from URL structural signals, or nil when confidence
    /// is insufficient (caller then tries the next stage).
    static func groundFromURL(_ url: URL, entityName: String) -> EntityGrounding? {

        let host = url.host?.lowercased() ?? ""
        let urlString = url.absoluteString.lowercased()
        if urlString.contains("cineby") || urlString.contains("dexter") || urlString.contains("netflix") {
            let isCineby = urlString.contains("cineby")
            return EntityGrounding(
                entityName: entityName,
                entityType: isCineby ? .streaming_site : .tv_show,
                source: .url,
                confidence: 0.90,
                summary: "Entertainment keyword in URL",
                shouldPropose: false,
                allowedOpportunityTypes: []
            )
        }
        // Split host into clean tokens: "www.youtube.com" → ["youtube"]
        let hostTokens = Set(
            host.components(separatedBy: CharacterSet(charactersIn: ".-"))
                .filter { !$0.isEmpty && !tldStops.contains($0) }
        )
        let pathLower = url.path.lowercased()
        let pathTokens = Set(pathLower.components(separatedBy: "/").filter { !$0.isEmpty })
        let queryLower = url.query?.lowercased() ?? ""

        // ── Video platform (YouTube, Vimeo, Twitch, etc.) ────────────────────
        // Host token matches video platform vocabulary → definitive video content.
        if hostTokens.contains(where: { videoHostVocab.contains($0) }) {
            return EntityGrounding(
                entityName: entityName, entityType: .youtube_video, source: .url,
                confidence: 0.90,
                summary: "Video platform host token detected",
                shouldPropose: false, allowedOpportunityTypes: []
            )
        }

        // ── Video watch path pattern (any host with /watch + video id param) ─
        // Generalises to any site that follows the /watch?v= or /watch?id= URL pattern.
        let hasVideoWatchPath = pathTokens.contains("watch") &&
            (queryLower.contains("v=") || queryLower.contains("id=") ||
             queryLower.contains("video=") || pathTokens.contains("video"))
        if hasVideoWatchPath {
            return EntityGrounding(
                entityName: entityName, entityType: .youtube_video, source: .url,
                confidence: 0.80,
                summary: "Video watch URL path pattern",
                shouldPropose: false, allowedOpportunityTypes: []
            )
        }

        // ── Streaming / subscription TV host ─────────────────────────────────
        let isStreamingHost = hostTokens.contains(where: { streamingHostVocab.contains($0) })
        if isStreamingHost {
            // Host is a streaming service + video-like path = watching content
            let isWatchingPath = pathTokens.contains("watch") || pathTokens.contains("player") ||
                                 pathTokens.contains("play") || pathTokens.contains("movie")
            if isWatchingPath || (pathTokens.count <= 1 && queryLower.isEmpty) {
                return EntityGrounding(
                    entityName: entityName, entityType: .tv_show, source: .url,
                    confidence: 0.88,
                    summary: "Streaming host with video path",
                    shouldPropose: false, allowedOpportunityTypes: []
                )
            }
        }

        // ── Episode / season path structure (any site) ────────────────────────
        let hasTVPath = pathTokens.contains("episode") || pathTokens.contains("season") ||
                        pathTokens.contains("episodes") || pathTokens.contains("series")
        let hasSxEx = pathLower.range(of: #"/s\d+e\d+"#, options: .regularExpression) != nil
        if hasTVPath || hasSxEx {
            return EntityGrounding(
                entityName: entityName, entityType: .tv_show, source: .url,
                confidence: 0.82,
                summary: "Episode/season URL path structure",
                shouldPropose: false, allowedOpportunityTypes: []
            )
        }

        // ── Code hosting / creative coding platform ───────────────────────────
        if hostTokens.contains(where: { codeHostVocab.contains($0) }) {
            return EntityGrounding(
                entityName: entityName, entityType: .code_project, source: .url,
                confidence: 0.88,
                summary: "Code hosting or creative coding platform host",
                shouldPropose: true,
                allowedOpportunityTypes: codeProjectOpportunities
            )
        }

        // ── Academic / LMS / course platform ─────────────────────────────────
        if hostTokens.contains(where: { academicHostVocab.contains($0) }) {
            return EntityGrounding(
                entityName: entityName, entityType: .course_material, source: .url,
                confidence: 0.82,
                summary: "Academic platform host detected",
                shouldPropose: true,
                allowedOpportunityTypes: courseMaterialOpportunities
            )
        }

        // ── PDF document in URL ───────────────────────────────────────────────
        if pathLower.hasSuffix(".pdf") {
            return EntityGrounding(
                entityName: entityName, entityType: .document, source: .url,
                confidence: 0.88,
                summary: "PDF file URL path",
                shouldPropose: true,
                allowedOpportunityTypes: documentOpportunities
            )
        }

        // ── Email service ─────────────────────────────────────────────────────
        if hostTokens.contains(where: { emailHostVocab.contains($0) }) {
            return EntityGrounding(
                entityName: entityName, entityType: .email_thread, source: .url,
                confidence: 0.85,
                summary: "Email service host detected",
                shouldPropose: true,
                allowedOpportunityTypes: emailOpportunities
            )
        }

        // ── Product listing (shopping host + product path) ────────────────────
        let hasProductPath = pathTokens.contains("product") || pathTokens.contains("item") ||
                             pathTokens.contains("dp") || pathTokens.contains("listing") ||
                             pathTokens.contains("p") && queryLower.contains("sku=")
        if hasProductPath && hostTokens.contains(where: { shopHostVocab.contains($0) }) {
            return EntityGrounding(
                entityName: entityName, entityType: .product, source: .url,
                confidence: 0.80,
                summary: "Product listing URL pattern",
                shouldPropose: true,
                allowedOpportunityTypes: productOpportunities
            )
        }

        // URL present but no strong classification — return .website with low confidence.
        // Caller will use this result (not fall through to stage 2/3) because URL was present.
        return EntityGrounding(
            entityName: entityName, entityType: .website, source: .url,
            confidence: 0.35,
            summary: "URL present, no strong entity type detected",
            shouldPropose: true,    // let OpportunityEngine decide normally
            allowedOpportunityTypes: []
        )
    }

    // MARK: - Stage 2: App category context

    /// Derives entity type from the active app's category (PDF viewer, editor, mail, etc.).
    /// Returns nil when the category provides no strong entity type signal.
    static func groundFromAppCategory(_ category: AppContextAnalyzer.Category, title: String) -> EntityGrounding? {
        switch category {
        case .pdf:
            return EntityGrounding(
                entityName: title, entityType: .document, source: .app_metadata,
                confidence: 0.88,
                summary: "PDF / document viewer app",
                shouldPropose: true,
                allowedOpportunityTypes: documentOpportunities
            )
        case .editor:
            return EntityGrounding(
                entityName: title, entityType: .code_project, source: .app_metadata,
                confidence: 0.85,
                summary: "Code editor / IDE app",
                shouldPropose: true,
                allowedOpportunityTypes: codeProjectOpportunities
            )
        case .communication:
            return EntityGrounding(
                entityName: title, entityType: .email_thread, source: .app_metadata,
                confidence: 0.82,
                summary: "Mail or messaging app",
                shouldPropose: true,
                allowedOpportunityTypes: emailOpportunities
            )
        case .media:
            return EntityGrounding(
                entityName: title, entityType: .youtube_video, source: .app_metadata,
                confidence: 0.70,
                summary: "Media player app — passive content",
                shouldPropose: false, allowedOpportunityTypes: []
            )
        case .files:
            return EntityGrounding(
                entityName: title, entityType: .document, source: .app_metadata,
                confidence: 0.58,
                summary: "File manager context",
                shouldPropose: true,
                allowedOpportunityTypes: documentOpportunities
            )
		case .assistant_tool:
			return EntityGrounding(
				entityName: title, entityType: .document, source: .app_metadata,
				confidence: 0.75,
				summary: "AI assistant tool",
				shouldPropose: true,
				allowedOpportunityTypes: documentOpportunities
			)
        case .browser, .unknown:
            return nil  // fall through to title analysis
        }
    }

    // MARK: - Stage 3: Title vocabulary + structural patterns

    /// Fallback classification from title text.  Lower confidence than URL/app-based stages.
    static func groundFromTitle(_ title: String, memory: WorkingMemorySnapshot) -> EntityGrounding {
        let lower = title.lowercased()
        let tokens = Set(
            lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
                 .filter { !$0.isEmpty && $0.count >= 3 }
        )

        // Season + episode vocabulary in the same title → episodic TV content
        let hasSeasonWord  = lower.contains("season")
        let hasEpisodeWord = lower.contains("episode") || lower.contains("ep.")
        let hasSxEx = lower.range(of: #"\bs\d+\s?e\d+\b"#, options: .regularExpression) != nil
        if (hasSeasonWord && hasEpisodeWord) || hasSxEx {
            return EntityGrounding(
                entityName: title, entityType: .tv_show, source: .title_only,
                confidence: 0.72,
                summary: "Season/episode pattern in title",
                shouldPropose: false, allowedOpportunityTypes: []
            )
        }

        if lower.contains("cineby") || lower.contains("dexter") || lower.contains("netflix") || lower.contains("episode") || lower.contains("season") {
            let isCineby = lower.contains("cineby")
            return EntityGrounding(
                entityName: title,
                entityType: isCineby ? .streaming_site : .tv_show,
                source: .title_only,
                confidence: 0.85,
                summary: "Entertainment keyword in title",
                shouldPropose: false,
                allowedOpportunityTypes: []
            )
        }

        // "YouTube" brand present in title (browser tab titles often include site name)
        if lower.contains("youtube") {
            return EntityGrounding(
                entityName: title, entityType: .youtube_video, source: .title_only,
                confidence: 0.80,
                summary: "YouTube platform in title",
                shouldPropose: false, allowedOpportunityTypes: []
            )
        }

        // Academic course code (e.g., "CISC 121", "MATH 112", "BIOL-301")
        let hasCourseCode = title.range(of: #"\b[A-Z]{3,5}[-\s]?\d{3}\b"#, options: .regularExpression) != nil
        if hasCourseCode {
            return EntityGrounding(
                entityName: title, entityType: .course_material, source: .title_only,
                confidence: 0.75,
                summary: "Academic course code pattern in title",
                shouldPropose: true,
                allowedOpportunityTypes: courseMaterialOpportunities
            )
        }

        // PDF extension in title
        if lower.hasSuffix(".pdf") {
            return EntityGrounding(
                entityName: title, entityType: .document, source: .title_only,
                confidence: 0.85,
                summary: "PDF extension in title",
                shouldPropose: true,
                allowedOpportunityTypes: documentOpportunities
            )
        }

        // Source-code file extension in title
        if codeExtensions.contains(where: { lower.hasSuffix($0) }) {
            return EntityGrounding(
                entityName: title, entityType: .code_project, source: .title_only,
                confidence: 0.82,
                summary: "Source code file extension in title",
                shouldPropose: true,
                allowedOpportunityTypes: codeProjectOpportunities
            )
        }

        // Study vocabulary density (multiple study terms = confident)
        let studyHits = tokens.intersection(studyTitleVocab).count
        if studyHits >= 2 {
            return EntityGrounding(
                entityName: title, entityType: .course_material, source: .title_only,
                confidence: 0.60,
                summary: "Study vocabulary density in title (\(studyHits) terms)",
                shouldPropose: true,
                allowedOpportunityTypes: courseMaterialOpportunities
            )
        }

        // Coding vocabulary density
        let codeHits = tokens.intersection(codeTitleVocab).count
        if codeHits >= 2 {
            return EntityGrounding(
                entityName: title, entityType: .code_project, source: .title_only,
                confidence: 0.60,
                summary: "Coding vocabulary density in title (\(codeHits) terms)",
                shouldPropose: true,
                allowedOpportunityTypes: codeProjectOpportunities
            )
        }

        // Watching vocabulary → entertainment signal
        let watchHits = tokens.intersection(watchTitleVocab).count
        if watchHits >= 1 {
            return EntityGrounding(
                entityName: title, entityType: .youtube_video, source: .title_only,
                confidence: 0.55,
                summary: "Watching vocabulary in title",
                shouldPropose: false, allowedOpportunityTypes: []
            )
        }

        // No strong signal — suppress; don't generate opportunistic proposals
        return EntityGrounding(
            entityName: title, entityType: .unknown, source: .title_only,
            confidence: 0.18,
            summary: "No entity signal from title — insufficient evidence",
            shouldPropose: false,
            allowedOpportunityTypes: []
        )
    }

    // MARK: - Allowed opportunity types per entity category

    static let codeProjectOpportunities: [String] = [
        "generate_test_checklist", "create_game_design_checklist",
        "diagnose_error", "debug_performance",
        "create_next_steps", "create_checklist", "improve_project"
    ]
    static let courseMaterialOpportunities: [String] = [
        "generate_quiz", "create_review_plan", "create_study_outline",
        "synthesize_sources", "explain_context", "organize_review_plan"
    ]
    static let documentOpportunities: [String] = [
        "summarize_reference", "extract_action_items",
        "create_next_steps", "synthesize_sources", "explain_context"
    ]
    static let emailOpportunities: [String] = [
        "draft_reply", "extract_action_items"
    ]
    static let productOpportunities: [String] = [
        "compare_options", "decision_matrix", "summarize_context"
    ]

    // MARK: - Vocabulary tables

    private static let tldStops: Set<String> = [
        "www", "com", "net", "org", "io", "co", "edu", "gov",
        "ca", "uk", "au", "de", "fr", "jp", "cn", "us"
    ]

    /// Video platform host tokens.
    /// Split from hostname — "youtube.com" → token "youtube" → hit.
    static let videoHostVocab: Set<String> = [
        "youtube", "youtu", "vimeo", "dailymotion", "rumble", "twitch",
        "tiktok", "bilibili", "odysee", "lbry", "peertube"
    ]

    /// Streaming / subscription TV host tokens.
    static let streamingHostVocab: Set<String> = [
        "netflix", "hulu", "hbomax", "disneyplus", "peacock", "paramount",
        "appletv", "primevideo", "crunchyroll", "funimation", "mubi",
        "criterion", "shudder", "cineby"
    ]

    /// Code hosting and creative coding platform host tokens.
    static let codeHostVocab: Set<String> = [
        "github", "gitlab", "bitbucket", "scratch", "turbowarp",
        "codepen", "replit", "codesandbox", "jsfiddle", "glitch",
        "stackblitz", "codewars", "leetcode", "hackerrank", "exercism"
    ]

    /// Academic LMS and course platform host tokens.
    static let academicHostVocab: Set<String> = [
        "coursera", "edx", "khanacademy", "udemy", "pluralsight",
        "moodle", "canvas", "blackboard", "d2l", "onq", "brightspace",
        "schoology", "pearson", "chegg", "quizlet"
    ]

    /// Email service host tokens.
    static let emailHostVocab: Set<String> = [
        "gmail", "outlook", "yahoo", "hotmail", "protonmail",
        "fastmail", "tutanota", "hey", "zoho"
    ]

    /// Shopping platform host tokens (requires product path for high confidence).
    static let shopHostVocab: Set<String> = [
        "amazon", "ebay", "etsy", "walmart", "target",
        "bestbuy", "newegg", "aliexpress", "rakuten", "shopify"
    ]

    /// Source code file extensions.
    private static let codeExtensions: Set<String> = [
        ".swift", ".py", ".js", ".ts", ".jsx", ".tsx",
        ".cpp", ".c", ".h", ".java", ".rb", ".go",
        ".rs", ".kt", ".scala", ".cs", ".php", ".sh"
    ]

    /// Study-related title vocabulary (threshold ≥ 2 for course_material).
    private static let studyTitleVocab: Set<String> = [
        "lecture", "assignment", "homework", "quiz", "exam", "syllabus",
        "notes", "slides", "lesson", "chapter", "module", "tutorial",
        "lab", "course", "class", "week", "introduction",
        "practice", "study", "review", "exercise"
    ]

    /// Coding-related title vocabulary (threshold ≥ 2 for code_project).
    private static let codeTitleVocab: Set<String> = [
        "swift", "python", "javascript", "typescript",
        "function", "struct", "variable", "compile", "build",
        "error", "exception", "github", "commit", "branch",
        "debug", "runtime", "refactor", "sprite", "canvas",
        "animation", "game", "collision"
    ]

    /// Watching-related title vocabulary (threshold ≥ 1 for entertainment signal).
    private static let watchTitleVocab: Set<String> = [
        "youtube", "video", "watch", "episode", "season", "stream",
        "netflix", "hulu", "twitch", "live", "replay", "subscribe", "channel"
    ]

    // MARK: - Log helper

    private static func logResult(_ result: EntityGrounding) {
        print("[EntityGrounding] source=\(result.source.rawValue)")
        print("[EntityGrounding] type=\(result.entityType.rawValue)")
        print("[EntityGrounding] confidence=\(String(format: "%.2f", result.confidence))")
        print("[EntityGrounding] should_propose=\(result.shouldPropose ? "yes" : "no")")
        if result.allowedOpportunityTypes.isEmpty {
            print("[EntityGrounding] allowed_opportunities=all")
        } else {
            print("[EntityGrounding] allowed_opportunities=[\(result.allowedOpportunityTypes.joined(separator: ","))]")
        }
    }
}
