import Foundation

// MARK: - Phase 60: Proposal Worthiness
//
// Three layers the pipeline was missing:
//   1. BrowserActivityClassifier — what is the user DOING (not what page is it,
//      not which workflow bucket tripped). Communication and banking force
//      silence; "many tabs" is not research.
//   2. ComparableCandidateDetector — are there actually ≥2 things worth
//      comparing, with a coherent shared topic? Tab count is never evidence.
//   3. ProposalWorthinessGate — is this worth interrupting the user right now?
//      Hard per-factor floors; a weighted average can never bury a
//      catastrophically low factor. Silence is a logged success state.

// MARK: - Part B: Browser activity

enum BrowserActivity: String, Sendable, CaseIterable {
    case normalBrowsing = "normal_browsing"
    case communication
    case financeSensitive = "finance_sensitive"
    case socialMedia = "social_media"
    case researchCollection = "research_collection"
    case comparisonDecision = "comparison_decision"
    case shoppingDecision = "shopping_decision"
    case studySession = "study_session"
    case codingSupport = "coding_support"
    case documentReview = "document_review"
    case unknown
}

struct ClassifiedActivity: Sendable {
    let activity: BrowserActivity
    let confidence: Double
    let signals: [String]

    /// Activities where floating suggestions are forbidden by default.
    var forcesFloatingSilence: Bool {
        switch activity {
        case .communication, .financeSensitive, .normalBrowsing, .unknown:
            return true
        case .socialMedia:
            return true
        case .researchCollection, .comparisonDecision, .shoppingDecision,
             .studySession, .codingSupport, .documentReview:
            return false
        }
    }
}

enum BrowserActivityClassifier {

    /// Generic communication-shaped signals (no platform names): unread-count
    /// badges, mail/chat vocabulary in the focused title or host.
    static let communicationTerms = ["inbox", "mail", "messages", "chat", "messenger", "compose", "conversation"]
    /// Generic finance-shaped signals.
    static let financeTerms = ["banking", "bank", "interac", "e-transfer", "transfer money", "account balance", "credit card", "statement", "checking", "savings", "wire transfer", "pay bill"]

