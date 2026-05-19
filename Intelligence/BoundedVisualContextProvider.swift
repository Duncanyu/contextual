import Foundation

/// Collects bounded visual context for explicit execution requests only.
protocol BoundedVisualContextProvider: Sendable {
	func collectVisualContext(request: BoundedVisualContextRequest) async throws -> BoundedVisualContextResult
}

/// Default safe provider — no capture, no OCR, no screen access.
struct NullBoundedVisualContextProvider: BoundedVisualContextProvider, Sendable {
	func collectVisualContext(request: BoundedVisualContextRequest) async throws -> BoundedVisualContextResult {
		BoundedVisualContextDebug.log(event: "provider_unavailable", requestId: request.id)
		return .unavailable(requestId: request.id, detail: "null_provider")
	}
}
