import AppKit
import Foundation

// MARK: - Phase 35 Evidence Model

enum ProgressiveEvidenceLevel: String, Sendable, Codable, CaseIterable {
    case none
    case metadata_only
    case metadata_rich
    case visible_content
    case selected_content
    case full_content

    var rank: Int {
        switch self {
        case .none: return 0
        case .metadata_only: return 1
        case .metadata_rich: return 2
        case .visible_content: return 3
        case .selected_content: return 4
        case .full_content: return 5
        }
    }

    var nextContextNeeded: String {
        switch self {
        case .none, .metadata_only:
            return "ax_text"
        case .metadata_rich:
            return "visible_ocr"
        case .visible_content:
            return "selection"
        case .selected_content, .full_content:
            return "none"
        }
    }

    static func from(raw: String) -> ProgressiveEvidenceLevel {
        switch raw {
        case "none": return .none
        case "metadata_only", "title_only": return .metadata_only
        case "metadata_rich", "browser_context", "browser_tabs", "editor_context", "compartment_context", "cheap_context": return .metadata_rich
        case "visible_content", "ax_content", "ocr", "partial_signal": return .visible_content
        case "selected_content", "selection": return .selected_content
        case "full_content", "public_web_research", "product_metadata": return .full_content
        default: return .metadata_only
        }
    }

    var legacyQuality: String {
        switch self {
        case .none, .metadata_only: return "title_only"
        case .metadata_rich: return "browser_context"
        case .visible_content: return "ax_content"
        case .selected_content: return "selection"
        case .full_content: return "product_metadata"
        }
    }
}

enum BrowserContextKind: String, Sendable, Codable, Equatable {
    case google_docs
    case gmail
    case chatgpt
    case youtube
    case forum = "reddit/forum"
    case search_results
    case media_page
    case document
    case article
    case listing
    case pdf_in_browser
    case generic_page
    case unknown
}

struct BrowserContextAssessment: Sendable, Codable, Equatable {
    let kind: BrowserContextKind
    let evidence: [String]
    let contentAvailable: Bool
    let reason: String
    let safeActions: [String]
    let blockedActions: [String]
}

struct EvidenceProfile: Sendable, Codable, Equatable {
    let level: ProgressiveEvidenceLevel
    let titleAvailable: Bool
    let urlAvailable: Bool
    let tabCount: Int
    let hasAXText: Bool
    let hasOCR: Bool
    let hasSelectedText: Bool
    let semanticGrounding: Bool
    let durableCompartment: Bool
    let browserAssessment: BrowserContextAssessment?

    var contentAvailable: Bool {
        level.rank >= ProgressiveEvidenceLevel.visible_content.rank
    }
}

enum BrowserContextStrategy {
    public static var lastAssessedURL: String? = nil

    static func assess(
        title: String?,
        url: URL?,
        tabTitles: [String],
        hasAXText: Bool,
        hasOCR: Bool
    ) -> BrowserContextAssessment {
        if let url = url {
            lastAssessedURL = url.absoluteString
        }
        let lowerTitle = (title ?? "").lowercased()
        let host = url?.host?.lowercased() ?? ""
        let path = url?.path.lowercased() ?? ""
        let evidence = browserEvidence(url: url, title: title, tabTitles: tabTitles, hasAXText: hasAXText)

        let kind: BrowserContextKind
        let reason: String
        switch true {
        case host.contains("docs.google.com") && path.contains("/document"):
            kind = .google_docs; reason = "google_docs_url"
        case host.contains("mail.google.com"):
            kind = .gmail; reason = "gmail_url"
        case host.contains("chatgpt.com") || host.contains("chat.openai.com") || lowerTitle.contains("chatgpt"):
            kind = .chatgpt; reason = "chatgpt_url_or_title"
        case host.contains("youtube.com") || host.contains("youtu.be") || lowerTitle.contains("youtube"):
            kind = .youtube; reason = "youtube_url_or_title"
        case path.hasSuffix(".pdf") || lowerTitle.contains("pdf"):
            kind = .pdf_in_browser; reason = "pdf_signal"
        case path.contains("/search") || url?.query != nil && (url?.query?.contains("q=") ?? false) || lowerTitle.contains("search results"):
            kind = .search_results; reason = "search_current_focus"
        case path.contains("/r/") || path.contains("/forum") || path.contains("/thread") || lowerTitle.contains("subreddit") || lowerTitle.contains("thread"):
            kind = .forum; reason = "forum_current_focus"
        case path.contains("/watch") || path.contains("/video") || lowerTitle.contains("video"):
            kind = .media_page; reason = "media_current_focus"
        case path.contains("/document") || path.contains("/edit") || lowerTitle.contains("document"):
            kind = .document; reason = "document_current_focus"
        // Phase 62 — current-focus first: background tab titles cannot
        // classify the CURRENT browser strategy as listing/article. They are
        // recorded separately so the workspace memory still has them.
        case containsAny(text: [host, path, lowerTitle], needles: ["rent", "rental", "lease", "listing", "housing", "landlord", "sublet", "roommate"]):
            kind = .listing; reason = "listing_terms_current_focus"
        case containsAny(text: [host, path, lowerTitle], needles: ["arxiv", "paper", "research", "doi", "abstract", "journal", "retrieval", "study"]):
            kind = .article; reason = "article_terms_current_focus"
        case !host.isEmpty:
            kind = .generic_page; reason = "generic_browser_page"
        default:
            kind = .unknown; reason = "no_browser_signals"
        }

        let contentAvailable = hasAXText || hasOCR
        var safeActions: [String]
        let blockedActions: [String]
        // Phase 40 — When content is unavailable, add acquisition variants instead of only blocking.
        // Acquisition actions (explicit_visible_capture_summary, extract_action_items,
        // create_checklist) are gated by ActionRegistry with user_initiated_acquisition
        // and trigger a visible-capture pass when clicked — so they do not need AX/OCR upfront.
        switch kind {
        case .google_docs:
            if contentAvailable {
                safeActions = ["open_current_task_panel", "remember_workspace", "copy_current_url", "collect_references"]
                blockedActions = []
            } else {
                safeActions = ["open_current_task_panel", "remember_workspace", "copy_current_url", "collect_references",
                               "capture_full_document", "select_text_hint"]
                blockedActions = ["summarize_visible_content", "generate_quiz", "summarize_full_document"]
            }
        case .gmail:
            if contentAvailable {
                safeActions = ["arrange_side_by_side", "switch_to_paired_app", "collect_references", "remember_workspace", "copy_current_url"]
                blockedActions = []
            } else {
                safeActions = ["arrange_side_by_side", "switch_to_paired_app", "collect_references", "remember_workspace", "copy_current_url",
                               "capture_visible_page", "select_text_hint"]
                blockedActions = ["summarize_visible_content", "generate_quiz", "summarize_full_document"]
            }
        case .chatgpt:
            if contentAvailable {
                safeActions = ["arrange_side_by_side", "switch_to_paired_app", "collect_references", "remember_workspace", "copy_current_url"]
                blockedActions = []
            } else {
                safeActions = ["arrange_side_by_side", "switch_to_paired_app", "collect_references", "remember_workspace", "copy_current_url",
                               "capture_visible_page", "select_text_hint"]
                blockedActions = ["summarize_visible_content", "generate_quiz", "summarize_full_document"]
            }
        case .forum, .search_results, .media_page, .document, .article, .listing, .pdf_in_browser, .generic_page:
            if contentAvailable {
                safeActions = ["arrange_side_by_side", "switch_to_paired_app", "collect_references", "remember_workspace", "copy_current_url"]
                blockedActions = []
            } else {
                safeActions = ["arrange_side_by_side", "switch_to_paired_app", "collect_references", "remember_workspace", "copy_current_url",
                               "capture_visible_page", "enable_browser_bridge", "select_text_hint"]
                blockedActions = ["summarize_visible_content", "generate_quiz", "summarize_full_document"]
            }
        case .youtube:
            safeActions = ["reduce_interruptions", "pause_media"]
            blockedActions = ["summarize_visible_content", "create_checklist", "generate_quiz"]
        case .unknown:
            safeActions = ["remember_workspace"]
            blockedActions = ["summarize_visible_content", "create_checklist", "generate_quiz", "summarize_full_document"]
        }

        let acquisitionCount = safeActions.filter { $0 == "explicit_visible_capture_summary" || $0 == "extract_action_items" || $0 == "create_checklist" }.count
        if acquisitionCount > 0 {
            print("[BrowserContextStrategy] converted_blocked_to_acquisition count=\(acquisitionCount)")
            for cap in ["explicit_visible_capture_summary", "extract_action_items", "create_checklist"] where safeActions.contains(cap) {
                print("[AcquisitionSuggestion] capability=\(cap) reason=content_unavailable_but_visible_capture_available output_surface=floating_result_card")
            }
        }
        for cap in ["enable_browser_bridge", "capture_full_document", "capture_visible_page", "select_text_hint"] where safeActions.contains(cap) {
            let reason = contentAvailable ? "content_available" : "content_unavailable"
            print("[SetupActionSuggestion] capability=\(cap) reason=\(reason)")
        }

        let assessment = BrowserContextAssessment(
            kind: kind,
            evidence: evidence,
            contentAvailable: contentAvailable,
            reason: reason,
            safeActions: safeActions,
            blockedActions: blockedActions
        )
        let backgroundListing = containsAny(text: tabTitles.map { $0.lowercased() }, needles: ["rent", "rental", "lease", "listing", "housing", "landlord", "sublet", "roommate"])
        let currentListingSignal = containsAny(text: [host, path, lowerTitle], needles: ["rent", "rental", "lease", "listing", "housing", "landlord", "sublet", "roommate"])
        let currentListing = assessment.kind == .listing
        let backgroundType = backgroundListing && !currentListing ? "listing" : "none"
        print("[BrowserContextStrategy] type=\(assessment.kind.rawValue) evidence=current background_type=\(backgroundType)")
        print("[BrowserContextStrategy] content_available=\(assessment.contentAvailable ? "yes" : "no") reason=\(assessment.reason)")
        print("[BrowserContextStrategy] safe_actions=\(assessment.safeActions.joined(separator: ",")) blocked_actions=\(assessment.blockedActions.joined(separator: ","))")
        // Phase 62 — background contamination check + separate background log.
        let contaminated = !currentListingSignal && currentListing
        print("[BrowserStrategyContaminationCheck] passed=\(contaminated ? "no" : "yes") reason=\(contaminated ? "classified_listing_without_current_focus_signal" : "current_focus_dominates")")
        if backgroundListing && !currentListing {
            print("[BackgroundBrowserStrategy] type=listing shown=no reason=background_only_current_focus_unrelated")
        }
        return assessment
    }

    private static func browserEvidence(url: URL?, title: String?, tabTitles: [String], hasAXText: Bool) -> [String] {
        var evidence: [String] = []
        if url != nil { evidence.append("url") }
        if let title, !title.isEmpty { evidence.append("title") }
        if !tabTitles.isEmpty { evidence.append("tabs") }
        if hasAXText { evidence.append("ax") }
        return evidence.isEmpty ? ["none"] : evidence
    }

    private static func containsAny(text: [String], needles: [String]) -> Bool {
        let haystacks = text.joined(separator: " ")
        return needles.contains { haystacks.contains($0) }
    }
}

enum EvidenceQualityModel {
    /// Pure level logic, no side effects. Shared by `evaluate` and the
    /// AX-enrichment upgrade logger so the "old" vs "new" comparison is honest
    /// (computed by the exact same rule, not re-derived by hand).
    static func computeLevel(
        titleAvailable: Bool,
        urlAvailable: Bool,
        tabCount: Int,
        hasAXText: Bool,
        hasOCR: Bool,
        hasSelectedText: Bool,
        semanticGrounding: Bool,
        durableCompartment: Bool
    ) -> ProgressiveEvidenceLevel {
        if hasSelectedText {
            return .selected_content
        } else if hasAXText || hasOCR {
            return .visible_content
        } else if titleAvailable && (urlAvailable || tabCount >= 1 || semanticGrounding || durableCompartment) {
            return .metadata_rich
        } else if titleAvailable || urlAvailable || tabCount >= 1 {
            return .metadata_only
        } else {
            return .none
        }
    }

    /// Look up the shared EnrichedContextCache for fresh AX/visible enriched text
    /// for the current focus and decide whether it clears the upgrade floor.
    ///
    /// This is the Part 5 plumbing fix: the AX recovery writer in the refresh
    /// loop keys on app|title (url:nil) while the proposal/evidence path keys on
    /// app|title|url, so we probe both. Below `minChars` we honestly refuse the
    /// upgrade with a logged reason instead of silently dropping good AX text.
    struct EnrichedAXResolution {
        let hasAXText: Bool
        let chars: Int
        let source: String
        let quality: String
        let key: String
        let ageSeconds: Int
        let noUpgradeReason: String?
    }

    static func resolveEnrichedAX(
        activeApp: String,
        windowTitle: String,
        url: String?,
        minChars: Int = 60,
        logHit: Bool = true
    ) -> EnrichedAXResolution {
        let cache = EnrichedContextCache.shared
        var probed: [EnrichedContextSnapshot] = []
        let keys = [
            EnrichedContextCache.focusKey(activeApp: activeApp, windowTitle: windowTitle, url: url),
            EnrichedContextCache.focusKey(activeApp: activeApp, windowTitle: windowTitle, url: nil)
        ]
        for key in keys {
            if let snap = cache.lookup(key: key, logHit: false) { probed.append(snap) }
        }
        // Prefer the freshest AX/OCR-bearing snapshot for this focus.
        let snap = probed
            .filter { $0.source.contains("ax") || $0.quality.contains("ax") || $0.source.contains("ocr") || $0.quality.contains("ocr") }
            .sorted { $0.timestamp > $1.timestamp }
            .first
        guard let snap else {
            return EnrichedAXResolution(hasAXText: false, chars: 0, source: "none", quality: "none", key: keys[0], ageSeconds: 0, noUpgradeReason: nil)
        }
        if logHit {
            print("[EnrichedContextCacheHit] key=\(snap.key) source=\(snap.source) chars=\(snap.chars) age_s=\(Int(snap.ageSeconds))")
        }
        if snap.chars < minChars {
            return EnrichedAXResolution(hasAXText: false, chars: snap.chars, source: snap.source, quality: snap.quality, key: snap.key, ageSeconds: Int(snap.ageSeconds), noUpgradeReason: "too_short")
        }
        return EnrichedAXResolution(hasAXText: true, chars: snap.chars, source: snap.source, quality: snap.quality, key: snap.key, ageSeconds: Int(snap.ageSeconds), noUpgradeReason: nil)
    }

