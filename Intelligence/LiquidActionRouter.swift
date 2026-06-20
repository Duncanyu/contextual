import Foundation

// MARK: - Phase 53: Workflow Detection + Liquid Action Router
//
// Detects what kind of workflow the user is in (forms, rental/lease,
// code/logs, multi-tab research, writing) from cheap, already-available
// signals, then routes ontology actions: specific before generic, executable
// before setup, setup before fake. Pure functions — fully self-testable.

// MARK: - Signals

struct WorkflowSignals: Sendable {
    let activeApp: String
    let windowTitle: String
    let urlHost: String
    let urlPath: String
    let tabTitles: [String]
    let selectedTextLength: Int
    /// Real readable content (AX/OCR visible text) currently available.
    let contentAvailable: Bool
    let workflow: String                 // ambient workflow string ("researching"…)
    let visibleAppNames: [String]
    let enrichedContext: EnrichedContextSnapshot?

    var enrichedTextLength: Int { enrichedContext?.chars ?? 0 }
    var enrichedEvidenceLevel: String { enrichedContext?.evidenceLevel ?? "metadata" }
    var enrichedEvidenceSource: String { enrichedContext?.source ?? "none" }

    init(
        activeApp: String,
        windowTitle: String,
        urlHost: String = "",
        urlPath: String = "",
        tabTitles: [String] = [],
        selectedTextLength: Int = 0,
        contentAvailable: Bool = false,
        workflow: String = "unknown",
        visibleAppNames: [String] = [],
        enrichedContext: EnrichedContextSnapshot? = nil
    ) {
        self.activeApp = activeApp
        self.windowTitle = windowTitle
        self.urlHost = urlHost
        self.urlPath = urlPath
        self.tabTitles = tabTitles
        self.selectedTextLength = selectedTextLength
        self.contentAvailable = contentAvailable || enrichedContext != nil
        self.workflow = workflow
        self.visibleAppNames = visibleAppNames
        self.enrichedContext = enrichedContext
    }
}

enum DetectedWorkflowKind: String, Sendable {
    case formApplication = "form_application"
    case actionPack      = "action_pack"
    /// Phase 59 — browsing/searching for rentals (listings, feeds, groups) is
    /// a different activity from reviewing a lease document.
    case rentalSearch    = "rental_search"
    case codeLogs        = "code_logs"
    case browserResearch = "browser_research"
    case writing         = "writing"
    case generic         = "generic"
}

struct DetectedWorkflow: Sendable {
    let kind: DetectedWorkflowKind
    let confidence: Double
    let signals: [String]
}

// MARK: - Detectors

enum WorkflowDetectors {

    static let formTerms = [
        "application", "apply", "eligibility", "financial information",
        "personal info", "current situation", "select your program", "program",
        "enrolment", "enrollment", "form", "questionnaire",
        "registration", "submit"
    ]

    static let rentalTerms = [
        "lease", "occupancy", "tenant", "landlord",
        "rent", "rental", "listing", "sublet", "deposit", "utilities",
        "move-in", "move in", "roommate", "housing", "apartment"
    ]

    static let deterministicRentalTerms = [
        "rent", "rental", "listing", "room", "landlord", "tenant",
        "lease", "agreement", "utilities", "deposit", "housing"
    ]

    static let codeApps = ["xcode", "terminal", "iterm", "github desktop", "console", "visual studio code", "cursor"]
    // Phase 59 — generic code/log vocabulary only. Dogfood-specific strings
    // (log.rtf, selftest, implementation_plan, codex, …) must never route.
    static let codeTerms = [
        ".swift", ".py", ".ts", ".js", ".rs", ".log", "error",
        "failed", "failure", "timeout", "exception", "xcodebuild", "build",
        "stack trace", "traceback", "compile", "debug"
    ]

    static let comparisonTerms = ["vs", "compare", "comparison", "best", "review", "alternative"]

    static func rentalFocusSupported(_ focus: String) -> Bool {
        let strongTerms = [
            "lease", "occupancy", "tenant", "landlord",
            "rent", "rental", "listing", "accommodation", "sublet", "deposit",
            "utilities", "move-in", "move in", "roommate", "housing",
            "apartment", "agreement"
        ]
        return strongTerms.contains { focus.contains($0) }
    }

    static func deterministicRentalWorkflow(_ s: WorkflowSignals) -> DetectedWorkflow? {
        let titles = ([s.windowTitle] + s.tabTitles)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let lowerTitles = titles.map { $0.lowercased() }
        let urlText = [s.urlHost, s.urlPath].joined(separator: " ").lowercased()
        var signals = deterministicRentalTerms.filter { term in
            lowerTitles.contains(where: { $0.contains(term) }) || urlText.contains(term)
        }
        var seenSignals = Set<String>()
        signals = signals.filter { seenSignals.insert($0).inserted }
        let matchedTabs = lowerTitles.filter { title in
            deterministicRentalTerms.contains(where: { title.contains($0) })
        }
        let hasDocument = lowerTitles.contains { title in
            title.contains("lease") || title.contains("agreement") || title.contains("occupancy")
        }
        let hasRentalCluster = matchedTabs.count >= 2 || signals.count >= 3
        guard hasRentalCluster || hasDocument else { return nil }

        let workflowLabel = hasDocument ? "action_pack" : "rental_search"
        let confidence = min(0.98, 0.68 + Double(min(max(matchedTabs.count, signals.count), 5)) * 0.06 + (hasDocument ? 0.10 : 0.0))
        let compactTitles = titles.prefix(6).map { $0.replacingOccurrences(of: ",", with: " ") }.joined(separator: " | ")
        let focusText = [s.windowTitle, s.urlHost, s.urlPath].joined(separator: " ").lowercased()
        let focusSupported = rentalFocusSupported(focusText)
        print("[TabClusterWorkflow] workflow=\(workflowLabel) confidence=\(String(format: "%.2f", confidence)) authority=\(focusSupported ? "current_focus_supported" : "workspace_only") tabs_matched=\(matchedTabs.count) titles=\(compactTitles)")
        print("[DeterministicWorkflowClassifier] workflow=\(workflowLabel) confidence=\(String(format: "%.2f", confidence)) signals=\(signals.prefix(10).joined(separator: ","))")
        print("[HardcodeAudit] system=DeterministicWorkflowClassifier.\(workflowLabel) hardcoded=yes replacement=content_type_action_pack")
        print("[WorkflowAuthority] source=tab_cluster authority=\(focusSupported ? "live" : "panel_background")")
        // Phase 61 — a deterministic workflow detected ONLY from background
        // tabs cannot define the current task and cannot bypass semantic
        // grounding. The active page wins; the cluster stays workspace memory.
        print("[SemanticGroundingBypassCheck] deterministic_source=\(focusSupported ? "current_focus" : "background") allowed=\(focusSupported ? "yes" : "no") reason=\(focusSupported ? "focused_page_matches_workflow" : "background_tabs_cannot_define_current_task")")
        guard focusSupported else {
            print("[CurrentFocusOverride] old_workflow=\(workflowLabel) new_workflow=none reason=active_task_dominates")
            print("[BackgroundClusterDemotion] cluster=\(workflowLabel) reason=current_focus_unrelated")
            return nil
        }
        if confidence >= 0.80 {
            print("[DeterministicBypassBlocked] old=\(workflowLabel) reason=use_action_pack_pipeline")
        }
        // Phase 59 — the search/lease split is real, not just a log label:
        // browsing listings is rentalSearch; only a document is rentalLease.
        return DetectedWorkflow(kind: hasDocument ? .actionPack : .rentalSearch, confidence: confidence, signals: signals.isEmpty ? ["tab_cluster"] : signals)
    }

