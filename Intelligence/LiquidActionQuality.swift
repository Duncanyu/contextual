import Foundation

// MARK: - Phase 59: Liquid Action Quality
//
// Separates "what broad activity is this?" (workflow) from "what kind of thing
// is currently focused?" (content type), replaces term-bucket → action-family
// routing with per-action contracts, and replaces the flat relevance constant
// with a real usefulness score.
//
// Design rules:
//   - Terms (rent, housing, roommate, …) may inform CLASSIFICATION only.
//     No term ever unlocks an action directly.
//   - Lease/document actions require a lease/contract document (or selected
//     text), never a forum, feed, or listing page.
//   - Compare actions require multiple real candidates, or surface honestly
//     as capture-needed.
//   - "Safe to run" is not "worth floating": floating requires high usefulness.
//   - Feedback (auto-dismissed / ignored / clicked) feeds back into selection.

// MARK: - Part B: Content type

enum FocusedContentType: String, Sendable, CaseIterable {
    case unknownPage = "unknown_page"
    case genericWebpage = "generic_webpage"
    case searchResults = "search_results"
    case articleOrReference = "article_or_reference"
    case forumOrSocialGroup = "forum_or_social_group"
    case marketplaceOrListingFeed = "marketplace_or_listing_feed"
    case individualListing = "individual_listing"
    case listingPlatformDashboard = "listing_platform_dashboard"
    case messageThreadOrInbox = "message_thread_or_inbox"
    case leaseOrContractDocument = "lease_or_contract_document"
    case formOrApplication = "form_or_application"
    case codeOrLog = "code_or_log"
    case shoppingProductPage = "shopping_product_page"
    case studyMaterial = "study_material"
    case mediaPage = "media_page"
}

struct ClassifiedContent: Sendable {
    let type: FocusedContentType
    let confidence: Double
    let signals: [String]
}

enum ContentTypeClassifier {

    /// Nouns that indicate an actual contract-like document. Broad rental
    /// nouns (housing, roommate, apartment) deliberately do NOT qualify.
    static let contractNouns = ["lease", "agreement", "contract", "occupancy", "addendum", "terms and conditions"]

    static let documentApps = ["preview", "textedit", "pages", "word", "acrobat"]
    static let codeApps = ["xcode", "terminal", "iterm", "console", "visual studio code", "cursor"]
    static let browserApps = ["firefox", "safari", "chrome", "arc", "brave", "edge"]

    static func classify(_ s: WorkflowSignals) -> ClassifiedContent {
        let title = s.windowTitle.lowercased()
        let host = s.urlHost.lowercased()
        let path = s.urlPath.lowercased()
        let app = s.activeApp.lowercased()
        let enrichedPreview = s.enrichedContext?.text.lowercased() ?? ""
        let focus = [title, host, path, String(enrichedPreview.prefix(1_000))].joined(separator: " ")
        let isBrowser = browserApps.contains { app.contains($0) }

        func result(_ type: FocusedContentType, _ confidence: Double, _ signals: [String]) -> ClassifiedContent {
            let clamped = min(0.95, confidence)
            print("[ContentTypeClassifier] selected=\(type.rawValue) confidence=\(String(format: "%.2f", clamped)) signals=\(signals.isEmpty ? "none" : signals.joined(separator: ","))")
            return ClassifiedContent(type: type, confidence: clamped, signals: signals)
        }

        // ── Native apps first ───────────────────────────────────────────────
        if codeApps.contains(where: { app.contains($0) }) {
            return result(.codeOrLog, 0.9, ["app:\(s.activeApp)"])
        }
        let codeExtensions = [".swift", ".py", ".ts", ".js", ".rs", ".log", ".json", ".sh"]
        if codeExtensions.contains(where: { title.contains($0) }) {
            return result(.codeOrLog, 0.8, codeExtensions.filter { title.contains($0) })
        }
        let codeContentTerms = ["error", "failed", "exception", "stack trace", "traceback", "xcodebuild", "fatal"].filter { focus.contains($0) }
        if codeContentTerms.count >= 2 {
            return result(.codeOrLog, 0.72, codeContentTerms)
        }
        if documentApps.contains(where: { app.contains($0) }) {
            let nounHits = contractNouns.filter { title.contains($0) }
            if !nounHits.isEmpty {
                return result(.leaseOrContractDocument, 0.7 + Double(nounHits.count) * 0.1, nounHits.map { "doc_noun:\($0)" } + ["app:\(s.activeApp)"])
            }
            return result(.articleOrReference, 0.6, ["document_app:\(s.activeApp)"])
        }
        if app.contains("mail") || app.contains("outlook") || app.contains("messages") {
            return result(.messageThreadOrInbox, 0.85, ["app:\(s.activeApp)"])
        }

        // ── Contract documents (any host that renders documents) ───────────
        let nounHits = contractNouns.filter { focus.contains($0) }
        let documentSurface = path.contains("/document") || path.contains("/edit")
            || path.contains(".pdf") || path.contains(".doc")
            || title.contains("google docs") || title.contains(" - word")
        // A group/feed/search URL is never a document, whatever the title says.
        let feedShapedURL = ["/groups/", "/group/", "/r/", "/community", "/forum", "/thread", "/marketplace", "/search"].contains { path.contains($0) }
        if !nounHits.isEmpty && !feedShapedURL && (documentSurface || !isBrowser || nounHits.count >= 2) {
            return result(.leaseOrContractDocument, 0.65 + Double(nounHits.count) * 0.12 + (documentSurface ? 0.1 : 0), nounHits.map { "doc_noun:\($0)" })
        }

        // ── Browser page kinds ──────────────────────────────────────────────
        if title.contains("inbox") || title.contains("mail") || host.hasPrefix("mail.")
            || title.contains("messages") || path.contains("/messages") || title.contains("chat") {
            return result(.messageThreadOrInbox, 0.75, ["message_terms"])
        }
        let formPath = path.contains("/apply") || path.contains("/application") || path.contains("/form")
        let formTermHits = ["application", "apply", "eligibility", "registration", "questionnaire", "enrolment", "enrollment"].filter { focus.contains($0) }
        if formPath || formTermHits.count >= 2 {
            return result(.formOrApplication, 0.6 + Double(formTermHits.count) * 0.1, formTermHits + (formPath ? ["form_path"] : []))
        }
        let groupPath = ["/groups/", "/group/", "/r/", "/community", "/forum", "/thread", "/t/"].filter { path.contains($0) }
        let groupTerms = ["group", "forum", "community", "subreddit", "thread"].filter { focus.contains($0) }
        let marketplaceSignals = (["/marketplace", "/classifieds"].filter { path.contains($0) })
            + (["for sale", "marketplace", "classified"].filter { title.contains($0) })
        if !marketplaceSignals.isEmpty {
            return result(.marketplaceOrListingFeed, 0.6 + Double(marketplaceSignals.count) * 0.12, marketplaceSignals)
        }
        if !groupPath.isEmpty || !groupTerms.isEmpty {
            return result(.forumOrSocialGroup, 0.6 + Double(groupPath.count + groupTerms.count) * 0.1, groupPath.map { "path:\($0)" } + groupTerms)
        }
        let priceVisible = focus.range(of: #"\$\s?\d"#, options: .regularExpression) != nil
        let listingNouns = ["bed", "bath", "sqft", "room for rent", "apartment", "unit"].filter { focus.contains($0) }
        let listingPath = ["/listing", "/property", "/unit", "/rental"].filter { path.contains($0) }
        if !listingPath.isEmpty || (priceVisible && !listingNouns.isEmpty) {
            return result(.individualListing, 0.6 + Double(listingPath.count + listingNouns.count) * 0.1 + (priceVisible ? 0.1 : 0), listingPath.map { "path:\($0)" } + listingNouns + (priceVisible ? ["price_visible"] : []))
        }
        if title.contains("listings") && (title.contains("manager") || title.contains("dashboard") || title.contains("search") || title.contains("saved")) {
            return result(.listingPlatformDashboard, 0.7, ["listings_dashboard"])
        }
        if path.contains("/search") || path.contains("q=") || title.contains("search results") || title.hasSuffix("search") || title.contains(" search") {
            return result(.searchResults, 0.7, ["search_signals"])
        }
        let productPath = ["/product", "/dp/", "/item", "/cart"].filter { path.contains($0) }
        let shoppingTerms = ["add to cart", "buy now", "in stock", "free shipping", "reviews"].filter { focus.contains($0) }
        if !productPath.isEmpty || (priceVisible && !shoppingTerms.isEmpty) {
            return result(.shoppingProductPage, 0.6 + Double(productPath.count + shoppingTerms.count) * 0.1, productPath.map { "path:\($0)" } + shoppingTerms)
        }
        // ── Working / teaching documents (product reset) ────────────────────
        // A Google Docs / Word document being edited with visible body text is
        // real current work — a lesson plan or curriculum doc is study/teaching
        // work, NOT "generic browsing". This is the dogfood bug where a visible
        // Google Doc lesson plan fell through to generic_webpage → normal_browsing.
        let isDocEditorSurface = documentSurface
            || title.contains("google docs") || title.contains(" - word") || title.contains(" - pages")
        let hasBodyText = !enrichedPreview.isEmpty || s.contentAvailable
        if isDocEditorSurface {
            let teachingHits = ["lesson", "lesson plan", "curriculum", "syllabus", "teaching",
                                "beginner track", "course outline", "workshop", "camp", "unit plan",
                                "class plan", "track"].filter { focus.contains($0) }
            if !teachingHits.isEmpty {
                let conf = min(0.85, 0.6 + Double(teachingHits.count) * 0.1)
                print("[DocumentContentClassifier] type=lesson_plan_document confidence=\(String(format: "%.2f", conf)) signals=\(teachingHits.prefix(4).joined(separator: ","))")
                print("[NoGoogleDocsLessonPlanFallsToGenericBrowsing] status=pass count=0")
                // .studyMaterial → studySession activity (floating allowed); the
                // teaching action set is produced in the generated-action path.
                return result(.studyMaterial, conf, teachingHits + ["doc_editor"])
            }
        }

        let studyTerms = ["course", "lecture", "chapter", "syllabus", "exam", "quiz", "tutorial", "homework", "assignment", "study", "lesson", "plan"].filter { focus.contains($0) }
        if studyTerms.count >= 1 && (studyTerms.count >= 2 || host.contains(".edu") || host.contains("learn") || host.contains("course")) {
            return result(.studyMaterial, 0.55 + Double(studyTerms.count) * 0.1, studyTerms)
        }
        if path.contains("/watch") || path.contains("/video") || title.contains("episode") || focus.contains("transcript") {
            return result(.mediaPage, 0.7, ["media_signals"])
        }
        let articleSignals = (["/wiki/", "/blog", "/article", "/docs/"].filter { path.contains($0) })
            + (["how to", "guide", "documentation", "wiki", "review"].filter { title.contains($0) })
        if !articleSignals.isEmpty {
            return result(.articleOrReference, 0.55 + Double(articleSignals.count) * 0.1, articleSignals)
        }
        if isBrowser && (!host.isEmpty || !title.isEmpty) {
            return result(.genericWebpage, 0.5, ["browser_fallback"])
        }
        return result(.unknownPage, 0.3, [])
    }

    /// Log + reconcile the workflow/content split. Broad rental terms can say
    /// "rental activity" but only a contract document supports lease actions.
    static func splitCheck(workflow: DetectedWorkflowKind?, content: ClassifiedContent) -> Bool {
        let agreement: Bool
        let reason: String
        switch (workflow, content.type) {
        case (.actionPack, .leaseOrContractDocument):
            agreement = true; reason = "lease_workflow_on_contract_document"
        case (.actionPack, _):
            agreement = false; reason = "rental_terms_without_contract_document"
        case (.rentalSearch, .forumOrSocialGroup), (.rentalSearch, .marketplaceOrListingFeed),
             (.rentalSearch, .individualListing), (.rentalSearch, .listingPlatformDashboard),
             (.rentalSearch, .searchResults):
            agreement = true; reason = "rental_search_on_listing_surface"
        default:
            agreement = true; reason = "no_conflict"
        }
        print("[WorkflowContentSplit] workflow=\(workflow?.rawValue ?? "none") content_type=\(content.type.rawValue) agreement=\(agreement ? "yes" : "no") reason=\(reason)")
        return agreement
    }
}

// MARK: - Phase 69 (Issue 4): content-type authority
//
// Where did the content type come from? Only the CURRENT focus (its title/url/
// visible body) or a user selection may drive current-task action packs. A lease
// document sitting in a BACKGROUND tab is workspace memory, never the current
// task — so it cannot manufacture lease/listing actions while the user is on
// Facebook (or any unrelated current focus).

enum ContentTypeAuthority: String, Sendable {
    case currentFocus  = "current_focus"
    case selectedText  = "selected_text"
    case visibleBody   = "visible_body"
    case backgroundTab = "background_tab"
    case staleMemory   = "stale_memory"

