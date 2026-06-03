import Foundation

public struct SemanticGroundingInput: Sendable {
    public let appName: String
    public let bundleId: String
    public let windowTitle: String
    public let url: URL?
    public let browserSelectedTitle: String?
    public let browserSelectedURL: URL?
    public let tabTitles: [String]
    public let axTextSnippet: String?
    public let selectedTextSnippet: String?
    public let recentCompartment: TaskCompartment?
    public let recentAppSwitches: [String]

    public init(
        appName: String,
        bundleId: String,
        windowTitle: String,
        url: URL?,
        browserSelectedTitle: String? = nil,
        browserSelectedURL: URL? = nil,
        tabTitles: [String] = [],
        axTextSnippet: String? = nil,
        selectedTextSnippet: String? = nil,
        recentCompartment: TaskCompartment? = nil,
        recentAppSwitches: [String] = []
    ) {
        self.appName = appName
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.url = url
        self.browserSelectedTitle = browserSelectedTitle
        self.browserSelectedURL = browserSelectedURL
        self.tabTitles = tabTitles
        self.axTextSnippet = axTextSnippet
        self.selectedTextSnippet = selectedTextSnippet
        self.recentCompartment = recentCompartment
        self.recentAppSwitches = recentAppSwitches
    }
}

public struct SemanticGroundingResult: Sendable, Codable, Equatable {
    public let entityName: String
    public let entityKind: String
    public let domain: String
    public let activity: String
    public let confidence: Double
    public let source: String
    public let sourceCategory: String
    public let shouldCreateDurableCompartment: Bool
    public let shouldPropose: Bool
    public let allowedLanes: [String]
    public let forbiddenLanes: [String]
    public let rationale: String

    public static let unknown = SemanticGroundingResult(
        entityName: "unknown",
        entityKind: "unknown",
        domain: "unknown",
        activity: "unknown",
        confidence: 0.0,
        source: "fallback",
        sourceCategory: "unknown",
        shouldCreateDurableCompartment: false,
        shouldPropose: false,
        allowedLanes: [],
        forbiddenLanes: [],
        rationale: "Unknown entity"
    )
}

struct GroundingLookupResponse: Codable {
    let entityKind: String
    let domain: String
    let activity: String
    let confidence: Double
    let rationale: String
    let sourceCategory: String
}

