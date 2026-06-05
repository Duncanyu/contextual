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
    // Phase 28.3: Made optional — model often omits this field, causing JSON parse failures.
    let sourceCategory: String?
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
        let isAITool = isAssistantTool(appName: input.appName, bundleId: input.bundleId) || isAssistantToolPage(input: input)
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

        // 6. Unknown Handling — try title-based deterministic fallback before storing unknown
        if result.confidence < 0.65 {
            if let titleFallback = titleBasedFallback(input: input, entityName: entityName) {
                print("[SemanticGrounding] model_low_confidence_title_fallback domain=\(titleFallback.domain) kind=\(titleFallback.entityKind)")
                cacheResult(key: cacheKey, result: titleFallback, ttl: 3600)
                return titleFallback
            }
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
            // Short TTL so deterministic fallbacks from context changes can repair quickly
            cacheResult(key: cacheKey, result: unknownResult, ttl: 120)
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

    private static let knownBrowserBundles: Set<String> = [
        "com.apple.safari", "org.mozilla.firefox", "com.google.chrome",
        "company.thebrowser.browser", "com.brave.browser", "com.microsoft.edgemac",
        "com.operasoftware.opera", "com.vivaldi.vivaldi"
    ]
    private static let knownBrowserApps: Set<String> = [
        "safari", "firefox", "google chrome", "chrome", "arc",
        "brave", "opera", "edge", "vivaldi", "orion"
    ]

    private func isAssistantTool(appName: String, bundleId: String) -> Bool {
        let app = appName.lowercased()
        let bid = bundleId.lowercased()
        if Self.knownBrowserApps.contains(app) { return false }
        if Self.knownBrowserBundles.contains(where: { bid.hasPrefix($0) }) { return false }
        let assistantKeywords = ["chatgpt", "claude", "perplexity", "gemini", "poe", "copilot"]
        return assistantKeywords.contains { app.contains($0) || bid.contains($0) }
    }

    private func isAssistantToolPage(input: SemanticGroundingInput) -> Bool {
        let assistantHosts = ["chatgpt.com", "claude.ai", "perplexity.ai",
                              "gemini.google.com", "poe.com", "copilot.microsoft.com"]
        let host = (input.browserSelectedURL ?? input.url)?.host?.lowercased() ?? ""
        if assistantHosts.contains(where: { host.contains($0) }) { return true }
        let isBrowser = Self.knownBrowserApps.contains(input.appName.lowercased())
            || Self.knownBrowserBundles.contains(where: { input.bundleId.lowercased().hasPrefix($0) })
        if isBrowser { return false }
        let assistantKeywords = ["chatgpt", "claude", "perplexity", "gemini", "poe", "copilot"]
        let title = (input.browserSelectedTitle ?? input.windowTitle).lowercased()
        return assistantKeywords.contains { title.contains($0) }
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
        let selectedTitle = (input.browserSelectedTitle ?? "").lowercased()
        let host = (input.browserSelectedURL ?? input.url)?.host?.lowercased() ?? ""
        let path = (input.browserSelectedURL ?? input.url)?.path.lowercased() ?? ""
        let query = URLComponents(url: input.browserSelectedURL ?? input.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?
            .percentEncodedQuery?
            .removingPercentEncoding?
            .lowercased() ?? ""
        let combinedVisibleText = [
            title,
            selectedTitle,
            input.axTextSnippet?.lowercased() ?? "",
            input.selectedTextSnippet?.lowercased() ?? "",
            query
        ].joined(separator: " ")

        let rentalDocumentTerms = ["accommodation", "agreement", "lease", "rental", "tenant", "landlord", "occupancy"]
        let legalRentalTerms = ["rta", "lease", "rent", "tenant", "tenancy", "landlord"]
        let isPDFLike = title.hasSuffix(".pdf")
            || path.hasSuffix(".pdf")
            || combinedVisibleText.contains("pdf")

        // ── Google Docs / cloud document editors with rental/legal terms ──
        let isCloudDoc = host.contains("docs.google.com")
            || host.contains("onedrive.live.com")
            || host.contains("sharepoint.com")
            || host.contains("notion.so")
        if isCloudDoc && rentalDocumentTerms.contains(where: { combinedVisibleText.contains($0) }) {
            return SemanticGroundingResult(
                entityName: entityName,
                entityKind: "rental_document",
                domain: "researching",
                activity: "lease_review",
                confidence: 0.94,
                source: "local_cloud_doc_rental_document",
                sourceCategory: "rental_document",
                shouldCreateDurableCompartment: true,
                shouldPropose: true,
                allowedLanes: ["research", "cognitive", "music", "friction", "workspace"],
                forbiddenLanes: ["entertainment"],
                rationale: "Cloud document editor with rental / lease terms"
            )
        }

        // ── Google Docs / cloud document editors (generic) ──
        if isCloudDoc {
            return SemanticGroundingResult(
                entityName: entityName,
                entityKind: "document",
                domain: "working",
                activity: "writing",
                confidence: 0.88,
                source: "local_cloud_doc_editor",
                sourceCategory: "working",
                shouldCreateDurableCompartment: true,
                shouldPropose: true,
                allowedLanes: ["workspace", "music", "friction", "cognitive", "research"],
                forbiddenLanes: ["entertainment"],
                rationale: "Cloud document editor"
            )
        }

        // ── Finance / investing platforms ──
        let financeHosts = ["wealthsimple.com", "questrade.com", "interactivebrokers.com",
                            "td.com", "rbcroyalbank.com", "scotiabank.com", "cibc.com",
                            "bmo.com", "fidelity.com", "vanguard.com", "schwab.com",
                            "robinhood.com", "etrade.com", "coinbase.com", "binance.com",
                            "yahoo.com/finance", "finance.yahoo.com", "google.com/finance",
                            "tradingview.com", "morningstar.com", "seekingalpha.com"]
        let financeTerms = ["xeqt", "veqt", "vgro", "etf", "stock", "portfolio", "dividend",
                            "tfsa", "rrsp", "invest", "ticker", "share", "fund", "market"]
        let isFinanceHost = financeHosts.contains(where: { host.contains($0) })
        let hasFinanceTerms = financeTerms.contains(where: { combinedVisibleText.contains($0) })
        if isFinanceHost || (hasFinanceTerms && !host.isEmpty) {
            return SemanticGroundingResult(
                entityName: entityName,
                entityKind: "finance_page",
                domain: "researching",
                activity: "reading",
                confidence: 0.90,
                source: "local_finance_platform",
                sourceCategory: "finance",
                shouldCreateDurableCompartment: false,
                shouldPropose: true,
                allowedLanes: ["research", "cognitive", "workspace"],
                forbiddenLanes: ["entertainment"],
                rationale: "Finance / investing platform or content"
            )
        }

        if isPDFLike && rentalDocumentTerms.contains(where: { combinedVisibleText.contains($0) }) {
            return SemanticGroundingResult(
                entityName: entityName,
                entityKind: "rental_document",
                domain: "researching",
                activity: "lease_review",
                confidence: 0.96,
                source: "local_pdf_rental_document",
                sourceCategory: "rental_document",
                shouldCreateDurableCompartment: true,
                shouldPropose: true,
                allowedLanes: ["research", "cognitive", "music", "friction", "workspace"],
                forbiddenLanes: ["entertainment"],
                rationale: "PDF-like document with rental / lease terms"
            )
        }

        if (host.contains("google.") || host.contains("bing.com"))
            && isSearchResultPage(input: input)
            && legalRentalTerms.contains(where: { combinedVisibleText.contains($0) }) {
            return SemanticGroundingResult(
                entityName: entityName,
                entityKind: "search_query",
                domain: "researching",
                activity: "legal_rental_research",
                confidence: 0.93,
                source: "local_search_rental_legal",
                sourceCategory: "legal_rental_research",
                shouldCreateDurableCompartment: false,
                shouldPropose: true,
                allowedLanes: ["research", "cognitive", "workspace"],
                forbiddenLanes: [],
                rationale: "Search results with rental / legal query terms"
            )
        }

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
                sourceCategory: response.sourceCategory ?? response.domain,
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

        // Google Docs fallback (model misclassified)
        if host.contains("docs.google.com") {
            return makeHostFallback(entityName: entityName, kind: "document", domain: "working", activity: "writing", source: "url_host_google_docs")
        }

        // Finance/investing fallback
        let financeFallbackHosts = ["wealthsimple.com", "questrade.com", "fidelity.com",
                                     "vanguard.com", "robinhood.com", "tradingview.com",
                                     "finance.yahoo.com", "morningstar.com", "seekingalpha.com",
                                     "coinbase.com", "schwab.com", "etrade.com"]
        if financeFallbackHosts.contains(where: { host.contains($0) }) {
            return makeHostFallback(entityName: entityName, kind: "finance_page", domain: "researching", activity: "reading", source: "url_host_finance")
        }

        // Title-based rental/housing fallback (no URL match but title has rental terms)
        let rentalTitleTerms: Set<String> = ["lease", "rental", "tenant", "landlord", "accommodation", "occupancy", "agreement"]
        if !titleTerms.intersection(rentalTitleTerms).isEmpty {
            return makeHostFallback(entityName: entityName, kind: "document", domain: "researching", activity: "lease_review", source: "title_rental_terms")
        }

        return nil
    }

    private func titleBasedFallback(input: SemanticGroundingInput, entityName: String) -> SemanticGroundingResult? {
        let title = entityName.lowercased()
        let titleTokens = Set(title.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 })

        let rentalTerms: Set<String> = ["lease", "rental", "tenant", "landlord", "accommodation", "occupancy", "agreement", "housing", "rent"]
        if titleTokens.intersection(rentalTerms).count >= 2 {
            return makeHostFallback(entityName: entityName, kind: "rental_document", domain: "researching", activity: "lease_review", source: "title_fallback_rental")
        }

        let financeTerms: Set<String> = ["xeqt", "veqt", "vgro", "etf", "stock", "portfolio", "dividend", "tfsa", "rrsp", "invest", "ticker", "fund"]
        if !titleTokens.intersection(financeTerms).isEmpty {
            return makeHostFallback(entityName: entityName, kind: "finance_page", domain: "researching", activity: "reading", source: "title_fallback_finance")
        }

        if title.contains("- google docs") || title.contains("- google sheets") || title.contains("- google slides") {
            return makeHostFallback(entityName: entityName, kind: "document", domain: "working", activity: "writing", source: "title_fallback_google_workspace")
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

enum SemanticGroundingSelfTest {
    static func run() async -> Bool {
        print("[SemanticGroundingSelfTest] starting")
        await SemanticGroundingEngine.shared.resetCache()
        var failures: [String] = []

        func check(_ name: String, _ ok: Bool) {
            if ok { print("[SemanticGroundingSelfTest] pass case=\(name)") }
            else { print("[SemanticGroundingSelfTest] fail case=\(name)"); failures.append(name) }
        }

        let inherited = await SemanticGroundingEngine.shared.ground(input: SemanticGroundingInput(
            appName: "Google Chrome",
            bundleId: "com.google.Chrome",
            windowTitle: "ChatGPT",
            url: URL(string: "https://chatgpt.com/c/123"),
            browserSelectedTitle: "ChatGPT",
            browserSelectedURL: URL(string: "https://chatgpt.com/c/123"),
            recentCompartment: TaskCompartment(
                workflow: .shopping,
                label: "Lease comparison",
                dominantTerms: ["lease", "rent"],
                entities: ["Lease comparison"],
                browserTabs: ["ChatGPT"]
            )
        ))
        check("assistant_tool_page_inherits_recent_compartment",
              inherited.source == "parent_compartment_inheritance" && inherited.entityName == "Lease comparison")

        // Firefox viewing Queen's Housing must NOT be detected as assistant_tool
        await SemanticGroundingEngine.shared.resetCache()
        let firefoxQueens = await SemanticGroundingEngine.shared.ground(input: SemanticGroundingInput(
            appName: "Firefox",
            bundleId: "org.mozilla.firefox",
            windowTitle: "Queen's Housing Rentals",
            url: URL(string: "https://housing.queensu.ca/rentals"),
            browserSelectedTitle: "Queen's Housing Rentals",
            browserSelectedURL: URL(string: "https://housing.queensu.ca/rentals"),
            recentCompartment: TaskCompartment(
                workflow: .researching,
                label: "182 Montreal",
                dominantTerms: ["lease", "montreal"],
                entities: ["182 Montreal"],
                browserTabs: ["Queen's Housing Rentals"]
            )
        ))
        check("firefox_queens_housing_not_assistant_tool",
              firefoxQueens.source != "parent_compartment_inheritance"
                && firefoxQueens.entityKind != "ai_assistant")

        // Chrome ChatGPT page SHOULD still be detected as assistant_tool
        await SemanticGroundingEngine.shared.resetCache()
        let chromeChatGPT = await SemanticGroundingEngine.shared.ground(input: SemanticGroundingInput(
            appName: "Google Chrome",
            bundleId: "com.google.Chrome",
            windowTitle: "ChatGPT",
            url: URL(string: "https://chatgpt.com/c/456"),
            browserSelectedTitle: "ChatGPT",
            browserSelectedURL: URL(string: "https://chatgpt.com/c/456"),
            recentCompartment: TaskCompartment(
                workflow: .coding,
                label: "My Project",
                dominantTerms: ["swift"],
                entities: ["My Project"],
                browserTabs: ["ChatGPT"]
            )
        ))
        check("chrome_chatgpt_still_detected_as_assistant",
              chromeChatGPT.source == "parent_compartment_inheritance"
                && chromeChatGPT.entityKind == "ai_assistant")

        let rentalPDF = await SemanticGroundingEngine.shared.ground(input: SemanticGroundingInput(
            appName: "Preview",
            bundleId: "com.apple.Preview",
            windowTitle: "Ontario Lease Agreement.pdf",
            url: nil,
            axTextSnippet: "Residential tenancy agreement lease rental accommodation"
        ))
        check("pdf_rental_document_fast_path",
              rentalPDF.entityKind == "rental_document" && rentalPDF.activity == "lease_review")

        let legalSearch = await SemanticGroundingEngine.shared.ground(input: SemanticGroundingInput(
            appName: "Google Chrome",
            bundleId: "com.google.Chrome",
            windowTitle: "Ontario RTA lease rent - Google Search",
            url: URL(string: "https://www.google.com/search?q=ontario+rta+lease+rent"),
            browserSelectedTitle: "Ontario RTA lease rent - Google Search",
            browserSelectedURL: URL(string: "https://www.google.com/search?q=ontario+rta+lease+rent")
        ))
        check("google_rental_legal_search_fast_path",
              legalSearch.domain == "researching" && legalSearch.activity == "legal_rental_research")

        // Google Docs lease — must not become creative_coding or unknown
        let googleDocsLease = await SemanticGroundingEngine.shared.ground(input: SemanticGroundingInput(
            appName: "Firefox",
            bundleId: "org.mozilla.firefox",
            windowTitle: "182 Montreal St - OCCUPANCY AGREEMENT - 2026 - Google Docs",
            url: URL(string: "https://docs.google.com/document/d/1vd394fgwp2vwrxrjx2hmcjewpcprou8izy_2y798r3y/edit"),
            browserSelectedTitle: "182 Montreal St - OCCUPANCY AGREEMENT - 2026 - Google Docs",
            browserSelectedURL: URL(string: "https://docs.google.com/document/d/1vd394fgwp2vwrxrjx2hmcjewpcprou8izy_2y798r3y/edit")
        ))
        check("google_docs_lease_grounds_as_rental_document",
              googleDocsLease.entityKind == "rental_document"
                && googleDocsLease.domain == "researching"
                && googleDocsLease.confidence >= 0.75)

        // Wealthsimple XEQT — must ground as finance, not streaming/unknown
        let wealthsimpleXEQT = await SemanticGroundingEngine.shared.ground(input: SemanticGroundingInput(
            appName: "Firefox",
            bundleId: "org.mozilla.firefox",
            windowTitle: "XEQT $44.74 (▼ 0.11%)",
            url: URL(string: "https://my.wealthsimple.com/app/security-details/sec-s-e7947deb977341ff9f0ddcf13703e9a6"),
            browserSelectedTitle: "XEQT $44.74 (▼ 0.11%)",
            browserSelectedURL: URL(string: "https://my.wealthsimple.com/app/security-details/sec-s-e7947deb977341ff9f0ddcf13703e9a6")
        ))
        check("wealthsimple_xeqt_grounds_as_finance",
              wealthsimpleXEQT.entityKind == "finance_page"
                && wealthsimpleXEQT.domain == "researching"
                && wealthsimpleXEQT.confidence >= 0.75)

        // Queen's Housing Rentals — housing service page
        let queensHousing = await SemanticGroundingEngine.shared.ground(input: SemanticGroundingInput(
            appName: "Firefox",
            bundleId: "org.mozilla.firefox",
            windowTitle: "Queen's Housing Rentals",
            url: URL(string: "https://housing.queensu.ca/rentals"),
            browserSelectedTitle: "Queen's Housing Rentals",
            browserSelectedURL: URL(string: "https://housing.queensu.ca/rentals")
        ))
        check("queens_housing_grounds_as_researching",
              queensHousing.domain == "researching"
                && queensHousing.confidence >= 0.70)

        // Generic Google Docs — should be working/document, not unknown
        let genericGDoc = await SemanticGroundingEngine.shared.ground(input: SemanticGroundingInput(
            appName: "Chrome",
            bundleId: "com.google.Chrome",
            windowTitle: "Meeting Notes - Google Docs",
            url: URL(string: "https://docs.google.com/document/d/abc123/edit"),
            browserSelectedTitle: "Meeting Notes - Google Docs",
            browserSelectedURL: URL(string: "https://docs.google.com/document/d/abc123/edit")
        ))
        check("generic_google_docs_grounds_as_working",
              genericGDoc.domain == "working"
                && genericGDoc.entityKind == "document"
                && genericGDoc.confidence >= 0.75)

        let ok = failures.isEmpty
        print("[SemanticGroundingSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
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
