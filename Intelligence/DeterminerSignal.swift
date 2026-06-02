import Foundation

/// Phase 21.1 — Composite actionability signal.
///
/// DeterminerSignal combines weak temporal signals (workflow/behavior state, which may
/// be stale or unknown during early-session cold-start) with strong structural signals
/// (compartment trust, working memory, current entity presence) to decide whether
/// Jarvis *can* produce a useful suggestion — independent of whether the temporal
/// workflow model has stabilized.
///
/// This breaks the dead-lock where `workflow=unknown / behavior=idle` suppresses
/// everything even though the compartment tracker has a rich, trusted task context.
///
/// Design constraints:
/// - No hardcoded app/site/brand mappings.
/// - Domain/mode inference uses generic term vocabularies only.
/// - All outputs are read-only signals; nothing is mutated.
public struct DeterminerSignal: Sendable, Equatable {

    // MARK: - Domain / Mode enums

    public enum Domain: String, Sendable, Equatable, CaseIterable {
        case creative_coding
        case studying
        case shopping
        case researching
        case coding
        case communicating
        case browsing
        case watching
        case gaming
        case working
        case unknown
    }

    public enum Mode: String, Sendable, Equatable, CaseIterable {
        case building
        case learning
        case comparing
        case debugging
        case reading
        case writing
        case communicating
        case browsing
        case idle
        case unknown
    }

    // MARK: - Output

    public let actionable: Bool
    public let inferredDomain: Domain
    public let inferredMode: Mode
    public let confidence: Double
    public let reason: String

    // MARK: - Evaluate

