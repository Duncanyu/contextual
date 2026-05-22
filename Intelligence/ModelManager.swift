import Foundation

/// Prepares local model runtime availability; inference uses `LocalAIClient` / `generate`.
final class ModelManager: @unchecked Sendable {
	static let shared = ModelManager()

	private static var serveProcess: Process?
	private static let serveDrainQueue = DispatchQueue(label: "com.contextual.ollama.serve.drain", qos: .utility)

	/// Isolated session for local probes — avoids `URLSession.shared` noise and matches generate client settings.
	private static let tagsURLSession: URLSession = {
		let c = URLSessionConfiguration.ephemeral
		c.waitsForConnectivity = false
		c.httpShouldSetCookies = false
		c.urlCache = nil
		c.requestCachePolicy = .reloadIgnoringLocalCacheData
		return URLSession(configuration: c)
	}()

	private static var serveSpawnCount: UInt64 = 0
	private static var tagsSettleDoneForSpawn: UInt64 = 0
	private static let postServeProbeSettleSeconds: TimeInterval = 1.35

	private static let startupGraceSeconds: TimeInterval = 5.5
	private static let availabilityCacheTTL: TimeInterval = 6.0
	private static let tagsTimeoutQuick: TimeInterval = 2.0
	private static let tagsTimeoutProbe: TimeInterval = 4.0
	private static let minimumDiskBytesForModelPull: Int64 = 8 * 1_073_741_824
	private static let pullCommandTimeoutSeconds: TimeInterval = 45 * 60

	private static var appLaunchTime: Date?
	private static let launchLock = NSLock()

	private let availabilityLock = NSLock()
	private var cachedGenerationAvailable: (value: Bool, at: Date)?
	private var inFlightGenerationTask: Task<Bool, Never>?

	private static var lastStartRequestAt: Date?
	private static let startRequestCooldown: TimeInterval = 8.0

	private static var dedupeLogAt: [String: Date] = [:]
	private static let dedupeLogWindow: TimeInterval = 2.5

	private init() {}

	/// Call once from `AppDelegate.applicationDidFinishLaunching` so startup grace aligns with real launch.
	func noteAppLaunch() {
		Self.launchLock.lock()
		defer { Self.launchLock.unlock() }
		if Self.appLaunchTime == nil {
			Self.appLaunchTime = Date()
		}
	}

	/// Exposed for LLM proposal diagnostics (T18.3.3B); does not affect availability checks.
	func isWithinStartupGrace() -> Bool {
		Self.withinStartupGrace()
	}

	private static func withinStartupGrace() -> Bool {
		Self.launchLock.lock()
		let t = Self.appLaunchTime
		Self.launchLock.unlock()
		guard let t else { return false }
		return Date().timeIntervalSince(t) < Self.startupGraceSeconds
	}

	private static func dedupedPrint(_ key: String, _ line: String) {
		let now = Date()
		if let last = dedupeLogAt[key], now.timeIntervalSince(last) < dedupeLogWindow { return }
		dedupeLogAt[key] = now
		dedupeLogAt = dedupeLogAt.filter { now.timeIntervalSince($0.value) < 30 }
		print(line)
	}

	/// Returns whether the `ollama` CLI is on `PATH` (Homebrew / common locations included).
	func isRuntimeAvailable() -> Bool {
		detectOllamaInstalled()
	}

	func detectOllamaInstalled() -> Bool {
		Self.resolveOllamaExecutablePath() != nil
	}

	func detectOllamaServerRunning() async -> Bool {
		await Self.detectOllamaServerRunningImpl()
	}

	/// Starts `ollama serve` as a detached child process if the API is not already reachable.
	func startOllamaServer() async throws {
		try await Self.startOllamaServeIfNeeded()
	}

	private static func startOllamaServeIfNeeded() async throws {
		if await Self.detectOllamaServerRunningImpl() { return }
		let now = Date()
		if let last = lastStartRequestAt, now.timeIntervalSince(last) < startRequestCooldown {
			dedupedPrint("start_skip", "[ModelManager] start_skipped reason=cooldown")
			return
		}
		lastStartRequestAt = now
		dedupedPrint("start_req", "[ModelManager] start_requested")
		try Self.spawnOllamaServeProcess()
	}