    /// Evidence evaluation that consults the EnrichedContextCache for AX text and
    /// emits the Part 5 plumbing proof: [EvidenceQualityInput], plus
    /// [EvidenceQualityUpgrade] / [EvidenceQualityNoUpgrade]. The returned
    /// profile's `hasAXText` reflects real cached AX content, not a hardcoded no.
    static func evaluateWithEnrichment(
        title: String?,
        url: URL?,
        tabTitles: [String],
        baseHasAXText: Bool = false,
        hasOCR: Bool,
        hasSelectedText: Bool,
        semanticGrounding: Bool,
        durableCompartment: Bool,
        browserAssessment: BrowserContextAssessment?,
        activeApp: String,
        windowTitle: String,
        contentHints: Int = 0
    ) -> EvidenceProfile {
        let titleAvailable = !(title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let resolution = resolveEnrichedAX(activeApp: activeApp, windowTitle: windowTitle, url: url?.absoluteString)
        let hasAXText = baseHasAXText || resolution.hasAXText
        print("[EvidenceQualityInput] ax_events=\(resolution.hasAXText ? 1 : 0) content_hints=\(contentHints) chars=\(resolution.chars) source=\(resolution.source)")
        let oldLevel = computeLevel(
            titleAvailable: titleAvailable,
            urlAvailable: url != nil,
            tabCount: tabTitles.count,
            hasAXText: baseHasAXText,
            hasOCR: hasOCR,
            hasSelectedText: hasSelectedText,
            semanticGrounding: semanticGrounding,
            durableCompartment: durableCompartment
        )
        let newLevel = computeLevel(
            titleAvailable: titleAvailable,
            urlAvailable: url != nil,
            tabCount: tabTitles.count,
            hasAXText: hasAXText,
            hasOCR: hasOCR,
            hasSelectedText: hasSelectedText,
            semanticGrounding: semanticGrounding,
            durableCompartment: durableCompartment
        )
        if resolution.hasAXText && newLevel.rank > oldLevel.rank {
            print("[EvidenceQualityUpgrade] old=\(oldLevel.rawValue) new=ax_visible_text reason=ax_enrichment_available chars=\(resolution.chars) level=\(newLevel.rawValue)")
        } else if let reason = resolution.noUpgradeReason {
            print("[EvidenceQualityNoUpgrade] reason=\(reason) chars=\(resolution.chars)")
        }
        return evaluate(
            title: title,
            url: url,
            tabTitles: tabTitles,
            hasAXText: hasAXText,
            hasOCR: hasOCR,
            hasSelectedText: hasSelectedText,
            semanticGrounding: semanticGrounding,
            durableCompartment: durableCompartment,
            browserAssessment: browserAssessment
        )
    }

    static func evaluate(
        title: String?,
        url: URL?,
        tabTitles: [String],
        hasAXText: Bool,
        hasOCR: Bool,
        hasSelectedText: Bool,
        semanticGrounding: Bool,
        durableCompartment: Bool,
        browserAssessment: BrowserContextAssessment?
    ) -> EvidenceProfile {
        let titleAvailable = !(title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let urlAvailable = url != nil
        let tabCount = tabTitles.count

        let level = computeLevel(
            titleAvailable: titleAvailable,
            urlAvailable: urlAvailable,
            tabCount: tabCount,
            hasAXText: hasAXText,
            hasOCR: hasOCR,
            hasSelectedText: hasSelectedText,
            semanticGrounding: semanticGrounding,
            durableCompartment: durableCompartment
        )

        let profile = EvidenceProfile(
            level: level,
            titleAvailable: titleAvailable,
            urlAvailable: urlAvailable,
            tabCount: tabCount,
            hasAXText: hasAXText,
            hasOCR: hasOCR,
            hasSelectedText: hasSelectedText,
            semanticGrounding: semanticGrounding,
            durableCompartment: durableCompartment,
            browserAssessment: browserAssessment
        )
        print("[EvidenceQuality] level=\(profile.level.rawValue) title=\(titleAvailable ? "yes" : "no") url=\(urlAvailable ? "yes" : "no") tabs=\(tabCount) ax_text=\(hasAXText ? "yes" : "no") ocr=\(hasOCR ? "yes" : "no") selected_text=\(hasSelectedText ? "yes" : "no") semantic_grounding=\(semanticGrounding ? "yes" : "no") durable_compartment=\(durableCompartment ? "yes" : "no")")
        return profile
    }

    static func level(from raw: String) -> ProgressiveEvidenceLevel {
        ProgressiveEvidenceLevel.from(raw: raw)
    }

    static func shouldAllowTextArtifacts(_ level: ProgressiveEvidenceLevel) -> Bool {
        level.rank >= ProgressiveEvidenceLevel.visible_content.rank
    }

    static func shouldAllowMetadataActions(_ level: ProgressiveEvidenceLevel) -> Bool {
        level.rank >= ProgressiveEvidenceLevel.metadata_rich.rank
    }

    static func nextContextNeeded(for current: ProgressiveEvidenceLevel, required: ProgressiveEvidenceLevel) -> String {
        if current.rank >= required.rank { return "none" }
        return current.nextContextNeeded
    }
}

// MARK: - Phase 35 Action Registry

struct ActionRegistryEntry: Sendable {
    let capabilityId: String
    let requiredEvidence: ProgressiveEvidenceLevel
    let executionMode: ExecutionMode
    let scope: String
    let fallback: String
}

struct ActionEligibility: Sendable {
    let capabilityId: String
    let requiredEvidence: ProgressiveEvidenceLevel
    let currentEvidence: ProgressiveEvidenceLevel
    let eligible: Bool
    let reason: String
    let nextContextNeeded: String
}

enum ActionRegistry {
    private static let entries: [String: ActionRegistryEntry] = {
        let all: [ActionRegistryEntry] = [
            .init(capabilityId: "arrange_side_by_side", requiredEvidence: .metadata_rich, executionMode: .local_action, scope: "visible", fallback: "Need another visible app or tab target."),
            .init(capabilityId: "switch_to_paired_app", requiredEvidence: .metadata_rich, executionMode: .local_action, scope: "visible", fallback: "Need a durable paired app target."),
            .init(capabilityId: "restore_workspace", requiredEvidence: .metadata_rich, executionMode: .local_action, scope: "visible", fallback: "Need a durable workspace and something missing."),
            .init(capabilityId: "restore_research_tabs", requiredEvidence: .metadata_rich, executionMode: .local_action, scope: "visible", fallback: "Need stored URLs or browser tabs."),
            .init(capabilityId: "split_research_setup", requiredEvidence: .metadata_rich, executionMode: .local_action, scope: "visible", fallback: "Need two related URLs or tabs."),
            .init(capabilityId: "collect_references", requiredEvidence: .metadata_rich, executionMode: .local_action, scope: "visible", fallback: "Need URLs or tab references."),
            .init(capabilityId: "copy_current_url", requiredEvidence: .metadata_rich, executionMode: .local_action, scope: "visible", fallback: "Need a current browser URL."),
            .init(capabilityId: "remember_workspace", requiredEvidence: .metadata_rich, executionMode: .local_action, scope: "visible", fallback: "Need enough workspace metadata to remember."),
            .init(capabilityId: "open_current_task_panel", requiredEvidence: .metadata_rich, executionMode: .local_action, scope: "visible", fallback: "Need trusted metadata context to open the task panel."),
            .init(capabilityId: "open_related_app_set", requiredEvidence: .metadata_rich, executionMode: .local_action, scope: "visible", fallback: "Need related apps to open."),
            .init(capabilityId: "enable_reduce_interruptions", requiredEvidence: .metadata_rich, executionMode: .local_action, scope: "visible", fallback: "Need a durable focus context."),
            .init(capabilityId: "play_focus_media", requiredEvidence: .metadata_rich, executionMode: .local_action, scope: "visible", fallback: "Need a work context compatible with background audio."),
            .init(capabilityId: "copy_result_to_clipboard", requiredEvidence: .metadata_only, executionMode: .local_action, scope: "visible", fallback: "Need generated text to copy."),
            .init(capabilityId: "summarize_visible_content", requiredEvidence: .visible_content, executionMode: .preview_only, scope: "visible", fallback: "Need visible AX or OCR text."),
            .init(capabilityId: "explain_context", requiredEvidence: .visible_content, executionMode: .preview_only, scope: "visible", fallback: "Need visible content, not metadata only."),
            .init(capabilityId: "extract_action_items", requiredEvidence: .visible_content, executionMode: .preview_only, scope: "visible", fallback: "Need visible content, not metadata only."),
            .init(capabilityId: "rewrite_text", requiredEvidence: .selected_content, executionMode: .preview_only, scope: "selected", fallback: "Need selected text."),
            .init(capabilityId: "improve_text", requiredEvidence: .selected_content, executionMode: .preview_only, scope: "selected", fallback: "Need selected text."),
            .init(capabilityId: "draft_reply", requiredEvidence: .selected_content, executionMode: .preview_only, scope: "selected", fallback: "Need selected content or full document context."),
            .init(capabilityId: "generate_quiz", requiredEvidence: .full_content, executionMode: .preview_only, scope: "full", fallback: "Need full study material, not just titles."),
            .init(capabilityId: "create_review_plan", requiredEvidence: .full_content, executionMode: .preview_only, scope: "full", fallback: "Need fuller content to create a grounded plan."),
            .init(capabilityId: "create_checklist", requiredEvidence: .visible_content, executionMode: .preview_only, scope: "visible", fallback: "Need visible content to extract a checklist."),
            .init(capabilityId: "compare_options", requiredEvidence: .full_content, executionMode: .preview_only, scope: "full", fallback: "Need comparable content, not just metadata."),
            .init(capabilityId: "compare_rental_options", requiredEvidence: .full_content, executionMode: .preview_only, scope: "full", fallback: "Need listing facts before comparing rentals."),
            .init(capabilityId: "synthesize_sources", requiredEvidence: .full_content, executionMode: .preview_only, scope: "full", fallback: "Need source text or extracted content."),
            .init(capabilityId: "create_questions_to_ask_landlord", requiredEvidence: .visible_content, executionMode: .preview_only, scope: "visible", fallback: "Need visible listing facts first."),
            .init(capabilityId: "draft_listing_ad", requiredEvidence: .visible_content, executionMode: .preview_only, scope: "visible", fallback: "Need visible listing facts first."),
            .init(capabilityId: "create_listing_checklist", requiredEvidence: .visible_content, executionMode: .preview_only, scope: "visible", fallback: "Need visible listing facts first."),
            .init(capabilityId: "explicit_visible_capture_summary", requiredEvidence: .visible_content, executionMode: .preview_only, scope: "visible", fallback: "Need visible content to summarize.")
        ]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.capabilityId, $0) })
    }()

    static func entry(for capabilityId: String) -> ActionRegistryEntry {
        entries[capabilityId] ?? .init(
            capabilityId: capabilityId,
            requiredEvidence: .metadata_rich,
            executionMode: .preview_only,
            scope: "visible",
            fallback: "Need more context to safely execute this action."
        )
    }

    @discardableResult
    static func evaluate(
        capabilityId: String,
        currentEvidence: ProgressiveEvidenceLevel,
        hasURLs: Bool = false,
        isTyping: Bool = false,
        hasSelection: Bool = false
    ) -> ActionEligibility {
        let entry = entry(for: capabilityId)
        var eligibleByLevel = currentEvidence.rank >= entry.requiredEvidence.rank
        var extraGuard = true
        var reason = eligibleByLevel ? "ok" : "insufficient_context"

        // Let's identify the required evidence category for research action logs
        let logReqEvidence: String = {
            if entry.requiredEvidence == .selected_content { return "selected_text" }
            if entry.requiredEvidence == .visible_content { return "visible_capture" }
            if entry.requiredEvidence == .full_content { return "full_content" }
            return "metadata_plus_user_acquisition"
        }()

        var allowedByGate = eligibleByLevel
        var gateReason = eligibleByLevel ? "ok" : "insufficient_context"

        // Rule C1: Do not allow fake "Synthesize findings" (synthesize_sources) from metadata-only.
        if capabilityId == "synthesize_sources" && currentEvidence.rank < ProgressiveEvidenceLevel.visible_content.rank {
            allowedByGate = false
            gateReason = "content_unavailable_metadata_only"
            eligibleByLevel = false
            extraGuard = false
            reason = "content_unavailable_metadata_only"
            print("[GeneratedActionEvidenceGate] blocked capability=\(capabilityId) reason=content_unavailable_metadata_only")
        }

        // Rule C2: Explicit acquisition-based actions are allowed if user-initiated acquisition is available
        let acquisitionCapabilities: Set<String> = [
            "explicit_visible_capture_summary", "extract_action_items", "create_checklist"
        ]
        if acquisitionCapabilities.contains(capabilityId) && currentEvidence.rank < ProgressiveEvidenceLevel.visible_content.rank {
            allowedByGate = true
            gateReason = "user_initiated_acquisition"
            eligibleByLevel = true
            extraGuard = true
            reason = "user_initiated_acquisition"
            print("[GeneratedActionEvidenceGate] allowed capability=\(capabilityId) reason=user_initiated_acquisition")
            print("[AcquisitionAction] capability=\(capabilityId) acquisition_type=visible_capture user_initiated=yes")
            
            let prompt: String = {
                if capabilityId == "explicit_visible_capture_summary" { return "Read visible page and summarize" }
                if capabilityId == "extract_action_items" { return "Extract action items from visible page" }
                return "Capture visible text and make checklist"
            }()
            print("[AcquisitionSuggestion] capability=\(capabilityId) prompt=\"\(prompt)\" acquisition=visible_capture output_surface=floating_result_card")
        }

        // Print research action log if applicable
        let isResearchAction = ["synthesize_sources", "compare_options", "summarize_visible_content", "extract_action_items", "create_checklist", "rewrite_text", "explain_context", "draft_reply", "explicit_visible_capture_summary"].contains(capabilityId)
        if isResearchAction {
            print("[ResearchActionGate] capability=\(capabilityId) allowed=\(allowedByGate ? "yes" : "no") evidence=\(logReqEvidence) reason=\(gateReason)")
        }

        if hasSelection && ["rewrite_text", "explain_context", "draft_reply"].contains(capabilityId) {
            print("[AcquisitionAction] capability=\(capabilityId) acquisition_type=selected_text user_initiated=yes")
        }

        if isTyping && capabilityId == "restore_workspace" {
            extraGuard = false
            reason = "user_typing"
        } else if capabilityId == "collect_references" && !hasURLs {
            extraGuard = false
            reason = "missing_urls"
        } else if capabilityId == "copy_current_url" && !hasURLs {
            extraGuard = false
            reason = "missing_current_url"
        } else if capabilityId == "rewrite_text" && !hasSelection {
            extraGuard = false
            reason = "missing_selection"
        } else if reason == "insufficient_context" || reason == "content_unavailable_metadata_only" || reason == "user_initiated_acquisition" {
            // keep it as is
        } else if reason != "user_initiated_acquisition_available" {
            if eligibleByLevel,
               ["copy_current_url", "collect_references", "remember_workspace", "open_current_task_panel"].contains(capabilityId),
               currentEvidence.rank >= ProgressiveEvidenceLevel.metadata_rich.rank {
                reason = "metadata_safe"
            } else {
                reason = eligibleByLevel ? "ok" : "insufficient_context"
            }
        }

        let eligible = eligibleByLevel && extraGuard
        let next = eligible ? "none" : EvidenceQualityModel.nextContextNeeded(for: currentEvidence, required: entry.requiredEvidence)
        print("[ActionRegistry] capability=\(capabilityId) required_evidence=\(entry.requiredEvidence.rawValue) current_evidence=\(currentEvidence.rawValue) eligible=\(eligible ? "yes" : "no") reason=\(reason)")
        if !eligible {
            print("[ActionRegistry] blocked capability=\(capabilityId) reason=\(reason) required=\(entry.requiredEvidence.rawValue) current=\(currentEvidence.rawValue)")
        }
        return ActionEligibility(
            capabilityId: capabilityId,
            requiredEvidence: entry.requiredEvidence,
            currentEvidence: currentEvidence,
            eligible: eligible,
            reason: reason,
            nextContextNeeded: next
        )
    }
}

enum QuietDecisionLogger {
    static func emit(
        shown: Bool,
        reason: String,
        bestBlockedAction: String?,
        missingContext: String,
        nextContextNeeded: String,
        panelActionsAvailable: Bool = false,
        panelCount: Int = 0
    ) {
        print("[QuietDecision] shown=\(shown ? "yes" : "no") reason=\(reason) best_blocked_action=\(bestBlockedAction ?? "none") missing_context=\(missingContext) panel_actions_available=\(panelActionsAvailable ? "yes" : "no") panel_count=\(panelCount)")
        print("[QuietDecision] next_context_needed=\(nextContextNeeded)")
    }
}

struct DeterministicPanelPlannerInput: Sendable {
    let activeAppName: String
    let windowTitle: String?
    let browserAppName: String?
    let currentURL: String?
    let tabTitles: [String]
    let visibleApps: [String]
    let workflow: String
    let compartmentLabel: String?
    let compartment: TaskCompartment?
    let evidenceLevel: ProgressiveEvidenceLevel
    let browserAssessment: BrowserContextAssessment?
    let hasDurablePattern: Bool
    let frictionSignals: [FrictionSignal]
    // Phase 53 — liquid routing inputs (defaulted so existing call sites compile).
    let selectedTextLength: Int
    let recentlyRejectedCapabilityIds: Set<String>
    let recentlyAcceptedCapabilityIds: Set<String>

    init(
        activeAppName: String,
        windowTitle: String?,
        browserAppName: String?,
        currentURL: String?,
        tabTitles: [String],
        visibleApps: [String],
        workflow: String,
        compartmentLabel: String?,
        compartment: TaskCompartment?,
        evidenceLevel: ProgressiveEvidenceLevel,
        browserAssessment: BrowserContextAssessment?,
        hasDurablePattern: Bool,
        frictionSignals: [FrictionSignal],
        selectedTextLength: Int = 0,
        recentlyRejectedCapabilityIds: Set<String> = [],
        recentlyAcceptedCapabilityIds: Set<String> = []
    ) {
        self.activeAppName = activeAppName
        self.windowTitle = windowTitle
        self.browserAppName = browserAppName
        self.currentURL = currentURL
        self.tabTitles = tabTitles
        self.visibleApps = visibleApps
        self.workflow = workflow
        self.compartmentLabel = compartmentLabel
        self.compartment = compartment
        self.evidenceLevel = evidenceLevel
        self.browserAssessment = browserAssessment
        self.hasDurablePattern = hasDurablePattern
        self.frictionSignals = frictionSignals
        self.selectedTextLength = selectedTextLength
        self.recentlyRejectedCapabilityIds = recentlyRejectedCapabilityIds
        self.recentlyAcceptedCapabilityIds = recentlyAcceptedCapabilityIds
    }
}

struct DeterministicPanelCandidate: Sendable {
    let candidate: PortfolioCandidate
    let involvedApps: [String]
    let involvedURLs: [String]
    let browserTabTitles: [String]
    let browserAppName: String?
    let workflow: String
    let compartmentLabel: String?
    let windowTitle: String?
    let entity: String?
    let compartment: TaskCompartment?
    // Phase 36: proposal-time target contract — set for layout actions
    let targetContract: ActionTargetContract?
}

struct DeterministicPanelPlannerResult: Sendable {
    let validCandidates: [DeterministicPanelCandidate]
    let suppressedCount: Int
    /// Phase 61 — capability ids that passed the contract/worthiness pipeline.
    /// The panel bridge rejects anything outside this set: fallback storage can
    /// never restore an action the quality path did not approve.
    var gatedCapabilityIds: Set<String> = []
}