    static func detect(_ s: WorkflowSignals) -> [DetectedWorkflow] {
        var detected: [DetectedWorkflow] = []
        let titleLower = s.windowTitle.lowercased()
        let haystack = ([titleLower, s.urlHost.lowercased(), s.urlPath.lowercased()]
            + s.tabTitles.map { $0.lowercased() }).joined(separator: " | ")
        let appLower = s.activeApp.lowercased()
        let isBrowser = ["firefox", "safari", "chrome", "arc", "brave", "edge"].contains { appLower.contains($0) }

        // Forms / applications
        let formHits = formTerms.filter { haystack.contains($0) }
        if isBrowser && !formHits.isEmpty {
            // Multi-page form navigation (repeated titles on the same site) boosts confidence.
            let sequentialPages = s.tabTitles.count >= 1 && formHits.count >= 2
            let confidence = min(0.95, 0.45 + Double(formHits.count) * 0.15 + (sequentialPages ? 0.1 : 0))
            if confidence >= 0.55 {
                detected.append(DetectedWorkflow(kind: .formApplication, confidence: confidence, signals: formHits))
                print("[FormWorkflowDetected] app=\(s.activeApp) url_host=\(s.urlHost) title=\"\(s.windowTitle.prefix(60))\" confidence=\(String(format: "%.2f", confidence)) signals=\(formHits.joined(separator: ","))")
            }
        }

        // Rental / lease (browser, Docs, PDF, TextEdit all count). Deterministic
        // tab-cluster detection wins over semantic fallback for obvious rental workspaces.
        if let deterministicRental = deterministicRentalWorkflow(s) {
            detected.append(deterministicRental)
        } else {
            // Phase 61 — the fallback also requires the FOCUSED page to carry
            // rental terms; background tabs alone never define rental work.
            let focusText = [titleLower, s.urlHost.lowercased(), s.urlPath.lowercased()].joined(separator: " ")
            let rentalHits = rentalTerms.filter { haystack.contains($0) }
            if !rentalHits.isEmpty && rentalFocusSupported(focusText) {
                let confidence = min(0.95, 0.4 + Double(rentalHits.count) * 0.15)
                if confidence >= 0.55 {
                    detected.append(DetectedWorkflow(kind: .actionPack, confidence: confidence, signals: rentalHits))
                    print("[RentalWorkflowDetected] confidence=\(String(format: "%.2f", confidence)) signals=\(rentalHits.joined(separator: ","))")
                }
            } else if !rentalHits.isEmpty {
                print("[SemanticVsWorkflowResolution] semantic_domain=current_focus deterministic_workflow=action_pack winner=current_focus reason=action_pack_background_only")
            }
        }

        // Code / logs / debugging
        let codeAppHit = codeApps.contains { appLower.contains($0) }
        let codeHits = codeTerms.filter { haystack.contains($0) }
        if codeAppHit || codeHits.count >= 2 {
            let confidence = min(0.95, (codeAppHit ? 0.55 : 0.3) + Double(codeHits.count) * 0.08)
            if confidence >= 0.55 {
                var signals = codeHits
                if codeAppHit { signals.insert("app:\(s.activeApp)", at: 0) }
                detected.append(DetectedWorkflow(kind: .codeLogs, confidence: confidence, signals: signals))
                print("[CodeWorkflowDetected] confidence=\(String(format: "%.2f", confidence)) signals=\(signals.prefix(6).joined(separator: ","))")
            }
        }

        // Multi-tab browser research — Phase 60: tab count alone is NEVER
        // research. The tabs must form a coherent topic/candidate cluster.
        if isBrowser && (s.tabTitles.count >= 3 || s.workflow == "researching") {
            let cluster = ComparableCandidateDetector.detect(signals: s)
            let comparisonHit = comparisonTerms.contains { haystack.contains($0) }
            // Phase 61 — a background cluster is workspace memory: it cannot
            // make the CURRENT task a research session.
            let coherent = (cluster.comparable && cluster.authority.canDriveCurrentTask)
                || (cluster.coherence >= 0.5 && cluster.authority != .background)
            if cluster.comparable && cluster.authority == .background {
                print("[ResearchWorkflowRejected] reason=unrelated_tabs")
                print("[SemanticVsWorkflowResolution] semantic_domain=current_focus deterministic_workflow=browser_research winner=current_focus reason=cluster_background_only")
            }
            if coherent {
                let confidence = min(0.9, 0.4 + cluster.coherence * 0.3 + Double(min(s.tabTitles.count, 6)) * 0.03 + (comparisonHit ? 0.1 : 0))
                var signals = ["tabs:\(s.tabTitles.count)", "coherence:\(String(format: "%.2f", cluster.coherence))"]
                if comparisonHit { signals.append("comparison_terms") }
                if s.workflow == "researching" { signals.append("workflow:researching") }
                detected.append(DetectedWorkflow(kind: .browserResearch, confidence: confidence, signals: signals))
                print("[ResearchWorkflowDetected] confidence=\(String(format: "%.2f", confidence)) signals=\(signals.joined(separator: ","))")
            } else {
                print("[ResearchWorkflowRejected] reason=\(cluster.candidateTabs <= 1 ? "unrelated_tabs" : "low_topic_coherence")")
            }
        }

        // Writing (meaningful selection anywhere)
        if s.selectedTextLength >= 80 {
            detected.append(DetectedWorkflow(kind: .writing, confidence: 0.7, signals: ["selection:\(s.selectedTextLength)"]))
        }

        return detected.sorted { $0.confidence > $1.confidence }
    }
}

// MARK: - Router

struct LiquidRoutingInput: Sendable {
    let signals: WorkflowSignals
    /// Capability ids already proposed by other lanes (utilities, friction, music).
    let existingCandidateIds: Set<String>
    /// Capability ids the user recently dismissed/ignored (cooldown).
    let recentlyRejected: Set<String>
    /// Capability ids the user accepted before in similar contexts (boost).
    let recentlyAccepted: Set<String>
    /// Phase 59 — ids recently auto-dismissed/ignored as floating cards:
    /// score penalty + floating ban, but may still appear in the panel.
    let floatingPenalized: Set<String>

    init(
        signals: WorkflowSignals,
        existingCandidateIds: Set<String> = [],
        recentlyRejected: Set<String> = [],
        recentlyAccepted: Set<String> = [],
        floatingPenalized: Set<String> = []
    ) {
        self.signals = signals
        self.existingCandidateIds = existingCandidateIds
        self.recentlyRejected = recentlyRejected
        self.recentlyAccepted = recentlyAccepted
        self.floatingPenalized = floatingPenalized
    }
}

struct LiquidActionCandidate: Sendable {
    let action: WorkflowAction
    let score: Double
    let reason: String
    let tier: Int
}

struct LiquidActionSelection: Sendable {
    let detected: [DetectedWorkflow]
    /// Up to 3 ids for "Suggested now".
    let primary: [String]
    /// Panel ids in rank order (includes primary).
    let panel: [String]
    let suppressed: [(id: String, reason: String)]
    let specificCount: Int
    let genericCount: Int
    let setupCount: Int

    func candidate(_ id: String) -> WorkflowAction? { WorkflowActionOntology.byId[id] }
}

enum LiquidActionCompartmentGate {
    // Phase 59 — generic surface patterns only (search pages, calendars,
    // social feeds). Platform names must never appear here.
    static let unrelatedFocusTerms = [
        "google.com/search", "calendar.google", "google calendar",
        "google search", "search results", "/feed", "sign up", "log in"
    ]

    static func currentFocusText(_ s: WorkflowSignals) -> String {
        [s.windowTitle, s.urlHost, s.urlPath].joined(separator: " ").lowercased()
    }

    static func currentFocusTerms(_ s: WorkflowSignals) -> [String] {
        terms(in: currentFocusText(s))
    }

    static func backgroundTerms(_ s: WorkflowSignals) -> [String] {
        terms(in: s.tabTitles.joined(separator: " ").lowercased())
            .filter { !currentFocusTerms(s).contains($0) }
    }

    static func terms(in text: String) -> [String] {
        let normalized = text.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9']+"#, with: " ", options: .regularExpression)
        let ignored: Set<String> = ["the", "and", "for", "with", "from", "https", "www", "com", "private", "browsing"]
        var seen = Set<String>()
        return normalized.split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 && !ignored.contains($0) }
            .filter { seen.insert($0).inserted }
            .prefix(24)
            .map { $0 }
    }

    static func selectedTabWorkflow(_ s: WorkflowSignals) -> DetectedWorkflow? {
        let focus = currentFocusText(s)
        let rentalHits = WorkflowDetectors.rentalTerms.filter { focus.contains($0) }
        if WorkflowDetectors.rentalFocusSupported(focus) {
            // Phase 59 — broad rental terms classify the ACTIVITY, but only a
            // contract document makes this a lease workflow. A housing group,
            // listing feed, or search page is rental SEARCH.
            let content = ContentTypeClassifier.classify(s)
            let isLeaseDocument = content.type == .leaseOrContractDocument
            let kind: DetectedWorkflowKind = isLeaseDocument ? .actionPack : .rentalSearch
            if !isLeaseDocument {
                print("[ContentTypeCorrection] old=action_pack new=rental_search reason=content_type_\(content.type.rawValue)")
            }
            let conf = min(0.95, 0.55 + Double(rentalHits.count) * 0.08 + (isLeaseDocument ? 0.20 : 0))
            print("[SelectedTabWorkflow] workflow=\(kind.rawValue) confidence=\(String(format: "%.2f", conf)) signals=\((rentalHits.isEmpty ? [content.type.rawValue] : rentalHits).joined(separator: ","))")
            _ = ContentTypeClassifier.splitCheck(workflow: kind, content: content)
            return DetectedWorkflow(kind: kind, confidence: conf, signals: rentalHits.isEmpty ? [content.type.rawValue] : rentalHits)
        }
        let codeHits = WorkflowDetectors.codeTerms.filter { focus.contains($0) }
        if !codeHits.isEmpty {
            let conf = min(0.90, 0.55 + Double(codeHits.count) * 0.08)
            print("[SelectedTabWorkflow] workflow=code_logs confidence=\(String(format: "%.2f", conf)) signals=\(codeHits.joined(separator: ","))")
            return DetectedWorkflow(kind: .codeLogs, confidence: conf, signals: codeHits)
        }
        let formHits = WorkflowDetectors.formTerms.filter { focus.contains($0) }
        if !formHits.isEmpty {
            let conf = min(0.90, 0.55 + Double(formHits.count) * 0.08)
            print("[SelectedTabWorkflow] workflow=form_application confidence=\(String(format: "%.2f", conf)) signals=\(formHits.joined(separator: ","))")
            return DetectedWorkflow(kind: .formApplication, confidence: conf, signals: formHits)
        }
        print("[SelectedTabWorkflow] workflow=unknown confidence=0.20 signals=none")
        return nil
    }

    static func isCrossTabAction(_ action: WorkflowAction) -> Bool {
        ["compare_open_tabs", "collect_sources_from_tabs", "make_research_brief", "create_decision_table", "save_research_session", "identify_next_research_step"].contains(action.id)
    }

    static func scope(for action: WorkflowAction, signals: WorkflowSignals, detectedKinds: Set<DetectedWorkflowKind>, content: ClassifiedContent) -> (allowed: Bool, scope: String, reason: String) {
        let focus = currentFocusText(signals)
        let selected = selectedTabWorkflow(signals)
        let selectedKind = selected?.kind
        let unfocusedBlocked = unrelatedFocusTerms.contains { focus.contains($0) }
        let currentTerms = currentFocusTerms(signals)
        let bgTerms = backgroundTerms(signals)
        print("[CurrentFocusTerms] terms=\(currentTerms.joined(separator: ","))")
        print("[BackgroundTerms] terms=\(bgTerms.joined(separator: ","))")
        print("[RelatedFocusTerms] terms=none")
        print("[StaleTerms] terms=none")

        if isCrossTabAction(action) {
            print("[TemporalSourceUse] id=\(action.id) source=background allowed=yes")
            print("[TemporalContaminationCheck] passed=yes reason=cross_tab_explicit")
            return (true, "cross_tab", "cross_tab_allowed")
        }

        let requiredKind: DetectedWorkflowKind? = {
            switch action.category {
            case .documentsLeases: return .actionPack
            case .formsApplications: return .formApplication
            case .codeLogs: return .codeLogs
            case .browserResearch: return .browserResearch
            case .writingEditing, .communication: return .writing
            case .workspaceFriction, .mediaFocus, .memoryWorkflows, .setupAcquisition: return nil
            }
        }()
        guard let requiredKind else {
            return (true, "current_focus", "current_focus_match")
        }

        // Phase 59 — rental search counts as research activity, not lease work.
        let kindMatches = selectedKind == requiredKind
            || (requiredKind == .browserResearch && selectedKind == .rentalSearch)
        if kindMatches {
            print("[TemporalSourceUse] id=\(action.id) source=current_focus allowed=yes")
            print("[TemporalContaminationCheck] passed=yes reason=current_focus_match")
            return (true, "current_focus", "current_focus_match")
        }

        let focusHasWorkflowTerms: Bool = {
            switch requiredKind {
            case .actionPack:
                // Phase 59 — broad rental terms are NOT enough for lease work;
                // the focused thing must actually be a contract document.
                return content.type == .leaseOrContractDocument
            case .rentalSearch:
                return WorkflowDetectors.rentalFocusSupported(focus)
            case .formApplication:
                return WorkflowDetectors.formTerms.contains { focus.contains($0) }
            case .codeLogs:
                return WorkflowDetectors.codeTerms.contains { focus.contains($0) }
            case .browserResearch:
                return detectedKinds.contains(.browserResearch) && signals.tabTitles.count >= 2
            case .writing:
                return signals.selectedTextLength >= 80
            case .generic:
                return false
            }
        }()
        if focusHasWorkflowTerms && !unfocusedBlocked {
            print("[TemporalSourceUse] id=\(action.id) source=related allowed=yes")
            print("[TemporalContaminationCheck] passed=yes reason=related_focus_match")
            return (true, "related_focus", "related_focus_match")
        }

        let reason = unfocusedBlocked ? "focus_mismatch" : "background_only"
        print("[TemporalSourceUse] id=\(action.id) source=background allowed=no")
        print("[TemporalContaminationCheck] passed=no reason=\(reason)")
        return (false, "background_workspace", reason)
    }
}