	private static func consumeTagsSettleAfterServeSpawnIfNeeded() async {
		guard tagsSettleDoneForSpawn < serveSpawnCount else { return }
		tagsSettleDoneForSpawn = serveSpawnCount
		let wait = postServeProbeSettleSeconds
		dedupedPrint("probe_settle", "[ModelManager] status=starting detail=tags_wait_s=\(String(format: "%.2f", wait))")
		try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
	}

	/// Verifies the configured model via HTTP `/api/tags` when reachable; pulls only when allowed (legacy helper).
	func ensureModelAvailable() async {
		guard LocalAISettings.shared.localAIEnabled else { return }
		let name = LocalAISettings.shared.modelName

		switch await Self.fetchTagsViaHTTP(timeout: Self.tagsTimeoutProbe) {
		case .unreachable:
			return
		case .reachable(let names):
			if Self.tagsListContainsModel(names, modelName: name) {
				return
			}
			_ = await Self.pullModelOnly(modelName: name)
		}
	}

	/// - Parameter allowModelPull: Startup probes should pass `false` to avoid blocking UI / disk on pull storms.
	func prepareLocalAIIfEnabled(
		settings: LocalAISettings,
		allowModelPull: Bool = false,
		updateState: @escaping (ModelRuntimeState) -> Void
	) async {
		guard settings.localAIEnabled else { return }

		await MainActor.run {
			updateState(.checking)
		}
		Self.dedupedPrint("status_checking", "[ModelManager] status=checking")

		guard Self.resolveOllamaExecutablePath() != nil else {
			await MainActor.run {
				updateState(.notInstalled)
			}
			return
		}

		let modelName = settings.modelName
		var tagsResult = await Self.fetchTagsViaHTTP(timeout: Self.tagsTimeoutProbe)

		if case .unreachable = tagsResult {
			if settings.autoStartOllama {
				await MainActor.run {
					updateState(.starting)
				}
				Self.dedupedPrint("status_starting", "[ModelManager] status=starting")
				do {
					try await Self.startOllamaServeIfNeeded()
				} catch {
					await MainActor.run {
						updateState(.unavailable)
					}
					Self.dedupedPrint("status_unavail_start", "[ModelManager] status=unavailable reason=start_failed")
					return
				}
				tagsResult = await Self.fetchTagsViaHTTP(timeout: Self.tagsTimeoutProbe)
				if case .unreachable = tagsResult {
					await MainActor.run {
						updateState(.unavailable)
					}
					Self.dedupedPrint("status_unavail_srv", "[ModelManager] status=unavailable reason=server_unreachable")
					return
				}
			} else {
				await MainActor.run {
					updateState(.unavailable)
				}
				Self.dedupedPrint("status_unavail_off", "[ModelManager] status=unavailable reason=server_unreachable")
				return
			}
		}

		guard case .reachable(let names) = tagsResult else {
			return
		}

		if Self.tagsListContainsModel(names, modelName: modelName) {
			await MainActor.run {
				updateState(.ready)
			}
			Self.dedupedPrint("status_ready", "[ModelManager] status=ready model=\(modelName)")
			Self.invalidateGenerationCache()
			return
		}

		Self.dedupedPrint("status_model_miss", "[ModelManager] status=model_missing model=\(modelName)")

		guard allowModelPull else {
			await MainActor.run {
				updateState(.modelMissing(model: modelName))
			}
			return
		}

		await MainActor.run {
			updateState(.installing)
		}

		let outcome = await Self.pullModelOnly(modelName: modelName)

		switch outcome {
		case .ok:
			await MainActor.run {
				updateState(.ready)
			}
			Self.dedupedPrint("pull_done", "[ModelManager] pull_completed model=\(modelName)")
			Self.invalidateGenerationCache()
		case .failed(let message):
			await MainActor.run {
				updateState(.error(message))
			}
		}
	}

	/// Pull a specific model by name. Used by `ModelAuditManager` to install fast inference
	/// models (e.g. qwen2.5:0.5b) when no suitable small model is found.
	/// Returns `true` on success, `false` on failure (disk, network, CLI missing).
	func pullModel(named modelName: String) async -> Bool {
		guard Self.resolveOllamaExecutablePath() != nil else {
			print("[ModelManager] pull_blocked model=\(modelName) reason=ollama_not_installed")
			return false
		}
		if let bytes = Self.availableDiskBytesForImportantUsage(), bytes < Self.minimumDiskBytesForModelPull {
			let gb = Double(bytes) / 1_073_741_824.0
			print("[ModelManager] pull_blocked model=\(modelName) reason=low_disk available=\(String(format: "%.1fGB", gb))")
			return false
		}
		print("[ModelManager] pull_started model=\(modelName)")
		let outcome = await Self.pullModelOnly(modelName: modelName)
		switch outcome {
		case .ok:
			print("[ModelManager] pull_completed model=\(modelName)")
			Self.invalidateGenerationCache()
			return true
		case .failed(let msg):
			print("[ModelManager] pull_failed model=\(modelName) reason=\(String(msg.prefix(120)))")
			return false
		}
	}

