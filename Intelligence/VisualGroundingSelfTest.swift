import AppKit
import Foundation

/// Live smoke test for VisualGrounder.
///
/// Captures the current frontmost window, asks the configured vision model to locate
/// "search bar", and reports whether the model returned usable coordinates within the
/// hard 2-second wall-clock budget.
///
/// Trigger: CONTEXTUAL_RUN_VISUAL_GROUNDING_SELFTEST=1
///
/// Required log output:
///   [VisualGroundingSmokeTest] started instruction="search bar"
///   [VisualGroundingSmokeTest] raw_response="..."
///   [VisualGroundingSmokeTest] parsed_region=x1,y1,x2,y2
///   [VisualGroundingSmokeTest] latency_ms=...
///   [VisualGroundingSmokeTest] ok=yes / ok=no reason=...
enum VisualGroundingSelfTest {

    static func run() async {
        let instruction = "search bar"
        print("[VisualGroundingSmokeTest] started instruction=\"\(instruction)\"")

        // Capture the frontmost window
        guard let frame = ScreenCaptureSource.captureSingleFrame(targetAnchor: nil) else {
            print("[VisualGroundingSmokeTest] failed reason=screenshot_unavailable")
            print("[VisualGroundingSmokeTest] ok=no reason=screenshot_unavailable")
            return
        }

        let wallStart = Date()
        let (outcome, rawResponse) = await VisualGrounder.ground(
            image: frame.image,
            instruction: instruction,
            targetRect: nil
        )
        let latencyMs = Int(Date().timeIntervalSince(wallStart) * 1000)

        let rawTruncated = rawResponse?.prefix(120) ?? "none"
        print("[VisualGroundingSmokeTest] raw_response=\"\(rawTruncated)\"")
        print("[VisualGroundingSmokeTest] latency_ms=\(latencyMs)")

        switch outcome {
        case .grounded(let region):
            print("[VisualGroundingSmokeTest] parsed_region=\(Int(region.x1)),\(Int(region.y1)),\(Int(region.x2)),\(Int(region.y2))")
            print("[VisualGroundingSmokeTest] click_center=\(Int(region.center.x)),\(Int(region.center.y))")
            let withinBudget = latencyMs <= 2000
            if withinBudget {
                print("[VisualGroundingSmokeTest] ok=yes")
                AgenticExperimentalMode.recordSmokeTestResult(passed: true)
            } else {
                print("[VisualGroundingSmokeTest] ok=slow latency_ms=\(latencyMs) warning=exceeds_2000ms_budget")
                AgenticExperimentalMode.recordSmokeTestResult(passed: false)
            }

        case .timedOut:
            print("[VisualGroundingSmokeTest] parsed_region=none")
            print("[VisualGroundingSmokeTest] ok=no reason=timeout model_too_slow_for_click_grounding")
            print("[VisualGroundingSmokeTest] recommendation=install_moondream or set CONTEXTUAL_VISUAL_GROUNDER_MODEL=moondream")
            AgenticExperimentalMode.recordSmokeTestResult(passed: false)

        case .unavailable(let reason):
            print("[VisualGroundingSmokeTest] parsed_region=none")
            print("[VisualGroundingSmokeTest] ok=no reason=\(reason)")
            if reason == "no_vision_model_installed" {
                print("[VisualGroundingSmokeTest] recommendation=run: ollama pull moondream")
            }
            AgenticExperimentalMode.recordSmokeTestResult(passed: false)
        }
    }
}