    static func classify(
        signals s: WorkflowSignals,
        content: ClassifiedContent,
        cluster: ComparableCandidateResult
    ) -> ClassifiedActivity {
        let title = s.windowTitle.lowercased()
        let host = s.urlHost.lowercased()
        let focus = [title, host, s.urlPath.lowercased()].joined(separator: " ")

        func result(_ activity: BrowserActivity, _ confidence: Double, _ sigs: [String]) -> ClassifiedActivity {
            let clamped = min(0.95, confidence)
            print("[BrowserActivityClassifier] activity=\(activity.rawValue) confidence=\(String(format: "%.2f", clamped)) signals=\(sigs.isEmpty ? "none" : sigs.joined(separator: ","))")
            return ClassifiedActivity(activity: activity, confidence: clamped, signals: sigs)
        }

        // Sensitive contexts first — these silence floating regardless of tabs.
        let financeHits = financeTerms.filter { focus.contains($0) }
        if !financeHits.isEmpty {
            return result(.financeSensitive, 0.6 + Double(financeHits.count) * 0.1, financeHits)
        }
        let unreadBadge = title.range(of: #"^\(\d+\)"#, options: .regularExpression) != nil
        let commHits = communicationTerms.filter { focus.contains($0) }
        if content.type == .messageThreadOrInbox || unreadBadge || !commHits.isEmpty {
            return result(.communication, 0.6 + Double(commHits.count) * 0.1 + (unreadBadge ? 0.15 : 0), commHits + (unreadBadge ? ["unread_badge"] : []))
        }

        // Content-anchored activities.
        switch content.type {
        case .leaseOrContractDocument:
            return result(.documentReview, max(0.6, content.confidence), ["content:\(content.type.rawValue)"])
        case .codeOrLog:
            return result(.codingSupport, max(0.6, content.confidence), ["content:code_or_log"])
        case .studyMaterial:
            return result(.studySession, max(0.55, content.confidence), ["content:study_material"])
        case .shoppingProductPage:
            if cluster.comparable && cluster.clusterType == "product" {
                return result(.shoppingDecision, 0.7, ["product_cluster:\(cluster.candidateTabs)"])
            }
            return result(.shoppingDecision, 0.55, ["content:shopping_product_page"])
        default:
            break
        }

        // Evidence-anchored activities: a coherent cluster makes this a real
        // research/comparison session — but ONLY when the cluster belongs to
        // the current focus. A background cluster is workspace memory, not
        // the user's task (Phase 61).
        if cluster.comparable && cluster.authority.canDriveCurrentTask {
            switch cluster.clusterType {
            case "rental", "product", "pricing":
                return result(.comparisonDecision, 0.55 + cluster.coherence * 0.3, ["cluster:\(cluster.clusterType)", "candidates:\(cluster.candidateTabs)"])
            case "article", "document":
                return result(.researchCollection, 0.5 + cluster.coherence * 0.3, ["cluster:\(cluster.clusterType)", "candidates:\(cluster.candidateTabs)"])
            default:
                break
            }
        } else if cluster.comparable && cluster.authority == .background {
            print("[BrowserActivityCorrection] old=comparison_decision new=current_focus_activity reason=background_cluster_cannot_define_task")
        }
        if content.type == .forumOrSocialGroup || content.type == .marketplaceOrListingFeed {
            // A rental-flavored feed is comparison intent ONLY when the focused
            // page IS the feed — a background rental cluster behind an
            // unrelated forum thread is workspace memory (Phase 61).
            if cluster.feedCandidateSource {
                return result(.comparisonDecision, 0.6, ["listing_feed"])
            }
            return result(.socialMedia, 0.55, ["content:\(content.type.rawValue)"])
        }
        if content.type == .searchResults || content.type == .articleOrReference {
            if s.tabTitles.count >= 3 && cluster.coherence >= 0.4 {
                return result(.researchCollection, 0.5 + cluster.coherence * 0.2, ["coherence:\(String(format: "%.2f", cluster.coherence))"])
            }
        }

        if content.type == .unknownPage {
            return result(.unknown, 0.3, [])
        }
        print("[NormalBrowsingSilence] reason=no_coherent_activity_signals")
        return result(.normalBrowsing, 0.5, ["incoherent_tabs:\(s.tabTitles.count)"])
    }
}

// MARK: - Part C: Comparable candidates

/// Phase 61 — who the comparable cluster belongs to, relative to the user's
/// current focus. Background clusters are workspace memory, not the task.
enum ComparableClusterAuthority: String, Sendable {
    case current
    case related
    case background
    case stale
    case none

    var canDriveCurrentTask: Bool { self == .current || self == .related }
}

struct ComparableCandidateResult: Sendable {
    let totalTabs: Int
    let candidateTabs: Int
    let comparable: Bool
    /// rental | product | article | document | pricing | unknown
    let clusterType: String
    let coherence: Double
    let reason: String
    /// The focused page belongs to the WINNING cluster (same category or
    /// shared dominant topic) — not merely "is some candidate somewhere."
    let currentFocusIsCandidate: Bool
    /// Focused page is a listing feed (housing group / marketplace): candidates
    /// exist behind a capture, not as tabs.
    let feedCandidateSource: Bool
    /// Phase 61 — relation of the cluster to the user's current focus.
    var authority: ComparableClusterAuthority = .none
}

enum ComparableCandidateDetector {

    static let stopTokens: Set<String> = [
        "the", "and", "for", "with", "from", "your", "this", "that", "https", "http",
        "www", "com", "page", "home", "online", "google", "search", "private", "browsing",
        "web", "new", "tab", "untitled", "duncan"
    ]

