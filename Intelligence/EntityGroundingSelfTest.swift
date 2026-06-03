import Foundation

/// Phase 22.1 — EntityGroundingLayer self-test.
///
/// Trigger: CONTEXTUAL_RUN_ENTITY_GROUNDING_SELFTEST=1
///
/// Test cases:
///  1.  youtube.com/watch?v=… → youtube_video, shouldPropose=false
///  2.  netflix.com/watch/…   → tv_show,       shouldPropose=false
///  3.  scratch.mit.edu       → code_project,  shouldPropose=true
///  4.  turbowarp.org         → code_project,  shouldPropose=true
///  5.  coursera.com/learn/…  → course_material, shouldPropose=true
///  6.  URL with /episode path → tv_show
///  7.  Title "Dexter Season 1 Episode 3" → tv_show, shouldPropose=false
///  8.  Title "CISC 121 Lecture 5"        → course_material, shouldPropose=true
///  9.  Title ending in .pdf              → document, shouldPropose=true
/// 10.  youtube_video → shouldPropose=false (entertainment gate)
/// 11.  course_material → shouldPropose=true, generate_quiz in allowed
/// 12.  Unknown entity (no URL, opaque title) → shouldPropose=false
/// 13.  tv_show → shouldPropose=false
/// 14.  AppCategory .pdf → document, allowedTypes includes summarize_reference
enum EntityGroundingSelfTest {

