import Foundation
import os.lock

enum LocalAIClientError: Error, LocalizedError {
	case invalidURL
	case badStatusCode(Int)
	case emptyResponse
	case serverMessage(String)
	case decodingFailed

	var errorDescription: String? {
		switch self {
		case .invalidURL:
			return "Invalid generate URL"
		case .badStatusCode(let code):
			return "HTTP \(code)"
		case .emptyResponse:
			return "Empty model response"
		case .serverMessage(let message):
			return message
		case .decodingFailed:
			return "Could not read model response"
		}
	}
}

final class LocalAIClient: @unchecked Sendable {
	static let shared = LocalAIClient()

	private let session: URLSession

	/// Tracks the number of concurrent Ollama HTTP requests in flight (across all purposes).
	/// Concurrent requests compete for Ollama's inference queue even with OLLAMA_NUM_PARALLEL=1,
	/// causing stalled requests and apparent timeouts. Logged as [LocalAIConcurrency].
	nonisolated(unsafe) private static var activeRequestCount: Int = 0
	nonisolated(unsafe) private static var concurrencyLock = os_unfair_lock()

	private static func incrementActive(purpose: String?) -> Int {
		withUnsafeMutablePointer(to: &concurrencyLock) { os_unfair_lock_lock($0) }
		activeRequestCount += 1
		let count = activeRequestCount
		withUnsafeMutablePointer(to: &concurrencyLock) { os_unfair_lock_unlock($0) }
		let p = purpose ?? "nil"
		print("[LocalAIConcurrency] started purpose=\(p) active_requests=\(count)")
		return count
	}

	private static func decrementActive(purpose: String?) {
		withUnsafeMutablePointer(to: &concurrencyLock) { os_unfair_lock_lock($0) }
		activeRequestCount = max(0, activeRequestCount - 1)
		let count = activeRequestCount
		withUnsafeMutablePointer(to: &concurrencyLock) { os_unfair_lock_unlock($0) }
		let p = purpose ?? "nil"
		print("[LocalAIConcurrency] completed purpose=\(p) active_requests=\(count)")
	}

	private init() {
		let config = URLSessionConfiguration.ephemeral
		config.timeoutIntervalForRequest = 120
		config.timeoutIntervalForResource = 180
		session = URLSession(configuration: config)
	}

	func generate(prompt: String, model: String) async throws -> String {
		try await generate(
			prompt: prompt,
			model: model,
			numPredict: 220,
			temperature: 0.15,
			purpose: nil
		)
	}