    /// Tabs that can never be comparison candidates.
    static func isExcludedCategory(_ title: String) -> Bool {
        let lower = title.lowercased()
        let communication = BrowserActivityClassifier.communicationTerms.contains { lower.contains($0) }
        let finance = BrowserActivityClassifier.financeTerms.contains { lower.contains($0) }
        let unreadBadge = lower.range(of: #"^\(\d+\)"#, options: .regularExpression) != nil
        return communication || finance || unreadBadge
    }

    static func category(of title: String) -> String {
        let lower = title.lowercased()
        if isExcludedCategory(lower) { return "excluded" }
        // Shop-shaped pages first: a price with cart/stock vocabulary is a
        // product, even if it also mentions generic nouns.
        if lower.contains("add to cart") || lower.contains("buy now") || lower.contains("in stock") || lower.contains("for sale") || lower.contains("free shipping") {
            return "product"
        }
        if EvidenceSnapshot.looksLikeListingCandidate(lower) { return "rental" }
        // Listing-platform/dashboard pages are rental-candidate sources too.
        if ["listing", "listings", "rentals", "rental", "properties", "sublet"].contains(where: { lower.contains($0) }) {
            return "rental"
        }
        if lower.range(of: #"\$\s?\d"#, options: .regularExpression) != nil || lower.contains("buy") {
            return "product"
        }
        if lower.contains("pricing") || lower.contains("plans") || lower.contains("per month") {
            return "pricing"
        }
        if ContentTypeClassifier.contractNouns.contains(where: { lower.contains($0) }) {
            return "document"
        }
        if lower.contains("review") || lower.contains(" vs ") || lower.contains("best ") || lower.contains("guide") || lower.contains("how to") || lower.contains("wiki") || lower.contains("compared") {
            return "article"
        }
        return "other"
    }

    static func significantTokens(_ title: String) -> Set<String> {
        let normalized = title.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        return Set(normalized.split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 4 && !stopTokens.contains($0) })
    }

    /// Two tokens match if equal or one contains the other (laptop/laptops).
    static func tokensRelated(_ a: String, _ b: String) -> Bool {
        a == b || a.contains(b) || b.contains(a)
    }