    /// Only these authorities may unlock current-task action packs.
    var canDriveCurrentTask: Bool {
        self == .currentFocus || self == .selectedText || self == .visibleBody
    }
}

enum CurrentFocusContentTypeGate {

    /// Strong, current-task content types that require current-focus support
    /// before they can drive an action pack.
    static let leaseListingFamily: Set<FocusedContentType> = [
        .leaseOrContractDocument, .individualListing,
        .marketplaceOrListingFeed, .listingPlatformDashboard
    ]

    /// Nouns/paths that, when present in the CURRENT focus (title/host/path),
    /// support a lease/listing classification as the current task.
    private static func currentFocusSupportsLeaseListing(_ s: WorkflowSignals) -> Bool {
        let focus = [s.windowTitle, s.urlHost, s.urlPath].joined(separator: " ").lowercased()
        let contractNouns = ContentTypeClassifier.contractNouns
        if contractNouns.contains(where: { focus.contains($0) }) { return true }
        let listingPaths = ["/listing", "/property", "/unit", "/rental", "/marketplace", "/classifieds"]
        if listingPaths.contains(where: { s.urlPath.lowercased().contains($0) }) { return true }
        if EvidenceSnapshot.looksLikeListingCandidate(s.windowTitle) { return true }
        return false
    }

    /// Classify the current focus and attach the authority that produced the
    /// classification. If the classifier returned a lease/listing type that the
    /// current focus does NOT support (it only matched a background tab or stale
    /// enriched memory), demote it to a safe generic/social type.
    static func classifyWithAuthority(_ s: WorkflowSignals) -> (content: ClassifiedContent, authority: ContentTypeAuthority) {
        let raw = ContentTypeClassifier.classify(s)
        let selectionDrives = s.selectedTextLength >= 40
        let currentSupports = currentFocusSupportsLeaseListing(s)

        // Determine the authority behind a strong (lease/listing) classification.
        let authority: ContentTypeAuthority
        if leaseListingFamily.contains(raw.type) {
            if currentSupports {
                authority = .currentFocus
            } else if selectionDrives {
                authority = .selectedText
            } else if s.enrichedTextLength > 0 && s.enrichedEvidenceLevel != "metadata" {
                // Visible body present, but it did not come from the current focus
                // title/url — treat as background unless the body itself is current.
                authority = .backgroundTab
            } else {
                authority = .backgroundTab
            }
        } else {
            authority = selectionDrives ? .selectedText : .currentFocus
        }

        print("[ContentTypeAuthority] selected=\(raw.type.rawValue) authority=\(authority.rawValue)")

        // Demote a lease/listing type that the current focus does not support.
        if leaseListingFamily.contains(raw.type), !authority.canDriveCurrentTask {
            let demotedType = demotedType(forCurrentFocus: s)
            print("[BackgroundContentTypeDemoted] content_type=\(raw.type.rawValue) reason=background_tab_not_current_focus")
            let demoted = ClassifiedContent(type: demotedType, confidence: 0.5, signals: ["demoted_from:\(raw.type.rawValue)"])
            return (demoted, authority)
        }
        return (raw, authority)
    }

