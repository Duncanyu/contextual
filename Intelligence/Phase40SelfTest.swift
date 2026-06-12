import Foundation
import AppKit

/// Phase 40: Non-Layout Action Activation + Panel Usefulness
/// Verifies music surface fix, acquisition action generation, research lane,
/// BrowserContextStrategy conversion, and panel inventory observability.
@MainActor
struct Phase40SelfTest {

    private static var failures: [String] = []

    static func check(_ label: String, _ condition: Bool) {
        if condition {
            print("[Phase40SelfTest] pass case=\(label)")
        } else {
            print("[Phase40SelfTest] FAIL case=\(label)")
            failures.append(label)
        }
    }

    static func run() async -> Bool {
        print("[Phase40SelfTest] starting")
        failures = []

        // 1. Music suppression fix — task_action_preferred must be panelOnly not suppressed.
        // SuggestionSurfacePolicy.evaluate() should return panelOnly when
        // isUserActivelySwitching=false, isLayoutAlreadyGood=false (layout task present), hasDurablePattern=true.
        let musicContext = ContextModel()
        let musicEval = SuggestionSurfacePolicy.evaluate(
            capabilityId: "play_focus_media",
            context: musicContext,
            isMusicPlaying: false,
            isMusicSuppressed: false,
            isUserTyping: false,
            missing: nil,
            recentFeedback: nil,
            frictionSignals: [],
            hasDurablePattern: true,
            involvedURLs: [],
            userAcceptedMusicBefore: false,
            isLayoutAlreadyGood: false
        )
        check("test_1_music_task_action_is_panel_not_suppressed", musicEval.surface == .panelOnly)
        check("test_1b_music_task_action_reason", musicEval.reason == "secondary_to_active_task")

        // 2. Music surface: already playing → suppressed (unchanged behavior).
        let musicPlayingEval = SuggestionSurfacePolicy.evaluate(
            capabilityId: "play_focus_media",
            context: musicContext,
            isMusicPlaying: true,
            isMusicSuppressed: false,
            isUserTyping: false,
            missing: nil,
            recentFeedback: nil,
            frictionSignals: [],
            hasDurablePattern: false,
            involvedURLs: [],
            userAcceptedMusicBefore: false,
            isLayoutAlreadyGood: true
        )
        check("test_2_music_already_playing_suppressed", musicPlayingEval.surface == .suppressed)

        // 3. Music surface: no prior acceptance, idle context → panelOnly (first_time_panel_safe).
        let musicFirstTimeEval = SuggestionSurfacePolicy.evaluate(
            capabilityId: "play_focus_media",
            context: musicContext,
            isMusicPlaying: false,
            isMusicSuppressed: false,
            isUserTyping: false,
            missing: nil,
            recentFeedback: nil,
            frictionSignals: [],
            hasDurablePattern: false,
            involvedURLs: [],
            userAcceptedMusicBefore: false,
            isLayoutAlreadyGood: true
        )
        check("test_3_music_first_time_is_panel", musicFirstTimeEval.surface == .panelOnly)
        check("test_3b_music_first_time_reason", musicFirstTimeEval.reason == "first_time_panel_safe")

        // 4. BrowserContextStrategy: article without content → acquisition actions in safeActions.
        let articleAssessment = BrowserContextStrategy.assess(
            title: "Research Paper on Machine Learning",
            url: URL(string: "https://arxiv.org/abs/2024.12345"),
            tabTitles: ["ML Paper", "Related Work"],
            hasAXText: false,
            hasOCR: false
        )
        // Phase 53 — weak context offers a capture/setup path, not the generic trio.
        check("test_4_article_no_content_has_acquisition",
              articleAssessment.safeActions.contains("capture_visible_page") ||
              articleAssessment.safeActions.contains("enable_browser_bridge") ||
              articleAssessment.safeActions.contains("select_text_hint"))
        check("test_4b_article_no_content_blocks_summarize",
              articleAssessment.blockedActions.contains("summarize_visible_content") ||
              !articleAssessment.safeActions.contains("summarize_visible_content"))

        // 5. BrowserContextStrategy: content available → no acquisition (regular safe actions only).
        let articleWithContentAssessment = BrowserContextStrategy.assess(
            title: "Research Paper on ML",
            url: URL(string: "https://arxiv.org/abs/2024.12345"),
            tabTitles: ["ML Paper"],
            hasAXText: true,
            hasOCR: false
        )
        check("test_5_article_with_content_no_acquisition_forced",
              articleWithContentAssessment.contentAvailable == true)

        // 6. BrowserContextStrategy: Google Docs without content → acquisition actions present.
        let docsAssessment = BrowserContextStrategy.assess(
            title: "Project Plan",
            url: URL(string: "https://docs.google.com/document/d/abc123"),
            tabTitles: [],
            hasAXText: false,
            hasOCR: false
        )
        // Phase 53 — Google Docs offers full-document capture, not the generic trio.
        check("test_6_google_docs_acquisition_actions",
              docsAssessment.safeActions.contains("capture_full_document") ||
              docsAssessment.safeActions.contains("select_text_hint"))

        // 7. ActionRegistry: acquisition capabilities allowed at metadata_rich evidence level.
        let acquisitionEligibility = ActionRegistry.evaluate(
            capabilityId: "explicit_visible_capture_summary",
            currentEvidence: .metadata_rich,
            hasURLs: true,
            hasSelection: false
        )
        check("test_7_acquisition_eligible_at_metadata_rich", acquisitionEligibility.eligible == true)
        check("test_7b_acquisition_reason_user_initiated", acquisitionEligibility.reason == "user_initiated_acquisition")

        // 8. ActionRegistry: extract_action_items allowed via user_initiated_acquisition.
        let extractEligibility = ActionRegistry.evaluate(
            capabilityId: "extract_action_items",
            currentEvidence: .metadata_only,
            hasURLs: false,
            hasSelection: false
        )
        check("test_8_extract_action_items_user_initiated", extractEligibility.eligible == true)

        // 9. DeterministicPanelActionPlanner: generates acquisition candidates for article contexts.
        let articleInput = DeterministicPanelPlannerInput(
            activeAppName: "Firefox",
            windowTitle: "Research Paper",
            browserAppName: "Firefox",
            currentURL: "https://arxiv.org/abs/2024.12345",
            tabTitles: ["ML Paper", "Related Work"],
            visibleApps: ["Firefox"],
            workflow: "researching",
            compartmentLabel: "researching",
            compartment: nil,
            evidenceLevel: .metadata_rich,
            browserAssessment: BrowserContextStrategy.assess(
                title: "Research Paper",
                url: URL(string: "https://arxiv.org/abs/2024.12345"),
                tabTitles: ["ML Paper"],
                hasAXText: false,
                hasOCR: false
            ),
            hasDurablePattern: false,
            frictionSignals: []
        )
        let plannerResult = DeterministicPanelActionPlanner.evaluate(articleInput)
        let acquisitionCapIds = plannerResult.validCandidates.map { $0.candidate.capabilityId }
        // Phase 53 — the planner generates a visible capture/setup path for weak articles.
        check("test_9_planner_generates_acquisition_for_article",
              acquisitionCapIds.contains("capture_visible_page") ||
              acquisitionCapIds.contains("capture_full_document") ||
              acquisitionCapIds.contains("enable_browser_bridge") ||
              acquisitionCapIds.contains("select_text_hint"))

        // 10. DeterministicPanelActionPlanner: research lane used for acquisition candidates.
        let researchCandidates = plannerResult.validCandidates.filter { $0.candidate.lane == .research }
        check("test_10_planner_acquisition_uses_research_lane", !researchCandidates.isEmpty)

        // 11. DeterministicPanelActionPlanner: youtube context → no acquisition candidates.
        let youtubeInput = DeterministicPanelPlannerInput(
            activeAppName: "Firefox",
            windowTitle: "Funny Cat Video - YouTube",
            browserAppName: "Firefox",
            currentURL: "https://www.youtube.com/watch?v=abc123",
            tabTitles: ["YouTube"],
            visibleApps: ["Firefox"],
            workflow: "browsing",
            compartmentLabel: "browsing",
            compartment: nil,
            evidenceLevel: .metadata_rich,
            browserAssessment: BrowserContextStrategy.assess(
                title: "Funny Cat Video - YouTube",
                url: URL(string: "https://www.youtube.com/watch?v=abc123"),
                tabTitles: [],
                hasAXText: false,
                hasOCR: false
            ),
            hasDurablePattern: false,
            frictionSignals: []
        )
        let youtubeResult = DeterministicPanelActionPlanner.evaluate(youtubeInput)
        let youtubeAcquisition = youtubeResult.validCandidates.filter {
            $0.candidate.capabilityId == "explicit_visible_capture_summary" ||
            $0.candidate.capabilityId == "extract_action_items" ||
            $0.candidate.capabilityId == "create_checklist"
        }
        check("test_11_youtube_no_acquisition_candidates", youtubeAcquisition.isEmpty)

        // 12. PortfolioCandidate.family: acquisition capabilities map to .research family.
        let candidate = PortfolioCandidate(
            lane: .research,
            title: "Read visible page and summarize",
            capabilityId: "explicit_visible_capture_summary",
            executionMode: .preview_only,
            confidence: 0.7,
            usefulness: 0.7,
            executability: 0.75,
            novelty: 1.0,
            reason: "acquisition_test",
            requiredEvidence: "metadata_rich",
            requiresConfirmation: false,
            involvedApps: [],
            frictionOpportunity: nil,
            musicIntent: nil,
            generatedAction: nil
        )
        check("test_12_acquisition_capability_family_is_research", candidate.family == .research)

        // 13. LocalActionPayloadValidator: play_focus_media always passes.
        let musicValidation = LocalActionPayloadValidator.validate(
            capabilityId: "play_focus_media",
            involvedApps: [],
            involvedURLs: [],
            browserTabTitles: [],
            compartmentLabel: nil
        )
        check("test_13_play_focus_media_payload_always_valid", musicValidation.valid == true)

        // 14. BrowserContextStrategy: listing without content → acquisition in safeActions.
        let listingAssessment = BrowserContextStrategy.assess(
            title: "2BR Apartment for Rent",
            url: URL(string: "https://example-rental.com/listing/123"),
            tabTitles: ["Rental Listing"],
            hasAXText: false,
            hasOCR: false
        )
        // Phase 53 — listings without content get the capture path, not the trio.
        check("test_14_listing_no_content_has_acquisition",
              listingAssessment.safeActions.contains("capture_visible_page") ||
              listingAssessment.safeActions.contains("select_text_hint"))

        let ok = failures.isEmpty
        print("[Phase40SelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
