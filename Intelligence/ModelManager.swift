import Foundation

/// Prepares local model runtime availability; inference is not implemented yet (see `generate`).
final class ModelManager: @unchecked Sendable {
	static let shared = ModelManager()

	private static var serveProcess: Process?
	private static let serveDrainQueue = DispatchQueue(label: "com.contextual.ollama.serve.drain", qos: .utility)

	private init() {}

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

	/// Starts `ollama serve` as a detached child process if the API is not already reachable. Does not wait for readiness beyond spawn.
	func startOllamaServer() async throws {
		try await Self.startOllamaServeIfNeeded()
	}

	private static func startOllamaServeIfNeeded() async throws {
		if await Self.detectOllamaServerRunningImpl() { return }
		try Self.spawnOllamaServeProcess()
	}

	/// Verifies the configured model via HTTP `/api/tags` when reachable; pulls if missing. Does not call `ollama list` while the server is unreachable.
	func ensureModelAvailable() async {
		guard LocalAISettings.shared.localAIEnabled else { return }
		let name = LocalAISettings.shared.modelName

		switch await Self.fetchTagsViaHTTP() {
		case .unreachable:
			return
		case .reachable(let names):
			if Self.tagsListContainsModel(names, modelName: name) {
				print("[ModelManager] \(name) already available")
				return
			}
			print("[ModelManager] \(name) missing, pulling...")
			_ = await Self.pullModelOnly(modelName: name)
		}
	}

	/// Orchestrates install detection, optional auto-start of the daemon, and model pull. Subprocess work stays off the main actor.
	func prepareLocalAIIfEnabled(
		settings: LocalAISettings,
		updateState: @escaping (ModelRuntimeState) -> Void
	) async {
		guard settings.localAIEnabled else { return }

		guard Self.resolveOllamaExecutablePath() != nil else {
			await MainActor.run {
				updateState(.notInstalled)
			}
			return
		}
		print("[ModelManager] Ollama installed")

		let modelName = settings.modelName
		var tagsResult = await Self.fetchTagsViaHTTP()

		if case .unreachable = tagsResult {
			if settings.autoStartOllama {
				do {
					try await Self.startOllamaServeIfNeeded()
					try await Task.sleep(nanoseconds: 2_000_000_000)
				} catch {
					await MainActor.run {
						updateState(.error(error.localizedDescription))
					}
					return
				}
				tagsResult = await Self.fetchTagsViaHTTP()
				if case .unreachable = tagsResult {
					print("[ModelManager] Ollama server not running")
					await MainActor.run {
						updateState(.error("Ollama server could not be started"))
					}
					return
				}
			} else {
				print("[ModelManager] Ollama server not running")
				await MainActor.run {
					updateState(.notRunning)
				}
				return
			}
		}

		guard case .reachable(let names) = tagsResult else {
			return
		}

		print("[ModelManager] Ollama server running")

		if Self.tagsListContainsModel(names, modelName: modelName) {
			print("[ModelManager] \(modelName) already available")
			await MainActor.run {
				updateState(.ready)
			}
			return
		}

		print("[ModelManager] \(modelName) missing, pulling...")
		await MainActor.run {
			updateState(.installing)
		}

		let outcome = await Self.pullModelOnly(modelName: modelName)

		switch outcome {
		case .ok:
			await MainActor.run {
				updateState(.ready)
			}
		case .failed(let message):
			await MainActor.run {
				updateState(.error(message))
			}
		}
	}

	func isGenerationAvailable() async -> Bool {
		guard LocalAISettings.shared.localAIEnabled else { return false }
		let model = LocalAISettings.shared.modelName
		switch await Self.fetchTagsViaHTTP() {
		case .unreachable:
			return false
		case .reachable(let names):
			return Self.tagsListContainsModel(names, modelName: model)
		}
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

	/// Uses `GET http://127.0.0.1:11434/api/tags` only; returns `.unreachable` if the server does not respond with HTTP 200.
	private static func fetchTagsViaHTTP() async -> HTTPFetchTagsResult {
		await Task.detached(priority: .utility) {
			guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else {
				return HTTPFetchTagsResult.unreachable
			}
			var request = URLRequest(url: url)
			request.httpMethod = "GET"
			request.timeoutInterval = 4
			do {
				let (data, response) = try await URLSession.shared.data(for: request)
				guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
					return .unreachable
				}
				let names = Self.parseTagsJSONModelNames(data)
				return .reachable(names: names)
			} catch {
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

	/// Matches configured model against names from `/api/tags` (e.g. `phi3`, `phi3:latest`).
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

		let pullOutcome = await Self.runOllama(
			binary: ollamaPath,
			arguments: ["pull", modelName],
			timeoutSeconds: Self.pullCommandTimeoutSeconds
		)
		Self.logStdioMetadata(label: "ollama pull \(modelName)", outcome: pullOutcome)

		switch pullOutcome {
		case .completed(let code, _, let stderr):
			if code == 0 {
				print("[ModelManager] \(modelName) pull completed")
				return .ok
			}
			let detail = Self.compactErrorDetail(exitCode: code, stderr: stderr)
			print("[ModelManager] \(modelName) pull failed: \(detail)")
			return .failed(detail)
		case .timedOut:
			print("[ModelManager] \(modelName) pull failed: timed out")
			return .failed("Model pull timed out")
		case .launchFailed(let error):
			print("[ModelManager] \(modelName) pull failed: \(error.localizedDescription)")
			return .failed(error.localizedDescription)
		}
	}

	// MARK: - Server probe

	private static func detectOllamaServerRunningImpl() async -> Bool {
		switch await Self.fetchTagsViaHTTP() {
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
		Self.serveProcess = task

		let outHandle = stdoutPipe.fileHandleForReading
		let errHandle = stderrPipe.fileHandleForReading
		Self.serveDrainQueue.async {
			_ = outHandle.readDataToEndOfFile()
			_ = errHandle.readDataToEndOfFile()
		}
	}

	// MARK: - Subprocess + timeouts (no inference)

	private static let pullCommandTimeoutSeconds: TimeInterval = 45 * 60

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

	/// Runs `ollama` with a wall-clock timeout; never blocks the main thread (caller uses background executor).
	private static func runOllama(binary: String, arguments: [String], timeoutSeconds: TimeInterval) async -> RunOutcome {
		await Task.detached(priority: .utility) {
			let task = Process()
			task.executableURL = URL(fileURLWithPath: binary)
			task.arguments = arguments
			task.environment = augmentedEnvironment()

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
			print("[ModelManager] \(label) exit=\(exitCode) stdoutBytes=\(stdout.count) stderrBytes=\(stderr.count)")
		case .timedOut:
			print("[ModelManager] \(label) timed out before completion")
		case .launchFailed(let error):
			print("[ModelManager] \(label) launch failed: \(error.localizedDescription)")
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