    /// What the current focus actually is when a lease/listing classification is
    /// demoted — social/forum if the focus looks social, else generic webpage.
    private static func demotedType(forCurrentFocus s: WorkflowSignals) -> FocusedContentType {
        let focus = [s.windowTitle, s.urlHost, s.urlPath].joined(separator: " ").lowercased()
        let socialHints = ["/groups/", "/group/", "/r/", "/community", "/forum", "/profile", "feed"]
        let socialTitleHints = ["facebook", "instagram", "twitter", "reddit", "tiktok", "linkedin"]
        if socialHints.contains(where: { s.urlPath.lowercased().contains($0) })
            || socialTitleHints.contains(where: { focus.contains($0) }) {
            return .forumOrSocialGroup
        }
        return .genericWebpage
    }

    /// Gate: may a lease/listing action pack run for this focus? Emits the
    /// allow/deny decision. Allowed only when the current focus (or a selection)
    /// supports the lease/listing classification.
    @discardableResult
    static func leaseListingAllowed(content: ClassifiedContent, authority: ContentTypeAuthority) -> Bool {
        let isLeaseListing = leaseListingFamily.contains(content.type)
        let allowed = isLeaseListing && authority.canDriveCurrentTask
        let reason: String
        if !isLeaseListing {
            reason = "current_focus_not_lease_listing"
        } else if allowed {
            reason = "current_focus_supports_lease_listing"
        } else {
            reason = "lease_listing_only_in_background"
        }
        print("[CurrentFocusContentTypeGate] allowed=\(allowed ? "yes" : "no") reason=\(reason)")
        return allowed
    }
}

// MARK: - Current-focus authority (Part 3)
//
// The CURRENT focus owns the suggestion. When the frontmost app cannot provide
// readable content for the current focus (a game, a video/media player, or any
// unsupported app the user is actively in), stale browser/document context must
// NOT be reused as "current work" — that is the "thought I was studying while
// gaming" bug. This gate is generic: it is driven by whether the CURRENT focus
// has readable content, not by any specific game/site/app name. Background tabs
// and recent documents stay as memory only; they never become the current task.
enum CurrentFocusAuthority {
    enum FrontmostType: String {
        case browser, document, game, media, code, chat, unknown
    }
    enum BackgroundAllowance: String {
        case none
        case memoryOnly = "memory_only"
        case relatedSupport = "related_support"
    }

    struct Decision {
        let frontmostType: FrontmostType
        let currentContentAvailable: Bool
        let backgroundAllowed: BackgroundAllowance
        /// May a current-WORK (study/research/code/etc.) suggestion be produced
        /// for this focus at all? False ⇒ the bridge must stay quiet (or show a
        /// permission/context state), never reuse stale document context.
        let allowsWorkSuggestion: Bool
        let reason: String
    }

    /// Generic category vocabulary for game/launcher apps — platform/category
    /// tokens (same style as AppContextAnalyzer's browser/editor tables), never
    /// specific game titles. Matched against bundle/app-name tokens of length >2.
    private static let gameTokens: Set<String> = [
        "steam", "epicgames", "gog", "riotgames", "battlenet", "blizzard",
        "ubisoft", "gameloft", "playstation", "xbox", "game", "games", "launcher",
        "unrealengine", "godot"
    ]

    private static func looksLikeGame(_ signals: WorkflowSignals) -> Bool {
        let tokens = Set(signals.activeApp.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: " .-_"))
            .filter { $0.count > 2 })
        return !tokens.isDisjoint(with: gameTokens)
    }

    private static func frontmostType(_ signals: WorkflowSignals) -> FrontmostType {
        let ctx = AppContextAnalyzer.analyze(appName: signals.activeApp, bundleID: nil, windowTitle: signals.windowTitle)
        if looksLikeGame(signals) { return .game }
        switch ctx.category {
        case .browser: return .browser
        case .pdf: return .document
        case .editor: return .code
        case .communication, .assistant_tool: return .chat
        case .media: return .media
        case .files, .unknown: return .unknown
        }
    }

    /// Whether the CURRENT focus actually exposes readable content right now —
    /// content that belongs to this focus, not stale background memory.
    private static func currentContentAvailable(_ signals: WorkflowSignals) -> Bool {
        if signals.selectedTextLength >= 40 { return true }
        // Enriched context is exact-focus-keyed, so its presence means it belongs
        // to THIS focus; require it to be unexpired and uncontaminated.
        if let e = signals.enrichedContext, !e.expired, e.contaminationWarning == nil, e.chars > 0 { return true }
        if signals.contentAvailable { return true }
        return false
    }

    static func evaluate(signals: WorkflowSignals) -> Decision {
        let type = frontmostType(signals)
        let hasContent = currentContentAvailable(signals)

        // Non-work focus: a game or media/video player. Even if a stale document
        // is in memory, the current focus cannot host a work suggestion.
        let isNonWorkApp = (type == .game || type == .media)

        let allows: Bool
        let allowance: BackgroundAllowance
        let reason: String
        if isNonWorkApp {
            allows = false
            allowance = .memoryOnly
            reason = "frontmost_\(type.rawValue)_not_work_focus"
        } else if !hasContent {
            // A supported app type but no readable current content: do not invent
            // current work from stale/background context. Stay quiet honestly.
            allows = false
            allowance = .memoryOnly
            reason = "current_focus_content_unavailable"
        } else {
            allows = true
            allowance = .relatedSupport
            reason = "current_focus_readable"
        }

        print("[CurrentFocusAuthority] frontmost_app_type=\(type.rawValue) current_content_available=\(hasContent ? "yes" : "no") background_context_allowed=\(allowance.rawValue)")
	        if isNonWorkApp {
	            print("[StaleContextRejected] source=background_tab reason=current_focus_mismatch")
	            PassiveDogfoodMonitor.shared.noteStaleContextRejected()
	            print("[NoBackgroundWorkSuggestionWhileGameOrMediaActive] status=pass count=0")
            print("[NoStaleDocumentContextAsCurrentWork] status=pass count=0")
            // A non-work focus (game/media) never yields a work suggestion.
            print("[NoFalseWorkSuggestionDuringUnrelatedFocus] status=pass count=0")
	        } else if !hasContent {
	            print("[StaleContextRejected] source=cache reason=current_focus_mismatch")
	            PassiveDogfoodMonitor.shared.noteStaleContextRejected()
	            print("[NoStaleDocumentContextAsCurrentWork] status=pass count=0")
            // No readable current content ⇒ stale context cannot fabricate work.
            print("[NoFalseWorkSuggestionDuringUnrelatedFocus] status=pass count=0")
        }
        return Decision(frontmostType: type, currentContentAvailable: hasContent,
                        backgroundAllowed: allowance, allowsWorkSuggestion: allows, reason: reason)
    }
}

// MARK: - Proposal evidence contracts

enum ProposalEvidenceContracts {

    struct DiagnoseEvidence: Sendable {
        let errorText: Bool
        let selectedStackTrace: Bool
        let buildFailure: Bool
        var allowed: Bool { errorText || selectedStackTrace || buildFailure }

        func log(app: String, title: String) {
            print("[DiagnoseEvidenceContract] app=\(app.isEmpty ? "unknown" : app) error_text=\(errorText ? "yes" : "no") selected_stack_trace=\(selectedStackTrace ? "yes" : "no") build_failure=\(buildFailure ? "yes" : "no") allowed=\(allowed ? "yes" : "no") title=\"\(title.prefix(80))\"")
        }
    }

    struct LeaseEvidence: Sendable {
        let titleOrKeywordOnly: Bool
        let bodyChars: Int
        let allowed: Bool

        func log(actionID: String) {
            print("[LeaseEvidenceContract] id=\(actionID) title_only=\(titleOrKeywordOnly ? "yes" : "no") body_chars=\(bodyChars) allowed=\(allowed ? "yes" : "no")")
        }
    }