	/// Check whether a model with the given name is currently installed in Ollama.
	func isModelInstalled(named modelName: String) async -> Bool {
		switch await Self.fetchTagsViaHTTP(timeout: Self.tagsTimeoutProbe) {
		case .unreachable: return false
		case .reachable(let names): return Self.tagsListContainsModel(names, modelName: modelName)
		}
	}

	/// User-triggered pull when server is expected up (System Status).
	func pullConfiguredModel(
		updateState: @escaping (ModelRuntimeState) -> Void
	) async {
		guard LocalAISettings.shared.localAIEnabled else { return }
		let name = LocalAISettings.shared.modelName
		Self.dedupedPrint("pull_req", "[ModelManager] pull_requested model=\(name)")

		guard Self.resolveOllamaExecutablePath() != nil else {
			await MainActor.run { updateState(.notInstalled) }
			return
		}

		switch await Self.fetchTagsViaHTTP(timeout: Self.tagsTimeoutProbe) {
		case .unreachable:
			await MainActor.run { updateState(.unavailable) }
			Self.dedupedPrint("pull_skip_net", "[ModelManager] status=unavailable reason=server_unreachable")
			return
		case .reachable(let names):
			if Self.tagsListContainsModel(names, modelName: name) {
				await MainActor.run { updateState(.ready) }
				Self.dedupedPrint("pull_skip_have", "[ModelManager] status=ready model=\(name)")
				Self.invalidateGenerationCache()
				return
			}
		}

		await MainActor.run {
			updateState(.installing)
		}

		let outcome = await Self.pullModelOnly(modelName: name)
		switch outcome {
		case .ok:
			await MainActor.run {
				updateState(.ready)
			}
			Self.dedupedPrint("pull_done_user", "[ModelManager] pull_completed model=\(name)")
			Self.invalidateGenerationCache()
		case .failed(let message):
			await MainActor.run {
				updateState(.error(message))
			}
		}
	}

	func isGenerationAvailable() async -> Bool {
		guard LocalAISettings.shared.localAIEnabled else {
			return false
		}

		if Self.withinStartupGrace() {
			Self.dedupedPrint("grace", "[ModelManager] check_cached status=startup_grace")
			return false
		}

		return await coalescedGenerationAvailable()
	}

	private func coalescedGenerationAvailable() async -> Bool {
		let model = LocalAISettings.shared.modelName

		availabilityLock.lock()
		if let c = cachedGenerationAvailable, Date().timeIntervalSince(c.at) < Self.availabilityCacheTTL {
			availabilityLock.unlock()
			Self.dedupedPrint("cache", "[ModelManager] check_cached status=\(c.value ? "ready" : "unavailable")")
			return c.value
		}

		if let inflight = inFlightGenerationTask {
			availabilityLock.unlock()
			Self.dedupedPrint("coal", "[ModelManager] check_coalesced")
			return await inflight.value
		}

		let task = Task<Bool, Never> {
			let r = await Self.computeGenerationAvailable(modelName: model)
			self.availabilityLock.lock()
			self.cachedGenerationAvailable = (r, Date())
			self.inFlightGenerationTask = nil
			self.availabilityLock.unlock()
			if r {
				Self.dedupedPrint("gen_ready", "[ModelManager] status=ready model=\(model)")
			} else {
				Self.dedupedPrint("gen_no", "[ModelManager] status=unavailable reason=generation_gate")
			}
			return r
		}
		inFlightGenerationTask = task
		availabilityLock.unlock()
		return await task.value
	}