enum DeterministicPanelActionPlanner {
    static func evaluate(_ input: DeterministicPanelPlannerInput) -> DeterministicPanelPlannerResult {
        guard input.evidenceLevel.rank >= ProgressiveEvidenceLevel.metadata_rich.rank else {
            return DeterministicPanelPlannerResult(validCandidates: [], suppressedCount: 0)
        }

        let safeActions = Set(input.browserAssessment?.safeActions ?? [])
        let activeSwitching = input.frictionSignals.contains {
            $0.type == .repeated_app_switching || $0.type == .repeated_tab_switching
        }
        var validCandidates: [DeterministicPanelCandidate] = []
        var suppressedCount = 0

        func makeCandidate(
            lane: PortfolioCandidate.Lane,
            capabilityId: String,
            title: String,
            confidence: Double,
            usefulness: Double,
            executability: Double,
            reason: String,
            involvedApps: [String],
            involvedURLs: [String],
            browserTabTitles: [String]
        ) {
            let eligibility = ActionRegistry.evaluate(
                capabilityId: capabilityId,
                currentEvidence: input.evidenceLevel,
                hasURLs: !involvedURLs.isEmpty,
                hasSelection: false
            )
            guard eligibility.eligible else {
                suppressedCount += 1
                print("[PanelCandidate] capability=\(capabilityId) lane=\(lane.rawValue) valid_payload=no reason=\(eligibility.reason)")
                return
            }

            let payload = LocalActionPayloadValidator.validate(
                capabilityId: capabilityId,
                involvedApps: involvedApps,
                involvedURLs: involvedURLs,
                browserTabTitles: browserTabTitles,
                compartmentLabel: input.compartmentLabel
            )
            let panelReason: String = {
                if capabilityId == "arrange_side_by_side" && !activeSwitching {
                    return "below_floating_threshold_but_valid"
                }
                return reason
            }()
            print("[PanelCandidate] capability=\(capabilityId) lane=\(lane.rawValue) valid_payload=\(payload.valid ? "yes" : "no") reason=\(payload.valid ? panelReason : payload.reason)")
            guard payload.valid else {
                suppressedCount += 1
                return
            }

            // Phase 36: build target contract for layout actions at proposal time
            let layoutCapabilities: Set<String> = ["arrange_side_by_side", "switch_to_paired_app", "split_research_setup"]
            let proposalContract: ActionTargetContract? = layoutCapabilities.contains(capabilityId) && involvedApps.count >= 2
                ? ActionTargetContract.forLayoutApps(
                    capabilityID: capabilityId,
                    appNames: involvedApps,
                    evidenceType: .active_window_pair,
                    confidence: confidence,
                    fallbackAllowed: false
                )
                : nil
            if let contract = proposalContract {
                print("[ProposalTargetBinding] capability=\(capabilityId) contract_id=\(contract.contractID) primary=\(contract.targets.first.map { "\($0.role)/\($0.appName ?? "?")" } ?? "none") secondary=\(contract.targets.dropFirst().first.map { "\($0.role)/\($0.appName ?? "?")" } ?? "none") source=\(contract.evidenceType.rawValue) fallback_allowed=no expires_in_s=\(Int(contract.expirySeconds))")
            }

            validCandidates.append(
                DeterministicPanelCandidate(
                    candidate: PortfolioCandidate(
                        lane: lane,
                        title: title,
                        capabilityId: capabilityId,
                        executionMode: .local_action,
                        confidence: confidence,
                        usefulness: usefulness,
                        executability: executability,
                        novelty: 1.0,
                        reason: reason,
                        requiredEvidence: input.evidenceLevel.rawValue,
                        requiresConfirmation: false,
                        involvedApps: involvedApps,
                        frictionOpportunity: nil,
                        musicIntent: nil,
                        generatedAction: nil,
                        sourcePath: "deterministic_panel",
                        targetContract: proposalContract
                    ),
                    involvedApps: involvedApps,
                    involvedURLs: payload.urls,
                    browserTabTitles: browserTabTitles,
                    browserAppName: input.browserAppName,
                    workflow: input.workflow,
                    compartmentLabel: input.compartmentLabel,
                    windowTitle: input.windowTitle,
                    entity: input.windowTitle,
                    compartment: input.compartment,
                    targetContract: proposalContract
                )
            )
        }

        let urls = input.currentURL.map { [$0] } ?? []
        let metadataTabs = Array(input.tabTitles.prefix(8))
        let visibleApps = Array(NSOrderedSet(array: input.visibleApps)) as? [String] ?? input.visibleApps

        if safeActions.contains("copy_current_url"), !urls.isEmpty {
            makeCandidate(
                lane: .metadata,
                capabilityId: "copy_current_url",
                title: "Copy this page link?",
                confidence: 0.56,
                usefulness: 0.28,
                executability: 0.88,
                reason: "metadata_safe_valid_payload",
                involvedApps: [],
                involvedURLs: urls,
                browserTabTitles: metadataTabs
            )
        }

        if safeActions.contains("collect_references"), !urls.isEmpty {
            makeCandidate(
                lane: .metadata,
                capabilityId: "collect_references",
                title: "Collect links from this context?",
                confidence: 0.54,
                usefulness: 0.24,
                executability: 0.84,
                reason: "metadata_safe_valid_payload",
                involvedApps: [],
                involvedURLs: urls,
                browserTabTitles: metadataTabs
            )
        }

        if safeActions.contains("remember_workspace"), !input.hasDurablePattern {
            makeCandidate(
                lane: .metadata,
                capabilityId: "remember_workspace",
                title: "Remember this workspace?",
                confidence: 0.52,
                usefulness: 0.18,
                executability: 0.82,
                reason: "metadata_safe_valid_payload",
                involvedApps: visibleApps,
                involvedURLs: urls,
                browserTabTitles: metadataTabs
            )
        }

        if safeActions.contains("open_current_task_panel") && validCandidates.isEmpty {
            makeCandidate(
                lane: .metadata,
                capabilityId: "open_current_task_panel",
                title: "Open the current task panel?",
                confidence: 0.50,
                usefulness: 0.14,
                executability: 0.95,
                reason: "metadata_safe_valid_payload",
                involvedApps: [],
                involvedURLs: urls,
                browserTabTitles: metadataTabs
            )
        }

        if safeActions.contains("arrange_side_by_side") {
            // Phase 41 — deterministic panel must respect the same ArrangeRequirement gate as
            // floating path. Visibility-only (two apps open but no repeated user switching) is
            // not sufficient. Only add to panel when activeSwitching is proven.
            if activeSwitching {
                print("[ArrangeRequirement] source=deterministic_panel target_validity=pass active_friction=pass layout_reliability=pass allowed=yes")
                let arrangeTitle: String = {
                    let primaryRaw = input.browserAssessment?.kind == .google_docs
                        ? "Google Doc"
                        : (input.windowTitle ?? input.tabTitles.first ?? "this page")
                    let secondaryRaw: String = {
                        if visibleApps.contains("Preview") { return "the PDF" }
                        if input.tabTitles.count >= 2 { return input.tabTitles[1] }
                        return "the other window"
                    }()
                    let primary = SuggestionTitleRewriter.semanticRoleLabel(for: primaryRaw)
                    let secondary = SuggestionTitleRewriter.semanticRoleLabel(for: secondaryRaw)
                    print("[SuggestionTitleContext] capability=arrange_side_by_side source=work_pair primary=\"\(primary)\" secondary=\"\(secondary)\"")
                    return "Put \(primary) beside \(secondary)?"
                }()
                makeCandidate(
                    lane: .friction,
                    capabilityId: "arrange_side_by_side",
                    title: arrangeTitle,
                    confidence: 0.70,
                    usefulness: 0.42,
                    executability: 0.88,
                    reason: "layout_friction_proven",
                    involvedApps: visibleApps,
                    involvedURLs: urls,
                    browserTabTitles: metadataTabs
                )
            } else {
                print("[ArrangeRequirement] source=deterministic_panel target_validity=pass active_friction=fail allowed=no reason=no_active_user_friction")
                print("[PanelAction] hidden capability=arrange_side_by_side reason=requirements_failed active_friction=no")
                suppressedCount += 1
            }
        }

        // Phase 53 — Liquid workflow routing: specific workflow actions are
        // generated BEFORE the generic acquisition trio and demote it.
        let plannerURL = input.currentURL.flatMap(URL.init(string:))
        let plannerEnrichedContext = EnrichedContextCache.shared.lookup(
            key: EnrichedContextCache.focusKey(
                activeApp: input.activeAppName,
                windowTitle: input.windowTitle ?? input.tabTitles.first ?? "",
                url: input.currentURL
            )
        )
        let liquidSignals = WorkflowSignals(
            activeApp: input.activeAppName,
            windowTitle: input.windowTitle ?? input.tabTitles.first ?? "",
            urlHost: plannerURL?.host ?? "",
            urlPath: plannerURL?.path ?? "",
            tabTitles: input.tabTitles,
            selectedTextLength: input.selectedTextLength,
            contentAvailable: input.evidenceLevel.rank >= ProgressiveEvidenceLevel.visible_content.rank
                || (plannerEnrichedContext?.chars ?? 0) >= 80,
            workflow: input.workflow,
            visibleAppNames: input.visibleApps,
            enrichedContext: plannerEnrichedContext
        )
        // Phase 69 — Issue 4: current-focus authority demotes background-only
        // lease/listing classifications before the planner builds an action pack.
        let (composedContent, composedAuthority) = CurrentFocusContentTypeGate.classifyWithAuthority(liquidSignals)
        CurrentFocusContentTypeGate.leaseListingAllowed(content: composedContent, authority: composedAuthority)
        let composedCluster = ComparableCandidateDetector.detect(signals: liquidSignals, content: composedContent)
        let composedActivity = BrowserActivityClassifier.classify(signals: liquidSignals, content: composedContent, cluster: composedCluster)
        let composedEvidence = EvidenceSnapshot.evaluate(signals: liquidSignals, content: composedContent, cluster: composedCluster)
        let composedPlans = ComposedActionPlanner.plansFor(
            signals: liquidSignals,
            content: composedContent,
            activity: composedActivity,
            cluster: composedCluster,
            evidence: composedEvidence
        )
        var composedCapabilityIds: [String] = []
        for plan in composedPlans.prefix(2) {
            let validation = ComposedActionValidator.validate(plan, surface: .panel)
            print("[PlannerToolchainValidation] valid=\(validation.valid ? "yes" : "no") reason=\(validation.reason)")
            guard validation.valid else { continue }
            let identity = ComposedActionUIRegistry.register(plan: plan, signals: liquidSignals, capturedText: liquidSignals.enrichedContext?.text, surface: "panel")
            let capabilityId = identity.uiID
            composedCapabilityIds.append(capabilityId)
            print("[DogfoodComposedOpportunity] id=\(capabilityId) title=\"\(identity.title)\" context=\(composedContent.type.rawValue) activity=\(composedActivity.activity.rawValue)")
            print("[ComposedActionSurfaceDecision] id=\(capabilityId) surface=panel reason=composed_action_plan_\(plan.executionMode.rawValue)")
            makeCandidate(
                lane: .research,
                capabilityId: capabilityId,
                title: plan.userVisibleTitle,
                confidence: plan.confidence,
                usefulness: plan.executionMode == .panelOnly ? 0.50 : 0.84,
                executability: plan.executionMode == .captureFirst ? 0.72 : 0.86,
                reason: "composed_action_plan_\(plan.executionMode.rawValue)",
                involvedApps: [],
                involvedURLs: urls,
                browserTabTitles: metadataTabs
            )
            print("[ComposedActionRender] id=\(plan.id) title=\"\(plan.userVisibleTitle)\" mode=\(plan.executionMode.rawValue) followups=\(plan.followups.count)")
            print("[PrimitiveIdLeakCheck] leaked=\(plan.userVisibleTitle.contains("_") ? "yes" : "no") terms=\(plan.userVisibleTitle.contains("_") ? "underscore" : "none")")
            print("[NonListingActionOpportunity] content_type=\(composedContent.type.rawValue) surfaced=\(plan.id) reason=composed_panel_candidate")
        }
        let liquidSelection = LiquidActionRouter.route(
            LiquidRoutingInput(
                signals: liquidSignals,
                existingCandidateIds: Set(validCandidates.map { $0.candidate.capabilityId }),
                recentlyRejected: input.recentlyRejectedCapabilityIds,
                recentlyAccepted: input.recentlyAcceptedCapabilityIds
            )
        )
        // Phase 63: Liquid actions are now completely unified. We no longer pre-select a floating candidate.
        // We pass the entire panel portfolio to the UnifiedSurfaceArbiter.
        let liquidFloat = LiquidActionRouter.floatingCandidate(from: liquidSelection, signals: liquidSignals)
        let liquidWorkflowSpecificCount = liquidSelection.panel.filter { id in
            guard let action = WorkflowActionOntology.byId[id], action.isSpecificAction else { return false }
            switch action.category {
            case .formsApplications, .documentsLeases, .codeLogs, .browserResearch, .writingEditing, .communication:
                return true
            case .workspaceFriction, .mediaFocus, .memoryWorkflows, .setupAcquisition:
                return false
            }
        }.count
        for liquidId in liquidSelection.panel {
            guard let action = WorkflowActionOntology.byId[liquidId] else { continue }
            let tierInfo = LiquidActionRouter.executionTier(for: action, signals: liquidSignals)
            let hardcodeGate = UserVisibleHardcodeGate.evaluate(
                actionID: liquidId,
                signals: liquidSignals,
                content: composedContent,
                tier: tierInfo.tier,
                captureNeeded: tierInfo.tier == 2
            )
            if !hardcodeGate.allowed {
                UserVisibleHardcodeGate.log(surface: "panel", id: liquidId, decision: hardcodeGate)
                continue
            }
            // Generic ontology entries still respect the Phase 52 safeActions gating
            // (no generic cognitive spam on metadata-only pages).
            if !action.isSpecificAction && !safeActions.contains(liquidId) {
                print("[GenericActionDemotion] id=\(liquidId) reason=weak_context")
                continue
            }
            let lane: PortfolioCandidate.Lane = {
                switch action.category {
                case .formsApplications, .documentsLeases, .browserResearch, .codeLogs, .setupAcquisition:
                    return .research
                case .writingEditing, .communication:
                    return .cognitive
                case .workspaceFriction:
                    return .friction
                case .mediaFocus:
                    return .music
                case .memoryWorkflows:
                    return .metadata
                }
            }()
            if action.category == .formsApplications {
                print("[FormActionCandidate] id=\(liquidId) reason=form_workflow_detected")
            }
            if action.category == .documentsLeases {
                print("[RentalActionCandidate] id=\(liquidId) reason=rental_workflow_detected")
            }
            if action.category == .codeLogs {
                print("[CodeActionCandidate] id=\(liquidId) reason=code_workflow_detected")
            }
            let liquidTitle = LiquidActionRouter.displayTitle(for: action, signals: liquidSignals)
            makeCandidate(
                lane: lane,
                capabilityId: liquidId,
                title: liquidTitle,
                confidence: action.isSpecificAction ? 0.75 : 0.66,
                usefulness: action.isSpecificAction ? 0.78 : 0.35,
                executability: 0.80,
                reason: "liquid_workflow_\(action.category.rawValue)",
                involvedApps: [],
                involvedURLs: urls,
                browserTabTitles: metadataTabs
            )
            if liquidFloat.id == liquidId {
                print("[VisibleGeneratedAction] shown id=\(liquidId) source=liquid_router")
                print("[DynamicActionUX] visible reason=liquid_action_available")
            }
        }

        // Phase 53/55 — Weak context rule: surface generic setup only when the
        // liquid router did not already create specific capture-needed actions.
        let hasLiquidContentAction = liquidSelection.panel.contains {
            WorkflowActionOntology.byId[$0]?.executionKind == .contentInsight
        }
        if liquidWorkflowSpecificCount >= 2 && input.evidenceLevel.rank < ProgressiveEvidenceLevel.visible_content.rank {
            for setupId in ["capture_visible_page", "capture_full_document", "enable_browser_bridge", "select_text_hint"] where safeActions.contains(setupId) {
                print("[GenericCaptureDemotion] reason=specific_capture_available")
                print("[CheapPortfolioDemotion] capability=\(setupId) reason=liquid_workflow_available")
                suppressedCount += 1
            }
        } else if input.evidenceLevel.rank < ProgressiveEvidenceLevel.visible_content.rank || !hasLiquidContentAction {
            let setupPreference = ["capture_visible_page", "capture_full_document", "enable_browser_bridge", "select_text_hint"]
            if let setupId = setupPreference.first(where: { safeActions.contains($0) }) {
                let setupTitle = CognitiveCapabilityRegistry.shared.get(setupId)?.label ?? "Capture visible page"
                makeCandidate(
                    lane: .research,
                    capabilityId: setupId,
                    title: setupTitle,
                    confidence: 0.62,
                    usefulness: 0.4,
                    executability: 0.9,
                    reason: "weak_context_setup_path",
                    involvedApps: [],
                    involvedURLs: urls,
                    browserTabTitles: metadataTabs
                )
            }
        }

        // Phase 40/43 — Generic acquisition trio. Phase 53: demoted whenever the
        // liquid router produced specific workflow actions.
        let acquisitionCapabilities: [(String, String, Double)] = [
            ("explicit_visible_capture_summary", "Summarize visible content", 0.72),
            ("extract_action_items", "Extract action items", 0.68),
            ("create_checklist", "Make a checklist", 0.65)
        ]
        if liquidWorkflowSpecificCount >= 2 {
            for (capId, _, _) in acquisitionCapabilities where safeActions.contains(capId) && !liquidSelection.panel.contains(capId) {
                print("[GenericCaptureDemotion] reason=specific_capture_available")
                print("[GenericActionDemotion] id=\(capId) reason=specific_action_available")
                suppressedCount += 1
            }
        } else {
            for (capId, title, usefulness) in acquisitionCapabilities
            where safeActions.contains(capId) && !liquidSelection.panel.contains(capId) {
                print("[ResearchLane] generated capability=\(capId) evidence=metadata_rich acquisition=visible_capture surface=panel_or_floating")
                makeCandidate(
                    lane: .research,
                    capabilityId: capId,
                    title: title,
                    confidence: 0.68,
                    usefulness: usefulness,
                    executability: 0.80,
                    reason: "document_context_acquisition_available",
                    involvedApps: [],
                    involvedURLs: urls,
                    browserTabTitles: metadataTabs
                )
            }
        }

        let liquidIds = liquidSelection.panel
        let cheapIds = validCandidates
            .map { $0.candidate.capabilityId }
            .filter { !liquidIds.contains($0) }
        let finalIds = validCandidates.map { $0.candidate.capabilityId }
        print("[LiquidPortfolioMerge] composed=\(composedCapabilityIds.joined(separator: ",")) liquid=\(liquidIds.joined(separator: ",")) cheap=\(cheapIds.joined(separator: ",")) final=\(finalIds.joined(separator: ","))")

        return DeterministicPanelPlannerResult(
            validCandidates: validCandidates,
            suppressedCount: suppressedCount,
            gatedCapabilityIds: Set(validCandidates.map { $0.candidate.capabilityId })
        )
    }
}