enum LiquidActionRouter {

    static let maxPrimary = 3
    static let maxPanel = 6
    static let maxGenericInPanel = 1
    static let leaseDocumentPriority: [String] = [
        "flag_risky_clauses",
        "extract_obligations",
        "extract_dates_deadlines_payments",
        "detect_missing_terms",
        "generate_questions_for_landlord"
    ]

    static func isLeaseDocumentContext(_ s: WorkflowSignals, detectedKinds: Set<DetectedWorkflowKind>) -> Bool {
        isLeaseDocumentContext(s, detectedKinds: detectedKinds, content: ContentTypeClassifier.classify(s))
    }

    /// Phase 59 — a lease-document context requires the focused content to BE
    /// a contract document. Rental terms, listing pages, and housing groups
    /// never qualify on their own.
    static func isLeaseDocumentContext(_ s: WorkflowSignals, detectedKinds: Set<DetectedWorkflowKind>, content: ClassifiedContent) -> Bool {
        guard detectedKinds.contains(.actionPack) || detectedKinds.contains(.rentalSearch) else { return false }
        let isDocument = content.type == .leaseOrContractDocument
        if isDocument {
            print("[HardcodeAudit] system=LiquidActionRouter.documentsLeases hardcoded=no replacement=contract_review_action_pack")
            print("[ActionPackSelected] pack=contract_review evidence=content_type:\(content.type.rawValue),workflow_evidence:\(detectedKinds.map(\.rawValue).sorted().joined(separator: ","))")
        }
        return isDocument
    }

    static func isTrueMultiTabResearchContext(_ s: WorkflowSignals, detectedKinds: Set<DetectedWorkflowKind>) -> Bool {
        guard detectedKinds.contains(.browserResearch) else { return false }
        let haystack = ([s.windowTitle] + s.tabTitles).joined(separator: " | ").lowercased()
        let hasComparison = WorkflowDetectors.comparisonTerms.contains { haystack.contains($0) }
        return s.tabTitles.count >= 3 && hasComparison && !isLeaseDocumentContext(s, detectedKinds: detectedKinds)
    }

    static func specificCaptureTitle(for action: WorkflowAction, signals: WorkflowSignals) -> String {
        let lower = ([signals.windowTitle] + signals.tabTitles).joined(separator: " | ").lowercased()
        let subject: String
        if action.category == .documentsLeases || lower.contains("agreement") || lower.contains("lease") || lower.contains("occupancy") {
            subject = "agreement"
        } else if action.category == .browserResearch && (lower.contains("rent") || lower.contains("listing") || lower.contains("room")) {
            subject = "listing"
        } else if action.category == .formsApplications {
            subject = "page"
        } else if action.category == .codeLogs {
            subject = "logs"
        } else {
            subject = "page"
        }
        switch action.id {
        case "flag_risky_clauses": return "Capture \(subject) to review risky clauses"
        case "extract_obligations": return "Capture \(subject) to extract obligations"
        case "extract_dates_deadlines_payments": return "Capture \(subject) to extract dates and payments"
        case "detect_missing_terms": return "Capture \(subject) to detect missing terms"
        case "generate_questions_for_landlord": return "Capture \(subject) to generate landlord questions"
        case "compare_document_to_listing": return "Capture listing/agreement to compare"
        case "extract_key_claims": return "Capture listing to extract details"
        case "find_conflicting_info": return "Capture listing to compare rental options"
        case "explain_current_form_field": return "Capture page to explain this form"
        case "detect_required_fields": return "Capture page to detect required fields"
        case "diagnose_latest_error", "summarize_log_failure": return "Capture logs to diagnose error"
        case "generate_next_agent_prompt": return "Capture logs to generate the next agent prompt"
        default:
            return "Capture \(subject) to \(action.title.lowercased())"
        }
    }

    static func displayTitle(for action: WorkflowAction, signals: WorkflowSignals) -> String {
        let (tier, reason) = executionTier(for: action, signals: signals)
        let title = honestDisplayTitle(for: action, signals: signals, tier: tier, tierReason: reason)
        ActionLabelTruthCheck.audit(
            actionID: action.id,
            label: title,
            tier: tier,
            contentAvailable: signals.contentAvailable,
            selectionAvailable: signals.selectedTextLength > 0
        )
        return title
    }

    /// Phase 58.6 — titles promise only what the available scope can deliver.
    /// Metadata-only never reads as a full comparison/review; capture-needed
    /// actions say "Capture X to …" up front.
    private static func honestDisplayTitle(for action: WorkflowAction, signals: WorkflowSignals, tier: Int, tierReason: String) -> String {
        let rentalSearch = ([signals.windowTitle] + signals.tabTitles).joined(separator: " | ").lowercased().contains("rent")
            || ([signals.windowTitle] + signals.tabTitles).joined(separator: " | ").lowercased().contains("listing")
            || ([signals.windowTitle] + signals.tabTitles).joined(separator: " | ").lowercased().contains("room")
        if rentalSearch {
            switch action.id {
            case "compare_open_tabs":
                if signals.contentAvailable {
                    return "Compare captured rental listings"
                }
                print("[FloatingDowngrade] id=\(action.id) from=\"Compare rental options\" to=\"Capture rental listings to compare them\" reason=metadata_only")
                return "Capture rental listings to compare them"
            case "extract_key_claims": return signals.contentAvailable ? "Extract listing details from visible page" : "Capture listing to extract details"
            case "save_research_session": return "Save rental research session"
            case "create_decision_table":
                if signals.contentAvailable {
                    return "Make rental decision table"
                }
                print("[FloatingDowngrade] id=\(action.id) from=\"Make rental decision table\" to=\"Capture rental listings to build the table\" reason=metadata_only")
                return "Capture rental listings to build the table"
            case "compare_document_to_listing": return signals.contentAvailable ? "Compare listing with agreement" : "Capture listing/agreement to compare"
            default: break
            }
        }
        if action.id == "flag_risky_clauses" && tier == 1 {
            // Visible text only — say so; "review full agreement" would overpromise.
            return "Check visible agreement text for risky clauses"
        }
        // Phase 60 — metadata-only compare never promises a comparison,
        // whatever the context: the honest step is a capture.
        if (action.id == "compare_open_tabs" || action.id == "create_decision_table") && !signals.contentAvailable {
            print("[FloatingDowngrade] id=\(action.id) from=\"\(action.title)\" to=\"Capture pages to compare them\" reason=metadata_only")
            return "Capture pages to compare them"
        }
        if tier == 2 && action.isSpecificAction && action.executionKind == .contentInsight {
            let title = specificCaptureTitle(for: action, signals: signals)
            print("[SpecificCaptureNeeded] original_id=\(action.id) title=\"\(title)\" reason=\(tierReason == "needs_visible_capture" ? "missing_visible_content" : tierReason)")
            print("[SpecificCaptureAction] original_id=\(action.id) capture_id=\(action.fallbackAction ?? "capture_visible_page") followup=\(action.id)")
            print("[FloatingDowngrade] id=\(action.id) from=\"\(action.title)\" to=\"\(title)\" reason=\(signals.contentAvailable ? "partial_content" : "scope_limited")")
            return title
        }
        return action.title
    }

