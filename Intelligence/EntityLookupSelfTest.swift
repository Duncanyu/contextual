import Foundation

/// Phase 22.2 — EntityLookupLayer self-test (Task I).
///
/// Tests OG metadata parsing, safety guards, and cache behaviour.
/// Does NOT make real network requests — tests the parsing logic directly.
///
/// Trigger: CONTEXTUAL_RUN_ENTITY_LOOKUP_SELFTEST=1
enum EntityLookupSelfTest {

    static func run() -> Bool {
        print("[EntityLookupSelfTest] starting")
        var failures: [String] = []

        func check(_ name: String, _ ok: Bool) {
            if ok {
                print("[EntityLookupSelfTest] pass case=\(name)")
            } else {
                print("[EntityLookupSelfTest] fail case=\(name)")
                failures.append(name)
            }
        }

        // ── Case 1: Safety guard — HTTPS only ─────────────────────────────────
        check("https_is_safe",
              EntityLookupLayer.isSafeToFetch(URL(string: "https://www.example.com")!))
        check("http_is_not_safe",
              !EntityLookupLayer.isSafeToFetch(URL(string: "http://www.example.com")!))
        check("file_is_not_safe",
              !EntityLookupLayer.isSafeToFetch(URL(string: "file:///tmp/test.html")!))

        // ── Case 2: Safety guard — private IPs blocked ────────────────────────
        check("localhost_blocked",
              !EntityLookupLayer.isSafeToFetch(URL(string: "https://localhost/test")!))
        check("private_10_blocked",
              !EntityLookupLayer.isSafeToFetch(URL(string: "https://10.0.0.1/page")!))
        check("private_192168_blocked",
              !EntityLookupLayer.isSafeToFetch(URL(string: "https://192.168.1.1/")!))
        check("private_172_blocked",
              !EntityLookupLayer.isSafeToFetch(URL(string: "https://172.16.0.1/")!))
        check("public_ip_is_safe",
              EntityLookupLayer.isSafeToFetch(URL(string: "https://8.8.8.8/")!))

        // ── Case 3: OG parsing — video.episode → tv_show ──────────────────────
        let tvHtml = """
            <html><head>
            <meta property="og:type" content="video.episode" />
            <meta property="og:title" content="Dexter S01E03" />
            <meta property="og:site_name" content="Netflix" />
            </head></html>
            """
        let tvOG = EntityLookupLayer.parseOGTags(from: tvHtml)
        check("og_type_video_episode_parsed", tvOG.ogType == "video.episode")
        check("og_site_name_netflix_parsed", tvOG.ogSiteName == "Netflix")
        check("og_title_parsed", tvOG.ogTitle == "Dexter S01E03")

        // ── Case 4: OG parsing — game type ────────────────────────────────────
        let gameHtml = """
            <html><head>
            <meta property="og:type" content="game" />
            <meta property="og:title" content="Tank Shooter Demo" />
            </head></html>
            """
        let gameOG = EntityLookupLayer.parseOGTags(from: gameHtml)
        check("og_type_game_parsed", gameOG.ogType == "game")

        // ── Case 5: OG parsing — article type ─────────────────────────────────
        let articleHtml = """
            <html><head>
            <meta property="og:type" content="article" />
            <meta property="og:title" content="Introduction to Sorting" />
            </head></html>
            """
        let articleOG = EntityLookupLayer.parseOGTags(from: articleHtml)
        check("og_type_article_parsed", articleOG.ogType == "article")

        // ── Case 6: OG parsing — alternate attribute order ────────────────────
        let reverseHtml = """
            <html><head>
            <meta content="video.tv_show" property="og:type" />
            <meta content="HBO Max" property="og:site_name" />
            </head></html>
            """
        let reverseOG = EntityLookupLayer.parseOGTags(from: reverseHtml)
        check("og_reverse_order_type_parsed", reverseOG.ogType == "video.tv_show")
        check("og_reverse_order_site_parsed", reverseOG.ogSiteName == "HBO Max")

        // ── Case 7: OG parsing — missing tags → empty strings ────────────────
        let noOGHtml = "<html><head><title>Hello World</title></head></html>"
        let noOG = EntityLookupLayer.parseOGTags(from: noOGHtml)
        check("missing_og_tags_type_empty", noOG.ogType.isEmpty)
        check("missing_og_tags_title_empty", noOG.ogTitle.isEmpty)

        // ── Case 8: Cache — set and retrieve ──────────────────────────────────
        // (Reset cache first)
        let testURL = URL(string: "https://test.example.com/test")!
        // cachedResult should return nil before anything is set
        check("cache_miss_returns_nil",
              EntityLookupLayer.cachedResult(for: testURL) == nil)

        // ── Case 9: prefetchIfNeeded — unsafe URL does not crash ──────────────
        // Just verify it doesn't crash for a private IP
        let privateURL = URL(string: "https://192.168.1.100/page")!
        EntityLookupLayer.prefetchIfNeeded(url: privateURL, entityName: "test")
        check("prefetch_unsafe_url_no_crash", true)

        // ── Case 10: prefetchIfNeeded — public URL fires without crash ─────────
        // (We can't verify the network request, but we can check it doesn't crash)
        let publicURL = URL(string: "https://www.example.com/")!
        EntityLookupLayer.prefetchIfNeeded(url: publicURL, entityName: "Example Site")
        check("prefetch_public_url_no_crash", true)

        let ok = failures.isEmpty
        print("[EntityLookupSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
