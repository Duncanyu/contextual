// StructuredOutputSelfTest.swift
// Validates that router and planner produce valid structured JSON via Ollama's
// native schema-constrained generation (format: {JSON Schema object}).
//
// Triggered by: CONTEXTUAL_RUN_STRUCTURED_OUTPUT_SELFTEST=1
// Run 25 router calls (phi4-mini) + 10 planner calls (phi4-mini).
// All calls use streaming + schema. No prose, no markdown fences, no parse failures.
//
// Expected output:
//   [StructuredOutputSelfTest] started
//   [StructuredOutputSelfTest] router_valid=25/25
//   [StructuredOutputSelfTest] planner_valid=10/10
//   [StructuredOutputSelfTest] prose_failures=0
//   [StructuredOutputSelfTest] markdown_failures=0
//   [StructuredOutputSelfTest] parse_failures=0
//   [StructuredOutputSelfTest] planner_avg_ms=NNN
//   [StructuredOutputSelfTest] planner_p95_ms=NNN
//   [StructuredOutputSelfTest] ok=true failures=0

import Foundation

struct StructuredOutputSelfTest {

    static func run() async {
        print("[StructuredOutputSelfTest] started")

        let llm = LocalAIClient.shared
        let routerSchema = TaskInferenceEngine.routerSchema
        let plannerSchema = TaskInferenceEngine.plannerSchema
        let routerModel = "phi4-mini"
        let plannerModel = "phi4-mini"
        let routerTotal = 25
        let plannerTotal = 10

        var routerValid = 0
        var plannerValid = 0
        var proseFailures = 0
        var markdownFailures = 0
        var parseFailures = 0
        var plannerLatencies: [Int] = []

        let testStart = Date()

        // ── Router calls ────────────────────────────────────────────────────────
        for i in 1...routerTotal {
            let prompt = syntheticRouterPrompt(index: i)
            let callStart = Date()
            do {
                let raw = try await llm.generateStreamingJSON(
                    prompt: prompt,
                    model: routerModel,
                    numPredict: TaskInferenceEngine.routerNumPredict,
                    temperature: 0.1,
                    purpose: "selftest_router",
                    schema: routerSchema
                )
                let ms = Int(Date().timeIntervalSince(callStart) * 1000)
                let verdict = evaluate(raw: raw, parseAs: .router, index: i, elapsed: ms,
                                       proseFailures: &proseFailures,
                                       markdownFailures: &markdownFailures,
                                       parseFailures: &parseFailures)
                if verdict { routerValid += 1 }
            } catch {
                let ms = Int(Date().timeIntervalSince(callStart) * 1000)
                print("[StructuredOutputSelfTest] router[\(i)] error=\(error) elapsed_ms=\(ms)")
                parseFailures += 1
            }
        }

        // ── Planner calls ───────────────────────────────────────────────────────
        for i in 1...plannerTotal {
            let prompt = syntheticPlannerPrompt(index: i)
            let callStart = Date()
            do {
                let raw = try await llm.generateStreamingJSON(
                    prompt: prompt,
                    model: plannerModel,
                    numPredict: 300,   // matches production plannerNumPredict (3 candidates ≈ 200 tokens + structure)
                    temperature: 0.05,    // matches production planner temperature
                    purpose: "selftest_planner",
                    schema: plannerSchema
                )
                let ms = Int(Date().timeIntervalSince(callStart) * 1000)
                plannerLatencies.append(ms)
                let verdict = evaluate(raw: raw, parseAs: .planner, index: i, elapsed: ms,
                                       proseFailures: &proseFailures,
                                       markdownFailures: &markdownFailures,
                                       parseFailures: &parseFailures)
                if verdict { plannerValid += 1 }
            } catch {
                let ms = Int(Date().timeIntervalSince(callStart) * 1000)
                plannerLatencies.append(ms)
                print("[StructuredOutputSelfTest] planner[\(i)] error=\(error) elapsed_ms=\(ms)")
                parseFailures += 1
            }
        }

        let totalMs = Int(Date().timeIntervalSince(testStart) * 1000)
        let totalFailures = (routerTotal - routerValid) + (plannerTotal - plannerValid)

        // Latency stats
        let avgMs = plannerLatencies.isEmpty ? 0 : plannerLatencies.reduce(0, +) / plannerLatencies.count
        let p95Ms: Int = {
            guard !plannerLatencies.isEmpty else { return 0 }
            let sorted = plannerLatencies.sorted()
            let idx = Int(ceil(Double(sorted.count) * 0.95)) - 1
            return sorted[max(0, min(idx, sorted.count - 1))]
        }()

        print("[StructuredOutputSelfTest] router_valid=\(routerValid)/\(routerTotal)")
        print("[StructuredOutputSelfTest] planner_valid=\(plannerValid)/\(plannerTotal)")
        print("[StructuredOutputSelfTest] prose_failures=\(proseFailures)")
        print("[StructuredOutputSelfTest] markdown_failures=\(markdownFailures)")
        print("[StructuredOutputSelfTest] parse_failures=\(parseFailures)")
        print("[StructuredOutputSelfTest] planner_avg_ms=\(avgMs)")
        print("[StructuredOutputSelfTest] planner_p95_ms=\(p95Ms)")
        print("[StructuredOutputSelfTest] ok=\(totalFailures == 0 ? "true" : "false") failures=\(totalFailures) total_ms=\(totalMs)")
    }