    /// Produces a DeterminerSignal from all available context.
    /// None of the inputs are required — graceful degradation applies:
    /// the more signals present, the higher the confidence.
    public static func evaluate(
        memory: WorkingMemorySnapshot?,
        compartment: TaskCompartment?,
        workflowConfidence: Double = 0.0,
        behaviorConfidence: Double = 0.0,
        browserTabCount: Int = 0,
        hasSelectedURL: Bool = false,
        activeTerms: [String] = [],
        currentEntity: String = "",
        activityState: ActivityState? = nil
    ) -> DeterminerSignal {

        // ── 0. Resolve entity and compartment trust before any term collection ──
        let resolvedEntity = memory?.currentEntity ?? currentEntity
        let compartmentTrust = compartment?.compartmentTrust ?? 0.0

        // Phase 21.2 — Failure 3: Blank/neutral tab guard.
        // Checked BEFORE term collection so that tokens from the entity name
        // ("new", "tab") are not counted as real active signal.
        // "New Tab", empty tabs, and browser chrome must NOT inherit context
        // from a stale compartment when there are no real external terms.
        // Exception (Phase 21.4): if user is actively typing/interacting on a
        // blank tab, let it pass — they may be about to navigate somewhere.
        let hasExternalTermSignal = !(memory?.repeatedConcepts ?? []).isEmpty
                                 || !activeTerms.isEmpty
                                 || !(memory?.relatedFocusEntities ?? []).isEmpty
                                 || !(compartment?.dominantTerms ?? []).isEmpty
        let userActiveOnBlank = activityState?.isActive == true && activityState?.state == .typing
        if isNeutralEntity(resolvedEntity) && !hasExternalTermSignal && compartmentTrust < 0.40 && !userActiveOnBlank {
            print("[DeterminerSignal] actionable=no confidence=0.00 compartment_trust=\(String(format: "%.2f", compartmentTrust))")
            print("[DeterminerSignal] inferred_domain=unknown inferred_mode=idle")
            print("[DeterminerSignal] reason=blank_or_neutral_tab")
            return DeterminerSignal(
                actionable: false,
                inferredDomain: .unknown,
                inferredMode: .idle,
                confidence: 0.0,
                reason: "blank_or_neutral_tab"
            )
        }

        // ── 1. Collect terms — current-focus separate from compartment history ──
        //
        // Phase 22 — Domain scoring fix.
        //
        // Before this fix, `allTerms` included compartment.dominantTerms and was
        // passed directly to inferDomain().  This caused stale compartment terms
        // (e.g., "scratch/sprite/shooter" from a Scratch session) to persist into
        // domain classification even after a full context switch, because the
        // compartment hadn't yet been evicted.
        //
        // Fix: build two separate sets.
        //   domainScoringTerms — current-focus evidence only (entity, memory,
        //                        activeTerms).  Used for inferDomain() and
        //                        BestEffortDomain decisions.  No compartment history.
        //   allTerms           — full union including compartment.  Still used for
        //                        structural actionability (activeTermCount gate) and
        //                        mode inference where recency matters less.
        var allTerms = Set<String>()
        var domainScoringTerms = Set<String>()   // current focus only — no compartment history

        if let mem = memory {
            allTerms.formUnion(mem.repeatedConcepts.map { $0.lowercased() })
            allTerms.formUnion(mem.relatedFocusEntities.flatMap { tokenize($0) })
            allTerms.formUnion(tokenize(mem.currentEntity))
            // Same sources added to domainScoringTerms — compartment intentionally excluded
            domainScoringTerms.formUnion(mem.repeatedConcepts.map { $0.lowercased() })
            domainScoringTerms.formUnion(mem.relatedFocusEntities.flatMap { tokenize($0) })
            domainScoringTerms.formUnion(tokenize(mem.currentEntity))
        }
        if let comp = compartment {
            // Compartment history in allTerms only — NOT in domainScoringTerms
            allTerms.formUnion(comp.dominantTerms.map { $0.lowercased() })
            allTerms.formUnion(comp.entities.flatMap { tokenize($0) })
        }
        allTerms.formUnion(activeTerms.map { $0.lowercased() })
        domainScoringTerms.formUnion(activeTerms.map { $0.lowercased() })
        if !currentEntity.isEmpty {
            allTerms.formUnion(tokenize(currentEntity))
            domainScoringTerms.formUnion(tokenize(currentEntity))
        }

        // ── 2. Structural actionability gates ─────────────────────────────────
        let entityPresent = !resolvedEntity.isEmpty
        let activeTermCount = allTerms.count
        let relatedEntityCount = memory?.relatedFocusEntities.count ?? 0

        // Phase 21.4 — Activity state: an active user (typing/interacting/
        // navigating/engaged) with ANY entity present is always actionable,
        // even when the temporal workflow model hasn't stabilised.
        // This ensures "unknown domain + active user ≠ idle/suppressed".
        let userIsActive: Bool = {
            guard let as_ = activityState else { return false }
            return as_.isActive && as_.state != .idle && as_.state != .reading
        }()

        // Actionable if any structural signal crosses its threshold:
        //   - compartmentTrust ≥ 0.40 — tracker has seen this task before
        //   - entity present + ≥2 active terms — enough working memory
        //   - ≥2 related focus entities — multi-tab context understood
        //   - workflow/behavior confidence ≥ 0.60 — temporal model confident
        //   - Phase 21.4: user is actively engaged + entity present
        let actionable: Bool = {
            if compartmentTrust >= 0.40 { return true }
            if entityPresent && activeTermCount >= 2 { return true }
            if relatedEntityCount >= 2 { return true }
            if workflowConfidence >= 0.60 { return true }
            if behaviorConfidence >= 0.60 { return true }
            if userIsActive && entityPresent { return true }   // Phase 21.4
            return false
        }()

        // ── 3. Domain / Mode scoring ──────────────────────────────────────────
        // Phase 22 — Use domainScoringTerms (current-focus only) for inferDomain().
        // This prevents a stale compartment (e.g., Scratch/creative_coding) from
        // winning domain classification after the user switches to unrelated content
        // (e.g., a TV show → no creative_coding vocabulary in current focus).
        print("[DomainClassifier] scoring_source=current_focus_only focus_term_count=\(domainScoringTerms.count) all_term_count=\(allTerms.count)")
        var domain = inferDomain(terms: domainScoringTerms)

        // Phase 21.4 / Phase 22 — Best-effort domain when unknown + user is active.
        // If the term scorer returned .unknown but the user is clearly active and a
        // compartment workflow hint is available, promote it — BUT only when the
        // current-focus terms actually contain vocabulary from that domain.
        //
        // Phase 22 guard: without currentFocusSupportsWorkflow(), a stale Scratch
        // compartment would push domain=creative_coding even while watching a TV show.
        if domain == .unknown && userIsActive {
            if let compWorkflow = compartment?.workflow {
                if currentFocusSupportsWorkflow(compWorkflow, focusTerms: domainScoringTerms) {
                    switch compWorkflow {
                    case .gaming:
                        domain = .gaming
                        print("[BestEffortDomain] selected=gaming confidence=0.40 source=compartment_workflow focus_supported=yes")
                    case .coding:
                        domain = .coding
                        print("[BestEffortDomain] selected=coding confidence=0.40 source=compartment_workflow focus_supported=yes")
                    case .debugging:
                        domain = .coding
                        print("[BestEffortDomain] selected=coding confidence=0.40 source=compartment_workflow_debugging focus_supported=yes")
                    case .studying, .reading, .researching:
                        domain = .studying
                        print("[BestEffortDomain] selected=studying confidence=0.40 source=compartment_workflow focus_supported=yes")
                    case .shopping, .comparing:
                        domain = .shopping
                        print("[BestEffortDomain] selected=shopping confidence=0.40 source=compartment_workflow focus_supported=yes")
                    case .watching:
                        domain = .watching
                        print("[BestEffortDomain] selected=watching confidence=0.40 source=compartment_workflow focus_supported=yes")
                    case .emailing, .writing:
                        domain = .communicating
                        print("[BestEffortDomain] selected=communicating confidence=0.40 source=compartment_workflow focus_supported=yes")
                    default:
                        break
                    }
                } else {
                    print("[BestEffortDomain] blocked reason=current_focus_contradicts_compartment comp_workflow=\(compWorkflow.rawValue) focus_terms=\(domainScoringTerms.count)")
                }
            }
            // Even with no compartment hint, keep domain=unknown but signal active_unknown.
            if domain == .unknown {
                print("[BestEffortDomain] selected=unknown confidence=0.20 source=active_user_no_terms")
            }
        }

        let mode = inferMode(terms: domainScoringTerms, domain: domain)

        // ── 4. Confidence: max of available structural + temporal signals ──────
        let structuralConfidence: Double = {
            var c = 0.0
            if compartmentTrust > 0 { c = max(c, compartmentTrust) }
            if entityPresent       { c = max(c, 0.45) }
            if activeTermCount >= 3 { c = max(c, 0.55) }
            if relatedEntityCount >= 2 { c = max(c, 0.60) }
            if browserTabCount >= 2 { c = max(c, 0.50) }
            if hasSelectedURL      { c = max(c, 0.50) }
            return c
        }()
        let confidence = min(0.95, max(structuralConfidence, workflowConfidence, behaviorConfidence))

        // ── 5. Reason tag ─────────────────────────────────────────────────────
        let reason: String = {
            if compartmentTrust >= 0.40 { return "compartment_memory_sufficient" }
            if entityPresent && activeTermCount >= 2 { return "entity_and_terms_sufficient" }
            if relatedEntityCount >= 2 { return "related_entities_sufficient" }
            if workflowConfidence >= 0.60 { return "workflow_confidence_sufficient" }
            if behaviorConfidence >= 0.60 { return "behavior_confidence_sufficient" }
            if userIsActive && entityPresent { return "active_user_entity_present" }   // Phase 21.4
            return "no_sufficient_signal"
        }()

        let confStr = String(format: "%.2f", confidence)
        let ctStr   = String(format: "%.2f", compartmentTrust)
        print("[DeterminerSignal] actionable=\(actionable ? "yes" : "no") confidence=\(confStr) compartment_trust=\(ctStr)")
        print("[DeterminerSignal] inferred_domain=\(domain.rawValue) inferred_mode=\(mode.rawValue)")
        print("[DeterminerSignal] reason=\(reason)")

        return DeterminerSignal(
            actionable: actionable,
            inferredDomain: domain,
            inferredMode: mode,
            confidence: confidence,
            reason: reason
        )
    }