	/// Variant for fast, bounded calls (e.g. task inference). Default `generate(prompt:model:)`
	/// remains the canonical path for longer completions.
	func generate(
		prompt: String,
		model: String,
		numPredict: Int,
		temperature: Double,
		purpose: String?,
		schema: [String: Any]? = nil
	) async throws -> String {
		let isTwoStage = LocalAISettings.shared.twoStageTaskInferenceEnabled
		let lanePurpose: String? = {
			if !isTwoStage { return nil }
			if purpose == "two_stage_router" { return "router" }
			if purpose == "two_stage_planner" { return "planner" }
			if purpose == "warmup" { return "keepalive" }
			return nil
		}()

		if let lp = lanePurpose {
			let acquired = await TwoStageLaneManager.shared.acquire(purpose: lp)
			if !acquired {
				throw LocalAIClientError.emptyResponse
			}
		}

		let startTime = Date()
		Self.incrementActive(purpose: purpose)
		defer {
			Self.decrementActive(purpose: purpose)
			if let lp = lanePurpose {
				let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
				Task {
					await TwoStageLaneManager.shared.release(purpose: lp, elapsedMs: elapsed)
				}
			}
		}

		let inputLength = prompt.utf8.count
		let purposePart = (purpose?.isEmpty == false) ? " purpose=\(purpose!)" : ""
		print("[LocalAI] generate_started model=\(model)\(purposePart) inputBytes=\(inputLength)")
		do {
			guard let url = URL(string: "http://127.0.0.1:11434/api/generate") else {
				throw LocalAIClientError.invalidURL
			}
			var request = URLRequest(url: url)
			request.httpMethod = "POST"
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")

			// keep_alive: keep model warm in Ollama for 10 min (or 5 min for two-stage) after each inference.
			let keepAlive: String? = {
				if isTwoStage {
					if purpose == "two_stage_router" || purpose == "two_stage_planner" || purpose == "warmup" {
						return "5m"
					}
				}
				return (purpose == "task_inference" || purpose == "warmup" || purpose == "model_audit") ? "10m" : nil
			}()
			let payload = OllamaGenerateRequest(
				model: model,
				prompt: prompt,
				stream: false,
				options: OllamaGenerateOptions(numPredict: numPredict, temperature: temperature),
				keepAlive: keepAlive,
				format: schema.map { AnyCodableValue(value: $0) }
			)
			request.httpBody = try JSONEncoder().encode(payload)

			let (data, response) = try await session.data(for: request)
			guard let http = response as? HTTPURLResponse else {
				throw LocalAIClientError.badStatusCode(-1)
			}
			guard http.statusCode == 200 else {
				throw LocalAIClientError.badStatusCode(http.statusCode)
			}

			let decoded = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
			if let err = decoded.error, !err.isEmpty {
				throw LocalAIClientError.serverMessage(err)
			}
			guard let text = decoded.response?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
				throw LocalAIClientError.emptyResponse
			}
			let outLen = text.utf8.count
			print("[LocalAI] generate_done model=\(model)\(purposePart) outputBytes=\(outLen)")
			#if DEBUG
			if ProcessInfo.processInfo.environment["CONTEXTUAL_DEBUG_LLM_OUTPUT"] == "1" {
				let preview = String(text.prefix(300))
				print("[LocalAI] debug_raw_output model=\(model) preview=\(preview)")
			}
			#endif
			return text
		} catch {
			print("[LocalAI] generate_failed model=\(model)\(purposePart)")
			throw error
		}
	}

	// MARK: - Streaming JSON generation (Part E — Early termination)
	//
	// Streams NDJSON from Ollama's `stream:true` endpoint and returns as soon as a
	// complete balanced `{...}` JSON object is detected in the accumulated response.
	// This avoids waiting for trailing prose or markdown that models sometimes emit
	// after the JSON object.
	//
	// Returns `nil` if streaming fails so callers can fall back to batch mode.

	func generateStreamingJSON(
		prompt: String,
		model: String,
		numPredict: Int,
		temperature: Double,
		purpose: String?,
		schema: [String: Any]? = nil
	) async throws -> String {
		let isTwoStage = LocalAISettings.shared.twoStageTaskInferenceEnabled
		let lanePurpose: String? = {
			if !isTwoStage { return nil }
			if purpose == "two_stage_router" { return "router" }
			if purpose == "two_stage_planner" { return "planner" }
			if purpose == "warmup" { return "keepalive" }
			return nil
		}()

		if let lp = lanePurpose {
			let acquired = await TwoStageLaneManager.shared.acquire(purpose: lp)
			if !acquired {
				throw LocalAIClientError.emptyResponse
			}
		}

		let startTime = Date()
		Self.incrementActive(purpose: purpose)
		defer {
			Self.decrementActive(purpose: purpose)
			if let lp = lanePurpose {
				let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
				Task {
					await TwoStageLaneManager.shared.release(purpose: lp, elapsedMs: elapsed)
				}
			}
		}

		guard let url = URL(string: "http://127.0.0.1:11434/api/generate") else {
			throw LocalAIClientError.invalidURL
		}
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")

		let keepAlive = isTwoStage ? "5m" : "10m"
		let payload = OllamaGenerateRequest(
			model: model,
			prompt: prompt,
			stream: true,
			options: OllamaGenerateOptions(numPredict: numPredict, temperature: temperature),
			keepAlive: keepAlive,
			format: schema.map { AnyCodableValue(value: $0) }
		)
		request.httpBody = try JSONEncoder().encode(payload)

		// Whether to emit detailed per-phase timing under [TwoStageRouterTiming] / [StructuredOutput] planner.
		let isRouter = purpose == "task_inference_router"
		let isPlanner = purpose == "task_inference_planner"
		let purposePart = purpose.map { " purpose=\($0)" } ?? ""
		let requestStart = Date()

		if isRouter {
			// Log sanitized request structure so we can verify model, options, keep_alive in logs.
			print("[TwoStageRouterRequest] model=\(model) stream=true num_predict=\(numPredict) temperature=\(temperature) keep_alive=\(keepAlive)")
			print("[TwoStageRouterTiming] phase=request_started model=\(model) bytes=\(prompt.utf8.count)")
		} else {
			print("[LocalAI] streaming_started model=\(model)\(purposePart) inputBytes=\(prompt.utf8.count)")
		}

		let (asyncBytes, response) = try await session.bytes(for: request)
		guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
			let code = (response as? HTTPURLResponse)?.statusCode ?? -1
			print("[LocalAI] streaming_http_error model=\(model) status=\(code)")
			throw LocalAIClientError.badStatusCode(code)
		}

		var accumulated = ""
		var firstByteLogged = false
		do {
			for try await line in asyncBytes.lines {
				guard !line.isEmpty else { continue }
				guard let lineData = line.data(using: .utf8) else { continue }
				if !firstByteLogged {
					firstByteLogged = true
					let ms = Int(Date().timeIntervalSince(requestStart) * 1000)
					if isRouter {
						print("[TwoStageRouterTiming] phase=first_token elapsed_ms=\(ms)")
					} else {
						print("[LocalAI] streaming_first_byte model=\(model)\(purposePart) elapsed_ms=\(ms)")
					}
				}
				guard let chunk = try? JSONDecoder().decode(OllamaStreamChunk.self, from: lineData) else { continue }
				if let token = chunk.response { accumulated += token }
				// Stop as soon as we have a complete JSON object.
				if hasCompletedJSONObject(accumulated) {
					let ms = Int(Date().timeIntervalSince(requestStart) * 1000)
					if isRouter {
						print("[TwoStageRouterTiming] phase=json_detected elapsed_ms=\(ms) bytes=\(accumulated.utf8.count)")
						print("[TwoStageRouter] early_stop_stream=yes elapsed_ms=\(ms)")
					} else {
						print("[LocalAI] streaming_early_stop model=\(model)\(purposePart) outputBytes=\(accumulated.utf8.count) elapsed_ms=\(ms)")
					}
					return accumulated
				}
				if chunk.done == true { break }
			}
		} catch {
			// Catch CancellationError (external timeout fired) or URLError so we can log
			// the partial output accumulated before cancellation — critical for diagnosing
			// whether the timeout is due to: (a) no tokens at all, (b) partial JSON that
			// never closed, or (c) prose output before JSON.
			let ms = Int(Date().timeIntervalSince(requestStart) * 1000)
			if isRouter {
				let preview = accumulated.prefix(300).replacingOccurrences(of: "\n", with: "↵")
				if accumulated.isEmpty {
					print("[TwoStageRouterTiming] phase=timeout elapsed_ms=\(ms)")
					print("[TwoStageRouter] timeout_partial raw=\"\" chars=0 note=no_tokens_produced")
				} else {
					print("[TwoStageRouterTiming] phase=timeout elapsed_ms=\(ms)")
					print("[TwoStageRouter] timeout_partial raw=\"\(preview)\" chars=\(accumulated.count)")
				}
			} else if isPlanner {
				let preview = String(accumulated.prefix(300)).replacingOccurrences(of: "\n", with: "↵")
				print("[StructuredOutput] planner timeout elapsed_ms=\(ms) partial_chars=\(accumulated.count)")
				if !accumulated.isEmpty {
					print("[StructuredOutput] planner timeout_partial raw=\"\(preview)\"")
				}
			}
			throw error
		}

		if accumulated.isEmpty {
			let ms = Int(Date().timeIntervalSince(requestStart) * 1000)
			print("[LocalAI] streaming_empty_response model=\(model)\(purposePart) first_byte=\(firstByteLogged ? "yes" : "no") elapsed_ms=\(ms)")
			throw LocalAIClientError.emptyResponse
		}
		let ms = Int(Date().timeIntervalSince(requestStart) * 1000)
		if isRouter {
			print("[TwoStageRouterTiming] phase=request_completed elapsed_ms=\(ms) bytes=\(accumulated.utf8.count)")
		} else {
			print("[LocalAI] streaming_done model=\(model)\(purposePart) outputBytes=\(accumulated.utf8.count) elapsed_ms=\(ms)")
		}
		return accumulated
	}

	/// Returns true when `s` contains at least one complete, balanced `{...}` JSON object.
	private func hasCompletedJSONObject(_ s: String) -> Bool {
		var depth = 0
		var inString = false
		var escape = false
		for ch in s {
			if escape { escape = false; continue }
			if ch == "\\" && inString { escape = true; continue }
			if ch == "\"" { inString.toggle(); continue }
			if inString { continue }
			if ch == "{" { depth += 1 }
			if ch == "}" {
				guard depth > 0 else { continue }
				depth -= 1
				if depth == 0 { return true }
			}
		}
		return false
	}

	private struct OllamaStreamChunk: Decodable {
		let response: String?
		let done: Bool?
		let error: String?
	}

	// MARK: - Structs

	private struct OllamaGenerateRequest: Encodable {
		let model: String
		let prompt: String
		let stream: Bool
		let options: OllamaGenerateOptions?
		/// Ask Ollama to keep the model loaded in memory after this request.
		/// "-1" = keep indefinitely; "10m" = 10 minutes. Prevents cold-start penalty.
		let keepAlive: String?
		let format: AnyCodableValue?

		enum CodingKeys: String, CodingKey {
			case model, prompt, stream, options
			case keepAlive = "keep_alive"
			case format
		}
	}

	private struct OllamaGenerateOptions: Encodable {
		let numPredict: Int
		let temperature: Double

		enum CodingKeys: String, CodingKey {
			case numPredict = "num_predict"
			case temperature
		}
	}

	private struct OllamaGenerateResponse: Decodable {
		let response: String?
		let error: String?
	}
}

// MARK: - AnyCodableValue for Dynamic JSON schema serialization

struct AnyCodableValue: Encodable {
	let value: Any

	func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		if let string = value as? String {
			try container.encode(string)
		} else if let number = value as? Double {
			try container.encode(number)
		} else if let int = value as? Int {
			try container.encode(int)
		} else if let bool = value as? Bool {
			try container.encode(bool)
		} else if let array = value as? [Any] {
			try container.encode(array.map { AnyCodableValue(value: $0) })
		} else if let dict = value as? [String: Any] {
			try container.encode(dict.mapValues { AnyCodableValue(value: $0) })
		} else {
			throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported value for AnyCodableValue"))
		}
	}
}