    // MARK: - Evaluation

    private enum ParseTarget { case router, planner }

    /// Returns true if the response passes all checks (valid JSON, no prose, no markdown).
    private static func evaluate(
        raw: String,
        parseAs target: ParseTarget,
        index: Int,
        elapsed: Int,
        proseFailures: inout Int,
        markdownFailures: inout Int,
        parseFailures: inout Int
    ) -> Bool {
        let label = target == .router ? "router[\(index)]" : "planner[\(index)]"

        // 1. Markdown fence check
        if raw.contains("```") {
            let preview = String(raw.prefix(120)).replacingOccurrences(of: "\n", with: "↵")
            print("[StructuredOutputSelfTest] \(label) FAIL markdown_fence raw=\"\(preview)\" elapsed_ms=\(elapsed)")
            markdownFailures += 1
            parseFailures += 1
            return false
        }

        // 2. Prose-before-JSON check
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstBrace = trimmed.firstIndex(of: "{") {
            let prefix = String(trimmed[trimmed.startIndex..<firstBrace])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                let preview = String(prefix.prefix(80))
                print("[StructuredOutputSelfTest] \(label) FAIL prose_before_json prefix=\"\(preview)\" elapsed_ms=\(elapsed)")
                proseFailures += 1
                parseFailures += 1
                return false
            }
        }

        // 3. Parse check
        switch target {
        case .router:
            guard let _ = TaskInferenceEngine.parseRouterOutput(raw) else {
                let preview = String(raw.prefix(120)).replacingOccurrences(of: "\n", with: "↵")
                print("[StructuredOutputSelfTest] \(label) FAIL parse raw=\"\(preview)\" elapsed_ms=\(elapsed)")
                parseFailures += 1
                return false
            }
        case .planner:
            guard let parsed = TaskInferenceEngine.parsePlannerCandidates(raw) else {
                let preview = String(raw.prefix(120)).replacingOccurrences(of: "\n", with: "↵")
                print("[StructuredOutputSelfTest] \(label) FAIL parse raw=\"\(preview)\" elapsed_ms=\(elapsed)")
                parseFailures += 1
                return false
            }
            // Verify: at least one candidate with title + caps
            let hasActions = !parsed.candidates.isEmpty
            let hasTitle   = parsed.candidates.first.map { !$0.title.isEmpty } ?? false
            let hasCaps    = parsed.candidates.first.map { !$0.caps.isEmpty } ?? false
            if !hasActions || !hasTitle || !hasCaps {
                print("[StructuredOutputSelfTest] \(label) FAIL missing_required_fields actions=\(hasActions) title=\(hasTitle) caps=\(hasCaps) elapsed_ms=\(elapsed)")
                parseFailures += 1
                return false
            }
        }

