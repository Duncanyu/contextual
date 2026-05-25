import AppKit
import Foundation

struct ReasoningDecision: Equatable {
	let shouldSurface: Bool
	let primaryActionId: String?
	let rankedActionIds: [String]
	let reason: String
	let confidence: Double
}

final class ReasoningEngine {
	static let shared = ReasoningEngine()
	private init() {}

	func evaluate(context: ContextModel, triggerPacket: TriggerPacket) -> ReasoningDecision {
		let candidates = DynamicOnlyProposalMode.filterGenericStaticActions(triggerPacket.candidateActions)

		if candidates.isEmpty {
			if DynamicOnlyProposalMode.isEnabled {
				return dynamicOnlySurfaceDecision(triggerType: triggerPacket.triggerType, context: context)
			}
			return ReasoningDecision(
				shouldSurface: false,
				primaryActionId: nil,
				rankedActionIds: [],
				reason: "No candidate actions",
				confidence: 0.0
			)
		}

		switch triggerPacket.triggerType {
		case .manualInvocation:
			let preferred = DynamicOnlyProposalMode.isEnabled
				? ["analyze_screen"]
				: ["summarize_text", "explain_text", "rewrite_text"]
			let ranked = rankActions(candidates: candidates, preferredOrder: preferred)
			if DynamicOnlyProposalMode.isEnabled {
				return ReasoningDecision(
					shouldSurface: true,
					primaryActionId: nil,
					rankedActionIds: ranked,
					reason: "Manual invocation (dynamic-only)",
					confidence: 0.55
				)
			}
			return ReasoningDecision(
				shouldSurface: !ranked.isEmpty,
				primaryActionId: ranked.first,
				rankedActionIds: ranked,
				reason: "Manual invocation",
				confidence: 1.0
			)

		case .selectedTextEligible:
			if DynamicOnlyProposalMode.isEnabled {
				return dynamicOnlySurfaceDecision(triggerType: .selectedTextEligible, context: context)
			}
			let ranked = rankActions(candidates: candidates, preferredOrder: ["summarize_text", "explain_text", "rewrite_text"])
			return ReasoningDecision(
				shouldSurface: !ranked.isEmpty,
				primaryActionId: ranked.first,
				rankedActionIds: ranked,
				reason: "Selected text eligible",
				confidence: ranked.isEmpty ? 0.0 : 0.9
			)

		case .clipboardTextEligible:
			if DynamicOnlyProposalMode.isEnabled {
				return dynamicOnlySurfaceDecision(triggerType: .clipboardTextEligible, context: context)
			}
			let looksError = looksErrorLikeClipboard()
			let preferred: [String]
			let reason: String
			let confidence: Double

			if looksError {
				preferred = ["explain_text", "summarize_text", "rewrite_text"]
				reason = "Clipboard looks error-like"
				confidence = 0.85
			} else if context.clipboardTextLength >= 800 {
				preferred = ["summarize_text", "explain_text", "rewrite_text"]
				reason = "Clipboard long text"
				confidence = 0.75
			} else {
				preferred = ["explain_text", "summarize_text", "rewrite_text"]
				reason = "Clipboard text eligible"
				confidence = 0.6
			}

			let ranked = rankActions(candidates: candidates, preferredOrder: preferred)
			return ReasoningDecision(
				shouldSurface: !ranked.isEmpty,
				primaryActionId: ranked.first,
				rankedActionIds: ranked,
				reason: reason,
				confidence: ranked.isEmpty ? 0.0 : confidence
			)

		case .contextMetadataEligible:
			return dynamicOnlySurfaceDecision(triggerType: .contextMetadataEligible, context: context)
		}
	}

	private func dynamicOnlySurfaceDecision(triggerType: TriggerType, context: ContextModel) -> ReasoningDecision {
		let confidence: Double
		let reason: String
		var shouldSurface = true

		switch triggerType {
		case .selectedTextEligible:
			confidence = 0.72
			reason = "dynamic_only_selected_text"
			if !AgenticPivot.isSelectedTextInfluenceEnabled { shouldSurface = false }
		case .clipboardTextEligible:
			confidence = looksErrorLikeClipboard() ? 0.68 : 0.58
			reason = "dynamic_only_clipboard"
			if !AgenticPivot.isClipboardInfluenceEnabled { shouldSurface = false }
		case .manualInvocation:
			confidence = 0.5
			reason = "dynamic_only_manual"
		case .contextMetadataEligible:
			confidence = 0.52
			reason = "dynamic_only_context_metadata"
		}
		_ = context
		return ReasoningDecision(
			shouldSurface: shouldSurface,
			primaryActionId: nil,
			rankedActionIds: [],
			reason: reason,
			confidence: confidence
		)
	}

	private func looksErrorLikeClipboard() -> Bool {
		guard let raw = NSPasteboard.general.string(forType: .string), !raw.isEmpty else { return false }
		let capped: String
		if raw.count > 2000 {
			let idx = raw.index(raw.startIndex, offsetBy: 2000)
			capped = String(raw[..<idx])
		} else {
			capped = raw
		}
		return looksErrorLike(capped)
	}

	private func looksErrorLike(_ text: String) -> Bool {
		if text.count < 20 { return false }

		let lowered = text.lowercased()
		let keywords = [
			"traceback",
			"exception",
			"stack trace",
			"segmentation fault",
			"panic",
			"fatal error",
			"assertion failed",
			"unhandled",
			"connection refused",
			"timed out"
		]
		if keywords.contains(where: { lowered.contains($0) }) {
			return true
		}

		if lowered.contains("error:") || lowered.contains("failed:") {
			return true
		}

		let newlineCount = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
		if newlineCount >= 6 && lowered.contains(" at ") {
			return true
		}

		let hasCodeLike = lowered.contains("0x") || lowered.contains("sig") || lowered.contains("errno")
		return hasCodeLike && newlineCount >= 2
	}

	private func rankActions(candidates: [String], preferredOrder: [String]) -> [String] {
		var ranked: [String] = []
		var seen = Set<String>()

		for id in preferredOrder {
			if candidates.contains(id), !seen.contains(id) {
				ranked.append(id)
				seen.insert(id)
			}
		}

		for id in candidates {
			if !seen.contains(id) {
				ranked.append(id)
				seen.insert(id)
			}
		}

		return ranked
	}
}

