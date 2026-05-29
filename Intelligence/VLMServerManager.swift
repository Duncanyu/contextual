import Foundation

// TODO: Dev bootstrap only. Production should bundle the VLM runtime as a proper
// launch agent or embedded helper, not rely on finding the script in a source repo.

/// Lightweight manager that ensures the local VLM HTTP server (port 8123) is running.
///
/// Called by `VLMPerceptionEngine` when a health check fails. Attempts to launch
/// `Scripts/start_vlm_server.sh` from the local repo, then polls `/health` for up
/// to `launchTimeoutSeconds` before giving up.
///
/// Safety guarantees:
///   - Never spawns a second process if one is already launching (`isLaunching` guard).
///   - Re-launch rate-limited to once per `minRelaunchInterval` seconds.
///   - Failure is always graceful — returns false; VLM is skipped, loop continues.
///
/// Logs:
///   [VLMServerManager] health_check started endpoint=...
///   [VLMServerManager] health_check ok=yes model=...
///   [VLMServerManager] health_check ok=no reason=server_unavailable
///   [VLMServerManager] launch_attempt started script=...
///   [VLMServerManager] launch_attempt ok=yes pid=...
///   [VLMServerManager] launch_attempt failed reason=...
///   [VLMServerManager] waiting_for_health attempt=N
///   [VLMServerManager] ready=yes model=...
///   [VLMServerManager] ready=no reason=timeout
actor VLMServerManager {

	static let shared = VLMServerManager()

	// MARK: - Configuration

	/// Maximum seconds to wait for the server to become healthy after launching.
	private let launchTimeoutSeconds: TimeInterval = 8.0

	/// Minimum interval between launch attempts to avoid hammering.
	private let minRelaunchInterval: TimeInterval = 30.0

	/// Poll interval while waiting for health after launch.
	private let pollIntervalNanoseconds: UInt64 = 1_500_000_000  // 1.5 s

	// MARK: - State

	private var isLaunching = false
	private var lastLaunchAttempt: Date? = nil

	// MARK: - Script Path

	/// Locate `Scripts/start_vlm_server.sh` in the source tree.
	///
	/// Resolution order:
	///   1. `CONTEXTUAL_VLM_SERVER_SCRIPT` env var (explicit override).
	///   2. Relative to this source file's location at compile time (dev path).
	private static let scriptPath: String = {
		if let envPath = ProcessInfo.processInfo.environment["CONTEXTUAL_VLM_SERVER_SCRIPT"],
		   !envPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return envPath
		}
		// Derive from source file path — works in dev (Xcode DerivedData copies source refs).
		let src = URL(fileURLWithPath: #filePath)
		let repoRoot = src
			.deletingLastPathComponent()   // Intelligence/
			.deletingLastPathComponent()   // contextual/
		return repoRoot
			.appendingPathComponent("Scripts")
			.appendingPathComponent("start_vlm_server.sh")
			.path
	}()

	// MARK: - URLSession

	/// Ephemeral session for health probing — no caching, no cookies.
	private let session: URLSession = {
		let cfg = URLSessionConfiguration.ephemeral
		cfg.urlCache = nil
		cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
		return URLSession(configuration: cfg)
	}()

	// MARK: - Public API

	/// Check health and, if the server is down, attempt to start it.
	///
	/// Returns `true` if the server is healthy (either already was or became healthy
	/// after launch). Returns `false` if launch failed or timed out.
	///
	/// - Parameter healthEndpoint: The `/health` URL to probe.
	func ensureServerRunning(healthEndpoint: URL) async -> Bool {
		print("[VLMServerManager] health_check started endpoint=\(healthEndpoint)")

		if let (ok, model) = await probeHealth(endpoint: healthEndpoint) {
			if ok {
				print("[VLMServerManager] health_check ok=yes model=\(model)")
				return true
			}
		}
		print("[VLMServerManager] health_check ok=no reason=server_unavailable")

		return await attemptLaunch(healthEndpoint: healthEndpoint)
	}

	// MARK: - Internal

	private func attemptLaunch(healthEndpoint: URL) async -> Bool {
		// De-duplicate concurrent calls.
		guard !isLaunching else {
			print("[VLMServerManager] launch_skipped reason=already_launching")
			return false
		}
		// Rate-limit re-launches.
		if let last = lastLaunchAttempt,
		   Date().timeIntervalSince(last) < minRelaunchInterval {
			let wait = Int(minRelaunchInterval - Date().timeIntervalSince(last))
			print("[VLMServerManager] launch_skipped reason=rate_limited next_attempt_in=\(wait)s")
			return false
		}

		let script = Self.scriptPath
		guard FileManager.default.fileExists(atPath: script) else {
			print("[VLMServerManager] launch_attempt failed reason=script_not_found script=\(script)")
			return false
		}

		isLaunching = true
		lastLaunchAttempt = Date()
		defer { isLaunching = false }

		print("[VLMServerManager] launch_attempt started script=\(script)")

		let proc = Process()
		proc.executableURL = URL(fileURLWithPath: "/bin/bash")
		proc.arguments = [script]
		// Detach I/O so the server's stdout doesn't pollute the app console.
		proc.standardOutput = FileHandle.nullDevice
		proc.standardError  = FileHandle.nullDevice

		do {
			try proc.run()
		} catch {
			print("[VLMServerManager] launch_attempt failed reason=\(error.localizedDescription)")
			return false
		}

		print("[VLMServerManager] launch_attempt ok=yes pid=\(proc.processIdentifier)")

		// Poll health until ready or timeout.
		let deadline = Date().addingTimeInterval(launchTimeoutSeconds)
		var attempt = 0
		while Date() < deadline {
			try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
			attempt += 1
			print("[VLMServerManager] waiting_for_health attempt=\(attempt)")

			if let (ok, model) = await probeHealth(endpoint: healthEndpoint), ok {
				print("[VLMServerManager] ready=yes model=\(model)")
				return true
			}
		}

		print("[VLMServerManager] ready=no reason=timeout")
		return false
	}

	/// Returns `(ok, modelName)` on a successful HTTP 200 with `{"ok":true}`, nil otherwise.
	private func probeHealth(endpoint: URL) async -> (Bool, String)? {
		var req = URLRequest(url: endpoint)
		req.httpMethod = "GET"
		req.timeoutInterval = 1.5   // Fast probe — fail quickly during polling loop.
		do {
			let (data, resp) = try await session.data(for: req)
			guard (resp as? HTTPURLResponse)?.statusCode == 200,
				  let obj   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
				  let ok    = obj["ok"] as? Bool
			else { return nil }
			let model = (obj["model"] as? String) ?? "unknown"
			return (ok, model)
		} catch {
			return nil
		}
	}
}