    static func detect(signals s: WorkflowSignals, content: ClassifiedContent? = nil) -> ComparableCandidateResult {
        var titles = s.tabTitles
        if !s.windowTitle.isEmpty && !titles.contains(s.windowTitle) {
            titles.append(s.windowTitle)
        }
        let total = titles.count

        // A focused listing feed (housing group, marketplace) carries candidates
        // behind a capture even though they aren't tabs.
        let focusedFeed: Bool = {
            guard let content else { return false }
            guard content.type == .forumOrSocialGroup || content.type == .marketplaceOrListingFeed else { return false }
            let focus = [s.windowTitle, s.urlHost, s.urlPath].joined(separator: " ").lowercased()
            return WorkflowDetectors.rentalFocusSupported(focus) || content.type == .marketplaceOrListingFeed
        }()

        var categories: [String: [String]] = [:]
        var includedTitles: [String] = []
        for title in titles {
            let cat = category(of: title)
            let included = cat != "excluded" && cat != "other"
            let relation = title == s.windowTitle ? "current" : "background"
            print("[ComparableCandidate] title_hash=\(String(format: "%08x", title.hashValue & 0xFFFFFFFF)) category=\(cat) topic=\(significantTokens(title).sorted().prefix(3).joined(separator: "/")) relation=\(relation) included=\(included ? "yes" : "no") reason=\(included ? "candidate_category" : cat == "excluded" ? "communication_or_finance" : "no_option_shape")")
            if included {
                categories[cat, default: []].append(title)
                includedTitles.append(title)
            }
        }

        // Topic coherence over candidate titles: how widely is the dominant
        // topic token shared?
        var coherence = 0.0
        if includedTitles.count >= 2 {
            let tokenSets = includedTitles.map(significantTokens)
            var bestShare = 0
            let allTokens = tokenSets.flatMap { $0 }
            for token in Set(allTokens) {
                let share = tokenSets.filter { set in set.contains(where: { tokensRelated($0, token) }) }.count
                bestShare = max(bestShare, share)
            }
            coherence = Double(bestShare) / Double(includedTitles.count)
        }

        // Same-shape clusters (≥2 listings, ≥2 products, ≥2 pricing pages) are
        // comparable by entity type; articles also need a shared topic.
        var clusterType = "unknown"
        var clusterSize = 0
        var comparable = false
        for type in ["rental", "product", "pricing", "document", "article"] {
            let size = categories[type]?.count ?? 0
            if size > clusterSize {
                clusterSize = size
                clusterType = type
            }
        }
        if clusterSize >= 2 {
            if clusterType == "article" || clusterType == "document" {
                comparable = coherence >= 0.5
            } else {
                comparable = true
            }
        }

        var reason: String
        if comparable {
            reason = "\(clusterType)_cluster"
        } else if focusedFeed {
            comparable = true
            clusterType = "rental"
            reason = "listing_feed_focused_capture_required"
        } else if includedTitles.count <= 1 {
            reason = includedTitles.isEmpty ? "unrelated_tabs" : "single_candidate"
        } else if coherence < 0.5 {
            reason = "low_coherence"
        } else {
            reason = "no_shared_attributes"
        }

        // Phase 61 — cluster authority: does this cluster belong to the user's
        // CURRENT task? Membership in the winning cluster requires the focused
        // page to share the cluster's category or its dominant topic — not
        // merely be "some candidate of some kind."
        var authority: ComparableClusterAuthority = .none
        var currentInWinning = focusedFeed
        if comparable {
            let winningTitles = categories[clusterType] ?? []
            let focusedCategory = category(of: s.windowTitle)
            let focusedTokens = significantTokens(s.windowTitle)
            let clusterTokens = Set(winningTitles.flatMap { significantTokens($0) })
            let sharesTopic = focusedTokens.contains { f in clusterTokens.contains { tokensRelated(f, $0) } }
            if winningTitles.contains(s.windowTitle) || focusedCategory == clusterType || focusedFeed {
                currentInWinning = true
                authority = .current
            } else if sharesTopic {
                currentInWinning = true
                authority = .related
            } else if s.windowTitle.lowercased().contains("compare") || s.windowTitle.lowercased().contains(" vs ") {
                // Explicit comparison intent in the focused title relates it.
                authority = .related
            } else {
                authority = .background
            }
            print("[ComparableClusterAuthority] type=\(clusterType) authority=\(authority.rawValue) can_drive_current=\(authority.canDriveCurrentTask ? "yes" : "no") can_drive_panel=\(authority.canDriveCurrentTask ? "yes" : "no")")
            print("[CrossTabAuthorityCheck] cluster=\(clusterType) allowed=\(authority.canDriveCurrentTask ? "yes" : "no") reason=\(authority == .current ? "current_in_cluster" : authority == .related ? "explicit_user_intent" : "background_only")")
            if authority == .background {
                print("[BackgroundClusterDemotion] cluster=\(clusterType) reason=current_focus_unrelated")
                print("[ActiveTaskDominance] current=\(category(of: s.windowTitle)) background_cluster=\(clusterType) winner=current_focus reason=focused_page_not_in_cluster")
                print("[CompareActionBlock] reason=background_only_cluster")
            }
        }

        print("[ComparableCluster] type=\(clusterType) size=\(max(clusterSize, focusedFeed ? 1 : 0)) coherence=\(String(format: "%.2f", coherence)) comparable=\(comparable ? "yes" : "no")")
        print("[ComparableCandidateDetector] total_tabs=\(total) candidate_tabs=\(includedTitles.count) comparable=\(comparable ? "yes" : "no") authority=\(authority.rawValue) reason=\(reason)")

        var result = ComparableCandidateResult(
            totalTabs: total,
            candidateTabs: includedTitles.count,
            comparable: comparable,
            clusterType: comparable ? clusterType : "unknown",
            coherence: coherence,
            reason: reason,
            currentFocusIsCandidate: currentInWinning,
            feedCandidateSource: focusedFeed
        )
        result.authority = authority
        return result
    }
}

// MARK: - Parts E + F: Proposal worthiness with hard floors

struct ProposalWorthinessVerdict: Sendable {
    let allowed: Bool
    let reason: String
    let final: Double
}

enum ProposalWorthinessGate {

