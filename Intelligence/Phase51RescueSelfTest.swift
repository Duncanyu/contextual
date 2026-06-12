import Foundation
import AppKit

// MARK: - Phase 51 (Rescue Sprint) Self-Test + Dogfood Matrix
//
// Validates the honesty layer end to end:
//   - ContentScope truth table (AX/OCR can never be full_page/full_document)
//   - scope gates and scope-truth titles
//   - Google Docs partial AX downgrade
//   - result card source/scope labels
//   - panel ranking sections + suppression
//   - manual vs proactive side-by-side
//   - music suppression / no random playlist fallback
//
// The dogfood matrix runs the same invariants over 10 deterministic fixtures
// modeled on the real dogfood scenarios (Firefox page, Google Docs, listing,
// Gmail, PDF, TextEdit, code/logs, music, manual/proactive arrange).

@MainActor
struct Phase51RescueSelfTest {

    private static var failures: [String] = []

    private static func check(_ label: String, _ condition: Bool) {
        if condition {
            print("[Phase51SelfTest] pass case=\(label)")
        } else {
            print("[Phase51SelfTest] FAIL case=\(label)")
            failures.append(label)
        }
    }

    private static func makeResult(
        text: String,
        quality: ContentQuality,
        coverage: ContentCoverage,
        source: ContentSource
    ) -> UniversalContentResult {
        UniversalContentResult(
            text: text, quality: quality, coverage: coverage, source: source,
            confidence: 0.9, attemptedRoutes: [], missingReason: nil, nextStep: .captureVisible
        )
    }