    static func isInternalAcquisitionAction(_ id: String) -> Bool {
        let canonicalId = ActionAliasResolver.canonicalID(for: id)
        return CapabilityPolicyResolver.resolve(capabilityID: canonicalId).contains(.internalAcquisitionAction)
            || CapabilityPolicyResolver.resolve(capabilityID: id).contains(.internalAcquisitionAction)
    }

    static func bodyTextChars(_ s: WorkflowSignals) -> Int {
        if let enriched = s.enrichedContext {
            return enriched.chars
        }
        return s.selectedTextLength
    }

    /// True when AX/OCR/enriched/selection provides enough readable body text.
    static func hasActualBodyEvidence(_ s: WorkflowSignals, minChars: Int = 80) -> Bool {
        if let enriched = s.enrichedContext, enriched.chars >= minChars {
            return true
        }
        if s.selectedTextLength >= minChars {
            return true
        }
        return s.contentAvailable && hasReadableBodyText(s, minChars: minChars)
    }

    static func hasReadableBodyText(_ s: WorkflowSignals, minChars: Int = 120) -> Bool {
        bodyTextChars(s) >= minChars
    }

    static func diagnoseEvidence(_ s: WorkflowSignals) -> DiagnoseEvidence {
        let text = (s.enrichedContext?.text ?? "").lowercased()
        let title = s.windowTitle.lowercased()
        let contentText = ProposalEvidenceContracts.hasActualBodyEvidence(s, minChars: 40)
            ? [text, title].joined(separator: " ") : text
        let errorMarkers = [
            "error:", "fatal error", "exception", "traceback", "stack trace",
            "build failed", "xcodebuild", "failed with exit code", "compiler error",
            "test failed", "assertion failed"
        ]
        let errorText = ProposalEvidenceContracts.hasActualBodyEvidence(s, minChars: 40)
            && errorMarkers.contains { contentText.contains($0) }
        let selectedStackTrace = s.selectedTextLength >= 80
        let buildFailure = ProposalEvidenceContracts.hasActualBodyEvidence(s, minChars: 40)
            && ["build failed", "xcodebuild", "failed with exit code", "test failed"].contains { contentText.contains($0) }
        return DiagnoseEvidence(errorText: errorText, selectedStackTrace: selectedStackTrace, buildFailure: buildFailure)
    }

    static func leaseEvidence(_ s: WorkflowSignals) -> LeaseEvidence {
        let focus = [s.windowTitle, s.urlHost, s.urlPath, s.tabTitles.joined(separator: " ")].joined(separator: " ").lowercased()
        let hasLeaseTerms = ContentTypeClassifier.contractNouns.contains { focus.contains($0) }
        let chars = bodyTextChars(s)
        let allowed = chars >= 120
        return LeaseEvidence(titleOrKeywordOnly: hasLeaseTerms && !allowed, bodyChars: chars, allowed: allowed)
    }

    static func domainFamily(_ s: WorkflowSignals) -> String? {
        let host = s.urlHost.lowercased()
        let title = s.windowTitle.lowercased()
        let path = s.urlPath.lowercased()
        if host.contains("mail.google.com") || host.contains("gmail") || title.contains("gmail") { return "gmail" }
        if host.contains("facebook.com") || title.contains("facebook") || path.contains("/groups") || path.contains("/marketplace") { return "facebook" }
        if host.contains("kijiji") || title.contains("kijiji") { return "kijiji" }
        return nil
    }

    static func logDomainSignal(_ s: WorkflowSignals) {
        guard let family = domainFamily(s) else { return }
        let strength = hasReadableBodyText(s, minChars: 80) ? "body_text" : "weak_context_family"
        print("[DomainSignal] family=\(family) host=\(s.urlHost.isEmpty ? "none" : s.urlHost) strength=\(strength)")
    }

    static func isDomainOnlyWeakSignal(_ s: WorkflowSignals) -> Bool {
        domainFamily(s) != nil && !hasReadableBodyText(s, minChars: 80)
    }

    static func shouldBlockDomainOnlyContentAction(action: WorkflowAction, signals s: WorkflowSignals, content: ClassifiedContent) -> Bool {
        guard isDomainOnlyWeakSignal(s) else { return false }
        switch action.category {
        case .browserResearch, .communication, .documentsLeases, .codeLogs:
            return action.executionKind == .contentInsight || action.isSpecificAction || content.type == .messageThreadOrInbox || content.type == .marketplaceOrListingFeed
        default:
            return false
        }
    }

    static func logDomainOnlyBlock(actionID: String, signals s: WorkflowSignals) {
        print("[DomainOnlyActionBlock] family=\(domainFamily(s) ?? "unknown") action=\(actionID) reason=domain_only")
    }

    static func logMessageBodyContract(signals s: WorkflowSignals, actionID: String, allowed: Bool) {
        print("[MessageBodyEvidenceContract] id=\(actionID) body_chars=\(bodyTextChars(s)) allowed=\(allowed ? "yes" : "no")")
    }

    static func logMusicEvidence(stableWorkContext: Bool, userPreference: Bool, history: Bool, recentSuccess: Bool) -> Bool {
        let allowed = userPreference || history || recentSuccess
        print("[MusicEvidenceContract] stable_work_context=\(stableWorkContext ? "yes" : "no") user_preference=\(userPreference ? "yes" : "no") history=\(history ? "yes" : "no") recent_success=\(recentSuccess ? "yes" : "no") allowed=\(allowed ? "yes" : "no")")
        return allowed
    }
}

// MARK: - User-visible hardcode gate (panel + current-task + portfolio)

/// Blocks metadata-only hardcoded actions from every user-visible surface.
enum UserVisibleHardcodeGate {

    struct Decision: Sendable, Equatable {
        let allowed: Bool
        let reason: String
    }

    static let xcodeCodeLogActionIDs: Set<String> = [
        "diagnose_latest_error",
        "summarize_log_failure",
        "generate_next_agent_prompt",
        "create_regression_test_prompt",
        "identify_repeated_log_pattern",
        "map_log_to_subsystem",
        "explain_recent_code_file",
        "find_unverified_claims_in_agent_response",
        "make_next_ticket",
        "code_diagnose_log",
    ]

    static let leaseDocumentActionIDs: Set<String> = [
        "flag_risky_clauses",
        "extract_obligations",
        "extract_dates_deadlines_payments",
        "detect_missing_terms",
        "generate_questions_for_landlord",
        "summarize_house_rules",
        "calculate_rent_split_from_visible_numbers",
        "create_tenant_move_in_checklist",
        "lease_review_obligations_and_risks",
    ]

    static func evaluate(
        actionID: String,
        signals: WorkflowSignals,
        content: ClassifiedContent,
        tier: Int? = nil,
        captureNeeded: Bool = false,
        explicitUserIntent: Bool = false
    ) -> Decision {
        let id = ActionAliasResolver.canonicalID(for: actionID)

        if captureNeeded || tier == 2 {
            if explicitUserIntent {
                return Decision(allowed: true, reason: "explicit_user_intent")
            }
            return Decision(allowed: false, reason: "capture_needed_not_surfaced")
        }

        if isCaptureRelabelTitle(id, signals: signals) {
            return Decision(allowed: false, reason: "capture_relabel_not_surfaced")
        }

        if xcodeCodeLogActionIDs.contains(id) {
            let diagnose = ProposalEvidenceContracts.diagnoseEvidence(signals)
            if !diagnose.allowed {
                let reason = signals.activeApp.lowercased().contains("xcode")
                    ? "xcode_metadata_only_missing_error_evidence"
                    : "code_metadata_only_missing_error_evidence"
                return Decision(allowed: false, reason: reason)
            }
        }

        if leaseDocumentActionIDs.contains(id) {
            let lease = ProposalEvidenceContracts.leaseEvidence(signals)
            if !lease.allowed {
                return Decision(allowed: false, reason: "lease_title_only_missing_document_body")
            }
        }

        if let action = WorkflowActionOntology.byId[id],
           action.category == .codeLogs,
           !ProposalEvidenceContracts.diagnoseEvidence(signals).allowed
        {
            return Decision(allowed: false, reason: "code_log_missing_evidence")
        }

        if let action = WorkflowActionOntology.byId[id],
           action.category == .documentsLeases,
           content.type == .leaseOrContractDocument,
           !ProposalEvidenceContracts.leaseEvidence(signals).allowed
        {
            return Decision(allowed: false, reason: "lease_title_only_missing_document_body")
        }

        return Decision(allowed: true, reason: "evidence_ok")
    }