	private static func computeGenerationAvailable(modelName: String) async -> Bool {
		switch await Self.fetchTagsViaHTTP(timeout: Self.tagsTimeoutQuick) {
		case .unreachable:
			return false
		case .reachable(let names):
			// Primary: accept if the configured model (phi3/planner) is installed.
			// Fallback: accept if the required task inference model is installed.
			// This prevents task inference from being blocked when the user has qwen2.5:0.5b
			// installed but not phi3 — the task inference model check is handled by
			// ModelAuditManager / ActiveModelTierConfig, not this gate.
			// Any installed model means Ollama is functional; the model-specific check
			// is done downstream via ActiveModelTierConfig.taskInferenceModel.
			if Self.tagsListContainsModel(names, modelName: modelName) { return true }
			return !names.isEmpty
		}
	}

	private static func invalidateGenerationCache() {
		ModelManager.shared.availabilityLock.lock()
		ModelManager.shared.cachedGenerationAvailable = nil
		ModelManager.shared.availabilityLock.unlock()
	}

	// MARK: - Model availability

	private enum ModelAvailabilityOutcome {
		case ok
		case failed(String)
	}

	private enum HTTPFetchTagsResult {
		case unreachable
		case reachable(names: [String])
	}

	private static func fetchTagsViaHTTP(timeout: TimeInterval) async -> HTTPFetchTagsResult {
		await consumeTagsSettleAfterServeSpawnIfNeeded()
		return await Task.detached(priority: .utility) {
			guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else {
				return HTTPFetchTagsResult.unreachable
			}
			var request = URLRequest(url: url)
			request.httpMethod = "GET"
			request.timeoutInterval = timeout
			do {
				let (data, response) = try await tagsURLSession.data(for: request)
				guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
					return .unreachable
				}
				let names = Self.parseTagsJSONModelNames(data)
				return .reachable(names: names)
			} catch {
				// No NSError / URL dump — T12.10; set DEBUG_VERBOSE_LOCAL_AI=1 in environment for diagnosis.
				if ProcessInfo.processInfo.environment["DEBUG_VERBOSE_LOCAL_AI"] == "1" {
					print("[ModelManager] tags_probe_failed (verbose only)")
				}
				return .unreachable
			}
		}.value
	}

	private static func parseTagsJSONModelNames(_ data: Data) -> [String] {
		struct TagsRoot: Codable {
			let models: [TagEntry]
		}
		struct TagEntry: Codable {
			let name: String
		}
		if let root = try? JSONDecoder().decode(TagsRoot.self, from: data) {
			return root.models.map(\.name)
		}
		return []
	}

	private static func tagsListContainsModel(_ names: [String], modelName: String) -> Bool {
		let needle = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !needle.isEmpty else { return false }
		let needleLower = needle.lowercased()
		for n in names {
			if n == needle { return true }
			if n.lowercased().hasPrefix("\(needleLower):") { return true }
		}
		return false
	}

	private static func pullModelOnly(modelName: String) async -> ModelAvailabilityOutcome {
		guard let ollamaPath = Self.resolveOllamaExecutablePath() else {
			return .failed("Ollama executable not found")
		}

		if let bytes = Self.availableDiskBytesForImportantUsage(), bytes < Self.minimumDiskBytesForModelPull {
			let gb = Double(bytes) / 1_073_741_824.0
			let label = String(format: "%.1fGB", gb)
			Self.dedupedPrint("disk", "[ModelManager] pull_blocked reason=low_disk available=\(label)")
			return .failed("Insufficient disk space to pull model")
		}

		let pullOutcome = await Self.runOllama(
			binary: ollamaPath,
			arguments: ["pull", modelName],
			timeoutSeconds: Self.pullCommandTimeoutSeconds
		)
		Self.logStdioMetadata(label: "ollama pull \(modelName)", outcome: pullOutcome)

		switch pullOutcome {
		case .completed(let code, _, let stderr):
			if code == 0 {
				return .ok
			}
			let detail = Self.compactErrorDetail(exitCode: code, stderr: stderr)
			return .failed(detail)
		case .timedOut:
			return .failed("Model pull timed out")
		case .launchFailed(let error):
			return .failed(error.localizedDescription)
		}
	}

	private static func availableDiskBytesForImportantUsage() -> Int64? {
		let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
		let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
		guard let values = try? home.resourceValues(forKeys: keys) else { return nil }
		return values.volumeAvailableCapacityForImportantUsage
	}

	private static func detectOllamaServerRunningImpl() async -> Bool {
		switch await Self.fetchTagsViaHTTP(timeout: Self.tagsTimeoutProbe) {
		case .reachable:
			return true
		case .unreachable:
			return false
		}
	}

	private static func spawnOllamaServeProcess() throws {
		guard let binary = Self.resolveOllamaExecutablePath() else {
			throw NSError(domain: "ModelManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ollama is not installed"])
		}

		let task = Process()
		task.executableURL = URL(fileURLWithPath: binary)
		task.arguments = ["serve"]
		task.environment = Self.augmentedEnvironment()

		let stdoutPipe = Pipe()
		let stderrPipe = Pipe()
		task.standardOutput = stdoutPipe
		task.standardError = stderrPipe

		try task.run()
		Self.serveSpawnCount &+= 1
		Self.serveProcess = task

		let outHandle = stdoutPipe.fileHandleForReading
		let errHandle = stderrPipe.fileHandleForReading
		Self.serveDrainQueue.async {
			_ = outHandle.readDataToEndOfFile()
			_ = errHandle.readDataToEndOfFile()
		}
	}

	private enum RunOutcome {
		case completed(exitCode: Int32, stdout: Data, stderr: Data)
		case timedOut
		case launchFailed(Error)
	}

	private static func augmentedEnvironment() -> [String: String] {
		var env = ProcessInfo.processInfo.environment
		let prefix = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
		if let path = env["PATH"], !path.isEmpty {
			env["PATH"] = prefix + ":" + path
		} else {
			env["PATH"] = prefix
		}
		return env
	}

	private static func resolveOllamaExecutablePath() -> String? {
		let task = Process()
		task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
		task.arguments = ["ollama"]
		task.environment = augmentedEnvironment()

		let out = Pipe()
		task.standardOutput = out
		task.standardError = Pipe()

		do {
			try task.run()
			task.waitUntilExit()
		} catch {
			return nil
		}

		guard task.terminationStatus == 0 else { return nil }
		let data = out.fileHandleForReading.readDataToEndOfFile()
		let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		guard !raw.isEmpty, FileManager.default.isExecutableFile(atPath: raw) else { return nil }
		return raw
	}

	private static func runOllama(binary: String, arguments: [String], timeoutSeconds: TimeInterval) async -> RunOutcome {
		await Task.detached(priority: .utility) {
			let task = Process()
			task.executableURL = URL(fileURLWithPath: binary)
			task.arguments = arguments
			task.environment = Self.augmentedEnvironment()

			let stdoutPipe = Pipe()
			let stderrPipe = Pipe()
			task.standardOutput = stdoutPipe
			task.standardError = stderrPipe

			do {
				try task.run()
			} catch {
				return .launchFailed(error)
			}

			let sem = DispatchSemaphore(value: 0)
			DispatchQueue.global(qos: .utility).async {
				task.waitUntilExit()
				sem.signal()
			}

			let deadline = DispatchTime.now() + timeoutSeconds
			if sem.wait(timeout: deadline) == .timedOut {
				task.terminate()
				task.waitUntilExit()
				return .timedOut
			}

			let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
			let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
			return .completed(exitCode: task.terminationStatus, stdout: stdoutData, stderr: stderrData)
		}.value
	}

	private static func logStdioMetadata(label: String, outcome: RunOutcome) {
		switch outcome {
		case .completed(let exitCode, let stdout, let stderr):
			Self.dedupedPrint("stdio_done", "[ModelManager] \(label) exit=\(exitCode) stdoutBytes=\(stdout.count) stderrBytes=\(stderr.count)")
		case .timedOut:
			Self.dedupedPrint("stdio_to", "[ModelManager] \(label) timed out before completion")
		case .launchFailed:
			Self.dedupedPrint("stdio_lf", "[ModelManager] \(label) launch_failed reason=process")
		}
	}

	private static func compactErrorDetail(exitCode: Int32, stderr: Data) -> String {
		var parts: [String] = ["exit \(exitCode)"]
		let cap = 160
		if !stderr.isEmpty, let snippet = String(data: stderr.prefix(cap), encoding: .utf8) {
			let cleaned = snippet
				.trimmingCharacters(in: .whitespacesAndNewlines)
				.replacingOccurrences(of: "\n", with: " ")
			if !cleaned.isEmpty {
				let ellipsis = stderr.count > cap ? "…" : ""
				parts.append("stderr: \(cleaned)\(ellipsis)")
			}
		} else if stderr.isEmpty {
			parts.append("stderr: empty")
		}
		return parts.joined(separator: ", ")
	}
}