public actor SemanticGroundingEngine {
    public static let shared = SemanticGroundingEngine()

    private var cache: [String: (result: SemanticGroundingResult, expiry: Date)] = [:]
    private var pendingQueries: Set<String> = []

    private init() {}

    public func resetCache() {
        cache.removeAll()
        pendingQueries.removeAll()
    }

    /// Evaluates semantic grounding for the given context.
    public func ground(input: SemanticGroundingInput) async -> SemanticGroundingResult {
        // 1. Assistant Tool Inheritance
        let isAITool = isAssistantTool(appName: input.appName, bundleId: input.bundleId)
        if isAITool, let recentComp = input.recentCompartment {
            print("[SemanticGrounding] assistant_tool detected appName=\(input.appName) inheriting_parent=\(recentComp.label)")
            return SemanticGroundingResult(
                entityName: recentComp.label,
                entityKind: "ai_assistant",
                domain: recentComp.workflow.rawValue,
                activity: recentComp.workflow == .coding ? "editing_code" : "searching",
                confidence: 0.95,
                source: "parent_compartment_inheritance",
                sourceCategory: "ai_assistant",
                shouldCreateDurableCompartment: true,
                shouldPropose: true,
                allowedLanes: ["workspace", "music", "friction", "cognitive"],
                forbiddenLanes: ["entertainment"],
                rationale: "Inherited from parent compartment: \(recentComp.label)"
            )
        }

        let entityName = getEntityName(input: input)
        let cacheKey = getCacheKey(input: input, entityName: entityName)

        // 2. Cache check
        if let cached = getCachedResult(key: cacheKey) {
            print("[SemanticGroundingCache] hit=yes key=\(cacheKey)")
            return cached
        }
        print("[SemanticGroundingCache] hit=no key=\(cacheKey)")

        print("[SemanticGrounding] started entity=\"\(entityName)\"")

        // 3. Layer 1: Local Deterministic Rules
        if let localResult = groundLocally(input: input, entityName: entityName) {
            print("[SemanticGrounding] local_confidence=\(String(format: "%.2f", localResult.confidence))")
            if localResult.confidence >= 0.75 {
                print("[SemanticGrounding] final domain=\(localResult.domain) entity_kind=\(localResult.entityKind) source=\(localResult.source)")
                let ttl: TimeInterval = 7 * 24 * 3600
                cacheResult(key: cacheKey, result: localResult, ttl: ttl)
                return localResult
            }
        }

        // 4. Layer 2: URL Metadata check
        if let url = input.browserSelectedURL ?? input.url {
            let host = url.host?.lowercased() ?? ""
            let path = url.path.lowercased()
            if host.contains("youtube.com") && (path.contains("watch") || path.contains("shorts")) {
                let isShorts = path.contains("shorts")
                let result = SemanticGroundingResult(
                    entityName: entityName,
                    entityKind: isShorts ? "youtube_shorts" : "youtube_video",
                    domain: "watching",
                    activity: "watching",
                    confidence: 0.95,
                    source: "url_metadata",
                    sourceCategory: "streaming_site",
                    shouldCreateDurableCompartment: false,
                    shouldPropose: false,
                    allowedLanes: isShorts ? [] : ["comfort"],
                    forbiddenLanes: ["cognitive", "music"],
                    rationale: "YouTube video URL"
                )
                print("[SemanticGrounding] final domain=watching entity_kind=\(result.entityKind) source=url_metadata")
                cacheResult(key: cacheKey, result: result, ttl: 7 * 24 * 3600)
                return result
            }
        }

        // 5. Layer 3: Local Model Classification
        let result = await performLookup(entityName: entityName, input: input)
        
        // 6. Unknown Handling
        if result.confidence < 0.65 {
            print("[SemanticGrounding] low_confidence result=unknown should_create_durable=false should_propose=false")
            let unknownResult = SemanticGroundingResult(
                entityName: entityName,
                entityKind: "unknown",
                domain: "unknown",
                activity: "unknown",
                confidence: result.confidence,
                source: result.source,
                sourceCategory: "unknown",
                shouldCreateDurableCompartment: false,
                shouldPropose: false,
                allowedLanes: [],
                forbiddenLanes: [],
                rationale: result.rationale
            )
            cacheResult(key: cacheKey, result: unknownResult, ttl: 600) // 10 mins for low confidence
            return unknownResult
        }

        // Cache the result
        let ttl: TimeInterval = isSearchResultPage(input: input) ? 3600 : 7 * 24 * 3600
        cacheResult(key: cacheKey, result: result, ttl: ttl)

        print("[SemanticGrounding] final domain=\(result.domain) entity_kind=\(result.entityKind) source=\(result.source)")
        return result
    }

    // MARK: - Helpers

    private func getEntityName(input: SemanticGroundingInput) -> String {
        if let title = input.browserSelectedTitle, !title.isEmpty { return title }
        if !input.windowTitle.isEmpty { return input.windowTitle }
        return input.appName
    }

    private func isAssistantTool(appName: String, bundleId: String) -> Bool {
        let app = appName.lowercased()
        let bid = bundleId.lowercased()
        let assistantKeywords = ["chatgpt", "claude", "perplexity", "gemini", "poe", "copilot"]
        return assistantKeywords.contains { app.contains($0) || bid.contains($0) }
    }

    private func isSearchResultPage(input: SemanticGroundingInput) -> Bool {
        let title = getEntityName(input: input).lowercased()
        let url = (input.browserSelectedURL ?? input.url)?.absoluteString.lowercased() ?? ""
        return title.contains("google search") || url.contains("google.com/search")
    }

    private func getCacheKey(input: SemanticGroundingInput, entityName: String) -> String {
        if let url = input.browserSelectedURL ?? input.url {
            let host = url.host?.lowercased() ?? ""
            let path = url.path.lowercased()
            return "\(host)\(path)"
        }
        return "\(input.appName.lowercased())|\(entityName.lowercased())"
    }

    private func getCachedResult(key: String) -> SemanticGroundingResult? {
        guard let entry = cache[key] else { return nil }
        if Date() < entry.expiry {
            return entry.result
        }
        return nil
    }

    private func cacheResult(key: String, result: SemanticGroundingResult, ttl: TimeInterval) {
        cache[key] = (result, Date().addingTimeInterval(ttl))
        print("[SemanticGroundingCache] stored ttl_s=\(Int(ttl)) key=\(key)")
    }

    private func groundLocally(input: SemanticGroundingInput, entityName: String) -> SemanticGroundingResult? {
        let app = input.appName.lowercased()
        let bid = input.bundleId.lowercased()
        let title = entityName.lowercased()

        // ── Obvious Media Apps ───────────────────────────────────────
        if app == "spotify" || app == "music" || app == "vlc" || app == "iina" {
            return SemanticGroundingResult(
                entityName: entityName,
                entityKind: "music_app",
                domain: "media",
                activity: "listening",
                confidence: 0.95,
                source: "app_metadata",
                sourceCategory: "media",
                shouldCreateDurableCompartment: false,
                shouldPropose: false,
                allowedLanes: ["comfort"],
                forbiddenLanes: ["cognitive", "workspace"],
                rationale: "Media app focus"
            )
        }

        // ── Xcode / Coding Fast-Path ──────────────────────────────────
        let codingExtensions = [".swift", ".py", ".js", ".java", ".cpp", ".h", ".m", ".ts", ".go", ".rs"]
        let hasCodeExtension = codingExtensions.contains { title.hasSuffix($0) }
        
        if app == "xcode" || bid == "com.apple.dt.xcode" || app == "visual studio code" || bid.contains("vscode") || hasCodeExtension {
            return SemanticGroundingResult(
                entityName: entityName,
                entityKind: app.contains("xcode") ? "code_editor" : "source_code_file",
                domain: "coding",
                activity: "editing_code",
                confidence: 0.95,
                source: "app_bundle+file_extension+title",
                sourceCategory: "coding",
                shouldCreateDurableCompartment: true,
                shouldPropose: true,
                allowedLanes: ["workspace", "music", "friction", "cognitive"],
                forbiddenLanes: ["entertainment"],
                rationale: "Coding environment fast-path"
            )
        }

        // ── Search Query Fast-Path ────────────────────────────────────
        if isSearchResultPage(input: input) {
            return SemanticGroundingResult(
                entityName: entityName,
                entityKind: "search_query",
                domain: "browsing",
                activity: "searching",
                confidence: 0.85,
                source: "url_metadata",
                sourceCategory: "search_query",
                shouldCreateDurableCompartment: false,
                shouldPropose: true,
                allowedLanes: ["research", "cognitive_light"],
                forbiddenLanes: [],
                rationale: "Search result page"
            )
        }

        // ── Taxonomy Lookup ──────────────────────────────────────────
        if let entry = SemanticGroundingTaxonomy.lookup(appName: input.appName, bundleId: input.bundleId, title: entityName) {
            let isEntertainment = entry.domain == "watching" || entry.domain == "gaming" || entry.domain == "media"
            
            // Map lanes based on domain
            let lanes: (allowed: [String], forbidden: [String]) = {
                switch entry.domain {
                case "coding", "creative_coding", "studying", "researching", "working":
                    return (["workspace", "music", "friction", "cognitive"], ["entertainment"])
                case "gaming":
                    if entry.entityKind == "competitive_game" {
                        return (["comfort"], ["music", "cognitive", "workspace"])
                    }
                    return (["comfort", "music"], ["cognitive"])
                case "watching", "media":
                    return (["comfort"], ["music", "cognitive", "workspace"])
                case "designing":
                    return (["workspace", "music", "friction"], ["entertainment"])
                default:
                    return (["browsing"], [])
                }
            }()

            return SemanticGroundingResult(
                entityName: entityName,
                entityKind: entry.entityKind,
                domain: entry.domain,
                activity: entry.activity,
                confidence: 0.95,
                source: "taxonomy_lookup",
                sourceCategory: entry.domain,
                shouldCreateDurableCompartment: !isEntertainment && entry.domain != "browsing",
                shouldPropose: !isEntertainment,
                allowedLanes: lanes.allowed,
                forbiddenLanes: lanes.forbidden,
                rationale: "Taxonomy match for \(entityName)"
            )
        }

        return nil
    }

    private func performLookup(entityName: String, input: SemanticGroundingInput) async -> SemanticGroundingResult {
        let url = input.browserSelectedURL ?? input.url
        
        // Phase 28.2 — Prompt rewritten to prevent pipe-delimited enum output.
        // The old format showed "value1|value2|..." which the model sometimes copied verbatim.
        // New format lists allowed values separately and instructs to choose exactly one.
        let prompt = """
        Classify the public app/window/page metadata below.
        Return strict JSON only. Do not include prose.

        Metadata:
        appName=\(input.appName)
        bundleId=\(input.bundleId)
        windowTitle=\(entityName)
        urlHost=\(url?.host ?? "")
        urlPath=\(url?.path ?? "")
        pageTitle=\(input.browserSelectedTitle ?? "")
        fileExtension=\(URL(fileURLWithPath: entityName).pathExtension)

        Choose EXACTLY ONE value for each field from the allowed values.
        Do NOT list multiple values. Do NOT use "|" in any value.

        Allowed entityKind values: source_code_file, code_editor, creative_coding_project, game, competitive_game, tv_show, streaming_site, youtube_video, music_app, design_tool, productivity_tool, ai_assistant, search_query, document, spreadsheet, slide_deck, website, unknown
        Allowed domain values: coding, creative_coding, gaming, watching, studying, researching, working, designing, communicating, browsing, media, unknown
        Allowed activity values: editing_code, building, playing, competitive_play, watching, searching, reading, writing, designing, communicating, listening, unknown

        Return JSON:
        {"entityKind": "ONE_VALUE", "domain": "ONE_VALUE", "activity": "ONE_VALUE", "confidence": 0.8, "rationale": "brief reason", "sourceCategory": "local_model"}
        """

        print("[SemanticGroundingLookup] started classification for entity=\"\(entityName)\"")
        
        do {
            let model = "qwen2.5:0.5b"
            let raw = try await LocalAIClient.shared.generate(
                prompt: prompt,
                model: model,
                numPredict: 256,
                temperature: 0.1,
                purpose: "semantic_grounding",
                schema: nil
            )
            
            print("[SemanticGroundingLookup] raw=\(raw)")
            
            // Clean up possible markdown wrappers
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let data = cleaned.data(using: .utf8) else {
                print("[SemanticGroundingLookup] parse_status=failed reason=invalid_utf8")
                return .unknown
            }
            
            let decoder = JSONDecoder()
            let response: GroundingLookupResponse
            do {
                response = try decoder.decode(GroundingLookupResponse.self, from: data)
            } catch {
                print("[SemanticGroundingLookup] parse_status=failed reason=invalid_json error=\(error)")
                return .unknown
            }
            
            print("[SemanticGroundingLookup] parse_status=success validated=yes")
            
            // Validate enums
            let validKinds: Set<String> = ["source_code_file", "code_editor", "creative_coding_project", "game", "competitive_game", "tv_show", "streaming_site", "youtube_video", "music_app", "design_tool", "productivity_tool", "ai_assistant", "search_query", "document", "spreadsheet", "slide_deck", "website", "unknown"]
            let validDomains: Set<String> = ["coding", "creative_coding", "gaming", "watching", "studying", "researching", "working", "designing", "communicating", "browsing", "media", "unknown"]
            
            // Phase 28.2 — Detect pipe-delimited enum output (model copies allowed values).
            // If value contains "|", the model returned the enum list instead of choosing one.
            // Fall back to URL/host-based deterministic grounding instead of unknown.
            let hasPipeKind = response.entityKind.contains("|")
            let hasPipeDomain = response.domain.contains("|")
            if hasPipeKind || hasPipeDomain {
                print("[SemanticGroundingLookup] rejected reason=pipe_delimited_enum kind=\(response.entityKind) domain=\(response.domain)")
                // Try URL host fallback before returning unknown
                if let fallback = urlHostFallback(input: input, entityName: entityName) {
                    print("[SemanticGroundingLookup] fallback=url_host_deterministic domain=\(fallback.domain)")
                    return fallback
                }
                return .unknown
            }

            guard validKinds.contains(response.entityKind), validDomains.contains(response.domain) else {
                print("[SemanticGroundingLookup] rejected reason=invalid_enum kind=\(response.entityKind) domain=\(response.domain)")
                if let fallback = urlHostFallback(input: input, entityName: entityName) {
                    print("[SemanticGroundingLookup] fallback=url_host_deterministic domain=\(fallback.domain)")
                    return fallback
                }
                return .unknown
            }

            if response.confidence < 0.65 {
                print("[SemanticGroundingLookup] rejected reason=low_confidence score=\(response.confidence)")
                return .unknown
            }

            let isEntertainment = response.domain == "watching" || response.domain == "gaming" || response.domain == "media"
            
            // Map lanes based on domain
            let lanes: (allowed: [String], forbidden: [String]) = {
                switch response.domain {
                case "coding", "creative_coding", "studying", "researching", "working":
                    return (["workspace", "music", "friction", "cognitive"], ["entertainment"])
                case "gaming":
                    if response.entityKind == "competitive_game" {
                        return (["comfort"], ["music", "cognitive", "workspace"])
                    }
                    return (["comfort", "music"], ["cognitive"])
                case "watching", "media":
                    return (["comfort"], ["music", "cognitive", "workspace"])
                case "designing":
                    return (["workspace", "music", "friction"], ["entertainment"])
                default:
                    return (["browsing"], [])
                }
            }()

            return SemanticGroundingResult(
                entityName: entityName,
                entityKind: response.entityKind,
                domain: response.domain,
                activity: response.activity,
                confidence: response.confidence,
                source: "local_model",
                sourceCategory: response.sourceCategory,
                shouldCreateDurableCompartment: !isEntertainment && response.domain != "browsing" && response.domain != "unknown",
                shouldPropose: !isEntertainment,
                allowedLanes: lanes.allowed,
                forbiddenLanes: lanes.forbidden,
                rationale: response.rationale
            )
        } catch {
            print("[SemanticGroundingLookup] parse_status=failed error=\(error)")
            return .unknown
        }
    }

    // Phase 28.2 — Deterministic URL host-based grounding fallback.
    // When the model fails (pipe-delimited output, invalid enum, etc.),
    // use URL host patterns for obvious pages.
    private func urlHostFallback(input: SemanticGroundingInput, entityName: String) -> SemanticGroundingResult? {
        let url = input.browserSelectedURL ?? input.url
        let host = url?.host?.lowercased() ?? ""
        let path = url?.path.lowercased() ?? ""
        let title = entityName.lowercased()
        let rentalTerms: Set<String> = ["housing", "rental", "rent", "listing", "accommodation", "landlord", "off-campus", "apartment", "lease", "tenant"]
        let titleTerms = Set(title.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 })
        let hasRentalTerms = !titleTerms.intersection(rentalTerms).isEmpty

        // Google/Bing search pages
        if host.contains("google.") && path.contains("/search") {
            return makeHostFallback(entityName: entityName, kind: "search_query", domain: "researching", activity: "searching", source: "url_host_google_search")
        }
        if host.contains("bing.com") && path.contains("/search") {
            return makeHostFallback(entityName: entityName, kind: "search_query", domain: "researching", activity: "searching", source: "url_host_bing_search")
        }

        // Housing/listing service pages
        if host.contains("housing") || host.contains("listing") || (hasRentalTerms && (host.contains(".edu") || host.contains(".ca") || host.contains(".ac."))) {
            return makeHostFallback(entityName: entityName, kind: "website", domain: "researching", activity: "searching", source: "url_host_housing_service")
        }

        // Reddit/forum with housing terms
        if (host.contains("reddit.com") || host.contains("facebook.com")) && hasRentalTerms {
            return makeHostFallback(entityName: entityName, kind: "website", domain: "researching", activity: "reading", source: "url_host_forum_housing")
        }

        // Reddit/forum general
        if host.contains("reddit.com") {
            return makeHostFallback(entityName: entityName, kind: "website", domain: "browsing", activity: "reading", source: "url_host_reddit")
        }

        // General search results (title contains " - Google Search", " - Bing", etc.)
        if title.contains("google search") || title.contains("- bing") || title.contains("- search") {
            return makeHostFallback(entityName: entityName, kind: "search_query", domain: "researching", activity: "searching", source: "title_search_pattern")
        }

        return nil
    }

    private func makeHostFallback(entityName: String, kind: String, domain: String, activity: String, source: String) -> SemanticGroundingResult {
        let isEntertainment = domain == "watching" || domain == "gaming" || domain == "media"
        let lanes: (allowed: [String], forbidden: [String]) = {
            switch domain {
            case "coding", "creative_coding", "studying", "researching", "working":
                return (["workspace", "music", "friction", "cognitive", "research"], ["entertainment"])
            case "browsing":
                return (["research", "cognitive"], [])
            default:
                return (["browsing"], [])
            }
        }()
        return SemanticGroundingResult(
            entityName: entityName,
            entityKind: kind,
            domain: domain,
            activity: activity,
            confidence: 0.75,
            source: source,
            sourceCategory: domain,
            shouldCreateDurableCompartment: domain == "researching",
            shouldPropose: !isEntertainment,
            allowedLanes: lanes.allowed,
            forbiddenLanes: lanes.forbidden,
            rationale: "URL host deterministic fallback"
        )
    }
}