    static func run() -> Bool {
        print("[EntityGroundingSelfTest] starting")
        var failures: [String] = []

        func check(_ name: String, _ ok: Bool) {
            if ok {
                print("[EntityGroundingSelfTest] pass case=\(name)")
            } else {
                print("[EntityGroundingSelfTest] fail case=\(name)")
                failures.append(name)
            }
        }

        // ── Case 1: YouTube watch URL ──────────────────────────────────────────
        let ytURL = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        let ytGrounding = EntityGroundingLayer.ground(
            title: "Never Gonna Give You Up - YouTube",
            url: ytURL,
            appCategory: .browser,
            memory: emptyMemory(),
            compartment: nil
        )
        check("youtube_url_type_is_youtube_video",
              ytGrounding.entityType == .youtube_video)
        check("youtube_url_should_not_propose",
              ytGrounding.shouldPropose == false)
        check("youtube_url_source_is_url",
              ytGrounding.source == .url)

        // ── Case 2: Netflix watch URL ──────────────────────────────────────────
        let nfURL = URL(string: "https://www.netflix.com/watch/12345678")!
        let nfGrounding = EntityGroundingLayer.ground(
            title: "Dexter: New Blood",
            url: nfURL,
            appCategory: .browser,
            memory: emptyMemory(),
            compartment: nil
        )
        check("netflix_url_type_is_tv_show",
              nfGrounding.entityType == .tv_show)
        check("netflix_url_should_not_propose",
              nfGrounding.shouldPropose == false)

        // ── Case 3: Scratch (code hosting) ────────────────────────────────────
        let scratchURL = URL(string: "https://scratch.mit.edu/projects/12345/editor")!
        let scratchGrounding = EntityGroundingLayer.ground(
            title: "Tank Shooter Demo - Scratch",
            url: scratchURL,
            appCategory: .browser,
            memory: emptyMemory(),
            compartment: nil
        )
        check("scratch_url_type_is_code_project",
              scratchGrounding.entityType == .code_project)
        check("scratch_url_should_propose",
              scratchGrounding.shouldPropose == true)

        // ── Case 4: TurboWarp (code hosting) ──────────────────────────────────
        let twURL = URL(string: "https://turbowarp.org/12345/editor")!
        let twGrounding = EntityGroundingLayer.ground(
            title: "My Platform Game - TurboWarp",
            url: twURL,
            appCategory: .browser,
            memory: emptyMemory(),
            compartment: nil
        )
        check("turbowarp_url_type_is_code_project",
              twGrounding.entityType == .code_project)
        check("turbowarp_url_should_propose",
              twGrounding.shouldPropose == true)

        // ── Case 5: Coursera course URL ────────────────────────────────────────
        let courseURL = URL(string: "https://www.coursera.org/learn/machine-learning/week/3")!
        let courseGrounding = EntityGroundingLayer.ground(
            title: "Machine Learning | Coursera",
            url: courseURL,
            appCategory: .browser,
            memory: emptyMemory(),
            compartment: nil
        )
        check("coursera_url_type_is_course_material",
              courseGrounding.entityType == .course_material)
        check("coursera_url_should_propose",
              courseGrounding.shouldPropose == true)

        // ── Case 6: Episode path → tv_show ────────────────────────────────────
        let episodeURL = URL(string: "https://www.somestreamer.tv/show/dexter/season/1/episode/3")!
        let episodeGrounding = EntityGroundingLayer.ground(
            title: "Dexter S01E03",
            url: episodeURL,
            appCategory: .browser,
            memory: emptyMemory(),
            compartment: nil
        )
        check("episode_path_type_is_tv_show",
              episodeGrounding.entityType == .tv_show)
        check("episode_path_should_not_propose",
              episodeGrounding.shouldPropose == false)

        // ── Case 7: Title "Dexter Season 1 Episode 3" (no URL) ────────────────
        let dexterMemory = WorkingMemorySnapshot(
            currentEntity: "Dexter Season 1 Episode 3",
            recentEntities: ["Dexter Season 1 Episode 3"],
            repeatedConcepts: ["dexter", "episode", "season"],
            inferredActivity: "watching",
            comparisonCandidates: [],
            relatedFocusEntities: []
        )
        let dexterGrounding = EntityGroundingLayer.ground(
            title: "Dexter Season 1 Episode 3",
            url: nil,
            appCategory: .unknown,
            memory: dexterMemory,
            compartment: nil
        )
        check("dexter_title_type_is_tv_show",
              dexterGrounding.entityType == .tv_show)
        check("dexter_title_should_not_propose",
              dexterGrounding.shouldPropose == false)
        check("dexter_title_is_entertainment",
              dexterGrounding.isEntertainment == true)

        // ── Case 8: Title "CISC 121 Lecture 5" (no URL) ───────────────────────
        let courseMemory = WorkingMemorySnapshot(
            currentEntity: "CISC 121 Lecture 5",
            recentEntities: ["CISC 121 Lecture 5"],
            repeatedConcepts: ["cisc", "lecture", "arrays", "sorting"],
            inferredActivity: "studying",
            comparisonCandidates: [],
            relatedFocusEntities: []
        )
        let ciscGrounding = EntityGroundingLayer.ground(
            title: "CISC 121 Lecture 5",
            url: nil,
            appCategory: .unknown,
            memory: courseMemory,
            compartment: nil
        )
        check("cisc121_title_type_is_course_material",
              ciscGrounding.entityType == .course_material)
        check("cisc121_title_should_propose",
              ciscGrounding.shouldPropose == true)

        // ── Case 9: Title ending in .pdf (no URL) ─────────────────────────────
        let pdfGrounding = EntityGroundingLayer.ground(
            title: "CISC121_Lecture5.pdf",
            url: nil,
            appCategory: .unknown,
            memory: emptyMemory(),
            compartment: nil
        )
        check("pdf_title_type_is_document",
              pdfGrounding.entityType == .document)
        check("pdf_title_should_propose",
              pdfGrounding.shouldPropose == true)

        // ── Case 10: YouTube shouldPropose=false (entertainment gate) ──────────
        check("youtube_is_entertainment",
              ytGrounding.isEntertainment == true)
        check("youtube_entertainment_no_propose",
              ytGrounding.shouldPropose == false)

        // ── Case 11: Course material → generate_quiz in allowedOpportunityTypes ─
        check("course_material_allows_generate_quiz",
              courseGrounding.allowedOpportunityTypes.contains("generate_quiz"))
        check("course_material_allows_create_review_plan",
              courseGrounding.allowedOpportunityTypes.contains("create_review_plan"))

        // ── Case 12: Unknown entity (opaque title, no URL) → shouldPropose=false
        let unknownGrounding = EntityGroundingLayer.ground(
            title: "Untitled 1",
            url: nil,
            appCategory: .unknown,
            memory: emptyMemory(),
            compartment: nil
        )
        check("unknown_entity_should_not_propose",
              unknownGrounding.shouldPropose == false)
        check("unknown_entity_type_is_unknown",
              unknownGrounding.entityType == .unknown)

        // ── Case 13: TV show should not propose ───────────────────────────────
        check("tv_show_should_not_propose",
              nfGrounding.shouldPropose == false)
        check("tv_show_is_entertainment",
              nfGrounding.isEntertainment == true)

        // ── Case 14: AppCategory .pdf → document, allowed includes summarize ──
        let pdfCatGrounding = EntityGroundingLayer.ground(
            title: "Chapter 3 - Sorting Algorithms",
            url: nil,
            appCategory: .pdf,
            memory: emptyMemory(),
            compartment: nil
        )
        check("pdf_category_type_is_document",
              pdfCatGrounding.entityType == .document)
        check("pdf_category_should_propose",
              pdfCatGrounding.shouldPropose == true)
        check("pdf_category_allows_summarize_reference",
              pdfCatGrounding.allowedOpportunityTypes.contains("summarize_reference"))

        let ok = failures.isEmpty
        print("[EntityGroundingSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }

    // MARK: - Helpers

    private static func emptyMemory() -> WorkingMemorySnapshot {
        WorkingMemorySnapshot(
            currentEntity: "",
            recentEntities: [],
            repeatedConcepts: [],
            inferredActivity: "unknown",
            comparisonCandidates: [],
            relatedFocusEntities: []
        )
    }
}
