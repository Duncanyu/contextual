import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Test-injectable dependencies

/// Frontmost-app provider abstraction. Returns the bundle identifier of the
/// currently frontmost macOS application (or nil if none / not available).
///
/// Methods are `@MainActor` because production implementations touch
/// `NSWorkspace` (main-thread-only) and because the handoff coordinator
/// itself runs on the main actor. Stubs satisfy the requirement by being
/// invoked from a `@MainActor` task in the self-test.
protocol ExecutionFocusFrontmostProvider {
	@MainActor func currentFrontmostBundleIdentifier() -> String?
}

/// Side-effect surface for activating a target macOS app by bundle id.
///
/// Production implementation uses `NSRunningApplication.activate(options:)`
/// / `NSWorkspace.shared.launchApplication(...)`. Tests can record requests
/// without launching processes.
protocol ExecutionFocusActivator {
	/// Returns `true` if an activation was issued (does not block on completion).
	@MainActor func activateApp(bundleIdentifier: String) -> Bool
}

/// Minimal contract for hiding/showing the assistant UI surfaces during execution.
///
/// Implemented by AppDelegate over `AppState`. Methods are `@MainActor`
/// because production implementations mutate `@Published` AppState fields.
protocol ExecutionFocusAssistantUI: AnyObject {
	/// Hide floating + collapse panel chrome BEFORE the runtime starts.
	@MainActor func hideAssistantUI(reason: String)
	/// Restore result/panel UI AFTER the runtime completes.
	@MainActor func restoreAssistantUI(reason: String)
}

// MARK: - Default implementations (AppKit-backed)

#if canImport(AppKit)
/// Production frontmost provider using NSWorkspace.
///
/// The protocol method is `@MainActor`, so the AppKit call is reachable
/// without `MainActor.assumeIsolated` (which would trap when called from a
/// non-main executor — the very Phase 4M crash we are recovering from).
struct NSWorkspaceFrontmostProvider: ExecutionFocusFrontmostProvider {
	@MainActor
	func currentFrontmostBundleIdentifier() -> String? {
		NSWorkspace.shared.frontmostApplication?.bundleIdentifier
	}
}

/// Production activator using NSRunningApplication / NSWorkspace.
struct NSWorkspaceFocusActivator: ExecutionFocusActivator {
	@MainActor
	func activateApp(bundleIdentifier: String) -> Bool {
		// Prefer an already-running instance — avoids relaunching a fresh app process.
		let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
		if let app = running.first {
			// `.activateIgnoringOtherApps` is the only way to re-front a different app
			// from our own non-frontmost process; without it macOS may refuse.
			if #available(macOS 14.0, *) {
				_ = app.activate(options: [])
			} else {
				_ = app.activate(options: [.activateIgnoringOtherApps])
			}
			return true
		}
		// Fall back to NSWorkspace launch — only requests, does not wait.
		let ok = NSWorkspace.shared.launchApplication(
			withBundleIdentifier: bundleIdentifier,
			options: [.async, .default],
			additionalEventParamDescriptor: nil,
			launchIdentifier: nil
		)
		return ok
	}
}
#endif

// MARK: - Coordinator