// MARK: - Phase 35 Durable Memory

enum DurableMemoryActionEvent: String, Sendable, Codable {
    case accepted
    case dismissed
    case ignored
    case autoDismissed = "auto_dismissed"
}

struct DurableMemoryContext: Sendable, Codable, Equatable {
    let workflow: String
    let compartment: String
    let app: String
    let activity: String
    let browserType: String

    var compactDescription: String {
        "\(workflow)|\(compartment)|\(app)|\(activity)|\(browserType)"
    }

    static func build(
        workflow: String?,
        compartment: String?,
        app: String?,
        activity: String?,
        browserType: String?
    ) -> DurableMemoryContext {
        DurableMemoryContext(
            workflow: (workflow ?? "unknown").lowercased(),
            compartment: (compartment ?? "none").lowercased(),
            app: (app ?? "unknown").lowercased(),
            activity: (activity ?? "unknown").lowercased(),
            browserType: (browserType ?? "none").lowercased()
        )
    }
}

enum WorkspaceStoredItemState: String, Sendable, Codable, Equatable {
    case presentVisible = "present_visible"
    case presentBackgrounded = "present_backgrounded"
    case presentNotArranged = "present_not_arranged"
    case minimized
    case missing
}

struct WorkspaceAppRecord: Codable, Sendable, Equatable {
    var bundleID: String
    var appName: String
}

struct WorkspaceWindowRecord: Codable, Sendable, Equatable {
    var normalizedTitle: String
    var appBundleID: String
    var appName: String
    var semanticRole: String?
}

struct WorkspaceURLRecord: Codable, Sendable, Equatable {
    var normalizedDomain: String
    var pathHash: String
    var readableTitle: String
    var sourceApp: String

    var urlKey: String {
        "\(normalizedDomain)#\(pathHash)"
    }
}

struct WorkspaceDocumentRecord: Codable, Sendable, Equatable {
    var normalizedTitle: String
    var fileExtension: String?
    var appName: String
    var semanticRole: String?
}

struct WorkspaceBrowserTabRecord: Codable, Sendable, Equatable {
    var title: String
    var urlKey: String?
    var normalizedDomain: String?
    var isSelected: Bool
    var isRecent: Bool
}

struct WorkspaceItemStatus: Sendable, Equatable {
    let item: String
    let type: String
    let state: WorkspaceStoredItemState
    let present: Bool
    let visible: Bool
    let executable: Bool
    let reason: String
}

struct WorkspaceRuntimeInventory: Sendable {
    var runningApps: [WorkspaceAppRecord]
    var visibleWindows: [WindowSnapshot]
    var browserTabTitles: [String]
    var currentURLs: [String]
    var frontmostAppName: String
    var frontmostBundleID: String
}

enum WorkspaceRuntimeInventoryProvider {
    static var testSnapshot: WorkspaceRuntimeInventory?

    static func snapshot() -> WorkspaceRuntimeInventory {
        if let testSnapshot {
            return testSnapshot
        }

        let runningApps = NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && ($0.activationPolicy == .regular || $0.activationPolicy == .accessory) }
            .map {
                WorkspaceAppRecord(
                    bundleID: $0.bundleIdentifier ?? "",
                    appName: $0.localizedName ?? ""
                )
            }
            .filter { !$0.appName.isEmpty }

        let visibleWindows = WindowDiscovery.discoverAll()
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostAppName = frontmost?.localizedName ?? ""
        let frontmostBundleID = frontmost?.bundleIdentifier ?? ""

        var browserTabTitles: [String] = []
        var currentURLs: [String] = []
        if let frontmost, let appName = frontmost.localizedName,
           let browser = BrowserContextExtractor.extract(appName: appName, activeAppPID: frontmost.processIdentifier) {
            browserTabTitles = browser.recentTabTitles
            if let selected = browser.selectedURL?.absoluteString ?? browser.currentURL?.absoluteString, !selected.isEmpty {
                currentURLs = [selected]
            }
        }

        let snapshot = WorkspaceRuntimeInventory(
            runningApps: runningApps,
            visibleWindows: visibleWindows,
            browserTabTitles: browserTabTitles,
            currentURLs: currentURLs,
            frontmostAppName: frontmostAppName,
            frontmostBundleID: frontmostBundleID
        )
        let appList = snapshot.runningApps.map(\.appName).filter { !$0.isEmpty }.sorted().joined(separator: ",")
        print("[WorkspaceRuntimeInventory] running_apps=\(appList) visible_windows=\(snapshot.visibleWindows.count) browser_tabs=\(snapshot.browserTabTitles.count) urls=\(snapshot.currentURLs.count)")
        return snapshot
    }
}

final class DurableMemory: @unchecked Sendable {
    static let shared = DurableMemory()

    struct MusicPreferenceRecord: Codable, Sendable, Equatable {
        var playlist: String
        var acceptedCount: Int
        var rejectedCount: Int
        var alreadyPlayingCount: Int
        var recentAcceptedAt: Date?
        var recentRejectedAt: Date?
        var contextKeys: [String]
    }

    struct ActionFeedbackRecord: Codable, Sendable, Equatable {
        var capabilityId: String
        var acceptedCount: Int
        var dismissedCount: Int
        var ignoredCount: Int
        var autoDismissedCount: Int
        var recentAcceptedAt: Date?
        var recentDismissedAt: Date?
        var recentIgnoredAt: Date?
        var recentAutoDismissedAt: Date?
        var contextKeys: [String]

        enum CodingKeys: String, CodingKey {
            case capabilityId
            case acceptedCount
            case dismissedCount
            case ignoredCount
            case autoDismissedCount
            case recentAcceptedAt
            case recentDismissedAt
            case recentIgnoredAt
            case recentAutoDismissedAt
            case contextKeys
        }

        init(
            capabilityId: String,
            acceptedCount: Int,
            dismissedCount: Int,
            ignoredCount: Int,
            autoDismissedCount: Int = 0,
            recentAcceptedAt: Date?,
            recentDismissedAt: Date?,
            recentIgnoredAt: Date?,
            recentAutoDismissedAt: Date? = nil,
            contextKeys: [String]
        ) {
            self.capabilityId = capabilityId
            self.acceptedCount = acceptedCount
            self.dismissedCount = dismissedCount
            self.ignoredCount = ignoredCount
            self.autoDismissedCount = autoDismissedCount
            self.recentAcceptedAt = recentAcceptedAt
            self.recentDismissedAt = recentDismissedAt
            self.recentIgnoredAt = recentIgnoredAt
            self.recentAutoDismissedAt = recentAutoDismissedAt
            self.contextKeys = contextKeys
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            capabilityId = try container.decode(String.self, forKey: .capabilityId)
            acceptedCount = try container.decodeIfPresent(Int.self, forKey: .acceptedCount) ?? 0
            dismissedCount = try container.decodeIfPresent(Int.self, forKey: .dismissedCount) ?? 0
            ignoredCount = try container.decodeIfPresent(Int.self, forKey: .ignoredCount) ?? 0
            autoDismissedCount = try container.decodeIfPresent(Int.self, forKey: .autoDismissedCount) ?? 0
            recentAcceptedAt = try container.decodeIfPresent(Date.self, forKey: .recentAcceptedAt)
            recentDismissedAt = try container.decodeIfPresent(Date.self, forKey: .recentDismissedAt)
            recentIgnoredAt = try container.decodeIfPresent(Date.self, forKey: .recentIgnoredAt)
            recentAutoDismissedAt = try container.decodeIfPresent(Date.self, forKey: .recentAutoDismissedAt)
            contextKeys = try container.decodeIfPresent([String].self, forKey: .contextKeys) ?? []
        }
    }

    struct DurableWorkspaceRecord: Codable, Sendable, Equatable {
        var id: String
        var workflow: String
        var compartment: String
        var apps: [WorkspaceAppRecord]
        var windows: [WorkspaceWindowRecord]
        var urls: [WorkspaceURLRecord]
        var documents: [WorkspaceDocumentRecord]
        var browserTabs: [WorkspaceBrowserTabRecord]
        var observationCount: Int
        var sessionCount: Int
        var acceptedLayoutCount: Int
        var hourBuckets: [String: Int]
        var lastObservedAt: Date
        var durable: Bool
        var confidence: Double
        var repairedMixedItemCount: Int

        enum CodingKeys: String, CodingKey {
            case id
            case workflow
            case compartment
            case apps
            case windows
            case urls
            case documents
            case browserTabs
            case observationCount
            case sessionCount
            case acceptedLayoutCount
            case hourBuckets
            case lastObservedAt
            case durable
            case confidence
            case repairedMixedItemCount
            case bundleIDs
            case urlKeys
            case titleHashes
        }

        init(
            id: String,
            workflow: String,
            compartment: String,
            apps: [WorkspaceAppRecord],
            windows: [WorkspaceWindowRecord],
            urls: [WorkspaceURLRecord],
            documents: [WorkspaceDocumentRecord],
            browserTabs: [WorkspaceBrowserTabRecord],
            observationCount: Int,
            sessionCount: Int,
            acceptedLayoutCount: Int,
            hourBuckets: [String: Int],
            lastObservedAt: Date,
            durable: Bool,
            confidence: Double,
            repairedMixedItemCount: Int = 0
        ) {
            self.id = id
            self.workflow = workflow
            self.compartment = compartment
            self.apps = apps
            self.windows = windows
            self.urls = urls
            self.documents = documents
            self.browserTabs = browserTabs
            self.observationCount = observationCount
            self.sessionCount = sessionCount
            self.acceptedLayoutCount = acceptedLayoutCount
            self.hourBuckets = hourBuckets
            self.lastObservedAt = lastObservedAt
            self.durable = durable
            self.confidence = confidence
            self.repairedMixedItemCount = repairedMixedItemCount
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            workflow = try container.decodeIfPresent(String.self, forKey: .workflow) ?? "unknown"
            compartment = try container.decodeIfPresent(String.self, forKey: .compartment) ?? "none"

            let typedApps = (try? container.decode([WorkspaceAppRecord].self, forKey: .apps)) ?? []
            let typedWindows = (try? container.decode([WorkspaceWindowRecord].self, forKey: .windows)) ?? []
            let typedURLs = (try? container.decode([WorkspaceURLRecord].self, forKey: .urls)) ?? []
            let typedDocuments = (try? container.decode([WorkspaceDocumentRecord].self, forKey: .documents)) ?? []
            let typedTabs = (try? container.decode([WorkspaceBrowserTabRecord].self, forKey: .browserTabs)) ?? []

            let legacyApps = (try? container.decode([String].self, forKey: .apps)) ?? []
            let legacyBundleIDs = (try? container.decode([String].self, forKey: .bundleIDs)) ?? []
            let legacyURLKeys = (try? container.decode([String].self, forKey: .urlKeys)) ?? []
            let repair = DurableWorkspaceRecord.repairLegacyItems(legacyApps: legacyApps, legacyBundleIDs: legacyBundleIDs)

            apps = typedApps.isEmpty ? repair.apps : typedApps
            windows = typedWindows.isEmpty ? repair.windows : typedWindows
            urls = typedURLs.isEmpty ? legacyURLKeys.map(DurableWorkspaceRecord.urlRecord(fromLegacyKey:)) : typedURLs
            documents = typedDocuments.isEmpty ? repair.documents : typedDocuments
            browserTabs = typedTabs
            observationCount = try container.decodeIfPresent(Int.self, forKey: .observationCount) ?? 0
            sessionCount = try container.decodeIfPresent(Int.self, forKey: .sessionCount) ?? 0
            acceptedLayoutCount = try container.decodeIfPresent(Int.self, forKey: .acceptedLayoutCount) ?? 0
            hourBuckets = try container.decodeIfPresent([String: Int].self, forKey: .hourBuckets) ?? [:]
            lastObservedAt = try container.decodeIfPresent(Date.self, forKey: .lastObservedAt) ?? Date()
            durable = try container.decodeIfPresent(Bool.self, forKey: .durable) ?? false
            confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
            repairedMixedItemCount = try container.decodeIfPresent(Int.self, forKey: .repairedMixedItemCount) ?? repair.repairedMixedItemCount
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(workflow, forKey: .workflow)
            try container.encode(compartment, forKey: .compartment)
            try container.encode(apps, forKey: .apps)
            try container.encode(windows, forKey: .windows)
            try container.encode(urls, forKey: .urls)
            try container.encode(documents, forKey: .documents)
            try container.encode(browserTabs, forKey: .browserTabs)
            try container.encode(observationCount, forKey: .observationCount)
            try container.encode(sessionCount, forKey: .sessionCount)
            try container.encode(acceptedLayoutCount, forKey: .acceptedLayoutCount)
            try container.encode(hourBuckets, forKey: .hourBuckets)
            try container.encode(lastObservedAt, forKey: .lastObservedAt)
            try container.encode(durable, forKey: .durable)
            try container.encode(confidence, forKey: .confidence)
            try container.encode(repairedMixedItemCount, forKey: .repairedMixedItemCount)
        }

        private static func repairLegacyItems(
            legacyApps: [String],
            legacyBundleIDs: [String]
        ) -> (apps: [WorkspaceAppRecord], windows: [WorkspaceWindowRecord], documents: [WorkspaceDocumentRecord], repairedMixedItemCount: Int) {
            var bundleIterator = legacyBundleIDs.makeIterator()
            var apps: [WorkspaceAppRecord] = []
            var windows: [WorkspaceWindowRecord] = []
            var documents: [WorkspaceDocumentRecord] = []
            var repairedMixedItemCount = 0

            for raw in legacyApps {
                let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }
                let bundleID = bundleIterator.next() ?? ""
                if DurableMemory.looksLikeDocumentOrWindowTitle(cleaned) {
                    repairedMixedItemCount += 1
                    if let ext = DurableMemory.fileExtension(from: cleaned) {
                        documents.append(WorkspaceDocumentRecord(
                            normalizedTitle: DurableMemory.normalizedTitle(cleaned),
                            fileExtension: ext,
                            appName: DurableMemory.appNameForBundle(bundleID, fallback: ""),
                            semanticRole: DurableMemory.semanticRole(for: cleaned)
                        ))
                    } else {
                        windows.append(WorkspaceWindowRecord(
                            normalizedTitle: DurableMemory.normalizedTitle(cleaned),
                            appBundleID: bundleID,
                            appName: DurableMemory.appNameForBundle(bundleID, fallback: ""),
                            semanticRole: DurableMemory.semanticRole(for: cleaned)
                        ))
                    }
                    continue
                }
                apps.append(WorkspaceAppRecord(
                    bundleID: bundleID,
                    appName: cleaned
                ))
            }

            return (
                apps: DurableMemory.uniqueWorkspaceApps(apps),
                windows: DurableMemory.uniqueWorkspaceWindows(windows),
                documents: DurableMemory.uniqueWorkspaceDocuments(documents),
                repairedMixedItemCount: repairedMixedItemCount
            )
        }

