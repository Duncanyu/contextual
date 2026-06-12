import Foundation

/// Phase 46 — Debug-only panel action for UCR dogfood validation.
///
/// Appears in the suggestion panel when `CONTEXTUAL_UCR_DOGFOOD=1` (or the
/// matching UserDefaults key) is set. When executed, runs UniversalContentReader
/// on the current frontmost app and shows a diagnostic floating result card.
///
/// This is a `final class` (not a struct) so it can hold a `weak` AppState ref
/// and avoid the retain cycle: action → appState.availableActions → action.
final class UCRDogfoodTestAction: ActionProtocol {

    static let actionId = "ucr_dogfood_test"

    let id   = UCRDogfoodTestAction.actionId
    let name = "Test content acquisition"

    /// Weak to avoid retain cycle. AppState is @MainActor; we always access it
    /// inside MainActor.run to satisfy concurrency requirements.
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func canExecute(context: ContextModel) -> Bool {
        // Always executable in dogfood mode
        return true
    }

    func execute(context: ContextModel) async -> ActionResult {
        // Hop to main actor so we can safely touch AppState and post the result card.
        await MainActor.run {
            guard let appState else {
                print("[UCRDogfoodTest] skipped reason=appState_released")
                return
            }
            Task {
                await UCRDogfoodMode.runDiagnostic(appState: appState)
            }
        }
        // Return empty output — the result card is shown directly by runDiagnostic.
        return ActionResult(actionId: id, outputText: "", executionStatus: .success)
    }
}