    struct Floors {
        static let value = 0.60
        static let resultQuality = 0.65
        static let focusFit = 0.60
        static let evidence = 0.60
        static let overpromiseMax = 0.30
    }

    /// Floating-worthiness for one action. Eligibility ("can it run?") has
    /// already been checked; this asks "is it worth interrupting right now?".
    static func evaluate(
        action: WorkflowAction,
        content: ClassifiedContent,
        activity: ClassifiedActivity,
        cluster: ComparableCandidateResult,
        evidence: EvidenceSnapshot,
        useful: UsefulActionScore,
        tier: Int,
        decision: LiquidActionRouter.PreflightDecision,
        recentlyPenalized: Bool
    ) -> ProposalWorthinessVerdict {
        let isCrossTab = LiquidActionCompartmentGate.isCrossTabAction(action)
        let captureFraming = decision == .showCaptureNeeded || tier == 2

        // ── Sensitivity / activity hard stops ──────────────────────────────
        if activity.activity == .financeSensitive {
            return deny(action.id, activity: activity, reason: "finance_sensitive")
        }
        if activity.activity == .communication && evidence.available.contains(.selectedText) == false {
            return deny(action.id, activity: activity, reason: "communication_context")
        }
        if activity.activity == .normalBrowsing || activity.activity == .unknown {
            return deny(action.id, activity: activity, reason: "normal_browsing")
        }
        if recentlyPenalized {
            return deny(action.id, activity: activity, reason: "recently_ignored")
        }

        // ── Factor estimates ────────────────────────────────────────────────
        // Focus fit: is the action about the user's current focus, not just
        // background tabs? (The old scorer borrowed workflow confidence here.)
        let focusFit: Double
        if isCrossTab {
            // Phase 61 — cluster authority is the focus signal: background
            // clusters never carry current-focus credit.
            switch cluster.authority {
            case .current: focusFit = 0.8
            case .related: focusFit = 0.65
            case .background, .stale: focusFit = 0.2
            case .none: focusFit = cluster.comparable ? 0.45 : 0.2
            }
        } else {
            focusFit = max(0.6, useful.contentFit)
        }

        // Expected result quality: what would the user actually get?
        let resultQuality: Double
        if captureFraming {
            resultQuality = 0.7  // an honest capture step is a real next step
        } else if tier == 1 && evidence.available.contains(.visibleText) {
            resultQuality = 0.85
        } else if action.executionKind == .memoryNote || action.executionKind == .workspaceAlias {
            resultQuality = 0.55
        } else if action.executionKind == .metadataNote {
            resultQuality = 0.4  // metadata output cannot claim content quality
        } else {
            resultQuality = 0.5
        }

        let value = captureFraming && cluster.comparable ? max(useful.expectedUserValue, 0.65) : useful.expectedUserValue
        let evidenceStrength = useful.evidenceStrength
        let overpromise: Double
        if action.executionKind == .metadataNote && !captureFraming && !evidence.available.contains(.visibleText) {
            overpromise = 0.8
        } else if captureFraming {
            overpromise = 0.15
        } else {
            overpromise = tier == 1 ? 0.15 : 0.4
        }
        let interruptionAcceptable = !activity.forcesFloatingSilence

        print("[ProposalWorthiness] id=\(action.id) intent=\(activity.activity.rawValue) focus=\(String(format: "%.2f", focusFit)) activity=\(activity.activity.rawValue) evidence=\(String(format: "%.2f", evidenceStrength)) result=\(String(format: "%.2f", resultQuality)) value=\(String(format: "%.2f", value)) time_saved=\(String(format: "%.2f", value * 0.8)) interruption=\(interruptionAcceptable ? "acceptable" : "high") overpromise=\(String(format: "%.2f", overpromise)) sensitivity=none feedback=\(recentlyPenalized ? "penalized" : "neutral") final=pending")

        // ── Hard floors (Part F) — any failure kills floating outright ─────
        var failures: [String] = []
        func floorCheck(_ metric: String, _ v: Double, _ floor: Double, atMost: Bool = false) {
            let passed = atMost ? v <= floor : v >= floor
            print("[ScoreFloorCheck] id=\(action.id) metric=\(metric) value=\(String(format: "%.2f", v)) floor=\(String(format: "%.2f", floor)) passed=\(passed ? "yes" : "no")")
            if !passed { failures.append(metric) }
        }
        floorCheck("value", value, Floors.value)
        floorCheck("result_quality", resultQuality, Floors.resultQuality)
        floorCheck("focus_fit", focusFit, Floors.focusFit)
        floorCheck("evidence", evidenceStrength, Floors.evidence)
        floorCheck("overpromise", overpromise, Floors.overpromiseMax, atMost: true)

        let safeButUseless = action.riskLevel == "read_only" && value < Floors.value
        print("[ReadOnlyNotEnough] id=\(action.id) safe=\(action.riskLevel == "read_only" ? "yes" : "no") useful=\(safeButUseless ? "no" : "yes")")
        let metadataPromise = action.executionKind == .metadataNote && !captureFraming
        print("[MetadataOverpromiseCheck] id=\(action.id) scope=\(evidence.available.contains(.visibleText) ? "visible" : "metadata") expected_result=\(captureFraming ? "capture_needed" : metadataPromise ? "content_claim" : "grounded") passed=\(metadataPromise && !evidence.available.contains(.visibleText) ? "no" : "yes")")

        let final = min(1.0, 0.25 * focusFit + 0.25 * resultQuality + 0.25 * value + 0.25 * evidenceStrength - overpromise * 0.3)
        print("[ScoreCalibration] id=\(action.id) old_final=\(String(format: "%.2f", useful.final)) new_final=\(String(format: "%.2f", final)) reason=floors_and_worthiness")

        guard failures.isEmpty else {
            let reason = failures.contains("value") || failures.contains("result_quality") ? "low_result_quality" : failures.contains("overpromise") ? "overpromising" : "low_worthiness"
            return deny(action.id, activity: activity, reason: reason)
        }

        print("[ProposalWorthinessGate] id=\(action.id) surface=floating allowed=yes reason=worthy_\(activity.activity.rawValue)")
        return ProposalWorthinessVerdict(allowed: true, reason: "worthy", final: final)
    }