    static func run() async -> Bool {
        print("[Phase51SelfTest] starting")
        failures = []

        // T1 — Scope truth table.
        check("t1_ax_visible_never_full_page",
              ContentScopeModel.derive(source: .browserAX, quality: .axVisibleText, coverage: .visible) == .visibleViewport)
        check("t1_ax_partial_is_partial_visible",
              ContentScopeModel.derive(source: .browserAX, quality: .axVisibleText, coverage: .partial) == .partialVisibleText)
        check("t1_ocr_never_full_page",
              ContentScopeModel.derive(source: .ocrCapture, quality: .visibleOCR, coverage: .visible) == .visibleViewport)
        check("t1_metadata_is_metadata_only",
              ContentScopeModel.derive(source: .browserMetadata, quality: .metadataOnly, coverage: .minimal) == .metadataOnly)
        check("t1_pdf_full_is_full_document",
              ContentScopeModel.derive(source: .pdfKit, quality: .fullDocumentText, coverage: .full) == .fullDocument)
        check("t1_clipboard_capture_full_is_full_document",
              ContentScopeModel.derive(source: .clipboardCaptureUserApproved, quality: .fullDocumentText, coverage: .full) == .fullDocument)
        check("t1_selection_is_selected_text",
              ContentScopeModel.derive(source: .selectedTextAX, quality: .selectedText, coverage: .partial) == .selectedText)

        // T2 — The 500-char AX promotion bug is dead: lots of AX text still never
        // resolves to a page-scope summary.
        let bigAX = makeResult(
            text: String(repeating: "Visible rental agreement text. ", count: 40),  // ~1200 chars
            quality: .axVisibleText, coverage: .visible, source: .browserAX
        )
        let bigAXScope = UniversalContentReader.resolveActionScope(
            capabilityId: "explicit_visible_capture_summary", result: bigAX
        )
        check("t2_1200_ax_chars_not_page_scope", bigAXScope.resolvedScope != .page)
        check("t2_1200_ax_chars_visible_title", bigAXScope.title == "Summarize visible content")

        // T3 — Google Docs partial AX downgrade.
        let gdocsPartial = makeResult(
            text: String(repeating: "Occupancy agreement clause. ", count: 16),  // ~450 chars
            quality: .axVisibleText, coverage: .partial, source: .browserAX
        )
        check("t3_gdocs_partial_scope", gdocsPartial.actualScope == .partialVisibleText)
        let gdocsScope = UniversalContentReader.resolveActionScope(
            capabilityId: "explicit_visible_capture_summary", result: gdocsPartial
        )
        check("t3_gdocs_partial_never_page", gdocsScope.resolvedScope != .page)
        check("t3_gdocs_title_does_not_claim_page", !gdocsScope.title.lowercased().contains("this page") && !gdocsScope.title.lowercased().contains("this document"))

        // T4 — Scope-truth titles.
        check("t4_full_page_title", ScopeTruthTitles.summarizeTitle(for: .fullPage) == "Summarize this page")
        check("t4_full_document_title", ScopeTruthTitles.summarizeTitle(for: .fullDocument) == "Summarize this document")
        check("t4_visible_title", ScopeTruthTitles.summarizeTitle(for: .visibleViewport) == "Summarize visible content")
        check("t4_metadata_title_is_capture", ScopeTruthTitles.summarizeTitle(for: .metadataOnly) == "Capture visible page")
        check("t4_failed_title_is_enable_access", ScopeTruthTitles.summarizeTitle(for: .failed) == "Enable page access")
        check("t4_static_product_title_does_not_overpromise",
              SuggestionTitleRewriter.cognitiveProductTitle(for: "explicit_visible_capture_summary") == "Summarize visible content")

        // T5 — ContentScopeGate.
        let metaGate = ContentScopeGate.evaluate(
            capabilityId: "explicit_visible_capture_summary",
            requested: .fullPage, actual: .metadataOnly, chars: 60
        )
        check("t5_metadata_blocked_for_cognitive", !metaGate.allowed)
        let fullGate = ContentScopeGate.evaluate(
            capabilityId: "explicit_visible_capture_summary",
            requested: .fullPage, actual: .fullDocument, chars: 4000
        )
        check("t5_full_document_allowed", fullGate.allowed && fullGate.downgrade == nil)
        let visGate = ContentScopeGate.evaluate(
            capabilityId: "explicit_visible_capture_summary",
            requested: .fullPage, actual: .visibleViewport, chars: 900
        )
        check("t5_visible_downgraded_not_blocked", visGate.allowed && visGate.downgrade == .visibleViewport)

        // T6 — Result card carries the scope label through to the rendered card state.
        var card = ResearchResultCardState(
            capabilityID: "explicit_visible_capture_summary",
            title: "Document Summary",
            text: "Summary body",
            outputChars: 12
        )
        card.cardType = .summary
        card.contentSource = "clipboard_capture_user_approved"
        card.contentScope = "full_document"
        if case .result(let rendered)? = ResultSurfaceCardState(card: card) {
            check("t6_result_card_scope_label", rendered.contentScope == "full_document")
        } else {
            check("t6_result_card_scope_label", false)
        }

        // T7 — Panel ranking.
        let rankInput = [
            PanelRankingInput(actionID: "a1", capabilityId: "explicit_visible_capture_summary", title: "Summarize visible content", isHighlighted: true),
            PanelRankingInput(actionID: "a2", capabilityId: "copy_current_url", title: "Copy URL", isHighlighted: false),
            PanelRankingInput(actionID: "a3", capabilityId: "arrange_side_by_side", title: "Arrange side by side", isHighlighted: false),
            PanelRankingInput(actionID: "a4", capabilityId: "restore_workspace", title: "Restore workspace", isHighlighted: false),
            PanelRankingInput(actionID: "a5", capabilityId: "copy_current_url", title: "Copy URL again", isHighlighted: false),
            PanelRankingInput(actionID: "a6", capabilityId: "extract_action_items", title: "Extract action items", isHighlighted: false)
        ]
        let decisions = PanelRanker.rank(actions: rankInput, contentAvailable: nil)
        check("t7_highlighted_cognitive_is_suggested_now",
              decisions.first(where: { $0.actionID == "a1" })?.section == .suggestedNow)
        check("t7_utility_in_utilities_section",
              decisions.first(where: { $0.actionID == "a2" })?.section == .utilities)
        check("t7_arrange_in_act_section",
              decisions.first(where: { $0.actionID == "a3" })?.section == .act)
        check("t7_workspace_section",
              decisions.first(where: { $0.actionID == "a4" })?.section == .workspace)
        check("t7_duplicate_suppressed",
              decisions.first(where: { $0.actionID == "a5" })?.suppressionReason == "duplicate")
        check("t7_cognitive_in_understand",
              decisions.first(where: { $0.actionID == "a6" })?.section == .understand)

        // Insufficient scope: cognitive (non-acquisition) actions are suppressed
        // when content is provably unavailable.
        let noContentDecisions = PanelRanker.rank(
            actions: [PanelRankingInput(actionID: "b1", capabilityId: "extract_action_items", title: "Extract action items", isHighlighted: false)],
            contentAvailable: false
        )
        check("t7_insufficient_scope_suppressed",
              noContentDecisions.first?.suppressionReason == "insufficient_scope")
        let utilityHighlighted = PanelRanker.rank(
            actions: [PanelRankingInput(actionID: "c1", capabilityId: "copy_current_url", title: "Copy URL", isHighlighted: true)],
            contentAvailable: nil
        )
        check("t7_utility_never_suggested_now",
              utilityHighlighted.first?.section == .utilities)

        // T8 — Manual vs proactive side-by-side.
        let savedSnapshot = WorkspaceRuntimeInventoryProvider.testSnapshot
        defer { WorkspaceRuntimeInventoryProvider.testSnapshot = savedSnapshot }
        WorkspaceRuntimeInventoryProvider.testSnapshot = WorkspaceRuntimeInventory(
            runningApps: [
                WorkspaceAppRecord(bundleID: "org.mozilla.firefox", appName: "Firefox"),
                WorkspaceAppRecord(bundleID: "com.apple.Preview", appName: "Preview")
            ],
            visibleWindows: [
                WindowSnapshot(windowID: 201, appName: "Firefox", bundleID: "org.mozilla.firefox", pid: 2001,
                               title: "Listing - Firefox", frame: CGRect(x: 0, y: 0, width: 800, height: 800),
                               layer: 0, isOnScreen: true, isOnActiveScreen: true),
                WindowSnapshot(windowID: 202, appName: "Preview", bundleID: "com.apple.Preview", pid: 2002,
                               title: "Lease.pdf", frame: CGRect(x: 100, y: 100, width: 800, height: 800),
                               layer: 0, isOnScreen: true, isOnActiveScreen: true)
            ],
            browserTabTitles: [],
            currentURLs: [],
            frontmostAppName: "Firefox",
            frontmostBundleID: "org.mozilla.firefox"
        )

        WorkPairMemory.shared.reset()
        guard let arrangeCapability = CognitiveCapabilityRegistry.shared.get("arrange_side_by_side") else {
            check("t8_arrange_capability_present", false)
            let passed = failures.isEmpty
            print("[Phase51SelfTest] result=\(passed ? "PASSED" : "FAILED") failed_cases=\(failures.joined(separator: ","))")
            return passed
        }

        // Proactive without a verified pair → blocked, with a visible blocked card.
        let proactiveStatus = await CapabilityExecutor.shared.execute(
            capability: arrangeCapability,
            context: ["apps": [], "source_surface": "floating"]
        )
        let proactiveCard = CapabilityExecutor.shared.takePendingResultCard(for: "arrange_side_by_side")
        check("t8_proactive_no_pair_blocked", proactiveStatus == .blocked)
        check("t8_proactive_block_has_card", proactiveCard?.cardType == .blockedAction)

        // Manual (panel click) without a verified pair → allowed; resolves live targets.
        var manualHookApps: [String] = []
        CapabilityExecutor.testHooks.arrangeSideBySide = { apps, _ in
            manualHookApps = apps
            return CapabilityExecutor.LocalActionOutcome(status: .success, verificationStatus: "success", reason: "test_hook")
        }
        let manualStatus = await CapabilityExecutor.shared.execute(
            capability: arrangeCapability,
            context: ["apps": ["Preview"], "source_surface": "panel"]
        )
        CapabilityExecutor.testHooks.arrangeSideBySide = nil
        check("t8_manual_no_pair_allowed", manualStatus == .success)
        check("t8_manual_resolves_frontmost_primary", manualHookApps.first == "Firefox")
        check("t8_manual_resolves_secondary", manualHookApps.dropFirst().first == "Preview")

        // T9 — Music honesty.
        check("t9_resume_has_no_random_fallback",
              MusicExecutor.executionPlanForTests(intent: nil, localPlaylistMatchExists: false, hasFirstLocalPlaylist: true) == "resume_only")
        let playIntent = MusicIntent(taskDomain: "coding", mood: .focus, query: "Deep Focus", playlistName: "Deep Focus", action: .playPlaylist)
        check("t9_missing_playlist_is_unavailable_not_random",
              MusicExecutor.executionPlanForTests(intent: playIntent, localPlaylistMatchExists: false, hasFirstLocalPlaylist: true) == "unavailable")
        let awareness = MediaAwarenessSnapshot(
            foregroundMediaPresent: false, foregroundMediaConfidence: 0,
            mediaSourceType: .unknown, foregroundMediaPlaybackState: "unknown",
            backgroundMusicState: "playing", audioConflictLikelihood: 0,
            userActivityState: "working", mediaPreferenceConfidence: 0.5,
            recentMediaFeedback: "none"
        )
        let alreadyPlaying = MusicUsefulnessEvaluator.evaluate(
            capabilityID: "play_focus_media", awareness: awareness,
            isMusicAlreadyPlaying: true, recentFeedbackCooldownActive: false,
            hasHigherPriorityTaskAction: false
        )
        check("t9_already_playing_suppressed", !alreadyPlaying.eligible && alreadyPlaying.reason == "already_playing")

        PlaylistMemory.shared.resetForTests()
        check("t9_no_history_no_learned_playlist",
              PlaylistMemory.shared.suggestWithConfidence(compartment: nil, workflow: .coding) == nil)
        for _ in 0..<4 {
            PlaylistMemory.shared.record(name: "Focus Beats", compartment: nil, workflow: .coding)
        }
        let learned = PlaylistMemory.shared.suggestWithConfidence(compartment: nil, workflow: .coding)
        check("t9_repeated_history_high_confidence", (learned?.confidence ?? 0) >= 0.6 && learned?.name == "Focus Beats")
        PlaylistMemory.shared.resetForTests()

        let passed = failures.isEmpty
        print("[Phase51SelfTest] result=\(passed ? "PASSED" : "FAILED") failed_cases=\(failures.joined(separator: ","))")
        return passed
    }
}