    static func floatingCandidate(from selection: LiquidActionSelection, signals: WorkflowSignals, floatingPenalized: Set<String> = []) -> (id: String?, reason: String) {
        // Phase 59 — floating is rare and high quality. "Safe and read-only"
        // is not enough: the action must satisfy its contract at floating
        // level, clear the usefulness threshold, and not be on feedback cooldown.
        // Phase 60 — silence-first: sensitive/normal-browsing activities float
        // nothing; everything else must clear the proposal-worthiness gate.
        let content = ContentTypeClassifier.classify(signals)
        let cluster = ComparableCandidateDetector.detect(signals: signals, content: content)
        let evidence = EvidenceSnapshot.evaluate(signals: signals, content: content, cluster: cluster)
        let activity = BrowserActivityClassifier.classify(signals: signals, content: content, cluster: cluster)

        // Selected message/page text is the one user-intent signal strong
        // enough to overrule activity-level silence.
        let selectionIntent = signals.selectedTextLength >= 40
        if activity.forcesFloatingSilence && !selectionIntent {
            let reason: String
            switch activity.activity {
            case .communication: reason = "communication_context"
            case .financeSensitive: reason = "finance_sensitive"
            case .socialMedia: reason = "all_generic"
            case .unknown: reason = "low_evidence"
            default: reason = "normal_browsing"
            }
            print("[SilenceDecision] allowed=yes reason=\(reason)")
            if let previous = selection.primary.first {
                print("[FloatingSilence] previous_candidate=\(previous) reason=\(reason)")
            }
            if !selection.panel.isEmpty {
                print("[PanelOnlySuggestionSet] actions=\(selection.panel.joined(separator: ",")) reason=floating_not_worthy")
            }
            return (nil, reason)
        }

        // Part 1 — lease-pack novelty/fatigue: on a lease/contract document, do
        // not float the same pack action every tick. Rotate to a novel action and
        // demote already-shown ones to panel; go silent when the pack is spent.
        let isLeaseContent = content.type == .leaseOrContractDocument
        let leaseMemory = LeaseActionFatigueMemory.shared
        let leaseDocSig = leaseMemory.docSignature(signals: signals)
        let leaseContentHash = leaseMemory.contentHash(signals: signals)
        let orderedPrimary = isLeaseContent
            ? leaseMemory.rotatedLeasePrimary(selection.primary, docSig: leaseDocSig, contentHash: leaseContentHash)
            : selection.primary
        if isLeaseContent && !orderedPrimary.contains(where: { WorkflowActionOntology.byId[$0]?.category == .documentsLeases }) {
            print("[NoRepeatedFloatingLeaseAction] status=pass count=0")
        }

        for id in orderedPrimary {
            guard let action = WorkflowActionOntology.byId[id] else { continue }
            let (tier, tierReason) = executionTier(for: action, signals: signals)
            let verdict = ActionContracts.check(action: action, content: content, evidence: evidence, selectedTextLength: signals.selectedTextLength)
            let useful = UsefulActionScorer.score(
                action: action,
                content: content,
                evidence: evidence,
                workflowConfidence: selection.detected.first?.confidence ?? 0.3,
                tier: tier,
                contractCeiling: verdict.surfaceCeiling,
                recentlyPenalized: floatingPenalized.contains(action.id),
                recentlyAcceptedSimilar: false
            )
            let preflight = computePreflight(action: action, signals: signals, tier: tier, tierReason: tierReason, relevance: useful.final, surfaceCeiling: verdict.surfaceCeiling)

            var suppressReason: String? = nil
            if !verdict.passed {
                suppressReason = "missing_evidence"
            } else if verdict.surfaceCeiling == .panel {
                suppressReason = "generic_low_value"
                print("[PanelOnlyDowngrade] id=\(id) reason=panel_only_contract")
            } else if floatingPenalized.contains(action.id) {
                suppressReason = "recently_ignored"
                print("[RepetitionPenalty] id=\(id) penalty=float_ban reason=auto_dismissed")
            } else if !UsefulActionScorer.passesThreshold(id: id, surface: .floating, final: useful.final) {
                suppressReason = "low_relevance"
            } else if preflight.expectedValue == "none" && preflight.decision != .showCaptureNeeded {
                suppressReason = "overpromises"
            } else if preflight.expectedValue == "template_only" {
                suppressReason = "generic_low_value"
            } else if content.type == .unknownPage || (content.type == .genericWebpage && verdict.surfaceCeiling != .captureNeeded && tier != 1) {
                suppressReason = "uncertain_context"
            }

            // Phase 60 — eligibility is not worthiness: hard floors on value,
            // result quality, focus fit, evidence, and overpromise risk.
            if suppressReason == nil {
                let worthiness = ProposalWorthinessGate.evaluate(
                    action: action,
                    content: content,
                    activity: activity,
                    cluster: cluster,
                    evidence: evidence,
                    useful: useful,
                    tier: tier,
                    decision: preflight.decision,
                    recentlyPenalized: floatingPenalized.contains(action.id)
                )
                if !worthiness.allowed {
                    suppressReason = worthiness.reason
                } else {
                    print("[HighQualityOpportunity] id=\(id) reason=\(worthiness.reason)_\(activity.activity.rawValue) evidence=\(evidence.available.map(\.rawValue).sorted().joined(separator: ","))")
                }
            }

            let structurallyAllowed = action.isSpecificAction
                && action.riskLevel == "read_only"
                && action.surfacePolicy == .panelPrimary
                && preflight.decision != .suppress
                && (tier == 1 || (tier == 2 && action.executionKind == .contentInsight))

            let allowed = structurallyAllowed && suppressReason == nil
            let reason = allowed
                ? (tier == 2 || preflight.decision == .showCaptureNeeded ? "specific_capture_needed" : "high_usefulness_read_only")
                : (suppressReason ?? (preflight.decision != .show ? preflight.blockReason ?? "preflight_suppressed" : "low_expected_value"))

            print("[FloatingQualityGate] id=\(id) allowed=\(allowed ? "yes" : "no") reason=\(reason)")
            print("[LiquidFloatingEligibility] id=\(id) allowed=\(allowed ? "yes" : "no") reason=\(reason)")
            if !allowed, let suppressReason {
                print("[FloatingSuppression] id=\(id) reason=\(suppressReason)")
            }
            if allowed {
                if isLeaseContent, WorkflowActionOntology.byId[id]?.category == .documentsLeases {
                    leaseMemory.recordShown(actionId: id, docSig: leaseDocSig, contentHash: leaseContentHash)
                }
                return (id, reason)
            }
        }
        return (nil, selection.primary.isEmpty ? "no_primary_actions" : "no_primary_action_eligible")
    }

    /// Compute the execution tier for an action given current signals (Part H).
    static func executionTier(for action: WorkflowAction, signals: WorkflowSignals) -> (tier: Int, reason: String) {
        switch action.executionKind {
        case .setupCard:
            return (3, "needs_source_native_bridge")
        case .metadataNote, .memoryNote, .workspaceAlias:
            return (1, "executes_from_available_context")
        case .selectionTransform:
            return signals.selectedTextLength >= max(action.minChars, 1)
                ? (1, "selection_available")
                : (2, "needs_selection")
        case .contentInsight:
            if let minScope = action.minScope, minScope.satisfiesFullScope {
                if signals.enrichedContext?.evidenceLevel == "full_document" {
                    return (1, "enriched_full_document_available")
                }
                return (3, "needs_full_scope_bridge")
            }
            if signals.enrichedContext != nil {
                return (1, "enriched_context_available")
            }
            return signals.contentAvailable
                ? (1, "visible_content_available")
                : (2, "needs_visible_capture")
        }
    }

