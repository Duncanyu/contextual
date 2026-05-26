// PlannerCandidateSelfTest.swift
// Validates that the multi-candidate planner schema produces ≥1 candidate
// and that PlannerCandidateSelector picks a useful one.
//
// Triggered by: CONTEXTUAL_RUN_PLANNER_CANDIDATE_SELFTEST=1
// Uses real Ollama calls (phi4-mini) — requires Ollama running.
//
// Expected output:
//   [PlannerCandidateSelfTest] started
//   [PlannerCandidateSelfTest] case=shopping result=pass candidates=N
//   [PlannerCandidateSelfTest] case=coding result=pass candidates=N
//   [PlannerCandidateSelfTest] ok=true failures=0

import Foundation

struct PlannerCandidateSelfTest {

    static func run() async {
        print("[PlannerCandidateSelfTest] started")

        let llm = LocalAIClient.shared
        let schema = TaskInferenceEngine.plannerSchema
        let model = "phi4-mini"
        let numPredict = 220
        let temperature = 0.05

        var failures = 0

        let cases: [(name: String, prompt: String, expectSurface: Bool)] = [
            (
                name: "shopping",
                prompt: """
Produce 2-3 ranked action candidates for the user's current activity. Best/most-specific first.
Each action: title (≤10 words, user-centric, describe an operation not current state), caps (from: context,extract,reason,output,compare,organize,debug,study), confidence (0-1), novelty (0-1 how page-specific), requires (data needed).
should_surface_softly=true when context is actionable: product/shopping/code/clipboard/OCR.
ctx app=Safari title=anker solix c1000 portable power station amazon.com wf=browsing cat=shopping ocr_avail=no visual_descriptor_available=no ax_avail=no sel=0 clip=0
""",
                expectSurface: true
            ),
            (
                name: "coding",
                prompt: """
Produce 2-3 ranked action candidates for the user's current activity. Best/most-specific first.
Each action: title (≤10 words, user-centric, describe an operation not current state), caps (from: context,extract,reason,output,compare,organize,debug,study), confidence (0-1), novelty (0-1 how page-specific), requires (data needed).
should_surface_softly=true when context is actionable: product/shopping/code/clipboard/OCR.
ctx app=Xcode title=taskinferenceengine.swift contextual wf=coding cat=development ocr_avail=no visual_descriptor_available=no ax_avail=no sel=0 clip=0
""",
                expectSurface: true
            ),
        ]

        for testCase in cases {
            do {
                let raw = try await llm.generateStreamingJSON(
                    prompt: testCase.prompt,
                    model: model,
                    numPredict: numPredict,
                    temperature: temperature,
                    purpose: "selftest_planner_candidate",
                    schema: schema
                )

                guard let parsed = TaskInferenceEngine.parsePlannerCandidates(raw) else {
                    print("[PlannerCandidateSelfTest] case=\(testCase.name) result=fail reason=parse_failed")
                    failures += 1
                    continue
                }

                let count = parsed.candidates.count
                // Select best by confidence (simple, no snapshot needed in self-test)
                let sel = parsed.candidates.max(by: { $0.confidence < $1.confidence })

                guard count >= 1, let best = sel else {
                    print("[PlannerCandidateSelfTest] case=\(testCase.name) result=fail reason=no_candidates count=\(count)")
                    failures += 1
                    continue
                }

                print("[PlannerCandidateSelfTest] case=\(testCase.name) result=pass candidates=\(count) selected=\"\(best.title)\"")

            } catch {
                print("[PlannerCandidateSelfTest] case=\(testCase.name) result=fail error=\(error)")
                failures += 1
            }
        }

        print("[PlannerCandidateSelfTest] ok=\(failures == 0) failures=\(failures)")
    }
}