// MARK: - Phase 52 Self-Test

@MainActor
struct Phase52SelfTest {

    private static var failures: [String] = []

    private static func check(_ label: String, _ condition: Bool) {
        if condition {
            print("[Phase52SelfTest] pass case=\(label)")
        } else {
            print("[Phase52SelfTest] FAIL case=\(label)")
            failures.append(label)
        }
    }

    static func run() async -> Bool {
        print("[Phase52SelfTest] starting")
        failures = []

        let savedSnapshot = WorkspaceRuntimeInventoryProvider.testSnapshot
        let savedArrangeHook = CapabilityExecutor.testHooks.arrangeSideBySide
        defer {
            WorkspaceRuntimeInventoryProvider.testSnapshot = savedSnapshot
            CapabilityExecutor.testHooks.arrangeSideBySide = savedArrangeHook
        }

        WorkspaceRuntimeInventoryProvider.testSnapshot = WorkspaceRuntimeInventory(
            runningApps: [
                WorkspaceAppRecord(bundleID: "org.mozilla.firefox", appName: "Firefox"),
                WorkspaceAppRecord(bundleID: "com.apple.Preview", appName: "Preview"),
                WorkspaceAppRecord(bundleID: "com.apple.Music", appName: "Music")
            ],
            visibleWindows: [
                WindowSnapshot(windowID: 5201, appName: "Firefox", bundleID: "org.mozilla.firefox", pid: 5201,
                               title: "OSAP student aid housing page", frame: CGRect(x: 0, y: 0, width: 720, height: 840),
                               layer: 0, isOnScreen: true, isOnActiveScreen: true),
                WindowSnapshot(windowID: 5202, appName: "Preview", bundleID: "com.apple.Preview", pid: 5202,
                               title: "Student budget.pdf", frame: CGRect(x: 760, y: 0, width: 720, height: 840),
                               layer: 0, isOnScreen: true, isOnActiveScreen: true),
                WindowSnapshot(windowID: 5203, appName: "Music", bundleID: "com.apple.Music", pid: 5203,
                               title: "Music", frame: CGRect(x: 200, y: 120, width: 500, height: 500),
                               layer: 0, isOnScreen: true, isOnActiveScreen: true)
            ],
            browserTabTitles: ["OSAP student aid housing page"],
            currentURLs: ["https://osap.gov.on.ca/"],
            frontmostAppName: "Firefox",
            frontmostBundleID: "org.mozilla.firefox"
        )

        let assessment = BrowserContextStrategy.assess(
            title: "OSAP student aid housing page",
            url: URL(string: "https://osap.gov.on.ca/"),
            tabTitles: ["OSAP student aid housing page"],
            hasAXText: false,
            hasOCR: false
        )
        check("osap_metadata_capture_visible_available", assessment.safeActions.contains("capture_visible_page"))
        check("osap_metadata_no_summary_safe_action", !assessment.safeActions.contains("explicit_visible_capture_summary"))
        check("osap_metadata_no_extract_safe_action", !assessment.safeActions.contains("extract_action_items"))
        check("osap_metadata_no_checklist_safe_action", !assessment.safeActions.contains("create_checklist"))

        let compartment = TaskCompartment(
            workflow: .researching,
            label: "OSAP research",
            dominantTerms: ["osap", "student", "housing"],
            entities: ["OSAP student aid housing page"],
            browserTabs: ["OSAP student aid housing page"],
            confidence: 0.82,
            activeScore: 0.9
        )
        let memory = WorkingMemorySnapshot(
            currentEntity: "OSAP student aid housing page",
            recentEntities: ["OSAP student aid housing page"],
            repeatedConcepts: ["osap", "student aid"],
            inferredActivity: "researching",
            comparisonCandidates: [],
            relatedFocusEntities: ["OSAP student aid housing page"],
            currentFocusTerms: ["osap", "student", "housing"]
        )
        let portfolio = CheapAlwaysOnPortfolio.evaluateDetailed(
            CheapAlwaysOnPortfolioInput(
                reason: "phase52_osap_firefox_metadata",
                workflow: .researching,
                modelReady: true,
                startupQuiet: false,
                frictionSignals: [],
                mediaState: EnvironmentMediaState(isMusicPlaying: false, visualMediaKind: .none, source: "phase52_test"),
                semanticState: nil,
                entityGrounding: nil,
                compartment: compartment,
                memory: memory,
                activityState: nil,
                entityKey: "osap-firefox",
                currentApp: "Firefox",
                appCategory: .browser,
                groundingResult: nil
            )
        )
        let normalPanelCaps = portfolio.panelCandidates.map(\.capabilityId)
        let allCaps = portfolio.allCandidates.map(\.capabilityId)
        let weakCognitiveCaps = ["explicit_visible_capture_summary", "extract_action_items", "create_checklist"]
        let cognitiveInPanel = normalPanelCaps.filter { weakCognitiveCaps.contains($0) }
        print("[Phase52Dogfood] osap_panel_capabilities=\(normalPanelCaps.joined(separator: ","))")
        print("[Phase52Dogfood] osap_all_capabilities=\(allCaps.joined(separator: ","))")
        check("osap_panel_has_setup_action", allCaps.contains("capture_visible_page") || allCaps.contains("enable_browser_bridge") || allCaps.contains("select_text_hint"))
        check("osap_panel_no_summary_extract_checklist_spam", !weakCognitiveCaps.contains { allCaps.contains($0) })
        check("osap_panel_at_most_one_cognitive", cognitiveInPanel.count <= 1)

        let shortSummary = CapabilityExecutor.shared.cognitiveUsefulnessGate(
            capabilityId: "explicit_visible_capture_summary",
            scope: .visibleViewport,
            source: .browserAX,
            chars: 850
        )
        check("850_ax_not_high_usefulness_summary", !shortSummary.allowed && shortSummary.reason == "too_short")
        let shortExtract = CapabilityExecutor.shared.cognitiveUsefulnessGate(
            capabilityId: "extract_action_items",
            scope: .visibleViewport,
            source: .browserAX,
            chars: 850
        )
        check("850_ax_extract_blocked", !shortExtract.allowed)
        let fullContextNeeded = CapabilityExecutor.shared.cognitiveUsefulnessGate(
            capabilityId: "create_checklist",
            scope: .visibleViewport,
            source: .browserAX,
            chars: 2200
        )
        check("visible_checklist_requires_full_context", !fullContextNeeded.allowed && fullContextNeeded.reason == "needs_full_context")

        _ = LocalActionPayloadValidator.validate(
            capabilityId: "arrange_side_by_side",
            involvedApps: ["Firefox", "Preview"],
            involvedURLs: [],
            browserTabTitles: [],
            compartmentLabel: "OSAP research"
        )

        guard let arrangeCapability = CognitiveCapabilityRegistry.shared.get("arrange_side_by_side") else {
            check("manual_arrange_capability_present", false)
            let passed = failures.isEmpty
            print("[Phase52SelfTest] result=\(passed ? "PASSED" : "FAILED") failed_cases=\(failures.joined(separator: ","))")
            return passed
        }

        var arrangedApps: [String] = []
        CapabilityExecutor.testHooks.arrangeSideBySide = { apps, _ in
            arrangedApps = apps
            return CapabilityExecutor.LocalActionOutcome(status: .success, verificationStatus: "success", reason: "phase52_manual_panel")
        }
        let manualStatus = await CapabilityExecutor.shared.execute(
            capability: arrangeCapability,
            context: [
                "apps": ["Preview"],
                "source_surface": "panel",
                "arrange_mode": "manual"
            ]
        )
        CapabilityExecutor.testHooks.arrangeSideBySide = savedArrangeHook
        print("[Phase52Dogfood] manual_arrange_apps=\(arrangedApps.joined(separator: ","))")
        check("manual_side_by_side_success", manualStatus == .success)
        check("manual_arrange_primary_firefox", arrangedApps.first == "Firefox")
        check("manual_arrange_secondary_preview", arrangedApps.dropFirst().first == "Preview")
        check("manual_arrange_did_not_select_music", !arrangedApps.contains("Music"))

        let passed = failures.isEmpty
        print("[Phase52SelfTest] result=\(passed ? "PASSED" : "FAILED") failed_cases=\(failures.joined(separator: ","))")
        return passed
    }
}