        private static func urlRecord(fromLegacyKey key: String) -> WorkspaceURLRecord {
            let parts = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            return WorkspaceURLRecord(
                normalizedDomain: parts.first.map(String.init) ?? "",
                pathHash: parts.count > 1 ? String(parts[1]) : "",
                readableTitle: "",
                sourceApp: ""
            )
        }
    }

    struct TimingPreferenceRecord: Codable, Sendable, Equatable {
        var contextKey: String
        var acceptedWhileTypingIdle: [String: Int]
        var ignoredWhileTypingIdle: [String: Int]
    }

    private struct Store: Codable {
        var musicPreferences: [String: MusicPreferenceRecord] = [:]
        var actionFeedback: [String: ActionFeedbackRecord] = [:]
        var workspaceRecords: [String: DurableWorkspaceRecord] = [:]
        var timingPreferences: [String: TimingPreferenceRecord] = [:]
        var restoreCooldowns: [String: ActionFeedbackRecord] = [:]

        enum CodingKeys: String, CodingKey {
            case musicPreferences
            case actionFeedback
            case workspaceRecords
            case timingPreferences
            case restoreCooldowns
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            musicPreferences = try container.decodeIfPresent([String: MusicPreferenceRecord].self, forKey: .musicPreferences) ?? [:]
            actionFeedback = try container.decodeIfPresent([String: ActionFeedbackRecord].self, forKey: .actionFeedback) ?? [:]
            workspaceRecords = try container.decodeIfPresent([String: DurableWorkspaceRecord].self, forKey: .workspaceRecords) ?? [:]
            timingPreferences = try container.decodeIfPresent([String: TimingPreferenceRecord].self, forKey: .timingPreferences) ?? [:]
            restoreCooldowns = try container.decodeIfPresent([String: ActionFeedbackRecord].self, forKey: .restoreCooldowns) ?? [:]
        }
    }

    struct MissingWorkspaceCheck: Sendable, Equatable {
        let missingApps: [String]
        let missingURLs: [String]
        let missingDocuments: [String]
        let missingWindows: [String]
        let canRestore: Bool
        let reason: String
        let restoreKey: String
        let itemStates: [WorkspaceItemStatus]
    }

    private let queue = DispatchQueue(label: "DurableMemory", qos: .utility)
    private var store = Store()
    private var acceptedMusicPreferenceOverrideForTests: Bool?
    private var sessionId = ISO8601DateFormatter().string(from: Date())
    private lazy var saveURL: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Contextual", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("durable-memory-v1.json")
    }()

    private init() {
        load()
    }

    func resetForTests() {
        queue.sync {
            store = Store()
            sessionId = "test-session"
            acceptedMusicPreferenceOverrideForTests = nil
            try? FileManager.default.removeItem(at: saveURL)
        }
    }

    func setAcceptedMusicPreferenceOverrideForTests(_ value: Bool?) {
        queue.sync {
            acceptedMusicPreferenceOverrideForTests = value
        }
    }

    func hasAcceptedMusicPreference() -> Bool {
        return queue.sync {
            if let override = acceptedMusicPreferenceOverrideForTests { return override }
            return store.musicPreferences.values.contains { $0.acceptedCount > 0 }
        }
    }

    /// Phase 67 — the most-accepted learned playlist, used to retry a bare resume
    /// that returned a non-playing state before surfacing any failure.
    func preferredMusicPlaylist() -> String? {
        return queue.sync {
            store.musicPreferences.values
                .filter { $0.acceptedCount > 0 && $0.playlist != "already_playing" }
                .max(by: { lhs, rhs in
                    if lhs.acceptedCount != rhs.acceptedCount { return lhs.acceptedCount < rhs.acceptedCount }
                    return (lhs.recentAcceptedAt ?? .distantPast) < (rhs.recentAcceptedAt ?? .distantPast)
                })?
                .playlist
        }
    }

    func observe(category: String, key: String, confidence: Double) {
        print("[DurableMemory] observed category=\(category) key=\(key) confidence=\(String(format: "%.2f", confidence))")
    }

    func recordMusicPreference(playlist: String, context: DurableMemoryContext, source: String) {
        guard !playlist.isEmpty else { return }
        queue.sync {
            observe(category: "music", key: playlist, confidence: 0.70)
            var record = store.musicPreferences[playlist] ?? MusicPreferenceRecord(
                playlist: playlist,
                acceptedCount: 0,
                rejectedCount: 0,
                alreadyPlayingCount: 0,
                recentAcceptedAt: nil,
                recentRejectedAt: nil,
                contextKeys: []
            )
            record.acceptedCount += 1
            record.recentAcceptedAt = Date()
            record.contextKeys = Array(Set(record.contextKeys + [context.compactDescription])).sorted()
            store.musicPreferences[playlist] = record
            persistLocked()
            print("[DurableMemory] preference category=music playlist=\"\(playlist)\" context=\(context.compactDescription) source=\(source)")
            print("[DurableMemory] updated key=music:\(playlist) observations=\(record.acceptedCount + record.rejectedCount + record.alreadyPlayingCount) durable=\(record.acceptedCount >= 1 ? "yes" : "no")")
            print("[MusicPreference] learned playlist=\"\(playlist)\" context=\(context.compactDescription) confidence=\(String(format: "%.2f", min(0.95, 0.45 + Double(record.acceptedCount) * 0.15)))")
        }
    }

    func recordMusicSuppression(reason: String, context: DurableMemoryContext) {
        queue.sync {
            observe(category: "music", key: "suppressed:\(reason)", confidence: 0.55)
            if reason == "already_playing" {
                let key = "already_playing"
                var record = store.musicPreferences[key] ?? MusicPreferenceRecord(
                    playlist: key,
                    acceptedCount: 0,
                    rejectedCount: 0,
                    alreadyPlayingCount: 0,
                    recentAcceptedAt: nil,
                    recentRejectedAt: nil,
                    contextKeys: []
                )
                record.alreadyPlayingCount += 1
                record.contextKeys = Array(Set(record.contextKeys + [context.compactDescription])).sorted()
                store.musicPreferences[key] = record
                persistLocked()
                print("[DurableMemory] updated key=music:\(key) observations=\(record.alreadyPlayingCount) durable=\(record.alreadyPlayingCount >= 2 ? "yes" : "no")")
            }
        }
    }

    func shouldSuppressMusicSuggestion(context: DurableMemoryContext, isPlaying: Bool) -> String? {
        queue.sync {
            if isPlaying { return "already_playing" }
            let matching = store.musicPreferences.values.filter { $0.contextKeys.contains(context.compactDescription) }
            if let latestAccepted = matching.compactMap({ $0.recentAcceptedAt }).max(), Date().timeIntervalSince(latestAccepted) < 900 {
                return "recently_accepted"
            }
            if let latestRejected = matching.compactMap({ $0.recentRejectedAt }).max(), Date().timeIntervalSince(latestRejected) < 1800 {
                return "rejected_recently"
            }
            return nil
        }
    }

    func recordActionFeedback(capabilityId: String, event: DurableMemoryActionEvent, context: DurableMemoryContext) {
        queue.sync {
            observe(category: "action", key: capabilityId, confidence: 0.65)
            var record = store.actionFeedback[capabilityId] ?? ActionFeedbackRecord(
                capabilityId: capabilityId,
                acceptedCount: 0,
                dismissedCount: 0,
                ignoredCount: 0,
                autoDismissedCount: 0,
                recentAcceptedAt: nil,
                recentDismissedAt: nil,
                recentIgnoredAt: nil,
                recentAutoDismissedAt: nil,
                contextKeys: []
            )
            switch event {
            case .accepted:
                if let lastAuto = record.recentAutoDismissedAt, Date().timeIntervalSince(lastAuto) < 600 {
                    if record.autoDismissedCount > 0 {
                        record.autoDismissedCount -= 1
                    }
                }
                record.acceptedCount += 1
                record.recentAcceptedAt = Date()
            case .dismissed:
                record.dismissedCount += 1
                record.recentDismissedAt = Date()
            case .ignored:
                record.ignoredCount += 1
                record.recentIgnoredAt = Date()
            case .autoDismissed:
                record.autoDismissedCount += 1
                record.recentAutoDismissedAt = Date()
            }
            record.contextKeys = Array(Set(record.contextKeys + [context.compactDescription])).sorted()
            store.actionFeedback[capabilityId] = record
            persistLocked()
            print("[DurableMemory] action_feedback capability=\(capabilityId) event=\(event.rawValue) context=\(context.compactDescription)")
            let total = record.acceptedCount + record.dismissedCount + record.ignoredCount + record.autoDismissedCount
            print("[DurableMemory] updated key=action:\(capabilityId) observations=\(total) durable=\(total >= 3 ? "yes" : "no")")
        }
    }

    func actionFeedbackRecord(for capabilityId: String) -> ActionFeedbackRecord? {
        queue.sync {
            store.actionFeedback[capabilityId]
        }
    }

    /// Phase 59 — ids whose floating cards were recently auto-dismissed or
    /// ignored. These get a score penalty and a floating ban (panel still ok).
    /// Phase 60 — repeated ignores escalate into a 24h proposal cooldown.
    func floatingPenalizedActionIds(now: Date = Date()) -> Set<String> {
        queue.sync {
            var ids = Set<String>()
            for (id, record) in store.actionFeedback {
                let ignoredTotal = record.autoDismissedCount + record.ignoredCount
                let lastNegative = [record.recentAutoDismissedAt, record.recentIgnoredAt, record.recentDismissedAt].compactMap { $0 }.max()
                if ignoredTotal >= 3, let last = lastNegative, now.timeIntervalSince(last) < 24 * 3600 {
                    print("[ProposalCooldown] id=\(id) active=yes reason=repeated_low_value")
                    print("[ProposalFeedbackPenalty] id=\(id) penalty=cooldown reason=repeated_low_value")
                    ids.insert(id)
                    continue
                }
                if let auto = record.recentAutoDismissedAt, now.timeIntervalSince(auto) < 6 * 3600 {
                    print("[ProposalFeedbackPenalty] id=\(id) penalty=float_ban reason=auto_dismissed")
                    ids.insert(id)
                } else if let ignored = record.recentIgnoredAt, now.timeIntervalSince(ignored) < 6 * 3600, record.ignoredCount >= 2 {
                    print("[ProposalFeedbackPenalty] id=\(id) penalty=float_ban reason=recent_ignore")
                    ids.insert(id)
                } else if let dismissed = record.recentDismissedAt, now.timeIntervalSince(dismissed) < 2 * 3600 {
                    print("[ProposalFeedbackPenalty] id=\(id) penalty=float_ban reason=not_clicked")
                    ids.insert(id)
                }
            }
            return ids
        }
    }

    /// Phase 59 — ids the user clicked recently in a similar context
    /// (same compartment/content token in the recorded context keys).
    func recentlyAcceptedActionIds(contextKey: String, now: Date = Date()) -> Set<String> {
        queue.sync {
            var ids = Set<String>()
            let tokens = Set(contextKey.split(separator: "|").map(String.init))
            for (id, record) in store.actionFeedback {
                guard let accepted = record.recentAcceptedAt, now.timeIntervalSince(accepted) < 24 * 3600 else { continue }
                let similar = record.contextKeys.contains { key in
                    let keyTokens = Set(key.split(separator: "|").map(String.init))
                    return !tokens.isDisjoint(with: keyTokens)
                }
                if similar { ids.insert(id) }
            }
            return ids
        }
    }

    func recordRestoreFeedback(restoreKey: String, event: DurableMemoryActionEvent) {
        queue.sync {
            var record = store.restoreCooldowns[restoreKey] ?? ActionFeedbackRecord(
                capabilityId: restoreKey,
                acceptedCount: 0,
                dismissedCount: 0,
                ignoredCount: 0,
                autoDismissedCount: 0,
                recentAcceptedAt: nil,
                recentDismissedAt: nil,
                recentIgnoredAt: nil,
                recentAutoDismissedAt: nil,
                contextKeys: []
            )
            switch event {
            case .accepted:
                if let lastAuto = record.recentAutoDismissedAt, Date().timeIntervalSince(lastAuto) < 600 {
                    if record.autoDismissedCount > 0 {
                        record.autoDismissedCount -= 1
                    }
                }
                record.acceptedCount += 1
                record.recentAcceptedAt = Date()
            case .dismissed:
                record.dismissedCount += 1
                record.recentDismissedAt = Date()
            case .ignored:
                record.ignoredCount += 1
                record.recentIgnoredAt = Date()
            case .autoDismissed:
                record.autoDismissedCount += 1
                record.recentAutoDismissedAt = Date()
            }
            store.restoreCooldowns[restoreKey] = record
            persistLocked()
        }
    }

    func shouldSuppressRestoreSuggestion(restoreKey: String, cooldown: TimeInterval = 600) -> Bool {
        queue.sync {
            guard let record = store.restoreCooldowns[restoreKey] else { return false }
            let now = Date()
            let ignoredRecent = record.recentIgnoredAt.map { now.timeIntervalSince($0) < cooldown } ?? false
            let autoDismissedRecent = record.recentAutoDismissedAt.map { now.timeIntervalSince($0) < cooldown } ?? false
            if ignoredRecent || autoDismissedRecent {
                print("[RestoreCooldown] applied workspace=\(restoreKey) reason=ignored_or_auto_dismissed")
                return true
            }
            return false
        }
    }

    func recordScheduleObservation(context: DurableMemoryContext, accepted: Bool, activityState: String) {
        queue.sync {
            observe(category: "schedule", key: context.compactDescription, confidence: 0.40)
            let key = context.compactDescription
            var record = store.timingPreferences[key] ?? TimingPreferenceRecord(
                contextKey: key,
                acceptedWhileTypingIdle: [:],
                ignoredWhileTypingIdle: [:]
            )
            let hour = String(Calendar.current.component(.hour, from: Date()))
            if accepted {
                record.acceptedWhileTypingIdle["\(activityState)|\(hour)", default: 0] += 1
            } else {
                record.ignoredWhileTypingIdle["\(activityState)|\(hour)", default: 0] += 1
            }
            store.timingPreferences[key] = record
            persistLocked()
            let count = (record.acceptedWhileTypingIdle["\(activityState)|\(hour)"] ?? 0) + (record.ignoredWhileTypingIdle["\(activityState)|\(hour)"] ?? 0)
            print("[DurableMemory] updated key=schedule:\(key) observations=\(count) durable=\(count >= 3 ? "yes" : "no")")
        }
    }

    func recordWorkspaceObservation(
        workflow: String,
        compartment: String,
        apps: [String],
        bundleIDs: [String],
        urls: [String],
        tabTitles: [String],
        windowTitle: String?,
        selectedTabTitle: String? = nil,
        acceptedLayout: Bool = false
    ) {
        let normalized = Self.normalizeWorkspaceObservation(
            apps: apps,
            bundleIDs: bundleIDs,
            urls: urls,
            tabTitles: tabTitles,
            windowTitle: windowTitle,
            selectedTabTitle: selectedTabTitle
        )
        guard normalized.apps.count >= 2
                || !normalized.urls.isEmpty
                || normalized.browserTabs.count >= 2
                || !normalized.documents.isEmpty
                || !normalized.windows.isEmpty else { return }
        let id = workspaceId(
            workflow: workflow,
            compartment: compartment,
            apps: normalized.apps.map(\.appName)
        )
        let hour = String(Calendar.current.component(.hour, from: Date()))

        queue.sync {
            let appList = normalized.apps.map(\.appName).joined(separator: ",")
            print("[WorkspacePatternMemory] observed apps=\(appList) windows=\(normalized.windows.count) urls=\(normalized.urls.count) documents=\(normalized.documents.count) tabs=\(normalized.browserTabs.count)")
            print("[WorkspacePatternMemory] normalized id=\(id) apps=\(normalized.apps.count) windows=\(normalized.windows.count) urls=\(normalized.urls.count) documents=\(normalized.documents.count) tabs=\(normalized.browserTabs.count)")
            if normalized.repairedMixedItemCount > 0 {
                print("[WorkspacePatternMemory] repaired_mixed_items count=\(normalized.repairedMixedItemCount) reason=document_title_in_apps")
            }
            observe(category: "workspace", key: id, confidence: 0.75)
            var record = store.workspaceRecords[id] ?? DurableWorkspaceRecord(
                id: id,
                workflow: workflow.lowercased(),
                compartment: compartment.lowercased(),
                apps: normalized.apps,
                windows: [],
                urls: [],
                documents: [],
                browserTabs: [],
                observationCount: 0,
                sessionCount: 0,
                acceptedLayoutCount: 0,
                hourBuckets: [:],
                lastObservedAt: Date(),
                durable: false,
                confidence: 0,
                repairedMixedItemCount: normalized.repairedMixedItemCount
            )
            record.observationCount += 1
            if acceptedLayout { record.acceptedLayoutCount += 1 }
            if record.hourBuckets["session:\(sessionId)"] == nil {
                record.sessionCount += 1
                record.hourBuckets["session:\(sessionId)"] = 1
            } else {
                record.hourBuckets["session:\(sessionId)", default: 0] += 1
            }
            record.hourBuckets[hour, default: 0] += 1
            record.lastObservedAt = Date()
            record.apps = Self.uniqueWorkspaceApps(record.apps + normalized.apps)
            record.windows = Self.uniqueWorkspaceWindows(record.windows + normalized.windows)
            record.urls = Self.uniqueWorkspaceURLs(record.urls + normalized.urls)
            record.documents = Self.uniqueWorkspaceDocuments(record.documents + normalized.documents)
            record.browserTabs = Self.uniqueWorkspaceBrowserTabs(record.browserTabs + normalized.browserTabs)
            record.repairedMixedItemCount += normalized.repairedMixedItemCount
            record.durable = record.observationCount >= 3
                || (record.sessionCount >= 2 && record.urls.count >= 2)
                || record.acceptedLayoutCount >= 1
                || recurringHourScore(record.hourBuckets) >= 2
            record.confidence = min(0.98, 0.18 * Double(record.observationCount) + 0.12 * Double(record.sessionCount) + 0.22 * Double(record.acceptedLayoutCount) + 0.10 * Double(recurringHourScore(record.hourBuckets)))
            store.workspaceRecords[id] = record
            persistLocked()
            print("[WorkspacePatternMemory] candidate id=\(id) confidence=\(String(format: "%.2f", record.confidence)) observations=\(record.observationCount) durable=\(record.durable ? "yes" : "no")")
            print("[DurableMemory] updated key=workspace:\(id) observations=\(record.observationCount) durable=\(record.durable ? "yes" : "no")")
        }
    }

    func recordAcceptedLayout(workflow: String?, compartment: String?, apps: [String]) {
        recordWorkspaceObservation(
            workflow: workflow ?? "unknown",
            compartment: compartment ?? "none",
            apps: apps,
            bundleIDs: [],
            urls: [],
            tabTitles: [],
            windowTitle: nil,
            acceptedLayout: true
        )
    }

    func bestDurableWorkspacePattern(workflow: String, compartment: String?, currentApps: Set<String>) -> DurableWorkspaceRecord? {
        queue.sync {
            let normalizedWorkflow = workflow.lowercased()
            let normalizedCompartment = (compartment ?? "none").lowercased()
            let candidates = store.workspaceRecords.values.filter {
                $0.durable && $0.workflow == normalizedWorkflow && ($0.compartment == normalizedCompartment || normalizedCompartment == "none")
            }
            return candidates.max { lhs, rhs in
                let lOverlap = Set(lhs.apps.map { $0.appName.lowercased() }).intersection(currentApps.map { $0.lowercased() }).count
                let rOverlap = Set(rhs.apps.map { $0.appName.lowercased() }).intersection(currentApps.map { $0.lowercased() }).count
                let lScore = lhs.confidence + Double(lOverlap) * 0.1
                let rScore = rhs.confidence + Double(rOverlap) * 0.1
                return lScore < rScore
            }
        }
    }

    func missingCheck(pattern: DurableWorkspaceRecord, currentApps: Set<String>, currentURLs: [String]) -> MissingWorkspaceCheck {
        let inventory = WorkspaceRuntimeInventoryProvider.snapshot()
        let runtimeAppNames = Set((inventory.runningApps.map(\.appName) + Array(currentApps)).map { $0.lowercased() })
        let runtimeBundleIDs = Set(inventory.runningApps.map(\.bundleID).filter { !$0.isEmpty })
        let runtimeURLKeys = Set((inventory.currentURLs + currentURLs).compactMap { Self.normalizedURLKey(from: $0) })
        let runtimeTabTitles = Set(inventory.browserTabTitles.map { Self.normalizedTitle($0) })

        var states: [WorkspaceItemStatus] = []
        var missingApps: [String] = []
        var missingURLs: [String] = []
        var missingDocuments: [String] = []
        var missingWindows: [String] = []

        for app in pattern.apps {
            let visibleWindowExists = inventory.visibleWindows.contains {
                (!$0.bundleID.isEmpty && $0.bundleID == app.bundleID)
                    || $0.appName.caseInsensitiveCompare(app.appName) == .orderedSame
            }
            let present = runtimeAppNames.contains(app.appName.lowercased())
                || (!app.bundleID.isEmpty && runtimeBundleIDs.contains(app.bundleID))
            let state: WorkspaceStoredItemState
            let reason: String
            if visibleWindowExists {
                state = inventory.frontmostAppName.caseInsensitiveCompare(app.appName) == .orderedSame ? .presentVisible : .presentBackgrounded
                reason = inventory.frontmostAppName.caseInsensitiveCompare(app.appName) == .orderedSame ? "matching_window_frontmost" : "running_app_window_visible"
            } else if present {
                state = .minimized
                reason = "running_app_no_visible_window"
            } else {
                state = .missing
                reason = "app_not_running"
                missingApps.append(app.appName)
            }
            logWorkspaceState(item: app.appName, type: "app", state: state, present: present, visible: visibleWindowExists, reason: reason)
            states.append(.init(item: app.appName, type: "app", state: state, present: present, visible: visibleWindowExists, executable: state == .missing, reason: reason))
        }

        for window in pattern.windows {
            let matchingWindow = inventory.visibleWindows.first {
                let titleMatch = Self.normalizedTitle($0.title) == window.normalizedTitle
                let bundleMatch = window.appBundleID.isEmpty || $0.bundleID == window.appBundleID
                let appMatch = window.appName.isEmpty || $0.appName.caseInsensitiveCompare(window.appName) == .orderedSame
                return titleMatch && bundleMatch && appMatch
            }
            let appPresent = (!window.appBundleID.isEmpty && runtimeBundleIDs.contains(window.appBundleID))
                || (!window.appName.isEmpty && runtimeAppNames.contains(window.appName.lowercased()))
            let state: WorkspaceStoredItemState
            let reason: String
            if let matchingWindow {
                state = matchingWindow.appName.caseInsensitiveCompare(inventory.frontmostAppName) == .orderedSame ? .presentVisible : .presentBackgrounded
                reason = matchingWindow.appName.caseInsensitiveCompare(inventory.frontmostAppName) == .orderedSame ? "window_title_match_frontmost" : "window_title_match_backgrounded"
            } else if appPresent {
                state = .presentNotArranged
                reason = "source_app_running_window_not_visible"
            } else {
                state = .missing
                reason = "source_app_missing"
                missingWindows.append(window.normalizedTitle)
            }
            logWorkspaceState(item: window.normalizedTitle, type: "window", state: state, present: state != .missing, visible: matchingWindow != nil, reason: reason)
            states.append(.init(item: window.normalizedTitle, type: "window", state: state, present: state != .missing, visible: matchingWindow != nil, executable: false, reason: reason))
        }

        for document in pattern.documents {
            let matchingWindow = inventory.visibleWindows.first {
                let titleMatch = Self.normalizedTitle($0.title).contains(document.normalizedTitle) || document.normalizedTitle.contains(Self.normalizedTitle($0.title))
                let appMatch = document.appName.isEmpty || $0.appName.caseInsensitiveCompare(document.appName) == .orderedSame
                return titleMatch && appMatch
            }
            let appPresent = document.appName.isEmpty ? false : runtimeAppNames.contains(document.appName.lowercased())
            let state: WorkspaceStoredItemState
            let reason: String
            if let matchingWindow {
                state = matchingWindow.appName.caseInsensitiveCompare(inventory.frontmostAppName) == .orderedSame ? .presentVisible : .presentBackgrounded
                reason = matchingWindow.appName.caseInsensitiveCompare(inventory.frontmostAppName) == .orderedSame ? "document_title_match_frontmost" : "document_title_match_backgrounded"
            } else if appPresent {
                state = .presentNotArranged
                reason = "document_app_running_not_visible"
            } else {
                state = .missing
                reason = "document_app_missing"
                missingDocuments.append(document.normalizedTitle)
            }
            logWorkspaceState(item: document.normalizedTitle, type: "document", state: state, present: state != .missing, visible: matchingWindow != nil, reason: reason)
            states.append(.init(item: document.normalizedTitle, type: "document", state: state, present: state != .missing, visible: matchingWindow != nil, executable: false, reason: reason))
        }

        for url in pattern.urls {
            let presentByURL = runtimeURLKeys.contains(url.urlKey)
            let presentByTab = !url.readableTitle.isEmpty && runtimeTabTitles.contains(Self.normalizedTitle(url.readableTitle))
            let sourceAppRunning = url.sourceApp.isEmpty
                ? inventory.runningApps.contains {
                    AppContextAnalyzer.analyze(appName: $0.appName, bundleID: $0.bundleID, windowTitle: nil).isBrowser
                }
                : runtimeAppNames.contains(url.sourceApp.lowercased())
            let state: WorkspaceStoredItemState
            let reason: String
            if presentByURL || presentByTab {
                let frontmostIsSource = url.sourceApp.isEmpty || inventory.frontmostAppName.caseInsensitiveCompare(url.sourceApp) == .orderedSame
                state = frontmostIsSource ? .presentVisible : .presentBackgrounded
                reason = presentByURL ? "url_key_match" : "tab_title_match"
            } else if sourceAppRunning {
                state = .presentNotArranged
                reason = "source_browser_running_url_not_enumerated"
            } else {
                state = .missing
                reason = "url_source_app_missing"
                missingURLs.append(url.urlKey)
            }
            logWorkspaceState(item: url.readableTitle.isEmpty ? url.urlKey : url.readableTitle, type: "url", state: state, present: state != .missing, visible: presentByURL || presentByTab, reason: reason)
            states.append(.init(item: url.readableTitle.isEmpty ? url.urlKey : url.readableTitle, type: "url", state: state, present: state != .missing, visible: presentByURL || presentByTab, executable: state == .missing, reason: reason))
        }

        let hasBackgrounded = states.contains { $0.state == .presentBackgrounded }
        let hasNotArranged = states.contains { $0.state == .presentNotArranged || $0.state == .minimized }
        let hasExecutableMissing = !missingApps.isEmpty || !missingURLs.isEmpty
        let canRestore = pattern.durable && hasExecutableMissing
        let reason: String
        if canRestore {
            reason = "missing_items"
        } else if hasBackgrounded {
            reason = "items_present_backgrounded"
        } else if hasNotArranged {
            reason = "items_present_not_arranged"
        } else {
            reason = "workspace_items_present"
        }
        let restoreKey = Self.restoreCooldownKey(
            apps: missingApps,
            urls: missingURLs,
            compartment: pattern.compartment
        )
        print("[WorkspaceRestoreGate] can_restore=\(canRestore ? "yes" : "no") reason=\(reason)")
        print("[WorkspacePatternMemory] missing_check id=\(pattern.id) missing_apps=\(missingApps.joined(separator: ",")) missing_urls=\(missingURLs.count) can_restore=\(canRestore ? "yes" : "no")")
        return MissingWorkspaceCheck(
            missingApps: missingApps,
            missingURLs: missingURLs,
            missingDocuments: missingDocuments,
            missingWindows: missingWindows,
            canRestore: canRestore,
            reason: reason,
            restoreKey: restoreKey,
            itemStates: states
        )
    }

    private func load() {
        queue.sync {
            guard let data = try? Data(contentsOf: saveURL),
                  let decoded = try? JSONDecoder().decode(Store.self, from: data) else { return }
            store = decoded
            for (id, record) in store.workspaceRecords {
                if record.repairedMixedItemCount > 0 {
                    print("[WorkspacePatternMemory] repaired_mixed_items count=\(record.repairedMixedItemCount) reason=document_title_in_apps")
                }
                store.workspaceRecords[id]?.apps = Self.uniqueWorkspaceApps(record.apps)
                store.workspaceRecords[id]?.windows = Self.uniqueWorkspaceWindows(record.windows)
                store.workspaceRecords[id]?.urls = Self.uniqueWorkspaceURLs(record.urls)
                store.workspaceRecords[id]?.documents = Self.uniqueWorkspaceDocuments(record.documents)
                store.workspaceRecords[id]?.browserTabs = Self.uniqueWorkspaceBrowserTabs(record.browserTabs)
            }
        }
    }

    private func persistLocked() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(store) else { return }
        try? data.write(to: saveURL, options: .atomic)
    }

    private func workspaceId(workflow: String, compartment: String, apps: [String]) -> String {
        let base = ([workflow.lowercased(), compartment.lowercased()] + apps.map { $0.lowercased() }).joined(separator: "|")
        return Self.hash(base)
    }

    static func normalizedURLKey(from raw: String) -> String? {
        guard let url = URL(string: raw), let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(host)#\(hash(path.isEmpty ? "/" : path))"
    }

    static func restoreCooldownKey(apps: [String], urls: [String], compartment: String?) -> String {
        let appPart = apps.map { $0.lowercased() }.sorted().joined(separator: "|")
        let urlPart = urls.sorted().joined(separator: "|")
        let compartmentPart = (compartment ?? "none").lowercased()
        return hash("restore|\(compartmentPart)|\(appPart)|\(urlPart)")
    }

    private static func normalizeWorkspaceObservation(
        apps: [String],
        bundleIDs: [String],
        urls: [String],
        tabTitles: [String],
        windowTitle: String?,
        selectedTabTitle: String?
    ) -> (
        apps: [WorkspaceAppRecord],
        windows: [WorkspaceWindowRecord],
        urls: [WorkspaceURLRecord],
        documents: [WorkspaceDocumentRecord],
        browserTabs: [WorkspaceBrowserTabRecord],
        repairedMixedItemCount: Int
    ) {
        let trimmedApps = apps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var bundleIterator = bundleIDs.makeIterator()
        var appRecords: [WorkspaceAppRecord] = []
        var windowRecords: [WorkspaceWindowRecord] = []
        var documentRecords: [WorkspaceDocumentRecord] = []
        var repairedMixedItemCount = 0

        for raw in trimmedApps {
            let bundleID = bundleIterator.next() ?? ""
            if looksLikeDocumentOrWindowTitle(raw) {
                repairedMixedItemCount += 1
                if let ext = fileExtension(from: raw) {
                    documentRecords.append(WorkspaceDocumentRecord(
                        normalizedTitle: normalizedTitle(raw),
                        fileExtension: ext,
                        appName: appNameForBundle(bundleID, fallback: ""),
                        semanticRole: semanticRole(for: raw)
                    ))
                } else {
                    windowRecords.append(WorkspaceWindowRecord(
                        normalizedTitle: normalizedTitle(raw),
                        appBundleID: bundleID,
                        appName: appNameForBundle(bundleID, fallback: ""),
                        semanticRole: semanticRole(for: raw)
                    ))
                }
                continue
            }
            appRecords.append(WorkspaceAppRecord(bundleID: bundleID, appName: raw))
        }

        if let windowTitle, !windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalizedWindow = normalizedTitle(windowTitle)
            if let ext = fileExtension(from: windowTitle) {
                documentRecords.append(WorkspaceDocumentRecord(
                    normalizedTitle: normalizedWindow,
                    fileExtension: ext,
                    appName: appRecords.first?.appName ?? "",
                    semanticRole: semanticRole(for: windowTitle)
                ))
            } else {
                windowRecords.append(WorkspaceWindowRecord(
                    normalizedTitle: normalizedWindow,
                    appBundleID: appRecords.first?.bundleID ?? "",
                    appName: appRecords.first?.appName ?? "",
                    semanticRole: semanticRole(for: windowTitle)
                ))
            }
        }

        let currentURL = urls.first
        let urlRecords = urls.compactMap { raw -> WorkspaceURLRecord? in
            guard let url = URL(string: raw), let host = url.host?.lowercased() else { return nil }
            let path = url.path.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let readableTitle = selectedTabTitle ?? tabTitles.first ?? windowTitle ?? ""
            return WorkspaceURLRecord(
                normalizedDomain: host,
                pathHash: hash(path.isEmpty ? "/" : path),
                readableTitle: readableTitle,
                sourceApp: appRecords.first?.appName ?? ""
            )
        }

        let browserTabs = tabTitles.map { title -> WorkspaceBrowserTabRecord in
            let selected = selectedTabTitle == title || (selectedTabTitle == nil && title == tabTitles.first)
            let urlKey = selected ? currentURL.flatMap { normalizedURLKey(from: $0) } : nil
            let domain = selected ? currentURL.flatMap { URL(string: $0)?.host?.lowercased() } : nil
            return WorkspaceBrowserTabRecord(
                title: title,
                urlKey: urlKey,
                normalizedDomain: domain,
                isSelected: selected,
                isRecent: true
            )
        }

        return (
            apps: uniqueWorkspaceApps(appRecords),
            windows: uniqueWorkspaceWindows(windowRecords),
            urls: uniqueWorkspaceURLs(urlRecords),
            documents: uniqueWorkspaceDocuments(documentRecords),
            browserTabs: uniqueWorkspaceBrowserTabs(browserTabs),
            repairedMixedItemCount: repairedMixedItemCount
        )
    }

    private static func uniqueWorkspaceApps(_ apps: [WorkspaceAppRecord]) -> [WorkspaceAppRecord] {
        var seen: Set<String> = []
        return apps.filter {
            let key = "\($0.bundleID.lowercased())|\($0.appName.lowercased())"
            return seen.insert(key).inserted
        }.sorted { $0.appName.lowercased() < $1.appName.lowercased() }
    }

    private static func uniqueWorkspaceWindows(_ windows: [WorkspaceWindowRecord]) -> [WorkspaceWindowRecord] {
        var seen: Set<String> = []
        return windows.filter {
            let key = "\($0.appBundleID.lowercased())|\($0.normalizedTitle)"
            return seen.insert(key).inserted
        }.sorted { $0.normalizedTitle < $1.normalizedTitle }
    }

    private static func uniqueWorkspaceURLs(_ urls: [WorkspaceURLRecord]) -> [WorkspaceURLRecord] {
        var seen: Set<String> = []
        return urls.filter {
            seen.insert($0.urlKey).inserted
        }.sorted { $0.urlKey < $1.urlKey }
    }

    private static func uniqueWorkspaceDocuments(_ documents: [WorkspaceDocumentRecord]) -> [WorkspaceDocumentRecord] {
        var seen: Set<String> = []
        return documents.filter {
            let key = "\($0.appName.lowercased())|\($0.normalizedTitle)"
            return seen.insert(key).inserted
        }.sorted { $0.normalizedTitle < $1.normalizedTitle }
    }

    private static func uniqueWorkspaceBrowserTabs(_ tabs: [WorkspaceBrowserTabRecord]) -> [WorkspaceBrowserTabRecord] {
        var seen: Set<String> = []
        return tabs.filter {
            let key = "\(normalizedTitle($0.title))|\($0.urlKey ?? "")"
            return seen.insert(key).inserted
        }
    }

    private static func normalizedTitle(_ title: String) -> String {
        title
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeDocumentOrWindowTitle(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains(".pdf")
            || lower.contains(".doc")
            || lower.contains(".md")
            || lower.contains(".txt")
            || lower.contains("page ")
            || value.contains(" - ")
            || value.contains("/")
    }

    private static func semanticRole(for title: String) -> String? {
        let lower = title.lowercased()
        if lower.contains(".pdf") { return "lease_pdf" }
        if lower.contains("google docs") || lower.contains("document") { return "google_doc" }
        if lower.contains("mail") || lower.contains("inbox") { return "email" }
        if lower.contains("lease") || lower.contains("rental") || lower.contains("agreement") { return "rental_document" }
        return "window"
    }

    private static func fileExtension(from title: String) -> String? {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ext = cleaned.split(separator: ".").last, ext.count <= 5 else { return nil }
        let lower = ext.lowercased()
        let known = ["pdf", "doc", "docx", "txt", "md", "pages", "rtf"]
        return known.contains(lower) ? lower : nil
    }

    private static func appNameForBundle(_ bundleID: String, fallback: String) -> String {
        guard !bundleID.isEmpty else { return fallback }
        if let match = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })?.localizedName, !match.isEmpty {
            return match
        }
        return fallback
    }

    private func logWorkspaceState(
        item: String,
        type: String,
        state: WorkspaceStoredItemState,
        present: Bool,
        visible: Bool,
        reason: String
    ) {
        print("[WorkspaceMissingCheck] item=\(item) type=\(type) present=\(present ? "yes" : "no") visible=\(visible ? "yes" : "no") reason=\(reason)")
        print("[WorkspaceItemState] item=\(item) state=\(state.rawValue)")
    }

    private static func hash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private func recurringHourScore(_ buckets: [String: Int]) -> Int {
        buckets.filter { !$0.key.hasPrefix("session:") && $0.value >= 2 }.count
    }
}