/// Phase 4M — Execution Focus Handoff.
///
/// Orchestrates the brief UI/focus transition that must happen each time the
/// user clicks Execute/Open on a generated proposal:
///
///   1. Hide assistant UI (floating + panel chrome)                       — `[ExecutionFocusHandoff] assistant_ui_hidden=...`
///   2. Activate target app (when frontmost is Contextual)                — `[ExecutionFocusHandoff] target_activate_requested ...`
///   3. Wait briefly for focus to settle                                  — `[ExecutionFocusHandoff] settle_ms=...`
///   4. Verify frontmost bundle matches target anchor                     — `[ExecutionFocusVerify] expected=... actual=... matched=...`
///   5. Decide whether control is allowed for the upcoming runtime        — `[ExecutionFocusVerify] control_allowed=...`
///   6. After runtime completes, restore assistant UI                     — `[ExecutionFocusHandoff] assistant_ui_restored=...`
///
/// **Non-negotiable constraints (Phase 4M):**
///   - Never sends keyboard / scroll control as a side effect.
///   - Does not re-enable the legacy hook catalog.
///   - Does not make every proposal floating.
///   - Does not depend on browser automation frameworks or cloud APIs.
///
/// The coordinator is intentionally stateless across calls — each `prepare(...)`
/// returns an `ExecutionFocusHandoffOutcome` value that the caller threads back
/// into `finalize(...)`. This keeps the contract self-test-friendly.
///
/// **MainActor isolation.** `prepare(...)` and `finalize(...)` are marked
/// `@MainActor` so that AppKit calls inside the protocol implementations
/// (`NSWorkspace.shared.frontmostApplication`, `NSRunningApplication.activate`,
/// `AppState` mutation) run on the main executor without needing
/// `MainActor.assumeIsolated`. The previous Phase 4M version trapped at
/// `EXC_BREAKPOINT` because the async function inherited the global executor
/// instead of MainActor.
struct ExecutionFocusHandoff {

	// MARK: - Settle timing

	/// Settle delay applied after hide + activate, before verification.
	/// Allows macOS to animate the focus switch and update the frontmost
	/// application before we ask "what is frontmost now".
	static let defaultSettleMs: Int = 220
	/// Lower bound the spec requires (150ms).
	static let minSettleMs: Int = 150
	/// Upper bound the spec requires (300ms).
	static let maxSettleMs: Int = 300

	// MARK: - Dependencies (injectable)

	let frontmostProvider: ExecutionFocusFrontmostProvider
	let activator: ExecutionFocusActivator
	let assistantUI: ExecutionFocusAssistantUI
	let assistantBundleIdentifier: String?
	let settleMs: Int

	init(
		frontmostProvider: ExecutionFocusFrontmostProvider,
		activator: ExecutionFocusActivator,
		assistantUI: ExecutionFocusAssistantUI,
		assistantBundleIdentifier: String? = Bundle.main.bundleIdentifier,
		settleMs: Int = ExecutionFocusHandoff.defaultSettleMs
	) {
		self.frontmostProvider = frontmostProvider
		self.activator = activator
		self.assistantUI = assistantUI
		self.assistantBundleIdentifier = assistantBundleIdentifier
		self.settleMs = max(Self.minSettleMs, min(Self.maxSettleMs, settleMs))
	}

	// MARK: - Public API