// MARK: - Rescue Dogfood Matrix

@MainActor
enum RescueDogfoodMatrix {

    struct CaseResult {
        let name: String
        let pass: Bool
        let reason: String
    }

    /// Deterministic fixture-mode matrix: validates the honesty invariants for
    /// each dogfood scenario without needing the live app in front.
    /// Live dogfood still needs a human driving the real apps — this matrix
    /// catches regressions in the decision layer.
    static func run() async -> Bool {
        print("[DogfoodMatrix] starting mode=fixture")
        var results: [CaseResult] = []

        func record(_ name: String, _ pass: Bool, _ reason: String) {
            results.append(CaseResult(name: name, pass: pass, reason: reason))
            print("[DogfoodMatrix] case=\(name) status=\(pass ? "pass" : "fail") reason=\(reason)")
        }

        func fixture(_ text: String, _ quality: ContentQuality, _ coverage: ContentCoverage, _ source: ContentSource) -> UniversalContentResult {
            UniversalContentResult(text: text, quality: quality, coverage: coverage, source: source,
                                   confidence: 0.9, attemptedRoutes: [], missingReason: nil, nextStep: .captureVisible)
        }

        // 1. Firefox normal webpage — AX visible text, ~800 chars.
        let webpage = fixture(String(repeating: "Article paragraph text. ", count: 34), .axVisibleText, .visible, .browserAX)
        let webpageScope = UniversalContentReader.resolveActionScope(capabilityId: "explicit_visible_capture_summary", result: webpage)
        record("firefox_normal_webpage",
               webpage.actualScope == .visibleViewport && webpageScope.allowed && webpageScope.title == "Summarize visible content" && webpageScope.resolvedScope != .page,
               "scope=\(webpage.actualScope.rawValue) title=\(webpageScope.title)")

        // 2. Firefox Google Docs — partial AX editor text (the log.rtf scenario).
        let gdocs = fixture(String(repeating: "Occupancy clause. ", count: 24), .axVisibleText, .partial, .browserAX)
        let gdocsScope = UniversalContentReader.resolveActionScope(capabilityId: "explicit_visible_capture_summary", result: gdocs)
        let gdocsHonest = gdocs.actualScope == .partialVisibleText
            && gdocsScope.resolvedScope != .page
            && !gdocsScope.title.lowercased().contains("this page")
            && !gdocsScope.title.lowercased().contains("this document")
        record("firefox_google_docs", gdocsHonest,
               "scope=\(gdocs.actualScope.rawValue) title=\(gdocsScope.title)")

        // 3. Rentals/listing page with only metadata — must show capture card, not summary.
        let listing = fixture("182 Montreal St - Rental Listing\nhttps://example.com/listing", .metadataOnly, .minimal, .browserMetadata)
        let listingScope = UniversalContentReader.resolveActionScope(capabilityId: "explicit_visible_capture_summary", result: listing)
        let listingGate = ContentScopeGate.evaluate(capabilityId: "explicit_visible_capture_summary", requested: .fullPage, actual: listing.actualScope, chars: listing.text.count)
        record("rentals_listing_page",
               !listingScope.allowed && !listingGate.allowed && listingScope.resolvedScope == .captureNeeded,
               "metadata_blocked_with_capture_card")

        // 4. Gmail page — selection available → selected-text summary.
        let gmail = fixture(String(repeating: "Email body sentence. ", count: 10), .selectedText, .partial, .selectedTextAX)
        let gmailScope = UniversalContentReader.resolveActionScope(capabilityId: "explicit_visible_capture_summary", result: gmail)
        record("gmail_page",
               gmail.actualScope == .selectedText && gmailScope.title == "Summarize selected text" && gmailScope.allowed,
               "scope=selected_text title=\(gmailScope.title)")

        // 5. Preview PDF — PDFKit full text → full document summary allowed.
        let pdf = fixture(String(repeating: "Lease agreement section. ", count: 80), .fullDocumentText, .full, .pdfKit)
        let pdfScope = UniversalContentReader.resolveActionScope(capabilityId: "explicit_visible_capture_summary", result: pdf)
        record("preview_pdf",
               pdf.actualScope == .fullDocument && pdfScope.resolvedScope == .page && pdfScope.title == "Summarize this document",
               "scope=full_document title=\(pdfScope.title)")

        // 6. TextEdit document — file-backed full text.
        let textedit = fixture(String(repeating: "Notes line. ", count: 60), .fullDocumentText, .full, .fileBacked)
        record("textedit_document",
               textedit.actualScope == .fullDocument && ScopeTruthTitles.summaryCardTitle(for: textedit.actualScope) == "Document Summary",
               "scope=full_document card_title=Document Summary")

        // 7. Xcode/code/log page — generic AX visible text; diagnose allowed at visible scope.
        let code = fixture(String(repeating: "error: use of unresolved identifier\n", count: 12), .axVisibleText, .visible, .axTree)
        let codeGate = ContentScopeGate.evaluate(capabilityId: "diagnose_error", requested: .visibleViewport, actual: code.actualScope, chars: code.text.count)
        record("xcode_code_log",
               code.actualScope == .visibleViewport && codeGate.allowed,
               "visible_scope_diagnosis_allowed")

        // 8. Music action — no random playlist, suppressed when already playing.
        let noRandom = MusicExecutor.executionPlanForTests(intent: nil, localPlaylistMatchExists: false, hasFirstLocalPlaylist: true) == "resume_only"
        let awareness = MediaAwarenessSnapshot(
            foregroundMediaPresent: false, foregroundMediaConfidence: 0,
            mediaSourceType: .unknown, foregroundMediaPlaybackState: "unknown",
            backgroundMusicState: "playing", audioConflictLikelihood: 0,
            userActivityState: "working", mediaPreferenceConfidence: 0.5,
            recentMediaFeedback: "none"
        )
        let suppressed = !MusicUsefulnessEvaluator.evaluate(
            capabilityID: "play_focus_media", awareness: awareness,
            isMusicAlreadyPlaying: true, recentFeedbackCooldownActive: false,
            hasHigherPriorityTaskAction: false
        ).eligible
        record("music_action", noRandom && suppressed, "no_random_fallback_and_already_playing_suppressed")

        // 9 + 10. Side-by-side manual vs proactive.
        let savedSnapshot = WorkspaceRuntimeInventoryProvider.testSnapshot
        defer { WorkspaceRuntimeInventoryProvider.testSnapshot = savedSnapshot }
        WorkspaceRuntimeInventoryProvider.testSnapshot = WorkspaceRuntimeInventory(
            runningApps: [
                WorkspaceAppRecord(bundleID: "org.mozilla.firefox", appName: "Firefox"),
                WorkspaceAppRecord(bundleID: "com.apple.Preview", appName: "Preview")
            ],
            visibleWindows: [
                WindowSnapshot(windowID: 301, appName: "Firefox", bundleID: "org.mozilla.firefox", pid: 3001,
                               title: "Listing", frame: CGRect(x: 0, y: 0, width: 800, height: 800),
                               layer: 0, isOnScreen: true, isOnActiveScreen: true),
                WindowSnapshot(windowID: 302, appName: "Preview", bundleID: "com.apple.Preview", pid: 3002,
                               title: "Lease.pdf", frame: CGRect(x: 100, y: 100, width: 800, height: 800),
                               layer: 0, isOnScreen: true, isOnActiveScreen: true)
            ],
            browserTabTitles: [], currentURLs: [],
            frontmostAppName: "Firefox", frontmostBundleID: "org.mozilla.firefox"
        )
        WorkPairMemory.shared.reset()

        if let arrangeCapability = CognitiveCapabilityRegistry.shared.get("arrange_side_by_side") {
            var manualApps: [String] = []
            CapabilityExecutor.testHooks.arrangeSideBySide = { apps, _ in
                manualApps = apps
                return CapabilityExecutor.LocalActionOutcome(status: .success, verificationStatus: "success", reason: "matrix_hook")
            }
            let manualStatus = await CapabilityExecutor.shared.execute(
                capability: arrangeCapability,
                context: ["apps": ["Preview"], "source_surface": "panel"]
            )
            CapabilityExecutor.testHooks.arrangeSideBySide = nil
            record("side_by_side_manual",
                   manualStatus == .success && manualApps == ["Firefox", "Preview"],
                   "manual_click_resolves_live_targets")

            let proactiveStatus = await CapabilityExecutor.shared.execute(
                capability: arrangeCapability,
                context: ["apps": [], "source_surface": "floating"]
            )
            let proactiveCard = CapabilityExecutor.shared.takePendingResultCard(for: "arrange_side_by_side")
            record("side_by_side_proactive",
                   proactiveStatus == .blocked && proactiveCard?.cardType == .blockedAction,
                   "proactive_without_pair_blocked_with_visible_card")
        } else {
            record("side_by_side_manual", false, "arrange_capability_missing")
            record("side_by_side_proactive", false, "arrange_capability_missing")
        }

        let passedCount = results.filter(\.pass).count
        let failedCases = results.filter { !$0.pass }
        let blockers = failedCases.map(\.name).joined(separator: ",")
        print("[DogfoodMatrixSummary] passed=\(passedCount) failed=\(failedCases.count) blockers=\(blockers.isEmpty ? "none" : blockers)")
        return failedCases.isEmpty
    }
}