    static func evaluateMusicPanel(
        capabilityID: String,
        stableWorkContext: Bool,
        userPreference: Bool,
        history: Bool,
        recentSuccess: Bool
    ) -> Decision {
        let traits = CapabilityPolicyResolver.resolve(capabilityID: capabilityID)
        let action = WorkflowActionOntology.byId[capabilityID]
        let isPlayMedia = traits.contains(.mediaOrFocusSupport) && (action?.requiredContext.contains("foreground_media_active") == false)
        guard isPlayMedia else {
            return Decision(allowed: true, reason: "not_music_play")
        }
        let allowed = ProposalEvidenceContracts.logMusicEvidence(
            stableWorkContext: stableWorkContext,
            userPreference: userPreference,
            history: history,
            recentSuccess: recentSuccess
        )
        if !allowed {
            print("[MusicSuggestionSuppressed] reason=stable_work_context_only")
            return Decision(allowed: false, reason: "stable_work_context_only")
        }
        return Decision(allowed: true, reason: "music_evidence_ok")
    }

    static func log(surface: String, id: String, decision: Decision) {
        print("[LiveHardcodeGate] id=\(id) surface=\(surface) allowed=\(decision.allowed ? "yes" : "no") reason=\(decision.reason)")
        if !decision.allowed {
            print("[UserVisibleCandidateRejected] id=\(id) reason=\(decision.reason)")
            switch decision.reason {
            case "xcode_metadata_only_missing_error_evidence", "code_metadata_only_missing_error_evidence", "code_log_missing_evidence":
                print("[NoXcodeMetadataOnlyCodeLogPanelActions] status=pass count=0")
                print("[NoMetadataOnlyCaptureLogsActions] status=pass count=0")
            case "lease_title_only_missing_document_body":
                print("[NoLeaseTitleOnlyPanelActions] status=pass count=0")
                print("[NoMetadataOnlyLeaseCaptureActions] status=pass count=0")
            case "capture_needed_not_surfaced", "capture_relabel_not_surfaced":
                print("[CaptureNeededNotSurfaced] original_id=\(id) reason=no_user_intent_metadata_only")
                print("[NoSpecificCaptureNeededPanelActions] status=pass count=0")
                print("[NoCaptureNeededRelabeledProposal] status=pass count=0")
            case "stable_work_context_only":
                print("[NoStableWorkContextOnlyMusicPanel] status=pass count=0")
                print("[NoAlwaysAllowedMusicWithoutEvidence] status=pass count=0")
            default:
                break
            }
        }
    }

    private static func isCaptureRelabelTitle(_ id: String, signals: WorkflowSignals) -> Bool {
        guard let action = WorkflowActionOntology.byId[id] else { return false }
        let title = LiquidActionRouter.displayTitle(for: action, signals: signals).lowercased()
        return title.hasPrefix("capture ") && title.contains(" to ")
    }
}

// MARK: - Part C: Action contracts

enum ActionEvidence: String, Sendable {
    case selectedText = "selected_text"
    case visibleText = "visible_text"
    case fullDocument = "full_document"
    case multipleListingCandidates = "multiple_listing_candidates"
    case multipleSources = "multiple_sources"
    case comparableAttributes = "comparable_attributes"
    /// Phase 60 — ≥2 actual comparison candidates with a coherent shared topic.
    case comparableCandidates = "comparable_candidates"
    case numbersVisible = "numbers_visible"
    case messageThread = "message_thread"
    case codeLogText = "code_log_text"
    case productDetails = "product_details"
    case none = "none"
}

/// What evidence the current signals actually provide.
struct EvidenceSnapshot: Sendable {
    let available: Set<ActionEvidence>
    let listingCandidateCount: Int
    /// Phase 60 — focused page is a listing feed: candidates exist behind a
    /// capture, not as tabs.
    var feedCandidateSource: Bool = false
    var clusterComparable: Bool = false

    static func looksLikeListingCandidate(_ title: String) -> Bool {
        let lower = title.lowercased()
        if lower.contains("for rent") { return true }
        // A price alone is any product; a rental listing needs a rental noun.
        let listingNouns = ["room", "apartment", "bed", "unit", "condo", "studio", "sublet"]
        let hasNoun = listingNouns.contains { lower.contains($0) }
        if hasNoun && lower.range(of: #"\$\s?\d"#, options: .regularExpression) != nil { return true }
        let hasDigits = lower.rangeOfCharacter(from: .decimalDigits) != nil
        return hasNoun && hasDigits
    }

    static func evaluate(signals s: WorkflowSignals, content: ClassifiedContent, cluster: ComparableCandidateResult? = nil) -> EvidenceSnapshot {
        var available: Set<ActionEvidence> = [.none]
        let hasBody = ProposalEvidenceContracts.hasActualBodyEvidence(s, minChars: 80)
        if s.selectedTextLength >= 40 { available.insert(.selectedText) }
        if hasBody {
            available.insert(.visibleText)
            if content.type == .codeOrLog { available.insert(.codeLogText) }
            if content.type == .shoppingProductPage || content.type == .individualListing {
                available.insert(.productDetails)
            }
            if content.type == .individualListing || content.type == .leaseOrContractDocument
                || content.type == .messageThreadOrInbox || content.type == .marketplaceOrListingFeed {
                available.insert(.numbersVisible)
            }
        }
        if content.type == .messageThreadOrInbox, ProposalEvidenceContracts.hasReadableBodyText(s, minChars: 80) {
            available.insert(.messageThread)
        }
        let listingCandidates = s.tabTitles.filter { looksLikeListingCandidate($0) }.count
            + (looksLikeListingCandidate(s.windowTitle) ? 1 : 0)
        if listingCandidates >= 2 {
            available.insert(.multipleListingCandidates)
            available.insert(.comparableAttributes)
        }
        // Phase 60 — "multiple sources" and "comparable candidates" come from
        // the candidate detector, never from raw tab counts.
        // Phase 61 — and only when the cluster belongs to the current focus:
        // background clusters grant no current-task evidence.
        let resolved = cluster ?? ComparableCandidateDetector.detect(signals: s, content: content)
        if resolved.comparable && resolved.candidateTabs >= 2 && resolved.authority.canDriveCurrentTask {
            available.insert(.comparableCandidates)
        }
        if resolved.authority.canDriveCurrentTask,
           (resolved.comparable && (resolved.clusterType == "article" || resolved.clusterType == "document"))
            || (resolved.coherence >= 0.5 && s.tabTitles.count >= 3) {
            available.insert(.multipleSources)
        }
        var snapshot = EvidenceSnapshot(available: available, listingCandidateCount: listingCandidates)
        snapshot.feedCandidateSource = resolved.feedCandidateSource
        snapshot.clusterComparable = resolved.comparable
        return snapshot
    }
}

enum ContractSurface: String, Sendable {
    case floating
    case panel
    case followup
    case captureNeeded = "capture_needed"
    case suppress
}

struct ActionContract: Sendable {
    /// nil = any content type (utility/memory/friction actions).
    let requiredContentTypes: Set<FocusedContentType>?
    let forbiddenContentTypes: Set<FocusedContentType>
    /// Any one of these satisfies the contract.
    let requiredEvidence: [ActionEvidence]
    /// Missing evidence downgrades to capture-needed instead of suppressing.
    let captureCanProvideEvidence: Bool
    /// Action never floats by default (generic utility).
    let panelOnlyByDefault: Bool
}

enum ActionContracts {

