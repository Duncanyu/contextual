import Foundation

/// Prepares local model runtime availability; inference is not implemented yet (see `generate`).
final class ModelManager: @unchecked Sendable {
	static let shared = ModelManager()

	private let primaryModelName = "phi3"

	private init() {}

	/// Returns whether the `ollama` CLI is on `PATH` (Homebrew / common locations included).
	func isRuntimeAvailable() -> Bool {
		Self.resolveOllamaExecutablePath() != nil
	}

	/// Verifies `phi3` is listed by `ollama list`; if not, runs `ollama pull phi3`. Work runs off the caller’s cooperative pool — call from a background task.
	func ensureModelAvailable() async {
		guard isRuntimeAvailable() else { return }

		print("[ModelManager] Ensuring model availability...")

		let alreadyPresent = await Self.isPhi3Listed()
		if alreadyPresent {
			print("[ModelManager] Model \(primaryModelName) already available")
			return
		}

		await Self.runOllamaPullPhi3()
	}

	/// Future hook for real inference; does not persist prompts or outputs.
	func generate(prompt: String) async -> String {
		_ = prompt
		return "MODEL_OUTPUT_PLACEHOLDER"
	}

	// MARK: - Subprocess helpers (no inference)

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

	private static func isPhi3Listed() async -> Bool {
		await Task.detached(priority: .utility) {
			guard let ollama = resolveOllamaExecutablePath() else { return false }

			let task = Process()
			task.executableURL = URL(fileURLWithPath: ollama)
			task.arguments = ["list"]
			task.environment = augmentedEnvironment()

			let out = Pipe()
			task.standardOutput = out
			task.standardError = Pipe()

			do {
				try task.run()
				task.waitUntilExit()
			} catch {
				return false
			}

			let data = out.fileHandleForReading.readDataToEndOfFile()
			let text = String(data: data, encoding: .utf8) ?? ""
			return text.range(of: "phi3", options: .caseInsensitive) != nil
		}.value
	}

	private static func runOllamaPullPhi3() async {
		await Task.detached(priority: .utility) {
			guard let ollama = resolveOllamaExecutablePath() else { return }

			let task = Process()
			task.executableURL = URL(fileURLWithPath: ollama)
			task.arguments = ["pull", "phi3"]
			task.environment = augmentedEnvironment()

			task.standardOutput = Pipe()
			task.standardError = Pipe()

			do {
				try task.run()
				task.waitUntilExit()
			} catch {
				return
			}
		}.value
	}
}