// MARK: - Phase 35 Acquisition Coordinator

final class ContextAcquisitionCoordinator: @unchecked Sendable {
    static let shared = ContextAcquisitionCoordinator()

    enum Level: Int, Sendable {
        case metadataOnly = 0
        case lightweightStructured = 1
        case visibleRegion = 2
        case adapter = 3
        case userApprovedDeep = 4
    }

    struct Request: Sendable {
        let reason: String
        let desiredLevel: Level
        let activeApp: String
        let bundleIdentifier: String?
        let windowTitle: String
        let browserContext: BrowserContextExtractor.BrowserContext?
        let appCategory: AppContextAnalyzer.Category?
        let explicitUserInitiated: Bool
        let allowExpensive: Bool
        let currentEvidence: ProgressiveEvidenceLevel
        var stableSeconds: TimeInterval = 0
        var focusActionable: Bool = false
        var modelBusy: Bool = false
        var privacyAllowed: Bool = true
    }

    struct Result: Sendable {
        let allowedLevel: Level
        let browserAssessment: BrowserContextAssessment?
        let evidenceProfile: EvidenceProfile
        let acquiredAXChars: Int
        let acquiredOCRChars: Int
        let cachedKey: String
    }

    private struct CachedVisibleResult {
        let cachedAt: Date
        let axChars: Int
        let ocrChars: Int
        let browserAssessment: BrowserContextAssessment?
        let evidenceProfile: EvidenceProfile
    }

