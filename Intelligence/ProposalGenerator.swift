import Foundation

struct ActionProposal: Equatable {
	let title: String
	/// Short input hint for panel/floating (no raw text). Empty when redundant with the title.
	let sourceCaption: String
	let primaryActionId: String
	let secondaryActionIds: [String]
	let confidence: Double
	let reason: String
}

final class ProposalGenerator {
	static let shared = ProposalGenerator()
	private init() {}

	func generate(
		context: ContextModel,
		triggerPacket: TriggerPacket,
		decision: ReasoningDecision,
		inputSourcePreference: InputSourceChoice,
		intelligenceTitleOverride: String? = nil
	) -> ActionProposal? {
		guard decision.shouldSurface else { return nil }
		guard let primary = decision.primaryActionId, !primary.isEmpty else { return nil }
		if DynamicOnlyProposalMode.isGenericStaticAction(primary) { return nil }

		let secondary = decision.rankedActionIds.filter { $0 != primary }
		let channel = resolveCopyChannel(triggerPacket: triggerPacket, inputSourcePreference: inputSourcePreference, context: context)
		let title: String
		if let override = intelligenceTitleOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
			title = override
		} else {
			title = titleFor(primaryActionId: primary, channel: channel, triggerType: triggerPacket.triggerType)
		}
		let caption = sourceCaption(for: channel, primaryActionId: primary)

		let proposal = ActionProposal(
			title: title,
			sourceCaption: caption,
			primaryActionId: primary,
			secondaryActionIds: secondary,
			confidence: decision.confidence,
			reason: decision.reason
		)

		let titleHash = String(Self.fnv1a64(title), radix: 16)
		print("[ProposalGenerator] proposal primary=\(primary) confidence=\(decision.confidence) titleHash=\(titleHash)")
		return proposal
	}

	private enum ProposalCopyChannel {
		case selectedText
		case clipboard
		case screenText
		case neutral
	}

	private func resolveCopyChannel(
		triggerPacket: TriggerPacket,
		inputSourcePreference: InputSourceChoice,
		context: ContextModel
	) -> ProposalCopyChannel {
		switch inputSourcePreference {
		case .clipboard:
			return context.clipboardTextAvailable ? .clipboard : .neutral
		case .selectedText:
			return context.selectedTextAvailable ? .selectedText : .neutral
		case .screenOCR:
			return context.screenOCRAvailable ? .screenText : .neutral
		case .automatic:
			break
		}

		switch triggerPacket.triggerType {
		case .clipboardTextEligible:
			return .clipboard
		case .selectedTextEligible:
			return .selectedText
		case .manualInvocation:
			if context.selectedTextAvailable { return .selectedText }
			if context.clipboardTextAvailable { return .clipboard }
			if context.screenOCRAvailable { return .screenText }
			return .neutral
		case .contextMetadataEligible:
			return .neutral
		}
	}

	private func sourceCaption(for channel: ProposalCopyChannel, primaryActionId: String) -> String {
		if primaryActionId == "analyze_screen" {
			return "Using screen text"
		}
		switch channel {
		case .selectedText:
			return "Using selected text"
		case .clipboard:
			return "Using clipboard"
		case .screenText:
			return "Using screen text"
		case .neutral:
			return ""
		}
	}

	private func titleFor(primaryActionId: String, channel: ProposalCopyChannel, triggerType: TriggerType) -> String {
		if primaryActionId == "analyze_screen" {
			return "Want to analyze what's on screen?"
		}

		switch channel {
		case .neutral:
			switch triggerType {
			case .manualInvocation:
				return "What would you like to do with this?"
			default:
				return "Want help with this?"
			}

		case .selectedText:
			switch primaryActionId {
			case "summarize_text":
				return "Want me to summarize this selected text?"
			case "explain_text":
				return "Want me to explain this selected text?"
			case "rewrite_text":
				return "Want me to rewrite this selected text?"
			default:
				return "Want help with this?"
			}

		case .clipboard:
			switch primaryActionId {
			case "summarize_text":
				return "Want a quick summary of what you copied?"
			case "explain_text":
				return "Want help understanding what you copied?"
			case "rewrite_text":
				return "Want me to clean up what you copied?"
			default:
				return "Want help with this?"
			}

		case .screenText:
			switch primaryActionId {
			case "summarize_text":
				return "Want a quick summary of this screen text?"
			case "explain_text":
				return "Want help understanding this screen text?"
			case "rewrite_text":
				return "Want me to clean up this screen text?"
			default:
				return "Want help with this screen text?"
			}
		}
	}

	private static func fnv1a64(_ text: String) -> UInt64 {
		var hash: UInt64 = 14_695_981_039_346_656_037
		for b in text.utf8 {
			hash ^= UInt64(b)
			hash &*= 1_099_511_628_211
		}
		return hash
	}
}

// MARK: - ProposalGenerationGate (T11.1)

/// Result of pre-proposal quality gate (no AI; metadata-only heuristics).
struct ProposalGateResult {
	let shouldGenerate: Bool
	let reason: String
}