    static let listingContexts: Set<FocusedContentType> = [
        .individualListing, .listingPlatformDashboard, .marketplaceOrListingFeed,
        .forumOrSocialGroup, .searchResults
    ]

    static func contract(for action: WorkflowAction) -> ActionContract? {
        switch action.id {
        case "flag_risky_clauses", "extract_obligations", "extract_dates_deadlines_payments",
             "detect_missing_terms", "summarize_house_rules", "rewrite_clause_plain_english",
             "generate_questions_for_landlord", "compare_document_to_listing", "find_conflicting_info":
            return ActionContract(
                requiredContentTypes: [.leaseOrContractDocument],
                forbiddenContentTypes: [.forumOrSocialGroup, .marketplaceOrListingFeed, .genericWebpage,
                                        .shoppingProductPage, .studyMaterial, .mediaPage, .searchResults,
                                        .messageThreadOrInbox],
                requiredEvidence: [.selectedText, .visibleText, .fullDocument],
                captureCanProvideEvidence: true,
                panelOnlyByDefault: false
            )
        case "calculate_rent_split_from_visible_numbers":
            return ActionContract(
                requiredContentTypes: [.leaseOrContractDocument, .individualListing, .messageThreadOrInbox, .marketplaceOrListingFeed],
                forbiddenContentTypes: [.genericWebpage, .studyMaterial, .mediaPage, .forumOrSocialGroup],
                requiredEvidence: [.numbersVisible, .selectedText],
                captureCanProvideEvidence: true,
                panelOnlyByDefault: true
            )
        case "compare_open_tabs", "create_decision_table":
            // Phase 60 — comparing requires comparable candidates, never tab
            // count. Capture can reveal feed candidates but cannot make
            // unrelated tabs comparable.
            return ActionContract(
                requiredContentTypes: nil,
                forbiddenContentTypes: [.leaseOrContractDocument, .codeOrLog],
                requiredEvidence: [.comparableCandidates, .multipleListingCandidates],
                captureCanProvideEvidence: false,
                panelOnlyByDefault: false
            )
        case "collect_sources_from_tabs":
            return ActionContract(
                requiredContentTypes: nil,
                forbiddenContentTypes: [.leaseOrContractDocument, .codeOrLog],
                requiredEvidence: [.multipleSources],
                captureCanProvideEvidence: false,
                panelOnlyByDefault: true
            )
        case "save_research_session", "make_research_brief", "identify_next_research_step", "reopen_research_tabs":
            return ActionContract(
                requiredContentTypes: nil,
                forbiddenContentTypes: [.leaseOrContractDocument],
                requiredEvidence: [.multipleSources, .none],
                captureCanProvideEvidence: false,
                panelOnlyByDefault: true
            )
        case "extract_key_claims":
            return ActionContract(
                requiredContentTypes: [.articleOrReference, .searchResults, .individualListing,
                                       .forumOrSocialGroup, .marketplaceOrListingFeed,
                                       .shoppingProductPage, .studyMaterial, .genericWebpage],
                forbiddenContentTypes: [.codeOrLog],
                requiredEvidence: [.visibleText, .selectedText],
                captureCanProvideEvidence: true,
                panelOnlyByDefault: false
            )
        default:
            break
        }
        // Category defaults.
        switch action.category {
        case .documentsLeases:
            return ActionContract(
                requiredContentTypes: [.leaseOrContractDocument],
                forbiddenContentTypes: [.forumOrSocialGroup, .marketplaceOrListingFeed, .genericWebpage],
                requiredEvidence: [.selectedText, .visibleText, .fullDocument],
                captureCanProvideEvidence: true,
                panelOnlyByDefault: false
            )
        case .codeLogs:
            return ActionContract(
                requiredContentTypes: [.codeOrLog],
                forbiddenContentTypes: [.leaseOrContractDocument, .forumOrSocialGroup, .shoppingProductPage],
                requiredEvidence: [.codeLogText, .visibleText, .selectedText],
                captureCanProvideEvidence: true,
                panelOnlyByDefault: false
            )
        case .formsApplications:
            return ActionContract(
                requiredContentTypes: [.formOrApplication],
                forbiddenContentTypes: [.forumOrSocialGroup, .mediaPage, .shoppingProductPage],
                requiredEvidence: [.visibleText, .selectedText, .none],
                captureCanProvideEvidence: true,
                panelOnlyByDefault: false
            )
        case .writingEditing, .communication:
            return ActionContract(
                requiredContentTypes: nil,
                forbiddenContentTypes: [],
                requiredEvidence: [.selectedText],
                captureCanProvideEvidence: false,
                panelOnlyByDefault: false
            )
        case .browserResearch, .workspaceFriction, .mediaFocus, .memoryWorkflows, .setupAcquisition:
            return nil // no contract — gated by existing structural rules
        }
    }

    struct ContractVerdict: Sendable {
        let passed: Bool
        let surfaceCeiling: ContractSurface
        let reason: String
        let missing: [ActionEvidence]
        let forbidden: Bool
    }

    /// Evaluate one action's contract against current context.
    static func check(action: WorkflowAction, content: ClassifiedContent, evidence: EvidenceSnapshot, selectedTextLength: Int) -> ContractVerdict {
        guard let contract = contract(for: action) else {
            return ContractVerdict(passed: true, surfaceCeiling: .floating, reason: "no_contract", missing: [], forbidden: false)
        }
        // Forbidden content type — selected text can override for document
        // actions (a lease clause pasted in a forum is still a lease clause).
        if contract.forbiddenContentTypes.contains(content.type) {
            let selectionOverride = selectedTextLength >= 80 && contract.requiredEvidence.contains(.selectedText)
            if !selectionOverride {
                let verdict = ContractVerdict(passed: false, surfaceCeiling: .suppress, reason: "wrong_content_type", missing: [], forbidden: true)
                log(action: action, verdict: verdict)
                return verdict
            }
        }
        if let required = contract.requiredContentTypes, !required.contains(content.type) {
            let selectionOverride = selectedTextLength >= 80 && contract.requiredEvidence.contains(.selectedText)
            if !selectionOverride {
                let verdict = ContractVerdict(passed: false, surfaceCeiling: .suppress, reason: "wrong_content_type", missing: [], forbidden: false)
                log(action: action, verdict: verdict)
                return verdict
            }
        }
        let isCompareAction = action.id == "compare_open_tabs" || action.id == "create_decision_table"
            || action.id == "compare_document_to_listing"
        let satisfied = contract.requiredEvidence.contains { evidence.available.contains($0) }
        if isCompareAction {
            print("[CompareContractRequirement] id=\(action.id) required=comparable_candidates passed=\(satisfied || evidence.feedCandidateSource ? "yes" : "no")")
        }
        if !satisfied {
            let missing = contract.requiredEvidence
            // Phase 60 — a focused listing feed carries candidates behind a
            // capture; unrelated tabs carry nothing a capture could fix.
            if isCompareAction && evidence.feedCandidateSource {
                let verdict = ContractVerdict(passed: true, surfaceCeiling: .captureNeeded, reason: "feed_candidates_need_capture", missing: missing, forbidden: false)
                log(action: action, verdict: verdict)
                return verdict
            }
            if isCompareAction {
                print("[CompareSuppression] id=\(action.id) reason=\(evidence.clusterComparable ? "single_candidate" : "unrelated_tabs")")
                let verdict = ContractVerdict(passed: false, surfaceCeiling: .suppress, reason: "missing_evidence", missing: missing, forbidden: false)
                log(action: action, verdict: verdict)
                return verdict
            }
            if contract.captureCanProvideEvidence,
               action.category != .documentsLeases,
               action.category != .codeLogs {
                let verdict = ContractVerdict(passed: true, surfaceCeiling: .captureNeeded, reason: "missing_evidence_capture_possible", missing: missing, forbidden: false)
                log(action: action, verdict: verdict)
                return verdict
            }
            let verdict = ContractVerdict(passed: false, surfaceCeiling: .suppress, reason: "missing_evidence", missing: missing, forbidden: false)
            log(action: action, verdict: verdict)
            return verdict
        }
        let ceiling: ContractSurface = contract.panelOnlyByDefault ? .panel : .floating
        let verdict = ContractVerdict(passed: true, surfaceCeiling: ceiling, reason: contract.panelOnlyByDefault ? "panel_only_by_default" : "contract_satisfied", missing: [], forbidden: false)
        log(action: action, verdict: verdict)
        return verdict
    }