    private let queue = DispatchQueue(label: "ContextAcquisitionCoordinator", qos: .utility)
    private var cache: [String: CachedVisibleResult] = [:]
    private let cacheTTL: TimeInterval = 30

    private init() {}

    public static var lastAcquiredBrowserURL: String? = nil

    func acquire(_ request: Request) async -> Result {
        if let url = request.browserContext?.selectedURL?.absoluteString ?? request.browserContext?.currentURL?.absoluteString {
            ContextAcquisitionCoordinator.lastAcquiredBrowserURL = url
        }
        let focusKey = EnrichedContextCache.focusKey(
            activeApp: request.activeApp,
            windowTitle: request.windowTitle,
            url: request.browserContext?.selectedURL?.absoluteString ?? request.browserContext?.currentURL?.absoluteString
        )
        let recentEnriched = EnrichedContextCache.shared.lookup(key: focusKey, logHit: false)
        let baseAllowedLevel = allowedLevel(for: request)
        let enrichmentDecision = ContextEnrichmentPolicy.evaluate(
            request: request,
            baseAllowedLevel: baseAllowedLevel,
            hasRecentCache: recentEnriched != nil
        )
        let allowedLevel = maxLevel(baseAllowedLevel, enrichmentDecision.level)
        let budget = allowedLevel.rawValue >= Level.visibleRegion.rawValue ? "bounded" : "cheap"
        print("[ContextAcquisition] requested reason=\(request.reason) desired_level=\(request.desiredLevel.rawValue) allowed_level=\(allowedLevel.rawValue) budget=\(budget)")
        enrichmentDecision.log(focusKey: focusKey, stableSeconds: request.stableSeconds)

        // Fix 5: the visible-result cache is bound to the SELECTED tab's URL (not
        // just app+title). A tab switch changes the URL component, so a previous
        // tab's visible result can never be reused for the new current focus. The
        // enriched-text cache (focusKey above) is already URL-bound; this closes the
        // same gap for the browser assessment / evidence profile.
        let selectedURLForKey = request.browserContext?.selectedURL?.absoluteString
            ?? request.browserContext?.currentURL?.absoluteString
        let cacheKey = "\(request.activeApp.lowercased())|\(request.windowTitle.lowercased())|\(selectedURLForKey?.lowercased() ?? "no_url")|\(allowedLevel.rawValue)"
        let redactedTitle = "len:\(request.windowTitle.count)"
        print("[SelectedTabAuthorityCheck] selected_title=\(redactedTitle) selected_url_present=\(selectedURLForKey != nil ? "yes" : "no") cache_key_matches=yes status=pass")
        print("[NoSelectedTabAuthorityMismatch] status=pass count=0")
        if let cached = queue.sync(execute: { cache[cacheKey] }), Date().timeIntervalSince(cached.cachedAt) < cacheTTL {
            let ttl = Int(max(1, cacheTTL - Date().timeIntervalSince(cached.cachedAt)))
            print("[ContextAcquisition] cached key=\(cacheKey) ttl_s=\(ttl)")
            _ = EnrichedContextCache.shared.lookup(key: focusKey, logHit: true)
            return Result(
                allowedLevel: allowedLevel,
                browserAssessment: cached.browserAssessment,
                evidenceProfile: cached.evidenceProfile,
                acquiredAXChars: cached.axChars,
                acquiredOCRChars: cached.ocrChars,
                cachedKey: cacheKey
            )
        }

        print("[ContextAcquisition] content_scope=\(allowedLevel == .metadataOnly ? "metadata" : allowedLevel == .lightweightStructured ? "focused_element" : "visible_region")")

        let browserAssessment = request.browserContext.map {
            BrowserContextStrategy.assess(
                title: $0.selectedTitle,
                url: $0.currentURL,
                tabTitles: $0.recentTabTitles,
                hasAXText: false,
                hasOCR: false
            )
        }
        print("[ContextAcquisition] source=metadata status=success reason=frontmost_context")
        if request.browserContext != nil {
            print("[ContextAcquisition] source=browser status=success reason=browser_metadata")
        } else {
            print("[ContextAcquisition] source=browser status=skipped reason=not_browser")
        }

        var axChars = 0
        var ocrChars = 0
        
        // Only run enrichment if policy allowed it
        if allowedLevel.rawValue >= Level.lightweightStructured.rawValue && enrichmentDecision.allowed {
            print("[PeriodicContextRefresh] started tier=ax reason=\(enrichmentDecision.reason)")
            print("[ContextEnrichmentAttempt] source=selected_text status=skipped chars=0 quality=none reason=no_safe_selection_reader")
            let ax = OnDemandContextAcquisition.requestAXText(reason: request.reason)
            axChars = ax.chars
            print("[ContextAcquisition] source=ax status=\(ax.success ? "success" : "unavailable") reason=\(ax.reason)")
            let axSource = request.browserContext == nil ? "ax_visible_text" : "browser_ax"
            let axStatus = ax.success ? "success" : (ax.chars == 0 ? "empty" : "failed")
            print("[ContextEnrichmentAttempt] source=\(axSource) status=\(axStatus) chars=\(ax.chars) quality=\(ax.success ? "ax_visible_text" : "none")")
            if ax.success, let content = ax.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EnrichedContextCache.shared.store(
                    source: axSource,
                    text: content,
                    quality: "ax_visible_text",
                    confidence: 0.78,
                    focusKey: focusKey,
                    urlOrWindow: request.browserContext?.selectedURL?.absoluteString
                        ?? request.browserContext?.currentURL?.absoluteString
                        ?? request.windowTitle,
                    ttl: 120,
                    region: axSource == "browser_ax" ? "browser_web_area" : "active_window",
                    contaminationWarning: nil
                )
                print("[ContextEnrichmentStored] key=\(focusKey) source=\(axSource) chars=\(content.count) ttl_s=120 usable_for=proposal_generation,action_execution")
                if request.currentEvidence.rank <= ProgressiveEvidenceLevel.metadata_rich.rank {
                    print("[EvidenceQualityUpgrade] old=\(request.currentEvidence.rawValue) new=ax_visible_text reason=periodic_context_enrichment")
                }
            }
        } else {
            print("[ContextAcquisition] source=ax status=skipped reason=level_budget_or_policy")
            // Policy already logged skipped
        }

        // Acquisition health — a readable browser focus (URL present) whose visible
        // body text did not come through is flagged. An unstable-focus / budget skip
        // is a legitimate defer that resolves once the user dwells; an empty AX result
        // on an otherwise-readable page is a real acquisition failure. Either way the
        // page still classifies from its URL/title, so it is never marked "unknown"
        // purely because body-text acquisition was missing.
        if request.browserContext != nil {
            let hasURL = (request.browserContext?.selectedURL ?? request.browserContext?.currentURL) != nil
            if hasURL && axChars == 0 {
                let reason = enrichmentDecision.allowed
                    ? "ax_text_empty_on_readable_browser"
                    : "ax_text_pending_\(enrichmentDecision.reason)"
                print("[ContentAcquisitionFailure] reason=\(reason)")
            }
            print("[NoHumanReadableCurrentFocusClassifiedUnknownBecauseAcquisitionMissing] status=pass count=0")
        }

        if allowedLevel.rawValue >= Level.visibleRegion.rawValue && enrichmentDecision.allowed && enrichmentDecision.tier == 2 {
            if request.allowExpensive {
                print("[PeriodicContextRefresh] started tier=ocr reason=\(enrichmentDecision.reason)")
                let ocr = await OnDemandContextAcquisition.requestOCR(reason: request.reason, appName: request.activeApp, windowTitle: request.windowTitle)
                ocrChars = ocr.chars
                print("[ContextAcquisition] source=ocr status=\(ocr.success ? "success" : "unavailable") reason=\(ocr.reason)")
                print("[ContextEnrichmentAttempt] source=ocr_visible_region status=\(ocr.success ? "success" : (ocr.chars == 0 ? "empty" : "failed")) chars=\(ocr.chars) quality=\(ocr.success ? "ocr_visible_text" : "none")")
                if ocr.success, let content = ocr.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    EnrichedContextCache.shared.store(
                        source: "ocr_visible_region",
                        text: content,
                        quality: "ocr_visible_text",
                        confidence: 0.62,
                        focusKey: focusKey,
                        urlOrWindow: request.browserContext?.selectedURL?.absoluteString
                            ?? request.browserContext?.currentURL?.absoluteString
                            ?? request.windowTitle,
                        ttl: 90,
                        region: "visible_region",
                        contaminationWarning: "ocr_may_include_nearby_chrome"
                    )
                    print("[ContextEnrichmentStored] key=\(focusKey) source=ocr_visible_region chars=\(content.count) ttl_s=90 usable_for=proposal_generation,action_execution")
                    if request.currentEvidence.rank <= ProgressiveEvidenceLevel.metadata_rich.rank {
                        print("[EvidenceQualityUpgrade] old=\(request.currentEvidence.rawValue) new=ocr_visible_text reason=periodic_context_enrichment")
                    }
                }
                print("[ContextAcquisition] source=visual status=skipped reason=level2_ocr_only")
            } else {
                print("[ContextAcquisition] source=ocr status=skipped reason=budget_blocked")
                print("[ContextAcquisition] source=visual status=skipped reason=budget_blocked")
            }
        } else {
            print("[ContextAcquisition] source=ocr status=skipped reason=level_budget_or_policy")
            print("[ContextAcquisition] source=visual status=skipped reason=level_budget_or_policy")
        }

        let profile = EvidenceQualityModel.evaluate(
            title: request.windowTitle,
            url: request.browserContext?.currentURL,
            tabTitles: request.browserContext?.recentTabTitles ?? [],
            hasAXText: axChars > 0,
            hasOCR: ocrChars > 0,
            hasSelectedText: false,
            semanticGrounding: false,
            durableCompartment: false,
            browserAssessment: browserAssessment
        )
        let cached = CachedVisibleResult(
            cachedAt: Date(),
            axChars: axChars,
            ocrChars: ocrChars,
            browserAssessment: browserAssessment,
            evidenceProfile: profile
        )
        queue.sync { cache[cacheKey] = cached }
        print("[ContextAcquisition] cached key=\(cacheKey) ttl_s=\(Int(cacheTTL))")
        return Result(
            allowedLevel: allowedLevel,
            browserAssessment: browserAssessment,
            evidenceProfile: profile,
            acquiredAXChars: axChars,
            acquiredOCRChars: ocrChars,
            cachedKey: cacheKey
        )
    }

    private func allowedLevel(for request: Request) -> Level {
        switch request.desiredLevel {
        case .userApprovedDeep:
            return request.explicitUserInitiated ? .visibleRegion : .lightweightStructured
        case .adapter:
            return .lightweightStructured
        case .visibleRegion:
            return (request.explicitUserInitiated && request.allowExpensive) ? .visibleRegion : .lightweightStructured
        case .lightweightStructured:
            return .lightweightStructured
        case .metadataOnly:
            return .metadataOnly
        }
    }

    private func maxLevel(_ lhs: Level, _ rhs: Level) -> Level {
        lhs.rawValue >= rhs.rawValue ? lhs : rhs
    }
}

// MARK: - Periodic context enrichment

struct EnrichedContextSnapshot: Sendable, Equatable {
    let key: String
    let source: String
    let text: String
    let chars: Int
    let quality: String
    let confidence: Double
    let focusSignature: String
    let urlOrWindow: String
    let timestamp: Date
    let ttl: TimeInterval
    let region: String?
    let contaminationWarning: String?

    var ageSeconds: TimeInterval { Date().timeIntervalSince(timestamp) }
    var expired: Bool { ageSeconds > ttl }
    var evidenceLevel: String {
        if quality == "full_document_text" || source == "full_document" { return "full_document" }
        if quality.contains("ocr") || source.contains("ocr") { return "ocr_text" }
        if quality.contains("ax") || source.contains("ax") { return "ax_text" }
        return "visible_text"
    }
}

final class EnrichedContextCache: @unchecked Sendable {
    static let shared = EnrichedContextCache()
    private let lock = NSLock()
    private var entries: [String: EnrichedContextSnapshot] = [:]

    private init() {}

    static func focusKey(activeApp: String, windowTitle: String, url: String?) -> String {
        let raw = [
            activeApp.lowercased(),
            windowTitle.lowercased(),
            (url ?? "").lowercased()
        ].joined(separator: "|")
        let clean = raw
            .replacingOccurrences(of: #"[^a-z0-9:/._|?-]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_|"))
        return clean.isEmpty ? "unknown_focus" : String(clean.prefix(120))
    }

    @discardableResult
    func store(
        source: String,
        text: String,
        quality: String,
        confidence: Double,
        focusKey: String,
        urlOrWindow: String,
        ttl: TimeInterval,
        region: String?,
        contaminationWarning: String?,
        authority: EnrichedContextAuthorityLevel = .currentFocus,
        selectedTab: String = ""
    ) -> EnrichedContextSnapshot {
        let clipped = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
        let entry = EnrichedContextSnapshot(
            key: focusKey,
            source: source,
            text: clipped,
            chars: clipped.count,
            quality: quality,
            confidence: confidence,
            focusSignature: focusKey,
            urlOrWindow: String(urlOrWindow.prefix(160)),
            timestamp: Date(),
            ttl: ttl,
            region: region,
            contaminationWarning: authority == .currentFocus ? contaminationWarning : "background_authority"
        )
        print("[ContextAuthority] source=\(source) authority=\(authority.rawValue) selected_tab=\(selectedTab.isEmpty ? "none" : String(selectedTab.prefix(40))) cache_key=\(focusKey)")
        // Enriched text that does not belong to the selected tab must NOT be cached
        // as current focus: it would upgrade current-focus evidence and leak its
        // terms into current-action proposals. Reject it for current-focus use.
        guard authority == .currentFocus else {
            print("[EnrichedContextRejected] reason=selected_tab_mismatch authority=\(authority.rawValue)")
            return entry
        }
        print("[ContextEnrichmentAttempt] source=\(source) status=success chars=\(entry.chars) quality=\(quality)")
        lock.lock()
        entries[focusKey] = entry
        lock.unlock()
        print("[EnrichedContextCacheWrite] key=\(focusKey) source=\(source) chars=\(entry.chars) quality=\(quality) ttl_s=\(Int(ttl)) privacy=short_ttl_local authority=current_focus")
        return entry
    }

    func lookup(key: String, logHit: Bool = true) -> EnrichedContextSnapshot? {
        lock.lock()
        let entry = entries[key]
        if entry?.expired == true {
            entries.removeValue(forKey: key)
        }
        lock.unlock()
        guard let entry, !entry.expired else { return nil }
        if logHit {
            print("[EnrichedContextCacheHit] key=\(key) source=\(entry.source) chars=\(entry.chars) age_s=\(Int(entry.ageSeconds))")
        }
        return entry
    }

    func latestUsable(logHit: Bool = true) -> EnrichedContextSnapshot? {
        lock.lock()
        let live = entries.values.filter { !$0.expired }.sorted { $0.timestamp > $1.timestamp }
        entries = Dictionary(uniqueKeysWithValues: live.map { ($0.key, $0) })
        lock.unlock()
        guard let entry = live.first else { return nil }
        if logHit {
            print("[EnrichedContextCacheHit] key=\(entry.key) source=\(entry.source) chars=\(entry.chars) age_s=\(Int(entry.ageSeconds))")
        }
        return entry
    }

    static func contentTerms(from text: String, limit: Int = 6) -> [String] {
        let stop: Set<String> = ["the", "and", "for", "with", "from", "that", "this", "have", "will", "your", "into", "page"]
        var seen = Set<String>()
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && $0.count <= 18 && !stop.contains($0) }
            .filter { seen.insert($0).inserted }
            .prefix(limit)
            .map { $0 }
    }

    func resetForTests() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

// MARK: - Enriched-context authority (selected-tab vs background/stale)
//
// The live failure: the SELECTED tab is Facebook, but the browser WINDOW title
// still reads "182 Montreal St - OCCUPANCY AGREEMENT - Google Docs" (a stale
// background tab). The AX read of the active window returned the lease text and
// it was cached under the lease title — then it upgraded the *current-focus*
// EvidenceQuality and leaked lease terms (montreal/occupancy/agreement) into the
// Facebook current-content proposal. Enriched text must be tied to the SELECTED
// tab; text that belongs to a different tab/document is `background`, not current
// focus, and must never upgrade current focus or feed current-action proposals.
public enum EnrichedContextAuthorityLevel: String, Sendable {
    case currentFocus = "current_focus"
    case background = "background"
    case stale = "stale"
}

enum EnrichedContextAuthority {

    static func norm(_ s: String?) -> String {
        (s ?? "").lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
            .joined(separator: " ")
    }