	/// Run the pre-execution focus handoff sequence.
	///
	/// Safe to call even when `targetAnchor` is nil — the coordinator will still
	/// hide assistant UI and report frontmost state, but it will not attempt to
	/// activate any specific app.
	///
	/// `@MainActor` so the internal AppKit/AppState calls are valid without
	/// any `assumeIsolated`. The internal `Task.sleep` yields cooperatively
	/// — it does not block the main thread.
	@MainActor
	func prepare(targetAnchor: TargetWindowAnchor?) async -> ExecutionFocusHandoffOutcome {
		// 1. Hide assistant UI first so we don't capture our own chrome.
		assistantUI.hideAssistantUI(reason: "execution_start")
		print("[ExecutionFocusHandoff] assistant_ui_hidden=yes reason=execution_start")
		print("[ExecutionFocusHandoff] floating_hidden=yes panel_hidden=yes")

		let frontmostBefore = frontmostProvider.currentFrontmostBundleIdentifier()
		let frontmostBeforeLabel = frontmostBefore ?? "nil"

		// 2. Activate target app when the user is currently in Contextual (or
		//    when a target anchor exists and we are not already on it).
		var activationRequested = false
		var activationSucceeded = false
		if let targetAnchor {
			let needsActivation: Bool = {
				if let frontmostBefore, frontmostBefore == targetAnchor.bundleIdentifier { return false }
				if let assistantBundleIdentifier, frontmostBefore == assistantBundleIdentifier { return true }
				// Different non-target app frontmost — restore target.
				return true
			}()
			if needsActivation {
				activationRequested = true
				print("[ExecutionFocusHandoff] target_activate_requested bundle=\(targetAnchor.bundleIdentifier) app=\(targetAnchor.appName)")
				activationSucceeded = activator.activateApp(bundleIdentifier: targetAnchor.bundleIdentifier)
				if !activationSucceeded {
					print("[ExecutionFocusHandoff] target_activate_fallback reason=activation_request_failed bundle=\(targetAnchor.bundleIdentifier)")
				}
			} else {
				print("[ExecutionFocusHandoff] target_activate_skipped reason=already_frontmost bundle=\(targetAnchor.bundleIdentifier)")
			}
		} else {
			print("[ExecutionFocusHandoff] target_activate_skipped reason=no_target_anchor")
		}

		// 3. Settle delay: lets macOS animate the focus switch.
		print("[ExecutionFocusHandoff] settle_ms=\(settleMs)")
		try? await Task.sleep(nanoseconds: UInt64(settleMs) * 1_000_000)

		// 4. Verify the frontmost app now matches the target anchor.
		let frontmostAfter = frontmostProvider.currentFrontmostBundleIdentifier()
		let frontmostAfterLabel = frontmostAfter ?? "nil"
		print("[ExecutionFocusHandoff] frontmost_before=\(frontmostBeforeLabel) frontmost_after=\(frontmostAfterLabel) success=\(activationRequested ? (frontmostAfter == targetAnchor?.bundleIdentifier ? "yes" : "no") : "n/a")")

		let expected = targetAnchor?.bundleIdentifier
		let matched: Bool
		if let expected, let frontmostAfter {
			matched = (expected == frontmostAfter)
		} else if expected == nil {
			// No anchor → policy will fall back to its own checks; we report "matched" as true
			// so this coordinator does not over-block when there is no anchor to enforce.
			matched = true
		} else {
			matched = false
		}
		let expectedLabel = expected ?? "nil"
		print("[ExecutionFocusVerify] expected=\(expectedLabel) actual=\(frontmostAfterLabel) matched=\(matched ? "yes" : "no")")

		// 5. Control allowed only when matched — runtime falls back to observation-only otherwise.
		let controlAllowed = matched
		print("[ExecutionFocusVerify] control_allowed=\(controlAllowed ? "yes" : "no")")

		return ExecutionFocusHandoffOutcome(
			targetBundleIdentifier: expected,
			frontmostBefore: frontmostBefore,
			frontmostAfter: frontmostAfter,
			activationRequested: activationRequested,
			activationSucceeded: activationSucceeded,
			matched: matched,
			controlAllowed: controlAllowed,
			settleMs: settleMs
		)
	}

	/// Restore assistant UI surfaces after the runtime completes.
	///
	/// Idempotent — safe to call even if `prepare(...)` was not invoked.
	@MainActor
	func finalize(outcome: ExecutionFocusHandoffOutcome?, reason: String = "execution_complete") {
		assistantUI.restoreAssistantUI(reason: reason)
		print("[ExecutionFocusHandoff] assistant_ui_restored=yes reason=\(reason)")
	}
}

// MARK: - Outcome

/// Snapshot of one execution-focus handoff.
///
/// The runtime threads `controlAllowed` into `AgenticControlPolicy` so that
/// scroll / find actions are blocked when focus did not actually transfer.
struct ExecutionFocusHandoffOutcome: Sendable, Equatable {
	let targetBundleIdentifier: String?
	let frontmostBefore: String?
	let frontmostAfter: String?
	let activationRequested: Bool
	let activationSucceeded: Bool
	let matched: Bool
	let controlAllowed: Bool
	let settleMs: Int

	/// A no-op outcome used when no anchor exists. Treated by downstream callers
	/// as "no focus opinion" — they apply their own defaults.
	static let unanchored = ExecutionFocusHandoffOutcome(
		targetBundleIdentifier: nil,
		frontmostBefore: nil,
		frontmostAfter: nil,
		activationRequested: false,
		activationSucceeded: false,
		matched: true,
		controlAllowed: true,
		settleMs: 0
	)
}