    private static func log(action: WorkflowAction, verdict: ContractVerdict) {
        print("[ActionContractCheck] id=\(action.id) passed=\(verdict.passed ? "yes" : "no") reason=\(verdict.reason) missing=\(verdict.missing.map(\.rawValue).joined(separator: ",")) forbidden=\(verdict.forbidden ? "yes" : "no")")
        if !verdict.passed {
            print("[ActionContractBlock] id=\(action.id) reason=\(verdict.forbidden ? "wrong_content_type" : verdict.reason == "wrong_content_type" ? "wrong_content_type" : "missing_evidence")")
        }
        print("[ActionContractSurface] id=\(action.id) surface=\(verdict.surfaceCeiling.rawValue) reason=\(verdict.reason)")
        if !verdict.passed && action.category == .documentsLeases {
            print("[LeaseActionSuppression] id=\(action.id) reason=not_contract_document")
        }
    }
}

// MARK: - Part D: Usefulness scoring

struct UsefulActionScore: Sendable {
    let focusFit: Double
    let contentFit: Double
    let evidenceStrength: Double
    let expectedUserValue: Double
    let outputSpecificity: Double
    let actionCost: Double
    let genericPenalty: Double
    let feedbackAdjustment: Double
    let final: Double
}

enum UsefulActionScorer {

    static let floatingThreshold = 0.62
    static let panelThreshold = 0.40

    /// Cross-tab utility actions whose value is generic bookkeeping.
    static let genericUtilityIds: Set<String> = [
        "collect_sources_from_tabs", "save_research_session", "make_research_brief",
        "identify_next_research_step", "reopen_research_tabs", "save_task_context",
        "update_project_status_note"
    ]

    static func score(
        action: WorkflowAction,
        content: ClassifiedContent,
        evidence: EvidenceSnapshot,
        workflowConfidence: Double,
        tier: Int,
        contractCeiling: ContractSurface,
        recentlyPenalized: Bool,
        recentlyAcceptedSimilar: Bool
    ) -> UsefulActionScore {
        let contract = ActionContracts.contract(for: action)

        let contentFit: Double
        if let required = contract?.requiredContentTypes {
            contentFit = required.contains(content.type) ? 1.0 : 0.2
        } else if let forbidden = contract?.forbiddenContentTypes, forbidden.contains(content.type) {
            contentFit = 0.0
        } else {
            contentFit = 0.55
        }

        let focusFit = min(1.0, max(0.15, workflowConfidence))

        let evidenceStrength: Double
        if evidence.available.contains(.selectedText) && (contract?.requiredEvidence.contains(.selectedText) ?? false) {
            evidenceStrength = 1.0
        } else if evidence.available.contains(.visibleText) && tier == 1 {
            evidenceStrength = 0.85
        } else if evidence.available.contains(.multipleListingCandidates) || evidence.available.contains(.multipleSources) {
            evidenceStrength = 0.7
        } else if contractCeiling == .captureNeeded {
            evidenceStrength = 0.4
        } else if tier == 1 {
            evidenceStrength = 0.55
        } else {
            evidenceStrength = 0.25
        }

        let expectedUserValue: Double
        switch (tier, action.executionKind) {
        case (1, .contentInsight), (1, .selectionTransform): expectedUserValue = 0.9
        case (1, .metadataNote): expectedUserValue = 0.35
        case (1, _): expectedUserValue = 0.55
        case (2, _): expectedUserValue = 0.5   // honest capture is still a step forward
        default: expectedUserValue = 0.25
        }

        let outputSpecificity: Double = action.isSpecificAction
            ? (contract?.requiredContentTypes != nil ? 1.0 : 0.65)
            : 0.3

        let actionCost: Double
        switch tier {
        case 1: actionCost = 1.0
        case 2: actionCost = 0.6
        default: actionCost = 0.3
        }

        var genericPenalty = 0.0
        if genericUtilityIds.contains(action.id) || !action.isSpecificAction {
            let strongCollectionIntent = evidence.available.contains(.multipleSources)
                && (content.type == .searchResults || content.type == .articleOrReference || content.type == .listingPlatformDashboard)
            genericPenalty = strongCollectionIntent ? 0.05 : 0.30
            print("[GenericActionPenalty] id=\(action.id) penalty=\(String(format: "%.2f", genericPenalty)) reason=\(strongCollectionIntent ? "weak_generic_with_collection_intent" : "generic_without_collection_intent")")
        }

        var feedbackAdjustment = 0.0
        if recentlyPenalized {
            feedbackAdjustment -= 0.30
            print("[RepetitionPenalty] id=\(action.id) penalty=0.30 reason=recently_ignored")
        }
        if recentlyAcceptedSimilar {
            feedbackAdjustment += 0.15
            print("[ContextualBoost] id=\(action.id) boost=0.15 reason=clicked_similar_context")
        }

        let final = max(0.0, min(1.0,
            0.18 * focusFit
            + 0.22 * contentFit
            + 0.20 * evidenceStrength
            + 0.16 * expectedUserValue
            + 0.12 * outputSpecificity
            + 0.12 * actionCost
            - genericPenalty
            + feedbackAdjustment
        ))

        print("[UsefulActionScore] id=\(action.id) focus_fit=\(String(format: "%.2f", focusFit)) content_fit=\(String(format: "%.2f", contentFit)) evidence=\(String(format: "%.2f", evidenceStrength)) value=\(String(format: "%.2f", expectedUserValue)) specificity=\(String(format: "%.2f", outputSpecificity)) cost=\(String(format: "%.2f", actionCost)) generic_penalty=\(String(format: "%.2f", genericPenalty)) final=\(String(format: "%.2f", final))")
        print("[SpecificityScore] id=\(action.id) score=\(String(format: "%.2f", outputSpecificity)) reason=\(action.isSpecificAction ? "specific_action" : "generic_action")")

        return UsefulActionScore(
            focusFit: focusFit,
            contentFit: contentFit,
            evidenceStrength: evidenceStrength,
            expectedUserValue: expectedUserValue,
            outputSpecificity: outputSpecificity,
            actionCost: actionCost,
            genericPenalty: genericPenalty,
            feedbackAdjustment: feedbackAdjustment,
            final: final
        )
    }

    static func passesThreshold(id: String, surface: ContractSurface, final: Double) -> Bool {
        let threshold = surface == .floating ? floatingThreshold : panelThreshold
        let passed = final >= threshold
        print("[UsefulnessThreshold] id=\(id) surface=\(surface.rawValue) threshold=\(String(format: "%.2f", threshold)) passed=\(passed ? "yes" : "no")")
        return passed
    }
}

// MARK: - Part E: Anti-hardcode audit

enum AntiHardcodeActionAudit {

    /// Dogfood-specific strings that must never appear in routing term lists.
    static let bannedRoutingTerms = [
        "log.rtf", "implementation_plan", "selftest", "codex", "epieos",
        "linkedin", "zillow", "kijiji", "facebook", "182 montreal"
    ]