    static func route(_ input: LiquidRoutingInput) -> LiquidActionSelection {
        let s = input.signals
        let detected = WorkflowDetectors.detect(s)
        let detectedKinds = Set(detected.map(\.kind))
        let topKind = detected.first?.kind ?? .generic

        // Phase 59 — classify what is focused once, evaluate evidence once.
        // Phase 60 — plus what the user is DOING and whether real comparison
        // candidates exist.
        let content = ContentTypeClassifier.classify(s)
        let cluster = ComparableCandidateDetector.detect(signals: s, content: content)
        let evidence = EvidenceSnapshot.evaluate(signals: s, content: content, cluster: cluster)
        let activity = BrowserActivityClassifier.classify(signals: s, content: content, cluster: cluster)
        ProposalEvidenceContracts.logDomainSignal(s)
        _ = ContentTypeClassifier.splitCheck(workflow: detected.first?.kind, content: content)
        if content.type == .forumOrSocialGroup || content.type == .marketplaceOrListingFeed {
            print("[FacebookGroupGeneralization] platform=social_group content_type=\(content.type.rawValue) hardcoded=no")
        }

        let leaseDocumentContext = isLeaseDocumentContext(s, detectedKinds: detectedKinds, content: content)
        let trueMultiTabResearch = isTrueMultiTabResearchContext(s, detectedKinds: detectedKinds)
        let rentalSearchContext = (detectedKinds.contains(.rentalSearch) || detectedKinds.contains(.actionPack))
            && !leaseDocumentContext
            && (ActionContracts.listingContexts.contains(content.type) || evidence.listingCandidateCount >= 1)

        var candidates: [LiquidActionCandidate] = []
        var suppressed: [(String, String)] = []
        var usefulnessById: [String: Double] = [:]
        var ceilingById: [String: ContractSurface] = [:]

        func workflowMatch(_ category: WorkflowActionCategory) -> DetectedWorkflowKind? {
            switch category {
            case .formsApplications: return detectedKinds.contains(.formApplication) ? .formApplication : nil
            case .documentsLeases:   return detectedKinds.contains(.actionPack) ? .actionPack : nil
            case .codeLogs:          return detectedKinds.contains(.codeLogs) ? .codeLogs : nil
            case .browserResearch:
                if detectedKinds.contains(.browserResearch) { return .browserResearch }
                // Rental search is research-shaped activity over listings.
                if detectedKinds.contains(.rentalSearch) { return .rentalSearch }
                return nil
            case .writingEditing, .communication: return detectedKinds.contains(.writing) ? .writing : nil
            case .workspaceFriction, .mediaFocus, .memoryWorkflows, .setupAcquisition: return nil
            }
        }

        for action in WorkflowActionOntology.all {
            // Suppression: duplicates of actions other lanes already proposed.
            if let dupRule = action.suppressionRules.first(where: { $0.hasPrefix("duplicate_of:") }) {
                let target = String(dupRule.dropFirst("duplicate_of:".count))
                if input.existingCandidateIds.contains(target) {
                    suppressed.append((action.id, "duplicate_of_\(target)"))
                    continue
                }
            }
            if input.existingCandidateIds.contains(action.id) {
                suppressed.append((action.id, "already_proposed"))
                continue
            }
            // Suppression: user recently rejected/ignored.
            if input.recentlyRejected.contains(action.id) {
                suppressed.append((action.id, "recent_feedback_cooldown"))
                continue
            }
            // Structural requirements.
            if action.suppressionRules.contains("needs_tabs:2") && s.tabTitles.count < 2 {
                suppressed.append((action.id, "needs_more_tabs"))
                continue
            }
            if action.suppressionRules.contains("needs_notes") && WorkflowNotesStore.shared.count() == 0 {
                suppressed.append((action.id, "no_saved_notes"))
                continue
            }
            if action.requiredContext.contains("selected_text") && s.selectedTextLength < max(action.minChars, 1) {
                suppressed.append((action.id, "no_selection"))
                continue
            }
            if action.requiredContext.contains("tabs") && s.tabTitles.isEmpty {
                suppressed.append((action.id, "no_tabs"))
                continue
            }
            if action.requiredContext.contains("focused_field") && !s.contentAvailable {
                // Without AX content there is no focused-field label to explain.
                suppressed.append((action.id, "no_focused_field_context"))
                continue
            }
            // Workspace aliases need two windows.
            if action.requiredContext.contains("windows") && s.visibleAppNames.count < 2 {
                suppressed.append((action.id, "not_enough_windows"))
                continue
            }
            if action.id == "put_browser_beside_pdf" && !s.visibleAppNames.contains(where: { $0.lowercased().contains("preview") }) {
                suppressed.append((action.id, "no_pdf_window"))
                continue
            }
            if action.id == "put_xcode_beside_logs" && !s.visibleAppNames.contains(where: { $0.lowercased().contains("xcode") }) {
                suppressed.append((action.id, "no_xcode_window"))
                continue
            }
            if action.id == "connect_google_docs" && !(s.urlHost.contains("docs.google.com") || s.windowTitle.lowercased().contains("google docs")) {
                suppressed.append((action.id, "not_google_docs"))
                continue
            }

            // Workflow relevance: specific workflow actions only surface when
            // their workflow is detected.
            let match = workflowMatch(action.category)
            let workflowCategories: Set<WorkflowActionCategory> = [
                .formsApplications, .documentsLeases, .codeLogs, .browserResearch,
                .writingEditing, .communication
            ]
            if workflowCategories.contains(action.category), action.isSpecificAction, match == nil {
                suppressed.append((action.id, "workflow_not_detected"))
                continue
            }

            if action.category == .codeLogs {
                let diagnose = ProposalEvidenceContracts.diagnoseEvidence(s)
                diagnose.log(app: s.activeApp, title: s.windowTitle)
                if !diagnose.allowed {
                    if s.activeApp.lowercased().contains("xcode") {
                        print("[NoXcodeMetadataOnlyDiagnose] status=pass count=0")
                    }
                    // Live-path proof: metadata-only code/log actions never reach
                    // any user-visible surface (panel/current-task/floating).
                    let gateReason = s.activeApp.lowercased().contains("xcode")
                        ? "xcode_metadata_only_missing_error_evidence"
                        : "code_metadata_only_missing_error_evidence"
                    UserVisibleHardcodeGate.log(
                        surface: "panel",
                        id: action.id,
                        decision: .init(allowed: false, reason: gateReason)
                    )
                    if UserVisibleHardcodeGate.xcodeCodeLogActionIDs.contains(ActionAliasResolver.canonicalID(for: action.id)) {
                        print("[CaptureNeededNotSurfaced] original_id=\(action.id) reason=no_user_intent_metadata_only")
                        print("[NoSpecificCaptureNeededPanelActions] status=pass count=0")
                        print("[NoCaptureNeededRelabeledProposal] status=pass count=0")
                    }
                    suppressed.append((action.id, "diagnose_evidence_missing"))
                    continue
                }
            }

            if action.category == .documentsLeases {
                let lease = ProposalEvidenceContracts.leaseEvidence(s)
                lease.log(actionID: action.id)
                if content.type == .leaseOrContractDocument && !lease.allowed {
                    if lease.titleOrKeywordOnly {
                        print("[NoLeaseTitleOnlyAction] status=pass count=0")
                    }
                    // Live-path proof: lease title/url-only metadata never produces
                    // user-visible lease actions without real document body text.
                    UserVisibleHardcodeGate.log(
                        surface: "panel",
                        id: action.id,
                        decision: .init(allowed: false, reason: "lease_title_only_missing_document_body")
                    )
                    if UserVisibleHardcodeGate.leaseDocumentActionIDs.contains(ActionAliasResolver.canonicalID(for: action.id)) {
                        print("[CaptureNeededNotSurfaced] original_id=\(action.id) reason=no_user_intent_metadata_only")
                        print("[NoSpecificCaptureNeededPanelActions] status=pass count=0")
                        print("[NoCaptureNeededRelabeledProposal] status=pass count=0")
                    }
                    suppressed.append((action.id, "lease_body_missing"))
                    continue
                }
            }

            if ProposalEvidenceContracts.shouldBlockDomainOnlyContentAction(action: action, signals: s, content: content) {
                ProposalEvidenceContracts.logDomainOnlyBlock(actionID: action.id, signals: s)
                switch ProposalEvidenceContracts.domainFamily(s) {
                case "gmail":
                    print("[NoGmailUrlOnlyCaptureProposal] status=pass count=0")
                case "facebook":
                    print("[NoFacebookTitleOnlyThreadAction] status=pass count=0")
                case "kijiji":
                    print("[NoKijijiDomainOnlyRentalAction] status=pass count=0")
                default:
                    break
                }
                suppressed.append((action.id, "domain_only"))
                continue
            }

            // Phase 59 — action contract: the right kind of content with the
            // right evidence, or no action. Term buckets no longer decide.
            let verdict = ActionContracts.check(action: action, content: content, evidence: evidence, selectedTextLength: s.selectedTextLength)
            if !verdict.passed {
                let reason = verdict.forbidden || verdict.reason == "wrong_content_type" ? "wrong_content_type" : "missing_evidence"
                print("[BadActionSuppression] id=\(action.id) content_type=\(content.type.rawValue) reason=\(reason)")
                suppressed.append((action.id, reason))
                continue
            }
            if verdict.surfaceCeiling == .captureNeeded,
               action.id == "compare_open_tabs" || action.id == "create_decision_table" {
                print("[CaptureNeededForListingCompare] reason=no_listing_details_yet")
            }
            if (content.type == .forumOrSocialGroup || content.type == .marketplaceOrListingFeed),
               rentalSearchContext, action.category == .browserResearch {
                print("[ListingFeedAction] id=\(action.id) reason=feed_or_marketplace_context")
            }

            let compartment = LiquidActionCompartmentGate.scope(for: action, signals: s, detectedKinds: detectedKinds, content: content)
            print("[ActionCompartmentScope] id=\(action.id) scope=\(compartment.scope)")
            print("[CompartmentActionGate] id=\(action.id) allowed=\(compartment.allowed ? "yes" : "no") reason=\(compartment.reason)")
            if !compartment.allowed {
                suppressed.append((action.id, compartment.reason))
                if compartment.reason == "focus_mismatch" {
                    print("[FocusMismatchSuppression] id=\(action.id) current_title=\"\(s.windowTitle.prefix(80))\" action_workflow=\(action.category.rawValue) reason=selected_tab_mismatch")
                } else {
                    print("[BackgroundContextDemotion] id=\(action.id) reason=not_current_focus")
                    print("[TabClusterDemotion] id=\(action.id) reason=selected_tab_mismatch")
                }
                print("[StaleWorkflowSuppression] id=\(action.id) reason=\(compartment.reason)")
                continue
            }

            let (tier, tierReason) = executionTier(for: action, signals: s)

            // Phase 59 — real usefulness score replaces the flat constant.
            let workflowConfidence = match.flatMap { m in detected.first(where: { $0.kind == m })?.confidence } ?? 0.3
            let useful = UsefulActionScorer.score(
                action: action,
                content: content,
                evidence: evidence,
                workflowConfidence: workflowConfidence,
                tier: tier,
                contractCeiling: verdict.surfaceCeiling,
                recentlyPenalized: input.floatingPenalized.contains(action.id),
                recentlyAcceptedSimilar: input.recentlyAccepted.contains(action.id)
            )
            usefulnessById[action.id] = useful.final
            ceilingById[action.id] = verdict.surfaceCeiling
            guard UsefulActionScorer.passesThreshold(id: action.id, surface: .panel, final: useful.final) else {
                print("[BadActionSuppression] id=\(action.id) content_type=\(content.type.rawValue) reason=low_value")
                suppressed.append((action.id, "low_usefulness"))
                continue
            }

            let preflight = computePreflight(action: action, signals: s, tier: tier, tierReason: tierReason, relevance: useful.final, surfaceCeiling: verdict.surfaceCeiling)
            print("[ActionPreflight] id=\(preflight.id) relevance=\(String(format: "%.2f", preflight.relevance)) scope=\(preflight.scope) can_execute_now=\(preflight.canExecuteNow ? "yes" : "no") expected_value=\(preflight.expectedValue) followup_available=\(preflight.followupAvailable ? "yes" : "no") decision=\(preflight.decision.rawValue)")
            if let enriched = s.enrichedContext {
                let terms = EnrichedContextCache.contentTerms(from: enriched.text, limit: 5).joined(separator: ",")
                print("[ProposalEvidenceInput] id=\(action.id) evidence_level=\(enriched.evidenceLevel) chars=\(enriched.chars) source=\(enriched.source)")
                print("[ContentAwareProposal] id=\(action.id) title=\"\(displayTitle(for: action, signals: s))\" evidence_source=\(enriched.source) content_terms=\(terms.isEmpty ? "none" : terms)")
                if preflight.canExecuteNow && tierReason == "enriched_context_available" {
                    print("[ActionPreflight] id=\(preflight.id) scope=\(preflight.scope) can_execute_now=yes reason=enriched_context_available")
                }
            }

            if preflight.decision == .suppress {
                let reason = preflight.blockReason ?? "preflight_suppressed"
                print("[ActionPreflightBlock] id=\(preflight.id) reason=\(reason)")
                suppressed.append((action.id, reason))
                continue
            }

            let hardcodeGate = UserVisibleHardcodeGate.evaluate(
                actionID: action.id,
                signals: s,
                content: content,
                tier: tier,
                captureNeeded: preflight.decision == .showCaptureNeeded
            )
            if !hardcodeGate.allowed {
                UserVisibleHardcodeGate.log(surface: "panel", id: action.id, decision: hardcodeGate)
                suppressed.append((action.id, hardcodeGate.reason))
                continue
            }
            if preflight.decision == .showCaptureNeeded {
                print("[ActionPreflightBlock] id=\(preflight.id) reason=\(preflight.blockReason ?? "capture_needed")")
                if !preflight.expectedFollowups.isEmpty {
                    print("[ActionPreflightFollowup] id=\(preflight.id) followups=\(preflight.expectedFollowups.joined(separator: ","))")
                }
            }

            // Scoring.
            var score = preflight.relevance
            var reasons: [String] = []
            if let match {
                let conf = detected.first(where: { $0.kind == match })?.confidence ?? 0.5
                score += 0.4 * conf
                reasons.append("workflow_\(match.rawValue)")
                if match == topKind { score += 0.1; reasons.append("top_workflow") }
            }
            switch tier {
            case 1: score += 0.2
            case 2: score -= 0.15
            default: score -= 0.3
            }
            reasons.append("tier\(tier)_\(tierReason)")
            if action.isSpecificAction { score += 0.15; reasons.append("specific") }
            else { score -= 0.25; reasons.append("generic") }
            if input.recentlyAccepted.contains(action.id) { score += 0.1; reasons.append("accepted_before") }
            if action.surfacePolicy == .panelLow { score -= 0.1 }

            if leaseDocumentContext {
                if action.category == .documentsLeases {
                    if let leaseRank = leaseDocumentPriority.firstIndex(of: action.id) {
                        score += 0.95 - (Double(leaseRank) * 0.02)
                        reasons.append("google_docs_lease")
                        reasons.append("document_context")
                    } else if action.executionKind == .metadataNote {
                        score -= 0.45
                        reasons.append("metadata_lease_secondary")
                    }
                }
                if action.category == .browserResearch && !trueMultiTabResearch {
                    score -= 0.75
                    reasons.append("not_multi_tab_research")
                    if ["compare_open_tabs", "make_research_brief", "create_decision_table"].contains(action.id) {
                        print("[GenericResearchDemotion] id=\(action.id) reason=lease_document_context")
                    }
                }
            }
            if rentalSearchContext {
                if action.category == .browserResearch {
                    if action.id == "compare_open_tabs" || action.id == "create_decision_table" || action.id == "save_research_session" || action.id == "make_research_brief" {
                        score += 0.45
                        reasons.append("rental_search_tabs")
                    }
                }
                if action.category == .documentsLeases && leaseDocumentPriority.contains(action.id) {
                    score += 0.25
                    reasons.append("related_agreement_tab")
                }
            }
            if trueMultiTabResearch {
                if action.category == .browserResearch {
                    score += 0.35
                    reasons.append("true_multi_tab_research")
                } else if action.category == .documentsLeases && action.executionKind == .contentInsight {
                    score -= 0.20
                    reasons.append("research_mode_lease_secondary")
                }
            }

            candidates.append(LiquidActionCandidate(action: action, score: score, reason: reasons.joined(separator: "+"), tier: tier))
            if action.category == .documentsLeases && leaseDocumentContext {
                print("[TemplateActionGenerated] pack=contract_review id=\(action.id) source=declarative_template")
            }
            print("[SpecificActionCandidate] id=\(action.id) evidence=\(action.evidenceSignals.joined(separator: ",")) score=\(String(format: "%.2f", score)) reason=\(reasons.joined(separator: "+"))")
        }

        let specificCandidates = candidates.filter { $0.action.isSpecificAction }
        let genericCandidates = candidates.filter { !$0.action.isSpecificAction }
        let setupCandidates = candidates.filter { $0.tier == 3 }
        print("[LiquidActionRouter] context=\(topKind.rawValue)/\(s.workflow) specific_candidates=\(specificCandidates.count) generic_candidates=\(genericCandidates.count) setup_candidates=\(setupCandidates.count)")

        // Selection: rank, cap generics, cap per-category, cap panel size.
        let ranked = candidates.sorted {
            if $0.score == $1.score { return $0.action.id < $1.action.id }
            return $0.score > $1.score
        }
        var panel: [String] = []
        var genericCount = 0
        var perCategory: [WorkflowActionCategory: Int] = [:]
        var reservedLeaseSlots = 0
        if leaseDocumentContext {
            let reserved = ranked.filter { $0.action.category == .documentsLeases && leaseDocumentPriority.contains($0.action.id) }.count
            reservedLeaseSlots = min(leaseDocumentPriority.count, reserved)
            print("[PanelSlotReservation] workflow=action_pack reserved=documents_leases count=\(reservedLeaseSlots)")
        }

        let frictionCandidates = ranked.filter { $0.action.category == .workspaceFriction }
        let mediaCandidates = ranked.filter { $0.action.category == .mediaFocus }
        let reserveFriction = frictionCandidates.isEmpty ? 0 : 1
        let reserveMedia = mediaCandidates.isEmpty ? 0 : 1
        print("[FamilySlotReservation] family=friction reserved=\(reserveFriction) used=0")
        print("[FamilySlotReservation] family=media reserved=\(reserveMedia) used=0")

        let liquidCategories: Set<WorkflowActionCategory> = [.formsApplications, .documentsLeases, .codeLogs, .browserResearch, .writingEditing, .communication]
        var usedFriction = 0
        var usedMedia = 0
        var usedLiquid = 0
        var usedMemory = 0
        var usedUtility = 0
        var suppressedFamilies = Set<String>()
        for (index, candidate) in ranked.enumerated() {
            print("[LiquidActionRanking] id=\(candidate.action.id) rank=\(index) score=\(String(format: "%.2f", candidate.score)) reason=\(candidate.reason)")
            if candidate.action.id == "flag_risky_clauses" && index <= 1 {
                print("[LiquidActionRanking] id=flag_risky_clauses rank<=2 actual_rank=\(index) score=\(String(format: "%.2f", candidate.score)) reason=\(candidate.reason)")
            }
            if candidate.action.id == "extract_obligations" && index <= 2 {
                print("[LiquidActionRanking] id=extract_obligations rank<=3 actual_rank=\(index) score=\(String(format: "%.2f", candidate.score)) reason=\(candidate.reason)")
            }
            guard panel.count < maxPanel else {
                suppressed.append((candidate.action.id, "panel_full"))
                continue
            }
            if leaseDocumentContext && candidate.action.category != .documentsLeases && reservedLeaseSlots > 0 {
                let leaseSelected = panel.filter { leaseDocumentPriority.contains($0) }.count
                let remainingSlots = maxPanel - panel.count
                let remainingLeaseNeeded = max(0, reservedLeaseSlots - leaseSelected)
                if remainingLeaseNeeded >= remainingSlots {
                    suppressed.append((candidate.action.id, "lower_priority_category"))
                    print("[PanelOverflowDemotion] id=\(candidate.action.id) reason=lower_priority_category")
                    continue
                }
            }
            if !candidate.action.isSpecificAction {
                guard genericCount < maxGenericInPanel else {
                    suppressed.append((candidate.action.id, "generic_cap_reached"))
                    print("[GenericCaptureDemotion] reason=specific_capture_available")
                    print("[GenericActionDemotion] id=\(candidate.action.id) reason=specific_action_available")
                    continue
                }
                // Generic actions never beat available specific actions for slots.
                if !specificCandidates.isEmpty && panel.count >= maxPanel - 1 {
                    suppressed.append((candidate.action.id, "generic_yields_to_specific"))
                    print("[GenericCaptureDemotion] reason=specific_capture_available")
                    print("[GenericActionDemotion] id=\(candidate.action.id) reason=specific_action_available")
                    continue
                }
                genericCount += 1
            }
            let categoryCount = perCategory[candidate.action.category, default: 0]
            let categoryCap = leaseDocumentContext && candidate.action.category == .documentsLeases ? 6 : 4
            guard categoryCount < categoryCap else {
                suppressed.append((candidate.action.id, "category_cap"))
                continue
            }
            let isFriction = candidate.action.category == .workspaceFriction
            let isMedia = candidate.action.category == .mediaFocus
            let isMemory = candidate.action.category == .memoryWorkflows
            let isUtility = candidate.action.category == .setupAcquisition
            let isLiquid = liquidCategories.contains(candidate.action.category)

            let remainingSlots = maxPanel - panel.count
            let neededReserves = max(0, reserveFriction - usedFriction) + max(0, reserveMedia - usedMedia)

            if isLiquid && remainingSlots <= neededReserves {
                suppressed.append((candidate.action.id, "family_balance"))
                suppressedFamilies.insert("liquid")
                print("[FamilyCrowdingSuppression] suppressed_family=liquid cause=family_balance")
                continue
            }

            perCategory[candidate.action.category] = categoryCount + 1
            let panelGate = UserVisibleHardcodeGate.evaluate(
                actionID: candidate.action.id,
                signals: s,
                content: content,
                tier: candidate.tier,
                captureNeeded: computePreflight(
                    action: candidate.action,
                    signals: s,
                    tier: candidate.tier,
                    tierReason: executionTier(for: candidate.action, signals: s).1,
                    relevance: usefulnessById[candidate.action.id] ?? 0,
                    surfaceCeiling: ceilingById[candidate.action.id] ?? .panel
                ).decision == .showCaptureNeeded
            )
            if !panelGate.allowed {
                UserVisibleHardcodeGate.log(surface: "panel", id: candidate.action.id, decision: panelGate)
                suppressed.append((candidate.action.id, panelGate.reason))
                continue
            }
            panel.append(candidate.action.id)

            if isFriction { usedFriction += 1 }
            else if isMedia { usedMedia += 1 }
            else if isMemory { usedMemory += 1 }
            else if isUtility { usedUtility += 1 }
            else if isLiquid { usedLiquid += 1 }
        }

        print("[ActionFamilyBalance] liquid=\(usedLiquid) friction=\(usedFriction) media=\(usedMedia) utility=\(usedUtility) memory=\(usedMemory) suppressed_families=\(suppressedFamilies.isEmpty ? "none" : suppressedFamilies.sorted().joined(separator: ","))")

        if leaseDocumentContext {
            let boosted = ranked.filter { $0.action.category == .documentsLeases && leaseDocumentPriority.contains($0.action.id) }.map(\.action.id)
            let demoted = ranked.filter {
                $0.action.category == .browserResearch && ["compare_open_tabs", "make_research_brief", "create_decision_table"].contains($0.action.id)
            }.map(\.action.id)
            print("[WorkflowRankingBoost] workflow=action_pack boosted=\(boosted.joined(separator: ",")) demoted=\(demoted.joined(separator: ",")) reason=\(s.urlHost.contains("docs.google.com") ? "action_pack_evidence" : "document_context")")
        }

        for (id, reason) in suppressed {
            print("[LiquidActionSuppression] id=\(id) reason=\(reason)")
        }

        // Primary = top 3 panel actions eligible for the suggested-now slot.
        let primary = panel.prefix(while: { _ in true }).filter { id in
            guard let action = WorkflowActionOntology.byId[id] else { return false }
            let tierInfo = executionTier(for: action, signals: s)
            let preflight = computePreflight(
                action: action,
                signals: s,
                tier: tierInfo.0,
                tierReason: tierInfo.1,
                relevance: usefulnessById[id] ?? 0.0,
                surfaceCeiling: ceilingById[id] ?? .panel
            )

            // Rules: An action with expected output template_only must not appear as a primary action.
            // Phase 60 exception — an honest capture-to-compare with PROVEN
            // comparable candidates is a real next step and may go primary.
            let honestCaptureCompare = (id == "compare_open_tabs" || id == "create_decision_table")
                && preflight.decision == .showCaptureNeeded
                && (ceilingById[id] ?? .panel) == .floating
                && evidence.available.contains(.comparableCandidates)
            if honestCaptureCompare {
                return action.surfacePolicy == .panelPrimary
            }
            if preflight.expectedValue == "none" || preflight.expectedValue == "template_only" || preflight.decision == .showCaptureNeeded {
                return false
            }
            // Phase 59 — low usefulness or panel-only contracts never go primary.
            if (usefulnessById[id] ?? 0) < UsefulActionScorer.floatingThreshold && (ceilingById[id] ?? .panel) != .floating {
                return false
            }
            return action.surfacePolicy == .panelPrimary
        }.prefix(maxPrimary).map { $0 }

        let specificSelected = panel.filter { WorkflowActionOntology.byId[$0]?.isSpecificAction == true }.count
        let genericSelected = panel.count - specificSelected
        for id in panel {
            if let action = WorkflowActionOntology.byId[id] {
                let target = LiquidActionCompartmentGate.isCrossTabAction(action) ? "cross_tab" : "current_focus"
                print("[PanelSectionTarget] id=\(id) section=\(action.category.rawValue) target=\(target)")
                print("[PanelMisfileCheck] id=\(id) pass=yes reason=category_scope_aligned")
            }
        }
        print("[LiquidActionSelection] primary=\(primary.joined(separator: ",")) panel=\(panel.joined(separator: ",")) generic_count=\(genericSelected) specific_count=\(specificSelected)")
        print("[ActionDiversity] total=\(panel.count) specific=\(specificSelected) generic=\(genericSelected) max_generic_allowed=\(maxGenericInPanel)")
        if let top = detected.first {
            print("[WorkflowActionSet] workflow=\(top.kind.rawValue) domain=\(s.workflow) actions=\(panel.joined(separator: ","))")
        }
        // Phase 59 — the action set is a function of content type, not bucket.
        let captureCount = panel.filter { (ceilingById[$0] ?? .panel) == .captureNeeded }.count
        let utilityCount = panel.filter { id in
            guard let a = WorkflowActionOntology.byId[id] else { return false }
            return a.category == .memoryWorkflows || a.category == .setupAcquisition || UsefulActionScorer.genericUtilityIds.contains(id)
        }.count
        print("[ContextualActionSet] content_type=\(content.type.rawValue) workflow=\(topKind.rawValue) actions=\(panel.joined(separator: ",")) reason=contract_driven")
        print("[ActionSetDiversity] content_type=\(content.type.rawValue) generic=\(genericSelected) specific=\(specificSelected) capture=\(captureCount) utility=\(utilityCount)")
        // Phase 60 — context quality: what good actions this activity supports
        // and whether silence is the right floating outcome.
        let silenceExpected = activity.forcesFloatingSilence
        print("[ContextActionQuality] activity=\(activity.activity.rawValue) content_type=\(content.type.rawValue) evidence=\(evidence.available.map(\.rawValue).sorted().joined(separator: ",")) good_actions=\(primary.joined(separator: ",")) surfaced=\(panel.joined(separator: ",")) silence=\(silenceExpected ? "yes" : "no")")

        // Phase 61 — panel discipline: every surfaced action passed contract +
        // panel threshold above; assign sections and prove background isolation.
        for id in panel {
            guard let action = WorkflowActionOntology.byId[id] else { continue }
            let isCrossTab = LiquidActionCompartmentGate.isCrossTabAction(action)
            let section: String
            if action.category == .memoryWorkflows || action.category == .setupAcquisition {
                section = "utility"
            } else if action.category == .workspaceFriction || action.category == .mediaFocus {
                section = "utility"
            } else if isCrossTab && cluster.comparable && cluster.authority == .related {
                section = "related_focus"
            } else {
                section = "current_task"
            }
            print("[PanelSectionAssignment] id=\(id) section=\(section) reason=\(isCrossTab ? "cluster_authority_\(cluster.authority.rawValue)" : "current_focus_action")")
            print("[PanelWorthinessGate] id=\(id) allowed=yes reason=contract_and_threshold_passed")
            print("[AvailableActionQualityGate] id=\(id) allowed=yes reason=contract_driven_panel")
            // Label truth: cross-tab labels must not imply current-page work
            // when the cluster is not current. (Background clusters never reach
            // the panel at all — strongest isolation.)
            let label = displayTitle(for: action, signals: s)
            let target = isCrossTab ? (cluster.authority == .current ? "current_focus" : cluster.authority == .related ? "related_focus" : "background_workspace") : "current_focus"
            print("[ActionTargetTruth] id=\(id) target=\(target) label=\"\(label)\" honest=\(target == "background_workspace" ? "no" : "yes")")
        }
        print("[CurrentTaskActionSet] actions=\(panel.joined(separator: ",")) reason=background_clusters_isolated")
        if cluster.comparable && cluster.authority == .background {
            print("[BackgroundWorkspaceAction] id=compare_open_tabs cluster=\(cluster.clusterType) shown=no reason=current_focus_unrelated")
            print("[BackgroundActionIsolation] id=compare_open_tabs isolated=yes reason=background_cluster_not_current_task")
            print("[MisleadingLabelBlock] id=compare_open_tabs label=\"Capture pages to compare them\" reason=background_action_labeled_as_current")
        }

        return LiquidActionSelection(
            detected: detected,
            primary: Array(primary),
            panel: panel,
            suppressed: suppressed,
            specificCount: specificSelected,
            genericCount: genericSelected,
            setupCount: panel.filter { id in
                guard let a = WorkflowActionOntology.byId[id] else { return false }
                return executionTier(for: a, signals: s).tier == 3
            }.count
        )
    }