    // MARK: - Domain vocabularies (generic — no site/brand hardcoding)

    // Creative / block-based coding, game building, interactive demos.
    private static let creativeCodingTerms: Set<String> = [
        "scratch", "turbowarp", "sprite", "blocks", "block", "script",
        "coding", "program", "programming", "playground", "demo", "prototype",
        "game", "shoot", "shooter", "tank", "enemy", "collision", "render",
        "canvas", "animation", "pixel", "stage", "backdrop"
    ]

    // Academic / course learning.
    private static let studyingTerms: Set<String> = [
        "lecture", "assignment", "homework", "quiz", "exam", "syllabus",
        "notes", "slides", "lesson", "chapter", "module", "tutorial",
        "lab", "course", "class", "week", "introduction", "reading",
        "practice", "study", "studying", "review", "exercise", "activity"
    ]

    // Shopping / purchasing intent.
    private static let shoppingTerms: Set<String> = [
        "price", "buy", "cart", "checkout", "deal", "deals", "shipping",
        "delivery", "rating", "spec", "specs", "compare",
        "product", "purchase", "order", "watt", "watts", "mah", "battery",
        "adapter", "charger", "portable"
    ]

    // Research / reading academic or reference material.
    private static let researchTerms: Set<String> = [
        "paper", "preprint", "arxiv", "doi", "pdf", "dataset", "method",
        "results", "analysis", "research", "survey", "experiment", "theory",
        "abstract", "citation", "publication", "reference", "bibliography",
        "gemini", "chatgpt", "claude", "copilot", "perplexity", "assistant", "chat"
    ]