/// Conservative gate **before** `ProposalGenerator.generate` runs. Prefers silence over weak proposals.
final class ProposalGenerationGate {
	private init() {}

	private static var lastFeaturesLogSig: String?
	private static var lastFeaturesLogAt: Date?
	private static var lastClassLogSig: String?
	private static var lastClassLogAt: Date?

	/// Evaluates automatic-style primary text (selection → clipboard → OCR). No raw text logging.
	static func evaluate(context: ContextModel) -> ProposalGateResult {
		guard let raw = ActionInputCapture.primaryText(for: context, minimumLength: 0, preference: .automatic)?
			.trimmingCharacters(in: .whitespacesAndNewlines),
			!raw.isEmpty
		else {
			return ProposalGateResult(shouldGenerate: false, reason: "no_input")
		}

		let text = raw
		let f = FeatureExtractor.extract(from: text)
		logContextFeaturesIfNeeded(f)

		if isStrongSignal(f) {
			return ProposalGateResult(shouldGenerate: true, reason: "strong_signal")
		}

		if f.textLength < 30 {
			return ProposalGateResult(shouldGenerate: false, reason: "too_short")
		}

		if isNonActionable(text: text, length: f.textLength) {
			return ProposalGateResult(shouldGenerate: false, reason: "non_actionable")
		}

		let type = ContextClassifier.classify(features: f, text: text)
		logContextTypeIfNeeded(type)

		// If type is random and we didn't already detect a strong signal, prefer silence.
		if type == .random {
			return ProposalGateResult(shouldGenerate: false, reason: "random")
		}

		// Bias allow list: question, logs, and code are generally actionable.
		if type == .question || type == .errorLog || type == .code {
			return ProposalGateResult(shouldGenerate: true, reason: "classified_\(type.rawValue)")
		}

		// Notes/articles: allow only when medium strength (we already checked strong above).
		let medium = f.textLength >= 80 && f.sentenceCount >= 2
		if (type == .notes || type == .article), medium {
			return ProposalGateResult(shouldGenerate: true, reason: "classified_\(type.rawValue)")
		}

		if f.repetitionScore > 0.6 || (f.punctuationDensity < 0.01 && f.sentenceCount <= 1) {
			return ProposalGateResult(shouldGenerate: false, reason: "low_signal")
		}

		if f.sentenceCount < 2 && f.punctuationDensity < 0.02 {
			return ProposalGateResult(shouldGenerate: false, reason: "weak_context")
		}

		return ProposalGateResult(shouldGenerate: false, reason: "uncertain")
	}

	private static func isStrongSignal(_ f: ContextFeatures) -> Bool {
		if f.textLength >= 120 { return true }
		if f.hasQuestion { return true }
		if f.isLikelyLog { return true }
		if f.lineCount > 3 { return true }
		return false
	}

	private static func logContextFeaturesIfNeeded(_ f: ContextFeatures) {
		let punct = String(format: "%.4f", f.punctuationDensity)
		let rep = String(format: "%.3f", f.repetitionScore)
		let sig = "\(f.textLength)|\(f.wordCount)|\(f.sentenceCount)|\(punct)|\(f.lineCount)|\(rep)"
		let now = Date()
		if let p = lastFeaturesLogSig, p == sig, let t = lastFeaturesLogAt, now.timeIntervalSince(t) < 2.0 {
			return
		}
		lastFeaturesLogSig = sig
		lastFeaturesLogAt = now
		print(
			"[ContextFeatures] len=\(f.textLength) words=\(f.wordCount) sentences=\(f.sentenceCount) punct=\(punct) question=\(f.hasQuestion) code=\(f.isLikelyCode) log=\(f.isLikelyLog) lines=\(f.lineCount) rep=\(rep)"
		)
	}

	private static func logContextTypeIfNeeded(_ type: ContextType) {
		let sig = type.rawValue
		let now = Date()
		if let p = lastClassLogSig, p == sig, let t = lastClassLogAt, now.timeIntervalSince(t) < 2.0 {
			return
		}
		lastClassLogSig = sig
		lastClassLogAt = now
		print("[ContextClassifier] type=\(type.rawValue)")
	}

	private static func isNonActionable(text: String, length len: Int) -> Bool {
		let compact = text.lowercased()
			.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
			.trimmingCharacters(in: .whitespaces)
		let tokens = compact.split(separator: " ").map(String.init)
		let ack = Set(["hi", "hello", "hey", "ok", "okay", "thanks", "thank", "yo", "sup", "bye", "lol"])

		if tokens.count <= 2 {
			let stripped = tokens.map { $0.trimmingCharacters(in: .punctuationCharacters) }
			if stripped.allSatisfy({ ack.contains($0) }) {
				return true
			}
		}

		if tokens.count <= 4, len < 48 {
			let prefixes = ["hi ", "hey ", "hello", "thanks", "thank you", "ok ", "okay", "yo "]
			for p in prefixes where compact.hasPrefix(p) {
				return true
			}
		}

		return false
	}
}