    enum PreflightDecision: String {
        case show
        case showCaptureNeeded = "show_capture_needed"
        case showBackground = "show_background"
        case suppress
    }

    struct LiquidActionPreflight {
        let id: String
        let relevance: Double
        let scope: String
        let canExecuteNow: Bool
        let expectedValue: String
        let followupAvailable: Bool
        let decision: PreflightDecision
        let blockReason: String?
        let expectedFollowups: [String]
    }

    private static func computePreflight(action: WorkflowAction, signals: WorkflowSignals, tier: Int, tierReason: String, relevance: Double, surfaceCeiling: ContractSurface) -> LiquidActionPreflight {
        let enriched = signals.enrichedContext
        let fullDocumentAvailable = enriched?.evidenceLevel == "full_document"
        let canUseEnriched = enriched != nil && !(action.minScope?.satisfiesFullScope == true && !fullDocumentAvailable)
        let isMetadataOnly = tier == 2 && tierReason == "needs_visible_capture" && !canUseEnriched
        
        var scope = "none"
        if tier == 1 {
            if fullDocumentAvailable { scope = "full_document" }
            else if enriched != nil { scope = "visible_partial" }
            else if signals.selectedTextLength > 0 { scope = "selection" }
            else if action.requiredContext.contains("ax_content") { scope = "visible_partial" }
            else if action.requiredContext.contains("full_document") { scope = "full_document" }
            else { scope = "visible_partial" }
        } else if isMetadataOnly {
            scope = "metadata"
        }
        
        var expectedValue = "medium"
        var followupAvailable = true
        var expectedFollowups: [String] = []
        var decision: PreflightDecision = .show
        var blockReason: String? = nil
        
        if action.executionKind == .metadataNote {
            expectedValue = "low"
        }
        
        if action.id == "compare_open_tabs" {
            // Phase 59/60 — a compare needs multiple real candidates with
            // captured details. Metadata-only can never claim a comparison:
            // the honest framing is a capture step.
            if isMetadataOnly || surfaceCeiling == .captureNeeded || !signals.contentAvailable {
                expectedValue = "none"
                decision = .showCaptureNeeded
                blockReason = isMetadataOnly ? "metadata_too_thin" : "no_listing_details_yet"
                expectedFollowups = ["capture_listing_pages", "compare_by_features", "save_research_session", "open_agreement_beside"]
            } else {
                expectedValue = "high"
                followupAvailable = true
                expectedFollowups = ["capture_listing_pages", "save_research_session", "open_agreement_beside"]
            }
        } else if action.id == "flag_risky_clauses" {
            if tier == 1 {
                expectedValue = "high"
                expectedFollowups = ["extract_obligations", "generate_questions_for_landlord"]
            } else {
                expectedValue = "none"
                decision = .showCaptureNeeded
                blockReason = "metadata_too_thin"
                expectedFollowups = ["capture_full_agreement"]
            }
        } else if action.executionKind == .metadataNote && !isMetadataOnly {
             expectedValue = "template_only"
             decision = .suppress
             blockReason = "template_only"
             followupAvailable = false
        }

        if let enriched, canUseEnriched, action.executionKind == .contentInsight {
            if surfaceCeiling == .captureNeeded || decision == .showCaptureNeeded || tierReason == "enriched_context_available" {
                print("[CaptureWrapperAvoided] id=\(action.id) reason=enriched_context_available source=\(enriched.source) chars=\(enriched.chars)")
                print("[ProposalQualityUpgrade] id=\(action.id) old=\(decision == .showCaptureNeeded ? "capture_needed" : "metadata_note") new=content_action reason=enriched_context_available")
                decision = .show
                blockReason = nil
                expectedValue = expectedValue == "none" ? "medium" : expectedValue
                followupAvailable = true
                if scope == "none" || scope == "metadata" {
                    scope = fullDocumentAvailable ? "full_document" : "visible_partial"
                }
            }
        }
        
        if decision == .show && expectedValue == "none" && !followupAvailable {
             decision = .suppress
             blockReason = "no_followup"
        }
        
        return LiquidActionPreflight(
            id: action.id,
            relevance: relevance,
            scope: scope,
            canExecuteNow: tier == 1,
            expectedValue: expectedValue,
            followupAvailable: followupAvailable,
            decision: decision,
            blockReason: blockReason,
            expectedFollowups: expectedFollowups
        )
    }
}

