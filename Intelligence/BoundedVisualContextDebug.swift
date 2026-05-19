import Foundation

/// Metadata-only logging for bounded visual context (no OCR text, no image payloads).
enum BoundedVisualContextDebug {
	static func log(event: String, requestId: UUID, detail: String? = nil) {
		var meta = IntelligenceDebugMeta(
			reason: event,
			layer: "bounded_visual_context",
			detail: detail
		)
		meta.action = requestId.uuidString.prefix(8).description
		IntelligenceDebugLogger.log(stage: .execution, event: "visual_\(event)", meta: meta)
	}
}