        print("[StructuredOutputSelfTest] \(label) ok elapsed_ms=\(elapsed)")
        return true
    }

    // MARK: - Synthetic prompts (varied scenarios, matching production builder format)

    private static let routerScenarios: [(app: String, title: String, wf: String)] = [
        ("Safari",    "Amazon.com: Sony WH-1000XM5 Wireless Headphones",   "browsing"),
        ("Xcode",     "TaskInferenceEngine.swift — Contextual",             "coding"),
        ("Chrome",    "Pull Request #42 — GitHub",                          "reviewing"),
        ("TextEdit",  "Meeting Notes — Q3 Planning",                        "writing"),
        ("Terminal",  "zsh — contextual",                                   "debugging"),
        ("Safari",    "eBay: Apple MacBook Pro 14-inch listing",            "browsing"),
        ("VS Code",   "AppDelegate.swift — contextual",                     "coding"),
        ("Chrome",    "RFC 9110 — HTTP Semantics — IETF Datatracker",       "reviewing"),
        ("Numbers",   "Budget 2024.numbers",                                "writing"),
        ("iTerm2",    "bash — npm test — 3 failing",                        "debugging"),
    ]

    private static let plannerScenarios: [(app: String, title: String, wf: String, cat: String)] = [
        ("Safari",    "Sony WH-1000XM5 — Amazon.com",           "browsing",   "shopping"),
        ("Xcode",     "TaskInferenceEngine.swift",               "coding",     "development"),
        ("Chrome",    "RFC 9110 — HTTP Semantics",               "reviewing",  "research"),
        ("TextEdit",  "Budget 2024.txt",                         "writing",    "finance"),
        ("Terminal",  "npm test — 3 failing",                    "debugging",  "development"),
        ("Safari",    "eBay MacBook Pro listing",                "browsing",   "shopping"),
        ("VS Code",   "AppDelegate.swift — contextual",          "coding",     "development"),
        ("Chrome",    "WWDC25 — Apple developer session",        "reviewing",  "research"),
        ("Numbers",   "Q3 Budget Tracker",                       "writing",    "finance"),
        ("iTerm2",    "pytest — 12 errors — contextual",         "debugging",  "development"),
    ]

    private static func syntheticRouterPrompt(index: Int) -> String {
        let s = routerScenarios[(index - 1) % routerScenarios.count]
        // Matches TwoStageRouterPromptBuilder output exactly
        return """
Task: Decide if the provided context is sufficient to classify the user's intent.
If app/title is clear, or ocr/visual/ax/sel is present -> enough_context.
If blank browser/media/game with no text -> need_more_context.
If need_more_context, you may request: ocr, visual_descriptor, ax_window_text.
ctx app=\(s.app) title=\(s.title) wf=\(s.wf) ocr=no visual=no ax=no sel=no clip=no
"""
    }

    private static func syntheticPlannerPrompt(index: Int) -> String {
        let s = plannerScenarios[(index - 1) % plannerScenarios.count]
        let needCatsAllowed = "context,extract,reason,output,compare,organize,debug,study"
        // Matches TwoStageCompactPlannerPromptBuilder multi-candidate output.
        return """
Produce 2-3 ranked action candidates for the user's current activity. Best/most-specific first.
Each action: title (≤10 words, user-centric, describe an operation not current state), caps (from: \(needCatsAllowed)), confidence (0-1), novelty (0-1 how page-specific), requires (data needed).
should_surface_softly=true when context is actionable: product/shopping/code/clipboard/OCR.
ctx app=\(s.app) title=\(s.title) wf=\(s.wf) cat=\(s.cat) ocr_avail=no visual_descriptor_available=no ax_avail=no sel=0 clip=0
"""
    }
}