// MARK: - Lease action fatigue / novelty / rotation (Part 1)
//
// The contract_review action pack is declarative (not a literal hardcode), but
// it FELT hardcoded because the same action (extract_obligations) floated every
// tick on the same document. This memory makes the floating lease action novel:
// once a lease action has floated for a (document, content) it is demoted to
// panel and the pack rotates to an alternate, until the content changes or the
// pack is exhausted (then floating goes silent for that document).
final class LeaseActionFatigueMemory: @unchecked Sendable {
    static let shared = LeaseActionFatigueMemory()
    private let lock = NSLock()

    struct Record {
        var lastContentHash: String
        var lastEvent: String   // shown | accepted | dismissed | extracted
        var count: Int
        var lastShownAt: Date
    }
    // key = "docSig|actionId"
    private var records: [String: Record] = [:]
    /// Within this window a just-shown action is still "the current float" so
    /// repeated floatingCandidate() calls in one render tick stay stable rather
    /// than rotating mid-tick.
    private let intraTickWindow: TimeInterval = 2.0

    private init() {}

    func docSignature(signals: WorkflowSignals) -> String {
        let raw: String
        if !signals.urlHost.isEmpty || !signals.urlPath.isEmpty {
            raw = (signals.urlHost + signals.urlPath)
        } else {
            raw = signals.windowTitle
        }
        let clean = raw.lowercased().replacingOccurrences(of: #"[^a-z0-9/._-]+"#, with: "_", options: .regularExpression)
        return clean.isEmpty ? "unknown_doc" : String(clean.prefix(80))
    }

    /// A coarse hash of the readable content so a real content change resets the
    /// pack. Uses enriched-context chars + a prefix when available, else the doc
    /// signature (so metadata-only revisits count as "same content").
    func contentHash(signals: WorkflowSignals) -> String {
        if let enriched = signals.enrichedContext, enriched.chars > 0 {
            return "ax:\(enriched.chars):\(enriched.text.prefix(24).hashValue)"
        }
        if signals.selectedTextLength >= 40 {
            return "sel:\(signals.selectedTextLength)"
        }
        return "meta:\(docSignature(signals: signals))"
    }

    private func key(_ docSig: String, _ actionId: String) -> String { "\(docSig)|\(actionId)" }

    /// Has this action already floated for this exact (doc, content)? True only
    /// after the intra-tick window so repeated calls within one tick are stable.
    func alreadyShown(actionId: String, docSig: String, contentHash: String, now: Date = Date()) -> (already: Bool, seenCount: Int, lastEvent: String) {
        lock.lock(); defer { lock.unlock() }
        guard let rec = records[key(docSig, actionId)] else { return (false, 0, "none") }
        let already = rec.lastContentHash == contentHash && now.timeIntervalSince(rec.lastShownAt) > intraTickWindow
        // An explicit accept/dismiss/extract sticks regardless of the window.
        let usedUp = rec.lastContentHash == contentHash && (rec.lastEvent == "accepted" || rec.lastEvent == "dismissed" || rec.lastEvent == "extracted")
        return (already || usedUp, rec.count, rec.lastEvent)
    }

    func recordShown(actionId: String, docSig: String, contentHash: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let k = key(docSig, actionId)
        if var rec = records[k] {
            rec.count += 1
            rec.lastContentHash = contentHash
            rec.lastShownAt = now
            if rec.lastEvent == "none" { rec.lastEvent = "shown" }
            records[k] = rec
        } else {
            records[k] = Record(lastContentHash: contentHash, lastEvent: "shown", count: 1, lastShownAt: now)
        }
    }

    func recordEvent(actionId: String, docSig: String, contentHash: String, event: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let k = key(docSig, actionId)
        if var rec = records[k] {
            rec.lastEvent = event
            rec.lastContentHash = contentHash
            rec.lastShownAt = now
            records[k] = rec
        } else {
            records[k] = Record(lastContentHash: contentHash, lastEvent: event, count: 1, lastShownAt: now)
        }
    }

    /// Rotate the lease-pack actions in `primary`: drop the ones already shown
    /// for this (doc, content) — keeping non-lease actions intact — and surface
    /// the first novel lease action. Emits the Part 1 proof logs.
    func rotatedLeasePrimary(_ primary: [String], docSig: String, contentHash: String, now: Date = Date()) -> [String] {
        var keptLease: [String] = []
        var droppedLease: [String] = []
        var nonLease: [String] = []
        for id in primary {
            guard let action = WorkflowActionOntology.byId[id] else { nonLease.append(id); continue }
            guard action.category == .documentsLeases else { nonLease.append(id); continue }
            let status = alreadyShown(actionId: id, docSig: docSig, contentHash: contentHash, now: now)
            let allow = !status.already
            print("[ActionFatigueCheck] id=\(id) context=\(docSig) seen_count=\(status.seenCount) last_event=\(status.lastEvent) allowed=\(allow ? "yes" : "no") reason=\(allow ? (status.seenCount == 0 ? "first_time_on_document" : "content_changed_or_new") : "already_shown_same_content")")
            if allow {
                keptLease.append(id)
            } else {
                droppedLease.append(id)
                print("[RepeatedActionDemotion] id=\(id) from=floating to=panel reason=already_shown_or_used")
            }
        }
        let selected = keptLease.first
        let previous = droppedLease.last
        if !primary.contains(where: { WorkflowActionOntology.byId[$0]?.category == .documentsLeases }) {
            // No lease actions in primary — nothing to rotate.
            return primary
        }
        print("[ActionDiversityRotation] pack=contract_review previous=\(previous ?? "none") selected=\(selected ?? "none") reason=\(selected != nil ? "rotated_to_novel_action" : "all_pack_actions_shown")")
        print("[LeasePackSelection] selected=\(selected ?? "none") alternatives=\(keptLease.dropFirst().joined(separator: ",")) reason=\(selected != nil ? "novelty_rotation" : "pack_fatigued_content_unchanged")")
        // Floating order: at most one novel lease action, then non-lease actions.
        return (selected.map { [$0] } ?? []) + nonLease
    }

    func resetForTests() {
        lock.lock(); records.removeAll(); lock.unlock()
    }
}
