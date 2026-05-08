import Foundation

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

	private init() {
		let config = URLSessionConfiguration.ephemeral
		config.timeoutIntervalForRequest = 120
		config.timeoutIntervalForResource = 180
		session = URLSession(configuration: config)
	}

	func generate(prompt: String, model: String) async throws -> String {
		let inputLength = prompt.utf8.count
		print("[LocalAI] generate_started model=\(model) inputBytes=\(inputLength)")
		do {
			guard let url = URL(string: "http://127.0.0.1:11434/api/generate") else {
				throw LocalAIClientError.invalidURL
			}
			var request = URLRequest(url: url)
			request.httpMethod = "POST"
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")

			let payload = OllamaGenerateRequest(model: model, prompt: prompt, stream: false)
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
			print("[LocalAI] generate_done model=\(model) outputBytes=\(outLen)")
			return text
		} catch {
			print("[LocalAI] generate_failed model=\(model)")
			throw error
		}
	}

	private struct OllamaGenerateRequest: Encodable {
		let model: String
		let prompt: String
		let stream: Bool
	}

	private struct OllamaGenerateResponse: Decodable {
		let response: String?
		let error: String?
	}
}