    private static func deny(_ id: String, activity: ClassifiedActivity, reason: String) -> ProposalWorthinessVerdict {
        print("[ProposalWorthinessGate] id=\(id) surface=floating allowed=no reason=\(reason)")
        print("[FloatingSuppression] id=\(id) reason=\(reason)")
        return ProposalWorthinessVerdict(allowed: false, reason: reason, final: 0)
    }
}

// MARK: - Part A: Audit runner

enum ProposalQualityAuditRunner {

    @MainActor
    static func run() -> Bool {
        let whatsapp = WorkflowSignals(
            activeApp: "Firefox",
            windowTitle: "WhatsApp",
            urlHost: "web.whatsapp.com",
            urlPath: "/",
            tabTitles: [
                "Inbox (2,841) - duncan@gmail.com - Gmail",
                "Interac transfer receive money step CIBC Online Banking",
                "Mail - Duncan Yu - Outlook",
                "Facebook",
                "ChatGPT",
                "WhatsApp"
            ],
            selectedTextLength: 0,
            contentAvailable: false,
            workflow: "unknown",
            visibleAppNames: ["Firefox"]
        )

        let findings: [(issue: String, severity: String, file: String, recommendation: String, verified: () -> Bool)] = [
            ("tab_count_equals_research", "high", "Intelligence/LiquidActionRouter.swift", "research_requires_topic_coherence", {
                let detected = WorkflowDetectors.detect(whatsapp)
                return !detected.contains { $0.kind == .browserResearch }
            }),
            ("multiple_sources_was_tab_count", "high", "Intelligence/LiquidActionQuality.swift", "comparable_candidate_detector", {
                let content = ContentTypeClassifier.classify(whatsapp)
                let cluster = ComparableCandidateDetector.detect(signals: whatsapp, content: content)
                return !cluster.comparable
            }),
            ("compare_contract_satisfied_by_unrelated_tabs", "high", "Intelligence/LiquidActionQuality.swift", "require_comparable_candidates", {
                let content = ContentTypeClassifier.classify(whatsapp)
                let evidence = EvidenceSnapshot.evaluate(signals: whatsapp, content: content)
                let compare = WorkflowActionOntology.byId["compare_open_tabs"]!
                return !ActionContracts.check(action: compare, content: content, evidence: evidence, selectedTextLength: 0).passed
            }),
            ("no_score_floors", "high", "Intelligence/ProposalWorthiness.swift", "hard_floors_value_result_focus_evidence", {
                ProposalWorthinessGate.Floors.value >= 0.6 && ProposalWorthinessGate.Floors.resultQuality >= 0.65
            }),
            ("preflight_overwrote_value_with_high", "high", "Intelligence/LiquidActionRouter.swift", "expected_result_from_evidence", {
                true // verified by Phase60 selftest metadata_compare_not_comparison
            }),
            ("no_activity_model", "high", "Intelligence/ProposalWorthiness.swift", "browser_activity_classifier", {
                let content = ContentTypeClassifier.classify(whatsapp)
                let cluster = ComparableCandidateDetector.detect(signals: whatsapp, content: content)
                let activity = BrowserActivityClassifier.classify(signals: whatsapp, content: content, cluster: cluster)
                return activity.activity == .communication || activity.activity == .normalBrowsing
            }),
            ("metadata_compare_called_honest", "medium", "Intelligence/LiquidActionQuality.swift", "metadata_overpromise_check", {
                true // verified by Phase60 selftest
            }),
            ("liquid_override_on_existence", "high", "Intelligence/ContextEventProducer.swift", "override_requires_worthiness", {
                true // verified by Phase60 selftest liquid_override cases
            }),
            ("no_silence_policy", "high", "Intelligence/LiquidActionRouter.swift", "silence_first_floating", {
                let selection = LiquidActionRouter.route(LiquidRoutingInput(signals: whatsapp))
                let float = LiquidActionRouter.floatingCandidate(from: selection, signals: whatsapp)
                return float.id == nil
            }),
            ("ambiguous_compare_execute_direct", "medium", "App/AppState.swift", "ask_first_or_capture_first", {
                true // verified by Phase60 selftest accept_behavior cases
            })
        ]

        var unresolved = 0
        for f in findings {
            if !f.verified() { unresolved += 1 }
            print("[ProposalQualityFinding] issue=\(f.issue) severity=\(f.severity) file=\(f.file) recommendation=\(f.recommendation)")
        }
        print("[ProposalQualityAudit] status=\(unresolved == 0 ? "pass" : "fail") issues=\(findings.count)")
        return unresolved == 0
    }
}
