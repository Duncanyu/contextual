import Foundation

/// Stable proposal-time execution anchor for correcting foreground-app drift during execution (Phase 4J).
///
/// Metadata-only: no raw text payloads. Used to preserve intended app/window identity after the
/// user clicks the assistant UI (which makes Contextual frontmost).
struct TargetWindowAnchor: Equatable, Sendable, Codable {
	let bundleIdentifier: String
	let appName: String
	let windowTitle: String
	let contextFingerprint: String
	let createdAt: Date
	let sourceCandidateId: String

	static func fingerprint(bundleIdentifier: String, windowTitle: String, workflow: WorkflowType) -> String {
		let title = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
		let prefix = title.isEmpty ? "none" : String(title.prefix(80))
		return "\(bundleIdentifier)|\(workflow.rawValue)|\(prefix)"
	}
}