// MARK: - Taxonomy

struct TaxonomyEntry {
    let entityKind: String
    let domain: String
    let activity: String
}

enum SemanticGroundingTaxonomy {
    private static let appMap: [String: TaxonomyEntry] = [
        "minecraft": TaxonomyEntry(entityKind: "game", domain: "gaming", activity: "playing"),
        "valorant": TaxonomyEntry(entityKind: "competitive_game", domain: "gaming", activity: "competitive_play"),
        "turbowarp": TaxonomyEntry(entityKind: "creative_coding_project", domain: "creative_coding", activity: "building"),
        "scratch": TaxonomyEntry(entityKind: "creative_coding_project", domain: "creative_coding", activity: "building"),
        "dexter": TaxonomyEntry(entityKind: "tv_show", domain: "watching", activity: "watching"),
        "cineby": TaxonomyEntry(entityKind: "streaming_site", domain: "watching", activity: "watching"),
        "obsidian": TaxonomyEntry(entityKind: "productivity_tool", domain: "working", activity: "writing"),
        "piskel": TaxonomyEntry(entityKind: "design_tool", domain: "designing", activity: "designing"),
        "aseprite": TaxonomyEntry(entityKind: "design_tool", domain: "designing", activity: "designing"),
        "blender": TaxonomyEntry(entityKind: "design_tool", domain: "designing", activity: "designing"),
        "unity": TaxonomyEntry(entityKind: "code_editor", domain: "coding", activity: "building"),
        "roblox studio": TaxonomyEntry(entityKind: "code_editor", domain: "coding", activity: "building"),
        "davinci resolve": TaxonomyEntry(entityKind: "design_tool", domain: "designing", activity: "designing"),
        "lm studio": TaxonomyEntry(entityKind: "ai_assistant", domain: "researching", activity: "searching"),
        "open webui": TaxonomyEntry(entityKind: "ai_assistant", domain: "researching", activity: "searching")
    ]

    static func lookup(appName: String, bundleId: String, title: String) -> TaxonomyEntry? {
        let app = appName.lowercased()
        let bid = bundleId.lowercased()
        let t = title.lowercased()

        for (key, entry) in appMap {
            if app.contains(key) || bid.contains(key) || t.contains(key) {
                return entry
            }
        }
        return nil
    }
}