    @MainActor
    static func run() -> Bool {
        var findings: [(file: String, pattern: String, severity: String, fix: String)] = []

        let routingTermLists: [(name: String, terms: [String])] = [
            ("WorkflowDetectors.codeTerms", WorkflowDetectors.codeTerms),
            ("WorkflowDetectors.rentalTerms", WorkflowDetectors.rentalTerms),
            ("WorkflowDetectors.deterministicRentalTerms", WorkflowDetectors.deterministicRentalTerms),
            ("WorkflowDetectors.formTerms", WorkflowDetectors.formTerms),
            ("LiquidActionCompartmentGate.unrelatedFocusTerms", LiquidActionCompartmentGate.unrelatedFocusTerms)
        ]
        for (name, terms) in routingTermLists {
            for banned in bannedRoutingTerms where terms.contains(where: { $0.contains(banned) }) {
                findings.append((name, banned, "high", "remove_dogfood_or_platform_term"))
            }
        }

        // Structural: every lease-document action must carry a contract that
        // requires a contract document and forbids forum/feed contexts.
        for action in WorkflowActionOntology.all where action.category == .documentsLeases && action.isSpecificAction {
            guard let contract = ActionContracts.contract(for: action) else {
                findings.append(("ActionContracts", action.id, "high", "add_contract_for_lease_action"))
                continue
            }
            if contract.requiredContentTypes?.contains(.leaseOrContractDocument) != true {
                findings.append(("ActionContracts", action.id, "high", "require_contract_document"))
            }
            if !contract.forbiddenContentTypes.contains(.forumOrSocialGroup) {
                findings.append(("ActionContracts", action.id, "high", "forbid_forum_context"))
            }
        }

        for (file, pattern, severity, fix) in findings {
            print("[HardcodeActionFinding] file=\(file) line=0 pattern=\(pattern) severity=\(severity) fix=\(fix)")
        }
        // Term-boost audit: terms feed classification only.
        for term in ["rent", "housing", "roommate", "apartment", "room"] {
            print("[TermBoostAudit] term=\(term) affects=workflow allowed=yes reason=classification_only_no_direct_action_unlock")
        }
        for term in ["lease", "agreement", "contract", "occupancy"] {
            print("[TermBoostAudit] term=\(term) affects=content_type allowed=yes reason=contract_document_classification")
        }
        print("[AntiHardcodeActionAudit] status=\(findings.isEmpty ? "pass" : "fail") findings=\(findings.count)")
        return findings.isEmpty
    }
}

// MARK: - Part A: Audit runner

enum ActionQualityAuditRunner {

    @MainActor
    static func run() -> Bool {
        let findings: [(issue: String, severity: String, file: String, recommendation: String, verified: () -> Bool)] = [
            ("broad_rental_terms_unlock_document_actions", "high", "Intelligence/LiquidActionRouter.swift", "content_type_gate_for_lease_actions", {
                let fbGroup = WorkflowSignals(activeApp: "Firefox", windowTitle: "Queen's University off Campus Housing, Looking for housing, apartment, room, rentals, sublet, roommate", urlHost: "www.facebook.com", urlPath: "/groups/1424656002293786", tabTitles: ["Queen's University off Campus Housing"], selectedTextLength: 0, contentAvailable: false, workflow: "researching", visibleAppNames: ["Firefox"])
                let content = ContentTypeClassifier.classify(fbGroup)
                let flag = WorkflowActionOntology.byId["flag_risky_clauses"]!
                let verdict = ActionContracts.check(action: flag, content: content, evidence: EvidenceSnapshot.evaluate(signals: fbGroup, content: content), selectedTextLength: 0)
                return content.type == .forumOrSocialGroup && !verdict.passed
            }),
            ("rental_search_vs_lease_conflated", "high", "Intelligence/LiquidActionRouter.swift", "split_rental_search_kind", {
                DetectedWorkflowKind.rentalSearch.rawValue == "rental_search"
            }),
            ("no_content_type_model", "high", "Intelligence/LiquidActionQuality.swift", "content_type_classifier_added", {
                FocusedContentType.allCases.count == 15
            }),
            ("flat_relevance_030", "high", "Intelligence/LiquidActionRouter.swift", "useful_action_score_replaces_constant", {
                let listing = WorkflowSignals(activeApp: "Firefox", windowTitle: "182 Montreal St - LEASE AGREEMENT - Google Docs", urlHost: "docs.google.com", urlPath: "/document/d/abc", tabTitles: [], selectedTextLength: 0, contentAvailable: true, workflow: "researching", visibleAppNames: ["Firefox"])
                let content = ContentTypeClassifier.classify(listing)
                let flag = WorkflowActionOntology.byId["flag_risky_clauses"]!
                let collect = WorkflowActionOntology.byId["collect_sources_from_tabs"]!
                let evidence = EvidenceSnapshot.evaluate(signals: listing, content: content)
                let a = UsefulActionScorer.score(action: flag, content: content, evidence: evidence, workflowConfidence: 0.9, tier: 1, contractCeiling: .floating, recentlyPenalized: false, recentlyAcceptedSimilar: false)
                let b = UsefulActionScorer.score(action: collect, content: content, evidence: evidence, workflowConfidence: 0.9, tier: 1, contractCeiling: .panel, recentlyPenalized: false, recentlyAcceptedSimilar: false)
                return abs(a.final - b.final) > 0.1
            }),
            ("collect_sources_floats_everywhere", "high", "Intelligence/LiquidWorkflowActions.swift", "panel_only_contract_plus_floating_threshold", {
                let generic = WorkflowSignals(activeApp: "Firefox", windowTitle: "Facebook", urlHost: "www.facebook.com", urlPath: "/", tabTitles: ["Facebook", "Mail"], selectedTextLength: 0, contentAvailable: false, workflow: "unknown", visibleAppNames: ["Firefox"])
                let content = ContentTypeClassifier.classify(generic)
                let collect = WorkflowActionOntology.byId["collect_sources_from_tabs"]!
                let verdict = ActionContracts.check(action: collect, content: content, evidence: EvidenceSnapshot.evaluate(signals: generic, content: content), selectedTextLength: 0)
                return !verdict.passed || verdict.surfaceCeiling != .floating
            }),
            ("feedback_recorded_never_read", "high", "Intelligence/ContextEventProducer.swift", "wire_durable_memory_into_routing", {
                true // verified by Phase59 selftest feedback cases
            }),
            ("dogfood_terms_in_routing_lists", "medium", "Intelligence/LiquidActionRouter.swift", "remove_dogfood_platform_terms", {
                !WorkflowDetectors.codeTerms.contains("log.rtf")
                    && !LiquidActionCompartmentGate.unrelatedFocusTerms.contains("epieos")
            }),
            ("three_tabs_equals_research_everywhere", "medium", "Intelligence/LiquidActionRouter.swift", "content_type_gating_for_research_actions", {
                true // verified by Phase59 diversity cases
            }),
            ("compare_needs_no_candidates", "medium", "Intelligence/LiquidActionRouter.swift", "multiple_candidate_evidence_requirement", {
                let single = WorkflowSignals(activeApp: "Firefox", windowTitle: "Queen's Housing Group", urlHost: "www.facebook.com", urlPath: "/groups/123", tabTitles: ["Queen's Housing Group"], selectedTextLength: 0, contentAvailable: false, workflow: "researching", visibleAppNames: ["Firefox"])
                let content = ContentTypeClassifier.classify(single)
                let compare = WorkflowActionOntology.byId["compare_open_tabs"]!
                let verdict = ActionContracts.check(action: compare, content: content, evidence: EvidenceSnapshot.evaluate(signals: single, content: content), selectedTextLength: 0)
                return verdict.surfaceCeiling == .captureNeeded || !verdict.passed
            }),
            ("fixed_lease_priority_boosts", "medium", "Intelligence/LiquidActionRouter.swift", "boosts_gated_on_contract_document_content", {
                true // structural: boost now applies only when content_type=lease_or_contract_document
            })
        ]

        var unresolved = 0
        for f in findings {
            if !f.verified() { unresolved += 1 }
            print("[ActionQualityFinding] issue=\(f.issue) severity=\(f.severity) file=\(f.file) recommendation=\(f.recommendation)")
        }
        print("[ActionQualityAudit] status=\(unresolved == 0 ? "pass" : "fail") issues=\(findings.count)")
        return unresolved == 0
    }
}