    // Software development / engineering.
    private static let codingTerms: Set<String> = [
        "swift", "python", "javascript", "typescript", "xcode", "vscode",
        "function", "struct", "variable", "compile", "build",
        "error", "exception", "stack", "github", "commit", "branch",
        "pull", "request", "lint", "runtime", "refactor", "deploy"
    ]

    // Email / messaging / collaboration / admin document work.
    private static let communicatingTerms: Set<String> = [
        "email", "mail", "slack", "message", "inbox", "sent", "reply", "thread",
        "compose", "send", "meeting", "calendar", "invite", "zoom",
        "teams", "discord", "notification", "gmail", "drafts",
        "invoice", "receipt", "payment", "client", "document",
        "attachment", "contract", "proposal", "billing"
    ]

    // Passive video / streaming.
    private static let watchingTerms: Set<String> = [
        "youtube", "video", "watch", "episode", "season", "stream",
        "netflix", "hulu", "twitch", "live", "replay", "subscribe", "channel"
    ]

    // Gaming / entertainment.
    private static let gamingTerms: Set<String> = [
        "steam", "gaming", "player", "level", "quest", "achievement",
        "multiplayer", "leaderboard", "respawn", "inventory", "weapon",
        "health", "boss", "checkpoint"
    ]

    // MARK: - Inference helpers

    // Phase 22 — Check whether current-focus terms contain vocabulary from the
    // workflow's domain.  Used by BestEffortDomain to prevent a stale compartment
    // from promoting its workflow when the user has already moved on.
    //
    // Design: generic domain vocabulary matching — no app/brand/keyword hardcoding.
    // Each workflow maps to the same generic term set already used in inferDomain().
    private static func currentFocusSupportsWorkflow(
        _ workflow: AmbientWorkflowType,
        focusTerms: Set<String>
    ) -> Bool {
        func hits(_ vocab: Set<String>) -> Bool { !focusTerms.intersection(vocab).isEmpty }
        switch workflow {
        case .coding, .debugging:
            // Check both engineering and creative/game coding vocabularies
            return hits(codingTerms) || hits(creativeCodingTerms)
        case .studying, .reading, .researching:
            return hits(studyingTerms) || hits(researchTerms)
        case .shopping, .comparing:
            return hits(shoppingTerms)
        case .watching:
            return hits(watchingTerms)
        case .gaming:
            return hits(gamingTerms)
        case .emailing, .writing:
            return hits(communicatingTerms)
        default:
            // browsing / idle / meeting / unknown: permissive — no specific domain to verify
            return true
        }
    }

    // Phase 21.2 — email/document negative gate terms.
    // These terms mean the user is in a communicating/admin context,
    // NOT shopping — even if multiple tabs or entities are present.
    private static let emailDocumentTerms: Set<String> = [
        "gmail", "inbox", "sent", "drafts", "mail", "thread", "reply", "compose",
        "invoice", "receipt", "payment", "client", "attachment", "document",
        "docx", "spreadsheet", "sheet", "slide", "proposal", "contract",
        "statement", "expense", "budget", "billing", "account"
    ]

    // Explicit commercial intent required to override emailDocumentTerms.
    private static let explicitShoppingTerms: Set<String> = [
        "price", "buy", "cart", "checkout", "purchase", "order", "product",
        "store", "shop", "deal", "discount", "coupon"
    ]