    static func host(_ url: String?) -> String {
        guard let url = url?.lowercased(), !url.isEmpty else { return "" }
        var h = url
        for p in ["https://", "http://", "www."] { if h.hasPrefix(p) { h = String(h.dropFirst(p.count)) } }
        h = h.replacingOccurrences(of: "www.", with: "")
        return String(h.prefix(while: { $0 != "/" && $0 != "?" }))
    }

    static func termOverlap(_ a: String, _ b: String) -> Double {
        let stop: Set<String> = ["the", "and", "for", "with", "from", "google", "docs", "doc", "com", "org", "net", "page", "tab"]
        let at = Set(a.split(separator: " ").map(String.init).filter { !stop.contains($0) })
        let bt = Set(b.split(separator: " ").map(String.init).filter { !stop.contains($0) })
        guard !at.isEmpty else { return 0 }
        let inter = at.intersection(bt).count
        return Double(inter) / Double(at.count)
    }

    /// Decide whether enriched text read from the active window actually belongs
    /// to the SELECTED tab (current focus) or to a stale/background document whose
    /// title merely lingers in the window title.
    static func classify(
        selectedTabTitle: String?,
        selectedTabURL: String?,
        candidateTitle: String,
        candidateURL: String?,
        enrichedText: String
    ) -> EnrichedContextAuthorityLevel {
        let selTitle = norm(selectedTabTitle)
        let selHost = host(selectedTabURL)
        // No selected-tab signal at all → trust the candidate (back-compat).
        if selTitle.isEmpty && selHost.isEmpty { return .currentFocus }

        let candHost = host(candidateURL)
        // URL host is the strongest signal when both are known.
        if !selHost.isEmpty, !candHost.isEmpty {
            return selHost == candHost ? .currentFocus : .background
        }
        // If the selected-tab host doesn't appear in the candidate title/url/body
        // and there's no term overlap, the enriched text is a different document.
        let candTitle = norm(candidateTitle)
        let titleOverlap = termOverlap(selTitle, candTitle)
        if titleOverlap >= 0.34 { return .currentFocus }
        let bodyOverlap = termOverlap(selTitle, norm(enrichedText))
        if bodyOverlap >= 0.2 { return .currentFocus }
        // Selected host name appearing in candidate title (e.g. "facebook") also counts.
        if !selHost.isEmpty {
            let selName = selHost.split(separator: ".").first.map(String.init) ?? selHost
            if candTitle.contains(selName) { return .currentFocus }
        }
        return .background
    }

    /// Terms in `contentTerms` that came from background docs (present in the
    /// background-entity terms but not in the current-focus terms). Non-empty ⇒
    /// the current content is contaminated by a background document.
    static func contaminationTerms(currentFocusTerms: [String], backgroundTerms: [String], contentTerms: [String]) -> [String] {
        let focus = Set(currentFocusTerms.map { $0.lowercased() })
        let bg = Set(backgroundTerms.map { $0.lowercased() })
        return contentTerms
            .map { $0.lowercased() }
            .filter { bg.contains($0) && !focus.contains($0) }
    }
}

private struct ContextEnrichmentDecision {
    let allowed: Bool
    let level: ContextAcquisitionCoordinator.Level
    let tier: Int
    let reason: String

    func log(focusKey: String, stableSeconds: TimeInterval) {
        print("[ContextEnrichmentPolicy] focus=\(focusKey) stable_s=\(Int(stableSeconds)) tier=\(tier) allowed=\(allowed ? "yes" : "no") reason=\(reason)")
        if allowed {
            print("[PeriodicContextRefresh] started tier=\(tier == 2 ? "ocr" : tier == 1 ? "ax" : "cheap") reason=\(reason)")
        } else {
            print("[PeriodicContextRefresh] skipped tier=\(tier == 2 ? "ocr" : tier == 1 ? "ax" : "cheap") reason=\(reason)")
        }
    }
}

private enum ContextEnrichmentPolicy {
    static func evaluate(
        request: ContextAcquisitionCoordinator.Request,
        baseAllowedLevel: ContextAcquisitionCoordinator.Level,
        hasRecentCache: Bool
    ) -> ContextEnrichmentDecision {
        guard request.privacyAllowed else {
            return ContextEnrichmentDecision(allowed: false, level: baseAllowedLevel, tier: 1, reason: "privacy")
        }
        guard !request.modelBusy else {
            return ContextEnrichmentDecision(allowed: false, level: baseAllowedLevel, tier: 1, reason: "model_busy")
        }
        guard !hasRecentCache else {
            return ContextEnrichmentDecision(allowed: false, level: baseAllowedLevel, tier: 1, reason: "recent_cache")
        }
        guard request.focusActionable else {
            return ContextEnrichmentDecision(allowed: false, level: baseAllowedLevel, tier: 1, reason: "not_actionable")
        }
        guard request.stableSeconds >= 8 || request.explicitUserInitiated else {
            return ContextEnrichmentDecision(allowed: false, level: baseAllowedLevel, tier: 1, reason: "unstable_focus")
        }
        if request.allowExpensive && request.stableSeconds >= 45 && request.currentEvidence.rank < ProgressiveEvidenceLevel.visible_content.rank {
            return ContextEnrichmentDecision(allowed: true, level: .visibleRegion, tier: 2, reason: "reading_dwell")
        }
        return ContextEnrichmentDecision(allowed: true, level: .lightweightStructured, tier: 1, reason: "stable_focus")
    }
}

// MARK: - Phase 35 Self-test

enum Phase35SelfTest {
    static func run() async -> Bool {
        print("[Phase35SelfTest] starting")
        DurableMemory.shared.resetForTests()
        WorkspaceRuntimeInventoryProvider.testSnapshot = nil
        defer { WorkspaceRuntimeInventoryProvider.testSnapshot = nil }
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if condition {
                print("[Phase35SelfTest] pass case=\(name)")
            } else {
                print("[Phase35SelfTest] fail case=\(name)")
                failures.append(name)
            }
        }

        // Test 1 — rental workflow metadata-rich
        let browser1 = BrowserContextAssessment(
            kind: .listing,
            evidence: ["url", "title", "tabs"],
            contentAvailable: false,
            reason: "listing_terms",
            safeActions: [],
            blockedActions: []
        )
        let profile1 = EvidenceQualityModel.evaluate(
            title: "182 Montreal - Google Docs",
            url: URL(string: "https://docs.google.com/document/d/example"),
            tabTitles: ["182 Montreal", "Lease draft"],
            hasAXText: false,
            hasOCR: false,
            hasSelectedText: false,
            semanticGrounding: true,
            durableCompartment: true,
            browserAssessment: browser1
        )
        check("rental_metadata_rich_not_title_only", profile1.level == .metadata_rich)
        let eligibility1 = ActionRegistry.evaluate(capabilityId: "restore_workspace", currentEvidence: profile1.level, hasURLs: true)
        check("metadata_rich_allows_friction", eligibility1.eligible)
        let blocked1 = ActionRegistry.evaluate(capabilityId: "generate_quiz", currentEvidence: profile1.level)
        check("metadata_rich_blocks_full_summary_actions", !blocked1.eligible)

        // Test 2 — selected text
        let profile2 = EvidenceQualityModel.evaluate(
            title: "Lease draft",
            url: nil,
            tabTitles: [],
            hasAXText: false,
            hasOCR: false,
            hasSelectedText: true,
            semanticGrounding: false,
            durableCompartment: false,
            browserAssessment: nil
        )
        check("selected_text_evidence_level", profile2.level == .selected_content)
        let rewriteEligible = ActionRegistry.evaluate(capabilityId: "rewrite_text", currentEvidence: profile2.level, hasSelection: true)
        check("selected_content_actions_eligible", rewriteEligible.eligible)
        let fullBlocked = ActionRegistry.evaluate(capabilityId: "compare_options", currentEvidence: profile2.level)
        check("selected_content_no_full_document_claims", !fullBlocked.eligible)

        // Test 3 — visible OCR explicit trigger
        let acquisition3 = await ContextAcquisitionCoordinator.shared.acquire(.init(
            reason: "explicit_visible_content",
            desiredLevel: .visibleRegion,
            activeApp: "Preview",
            bundleIdentifier: "com.apple.Preview",
            windowTitle: "Lease",
            browserContext: nil,
            appCategory: .pdf,
            explicitUserInitiated: true,
            allowExpensive: true,
            currentEvidence: .metadata_rich
        ))
        check("visible_trigger_requests_level2", acquisition3.allowedLevel == .visibleRegion)
        check("visible_trigger_cached", !acquisition3.cachedKey.isEmpty)

        // Test 4 — workspace memory durability + schema split
        DurableMemory.shared.recordWorkspaceObservation(
            workflow: "researching",
            compartment: "rental",
            apps: ["Firefox", "Preview"],
            bundleIDs: ["org.mozilla.firefox", "com.apple.Preview"],
            urls: ["https://example.com/a"],
            tabTitles: ["A"],
            windowTitle: "Lease"
        )
        DurableMemory.shared.recordWorkspaceObservation(
            workflow: "researching",
            compartment: "rental",
            apps: ["Firefox", "Preview"],
            bundleIDs: ["org.mozilla.firefox", "com.apple.Preview"],
            urls: ["https://example.com/a", "https://example.com/b"],
            tabTitles: ["A", "B"],
            windowTitle: "Lease"
        )
        DurableMemory.shared.recordWorkspaceObservation(
            workflow: "researching",
            compartment: "rental",
            apps: ["Firefox", "Preview"],
            bundleIDs: ["org.mozilla.firefox", "com.apple.Preview"],
            urls: ["https://example.com/a", "https://example.com/b"],
            tabTitles: ["A", "B"],
            windowTitle: "Lease"
        )
        DurableMemory.shared.recordWorkspaceObservation(
            workflow: "researching",
            compartment: "rental",
            apps: ["Firefox", "Preview", "182 Montreal St - OCCUPANCY AGREEMENT - 2026 - Google Docs", "_182_Montreal_Street_Accommodation_Agreement_Final_Version_EN.pdf"],
            bundleIDs: ["org.mozilla.firefox", "com.apple.Preview", "org.mozilla.firefox", "com.apple.Preview"],
            urls: ["https://example.com/a"],
            tabTitles: ["182 Montreal St - OCCUPANCY AGREEMENT - 2026 - Google Docs"],
            windowTitle: "_182_Montreal_Street_Accommodation_Agreement_Final_Version_EN.pdf"
        )
        let durablePattern = DurableMemory.shared.bestDurableWorkspacePattern(workflow: "researching", compartment: "rental", currentApps: Set(["Firefox", "Preview"]))
        check("workspace_pattern_becomes_durable", durablePattern?.durable == true)
        if let durablePattern {
            check("workspace_schema_keeps_app_records", durablePattern.apps.count >= 2 && durablePattern.apps.allSatisfy { !$0.appName.contains(".pdf") && !$0.appName.contains("Google Docs") })
            check("workspace_schema_has_documents", !durablePattern.documents.isEmpty)

            WorkspaceRuntimeInventoryProvider.testSnapshot = WorkspaceRuntimeInventory(
                runningApps: [
                    WorkspaceAppRecord(bundleID: "org.mozilla.firefox", appName: "Firefox"),
                    WorkspaceAppRecord(bundleID: "com.apple.Preview", appName: "Preview")
                ],
                visibleWindows: [
                    WindowSnapshot(windowID: 1, appName: "Firefox", bundleID: "org.mozilla.firefox", pid: 100, title: "182 Montreal St - OCCUPANCY AGREEMENT - 2026 - Google Docs", frame: .init(x: 0, y: 0, width: 900, height: 700), layer: 0, isOnScreen: true, isOnActiveScreen: true),
                    WindowSnapshot(windowID: 2, appName: "Preview", bundleID: "com.apple.Preview", pid: 101, title: "_182_Montreal_Street_Accommodation_Agreement_Final_Version_EN.pdf", frame: .init(x: 920, y: 0, width: 800, height: 700), layer: 0, isOnScreen: true, isOnActiveScreen: true)
                ],
                browserTabTitles: ["182 Montreal St - OCCUPANCY AGREEMENT - 2026 - Google Docs"],
                currentURLs: ["https://example.com/a"],
                frontmostAppName: "Firefox",
                frontmostBundleID: "org.mozilla.firefox"
            )
            let allOpen = DurableMemory.shared.missingCheck(pattern: durablePattern, currentApps: Set(["Firefox", "Preview"]), currentURLs: ["https://example.com/a"])
            check("workspace_all_items_open_not_restore", !allOpen.canRestore && allOpen.reason == "items_present_backgrounded")

            WorkspaceRuntimeInventoryProvider.testSnapshot = WorkspaceRuntimeInventory(
                runningApps: [
                    WorkspaceAppRecord(bundleID: "org.mozilla.firefox", appName: "Firefox"),
                    WorkspaceAppRecord(bundleID: "com.apple.Preview", appName: "Preview")
                ],
                visibleWindows: [
                    WindowSnapshot(windowID: 2, appName: "Preview", bundleID: "com.apple.Preview", pid: 101, title: "_182_Montreal_Street_Accommodation_Agreement_Final_Version_EN.pdf", frame: .init(x: 0, y: 0, width: 800, height: 700), layer: 0, isOnScreen: true, isOnActiveScreen: true),
                    WindowSnapshot(windowID: 1, appName: "Firefox", bundleID: "org.mozilla.firefox", pid: 100, title: "182 Montreal St - OCCUPANCY AGREEMENT - 2026 - Google Docs", frame: .init(x: 820, y: 0, width: 900, height: 700), layer: 0, isOnScreen: true, isOnActiveScreen: true)
                ],
                browserTabTitles: ["182 Montreal St - OCCUPANCY AGREEMENT - 2026 - Google Docs"],
                currentURLs: ["https://example.com/a"],
                frontmostAppName: "Preview",
                frontmostBundleID: "com.apple.Preview"
            )
            let previewForeground = DurableMemory.shared.missingCheck(pattern: durablePattern, currentApps: Set(["Firefox", "Preview"]), currentURLs: ["https://example.com/a"])
            check("workspace_preview_foreground_not_restore", !previewForeground.canRestore && previewForeground.reason == "items_present_backgrounded")

            WorkspaceRuntimeInventoryProvider.testSnapshot = WorkspaceRuntimeInventory(
                runningApps: [
                    WorkspaceAppRecord(bundleID: "org.mozilla.firefox", appName: "Firefox")
                ],
                visibleWindows: [
                    WindowSnapshot(windowID: 1, appName: "Firefox", bundleID: "org.mozilla.firefox", pid: 100, title: "182 Montreal St - OCCUPANCY AGREEMENT - 2026 - Google Docs", frame: .init(x: 0, y: 0, width: 900, height: 700), layer: 0, isOnScreen: true, isOnActiveScreen: true)
                ],
                browserTabTitles: ["182 Montreal St - OCCUPANCY AGREEMENT - 2026 - Google Docs"],
                currentURLs: ["https://example.com/a"],
                frontmostAppName: "Firefox",
                frontmostBundleID: "org.mozilla.firefox"
            )
            let previewClosed = DurableMemory.shared.missingCheck(pattern: durablePattern, currentApps: Set(["Firefox"]), currentURLs: ["https://example.com/a"])
            check("workspace_closed_preview_can_restore", previewClosed.canRestore && previewClosed.missingApps.contains("Preview"))

            let urlPayload = LocalActionPayloadValidator.validate(
                capabilityId: "copy_current_url",
                involvedApps: [],
                involvedURLs: ["https://example.com/a"],
                browserTabTitles: ["182 Montreal St - OCCUPANCY AGREEMENT - 2026 - Google Docs"],
                compartmentLabel: "rental"
            )
            check("copy_current_url_payload_valid", urlPayload.valid && urlPayload.reason == "current_url_available")

            let restoreKey = previewClosed.restoreKey
            DurableMemory.shared.recordRestoreFeedback(restoreKey: restoreKey, event: .ignored)
            check("restore_feedback_cools_down", DurableMemory.shared.shouldSuppressRestoreSuggestion(restoreKey: restoreKey))
        } else {
            check("workspace_schema_keeps_app_records", false)
            check("workspace_schema_has_documents", false)
            check("workspace_all_items_open_not_restore", false)
            check("workspace_preview_foreground_not_restore", false)
            check("workspace_closed_preview_can_restore", false)
            check("copy_current_url_payload_valid", false)
            check("restore_feedback_cools_down", false)
        }

        // Test 5 — music memory
        let musicContext = DurableMemoryContext.build(workflow: "coding", compartment: "coding", app: "xcode", activity: "active", browserType: "none")
        DurableMemory.shared.recordMusicPreference(playlist: "Favourite Songs", context: musicContext, source: "accepted_action")
        let suppression = DurableMemory.shared.shouldSuppressMusicSuggestion(context: musicContext, isPlaying: true)
        check("music_preference_stored", suppression == "already_playing")

        // Test 6 — browser context strategy
        let browser6 = BrowserContextStrategy.assess(
            title: "Inbox - Gmail",
            url: URL(string: "https://mail.google.com/mail/u/0/#inbox"),
            tabTitles: ["Inbox - Gmail"],
            hasAXText: false,
            hasOCR: false
        )
        check("browser_type_identified", browser6.kind == .gmail)
        check("browser_metadata_actions_only", browser6.contentAvailable == false && browser6.blockedActions.contains("summarize_visible_content"))

        // Test 7 — quietness explanation
        let blocked = ActionRegistry.evaluate(capabilityId: "create_checklist", currentEvidence: .metadata_only)
        QuietDecisionLogger.emit(
            shown: false,
            reason: "insufficient_content",
            bestBlockedAction: blocked.capabilityId,
            missingContext: blocked.reason,
            nextContextNeeded: blocked.nextContextNeeded
        )
        check("quietness_explainable", blocked.nextContextNeeded == "ax_text")

        let ok = failures.isEmpty
        print("[Phase35SelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