    private static func inferDomain(terms: Set<String>) -> Domain {
        func score(_ vocab: Set<String>) -> Int { terms.intersection(vocab).count }

        // Phase 21.2 — Failure 2: Email/document negative rule.
        // If the context is clearly email/admin/document work and there is NO
        // explicit commercial intent (price/buy/cart), block shopping entirely.
        let emailScore = score(emailDocumentTerms)
        let explicitShoppingScore = score(explicitShoppingTerms)
        if emailScore > 0 && explicitShoppingScore == 0 {
            print("[DomainClassifier] domain=communicating reason=email_or_invoice_context email_terms=\(emailScore)")
            print("[WorkflowFallback] blocked reason=email_or_document_context_not_shopping")
            return .communicating
        }

        var scores: [(Domain, Int)] = [
            (.creative_coding, score(creativeCodingTerms)),
            (.studying,        score(studyingTerms)),
            (.shopping,        score(shoppingTerms)),
            (.researching,     score(researchTerms)),
            (.coding,          score(codingTerms)),
            (.communicating,   score(communicatingTerms)),
            (.watching,        score(watchingTerms)),
            (.gaming,          score(gamingTerms)),
        ]

        // Give creative_coding a small bonus so project-oriented pages
        // (which often contain coding terms too) resolve correctly.
        // Only boost if the base score is at least 1 — no phantom wins.
        if let idx = scores.firstIndex(where: { $0.0 == .creative_coding }), scores[idx].1 >= 1 {
            scores[idx].1 += 1
        }

        guard let best = scores.max(by: { $0.1 < $1.1 }), best.1 > 0 else {
            return .unknown
        }

        print("[DomainClassifier] domain=\(best.0.rawValue) score=\(best.1)")
        return best.0
    }

    private static func inferMode(terms: Set<String>, domain: Domain) -> Mode {
        let debugTerms:   Set<String> = ["error", "exception", "crash", "failed", "debug", "stack", "trace", "warning"]
        let writeTerms:   Set<String> = ["draft", "edit", "revision", "essay", "outline", "proposal", "report", "paragraph"]
        let compareTerms: Set<String> = ["compare", "versus", "comparison", "difference", "pros", "cons"]
        let buildTerms:   Set<String> = ["build", "create", "make", "project", "prototype", "demo", "coding", "program"]
        let learnTerms:   Set<String> = ["learn", "study", "lecture", "homework", "quiz", "chapter", "lesson"]
        let readTerms:    Set<String> = ["read", "reading", "article", "paper", "pdf", "blog", "news"]
        let commTerms:    Set<String> = ["reply", "compose", "send", "email", "message", "thread"]

        func hit(_ vocab: Set<String>) -> Bool { !terms.intersection(vocab).isEmpty }

        if hit(debugTerms)   { return .debugging }
        if hit(compareTerms) { return .comparing }
        if hit(writeTerms)   { return .writing }
        if hit(commTerms)    { return .communicating }

        switch domain {
        case .creative_coding:
            return hit(buildTerms) ? .building : .learning
        case .studying:
            return hit(learnTerms) ? .learning : .reading
        case .researching:
            return hit(readTerms) ? .reading : .learning
        case .coding:
            return hit(buildTerms) ? .building : .debugging
        case .communicating:
            return .communicating
        case .watching, .gaming:
            return .browsing
        case .shopping:
            return hit(compareTerms) ? .comparing : .browsing
        case .working, .browsing, .unknown:
            return hit(learnTerms) ? .learning : .unknown
        }
    }

    // MARK: - Neutral entity detection (Failure 3)

    /// Returns true for browser chrome / blank tabs that carry no actual content signal.
    private static func isNeutralEntity(_ entity: String) -> Bool {
        let lower = entity.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.isEmpty { return true }
        let neutralPatterns = [
            "new tab", "blank", "about:blank", "about:newtab",
            "start page", "home page", "homepage", "untitled",
            "speed dial", "new window"
        ]
        return neutralPatterns.contains(where: { lower == $0 || lower.hasPrefix($0) })
    }

    // MARK: - Tokenizer (generic; mirrors FocusOverride without cross-import)

    private static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && $0.count <= 24 && Int($0) == nil }
    }
}
