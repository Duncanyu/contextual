import Foundation

// MARK: - Isolated Context

/// Sanitized view of a `CanonicalGeneratedExecutionContextSnapshot` for proposal
/// pipelines. Only sources cleared by `ProposalContextIsolationGate` end up here.
///
/// Use this struct everywhere proposal validation / planner prompting decides
/// "what counts as the active target context". Anything not present in this
/// struct is excluded from prompt input and from grounding overlap checks.
struct IsolatedProposalContext: Sendable, Equatable {
	let appName: String
	let bundleIdentifier: String?
	let windowTitle: String
	let selectedText: String?
	let ocrExcerpt: String?
	let axExcerpt: String?
	let recentChanges: String?
	let includedSources: [String]
	let excludedSources: [(name: String, reason: String)]

	/// True when at least one real page-content source survived isolation.
	var hasAnyContent: Bool {
		(selectedText?.isEmpty == false)
			|| (ocrExcerpt?.isEmpty == false)
			|| (axExcerpt?.isEmpty == false)
	}

	/// Combined text used by validators for token-overlap grounding checks.
	var groundingText: String {
		var parts: [String] = [appName, windowTitle]
		if let s = selectedText { parts.append(s) }
		if let o = ocrExcerpt { parts.append(o) }
		if let a = axExcerpt { parts.append(a) }
		if let r = recentChanges { parts.append(r) }
		return parts.joined(separator: " ")
	}

	static let empty = IsolatedProposalContext(
		appName: "",
		bundleIdentifier: nil,
		windowTitle: "",
		selectedText: nil,
		ocrExcerpt: nil,
		axExcerpt: nil,
		recentChanges: nil,
		includedSources: [],
		excludedSources: []
	)

	// Manual Equatable: tuple element in `excludedSources` isn't Equatable by default.
	static func == (lhs: IsolatedProposalContext, rhs: IsolatedProposalContext) -> Bool {
		lhs.appName == rhs.appName
			&& lhs.bundleIdentifier == rhs.bundleIdentifier
			&& lhs.windowTitle == rhs.windowTitle
			&& lhs.selectedText == rhs.selectedText
			&& lhs.ocrExcerpt == rhs.ocrExcerpt
			&& lhs.axExcerpt == rhs.axExcerpt
			&& lhs.recentChanges == rhs.recentChanges
			&& lhs.includedSources == rhs.includedSources
			&& lhs.excludedSources.map(\.name) == rhs.excludedSources.map(\.name)
			&& lhs.excludedSources.map(\.reason) == rhs.excludedSources.map(\.reason)
	}
}

// MARK: - Reasons

/// Typed reasons why a source is excluded from the proposal pipeline.
enum ProposalContextExclusionReason: String, Sendable, Equatable {
	case huge_clipboard_unrelated
	case stale_clipboard
	case ide_metadata_only
	case app_window_changed_since_clipboard
	case low_relevance
	case dev_artifact_text
	case log_text
	case clipboard_pipeline_suppressed
}

// MARK: - Gate

/// Phase 4P — Proposal Context Isolation Gate.
///
/// Decides which context sources are admissible as inputs to the router / planner /
/// candidate validator. The single non-negotiable rule: when clipboard text is
/// suppressed for ANY of the typed reasons in `ProposalContextExclusionReason`,
/// it must be excluded from EVERY proposal-pipeline input — not just one.
///
/// This is a pure value type with no model calls and no AppKit dependencies.
enum ProposalContextIsolationGate {

	/// Heuristics for detecting dev/log/IDE artifact text in any input field.
	///
	/// These patterns are intentionally generic (file extensions / common log
	/// markers / project chrome) — NOT website-specific or app-specific. We do
	/// not add hardcoded titles.
	private static let devArtifactFileExtensions: [String] = [
		".swift", ".md", ".m", ".mm", ".h", ".cpp", ".c", ".rs", ".go",
		".py", ".rb", ".ts", ".tsx", ".js", ".jsx", ".json", ".yaml", ".yml",
		".toml", ".lock", ".plist", ".xcodeproj", ".xcworkspace",
		".pbxproj", ".storyboard", ".xib", ".log", ".txt",
	]
	private static let devArtifactTokenSubstrings: [String] = [
		"appdelegate", "info.plist", "package.swift", "package.json",
		"implementation_plan", "walkthrough.md", "task.md", "agents.md",
		"contextual.xcodeproj",
		"import ", "func ", "class ", "struct ", "enum ", "extension ",
	]
	private static let logArtifactPrefixes: [String] = [
		"[debug", "[error", "[info", "[warn", "[notice", "stack trace", "traceback", "timestamp=", "log:", "stderr:"
	]

	// MARK: - Public

	/// Build an `IsolatedProposalContext` from a snapshot.
	///
	/// `clipboardSuppressionReason` is taken from the upstream pipeline. When
	/// the snapshot already excluded clipboard, callers pass `nil` — the gate
	/// still treats clipboard as excluded.
	static func isolate(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		clipboardSuppressionReason: ProposalContextExclusionReason? = nil,
		situationalRecentChanges: String? = nil,
		axExcerpt: String? = nil
	) -> IsolatedProposalContext {
		var included: [String] = ["window_title"]
		var excluded: [(name: String, reason: String)] = []

		let appName = snapshot.activeApp
		let bundle = snapshot.bundleIdentifier
		let windowTitle = snapshot.windowTitle

		// 1. selectedText — admit unless it itself smells like dev/log artifact text.
		var selectedText: String? = nil
		if let st = snapshot.selectedText, !st.isEmpty {
			if looksLikeDevArtifact(st) {
				excluded.append(("selected_text", ProposalContextExclusionReason.dev_artifact_text.rawValue))
			} else if looksLikeLogText(st) {
				excluded.append(("selected_text", ProposalContextExclusionReason.log_text.rawValue))
			} else {
				selectedText = st
				included.append("selected_text")
			}
		}

		// 2. OCR — sanitize line-by-line instead of whole-source exclusion.
		var ocrExcerpt: String? = nil
		if let ocr = snapshot.recentOCRExcerpt, !ocr.isEmpty {
			let (sanitized, keptChars, removedLines) = sanitizeArtifactLines(ocr, appName: appName, windowTitle: windowTitle)
			if keptChars > 0 {
				ocrExcerpt = sanitized
				included.append("ocr_excerpt_sanitized")
				print("[ProposalContextIsolation] ocr_sanitized=yes kept_chars=\(keptChars) removed_lines=\(removedLines)")
			} else {
				excluded.append(("ocr_excerpt", ProposalContextExclusionReason.dev_artifact_text.rawValue))
			}
		}

		// 3. AX text — same sanitization.
		var axOut: String? = nil
		if let ax = axExcerpt, !ax.isEmpty {
			let (sanitized, keptChars, removedLines) = sanitizeArtifactLines(ax, appName: appName, windowTitle: windowTitle)
			if keptChars > 0 {
				axOut = sanitized
				included.append("ax_excerpt_sanitized")
				print("[ProposalContextIsolation] ax_sanitized=yes kept_chars=\(keptChars) removed_lines=\(removedLines)")
			} else {
				excluded.append(("ax_excerpt", ProposalContextExclusionReason.dev_artifact_text.rawValue))
			}
		}

		// 4. Clipboard — always excluded from proposal pipelines when the upstream
		// pipeline flagged it OR when the snapshot still carries clipboard text
		// (we don't trust upstream to consistently nil it).
		if let reason = clipboardSuppressionReason {
			excluded.append(("clipboard", reason.rawValue))
		} else if snapshot.clipboardText != nil {
			excluded.append(("clipboard", ProposalContextExclusionReason.clipboard_pipeline_suppressed.rawValue))
		}

		// 5. recent_changes — admit only when it doesn't echo clipboard / dev artifacts.
		var recentChanges: String? = nil
		if let rc = situationalRecentChanges, !rc.isEmpty {
			if looksLikeDevArtifact(rc) || looksLikeLogText(rc) {
				excluded.append(("recent_changes", ProposalContextExclusionReason.dev_artifact_text.rawValue))
			} else {
				recentChanges = rc
				included.append("recent_changes")
			}
		}

		let isolated = IsolatedProposalContext(
			appName: appName,
			bundleIdentifier: bundle,
			windowTitle: windowTitle,
			selectedText: selectedText,
			ocrExcerpt: ocrExcerpt,
			axExcerpt: axOut,
			recentChanges: recentChanges,
			includedSources: included,
			excludedSources: excluded
		)

		emitLogs(isolated: isolated)
		return isolated
	}

	// MARK: - Stale entity rejection helper

	/// True when `title` contains content tokens that are *absent* from the
	/// active isolated context — i.e. the title is not anchored in what the
	/// user is actually looking at. Optionally checks for explicit dev/file
	/// artifact tokens that almost always indicate stale clipboard / log leak.
	///
	/// Returns the typed reason when stale; nil when the title is anchored.
	/// Reasons:
	///   `dev_artifact_not_in_active_context` — title contains a file extension
	///     or known dev token (e.g. ".md", "appdelegate") that is missing from
	///     the active context.
	///   `zero_overlap_with_active_context` — no dev artifact, but title tokens
	///     and context tokens are entirely disjoint.
	static func staleContextEntityReason(
		title: String,
		isolated: IsolatedProposalContext
	) -> String? {
		let titleLower = title.lowercased()
		let titleTokens = contentTokens(in: titleLower)
		guard !titleTokens.isEmpty else { return nil }

		let contextLower = isolated.groundingText.lowercased()
		let contextTokens = contentTokens(in: contextLower)

		// 1. Dev/file artifact detected by raw substring (tokenization drops the
		//    leading dot on extensions, so we check the original lowercased title).
		//    If any artifact substring is present in the title AND missing from the
		//    active context, reject as stale.
		let titleHasArtifactExt = devArtifactFileExtensions.contains { titleLower.contains($0) }
		let titleHasArtifactToken = devArtifactTokenSubstrings.contains { titleLower.contains($0) }
		if titleHasArtifactExt || titleHasArtifactToken {
			let artifactInContext: Bool = {
				for ext in devArtifactFileExtensions where titleLower.contains(ext) {
					if contextLower.contains(ext) { return true }
				}
				for tok in devArtifactTokenSubstrings where titleLower.contains(tok) {
					if contextLower.contains(tok) { return true }
				}
				return false
			}()
			if !artifactInContext {
				return "dev_artifact_not_in_active_context"
			}
		}

		// 2. Generic entity overlap: at least one content token in the title must
		//    appear in the active context.
		let overlap = titleTokens.intersection(contextTokens)
		if overlap.isEmpty {
			return "zero_overlap_with_active_context"
		}

		return nil
	}

	// MARK: - Logging

	private static func emitLogs(isolated: IsolatedProposalContext) {
		let included = isolated.includedSources.joined(separator: ",")
		let excluded = isolated.excludedSources.map { "\($0.name):\($0.reason)" }.joined(separator: ",")
		print("[ProposalContextIsolation] planner_input_sources=\(included)")
		if !isolated.excludedSources.isEmpty {
			print("[ProposalContextIsolation] excluded_sources=\(excluded)")
			for (name, reason) in isolated.excludedSources where name == "clipboard" {
				print("[ProposalContextIsolation] clipboard_excluded=yes reason=\(reason)")
			}
		}
	}

	// MARK: - Internals

	private static func sanitizeArtifactLines(_ text: String, appName: String, windowTitle: String) -> (sanitized: String, keptChars: Int, removedLines: Int) {
		let isDevelopmentContext = windowTitle.lowercased().contains(".swift") || appName.lowercased().contains("xcode")
		
		let lines = text.components(separatedBy: .newlines)
		var kept: [String] = []
		var removedCount = 0
		
		for line in lines {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.isEmpty { continue }
			
			if !isDevelopmentContext && (looksLikeDevArtifact(line) || looksLikeLogText(line)) {
				removedCount += 1
				continue
			}
			
			// Browser chrome filters (simple heuristics)
			let lower = line.lowercased()
			if lower.contains("http://") || lower.contains("https://") || lower.contains("www.") {
				// Keep URLs if they aren't obviously dev artifacts
				kept.append(line)
			} else if lower.hasSuffix(".com") || lower.hasSuffix(".org") || lower.hasSuffix(".io") {
				kept.append(line)
			} else {
				kept.append(line)
			}
		}
		
		let joined = kept.joined(separator: "\n")
		return (joined, joined.count, removedCount)
	}

	private static func looksLikeDevArtifact(_ text: String) -> Bool {
		let lower = text.lowercased()
		for ext in devArtifactFileExtensions where lower.contains(ext) {
			return true
		}
		for tok in devArtifactTokenSubstrings where lower.contains(tok) {
			return true
		}
		return false
	}

	private static func looksLikeLogText(_ text: String) -> Bool {
		let lower = text.lowercased()
		for prefix in logArtifactPrefixes where lower.contains(prefix) {
			return true
		}
		return false
	}

	private static func isDevArtifactToken(_ token: String) -> Bool {
		for ext in devArtifactFileExtensions where token.hasSuffix(ext) || token == String(ext.dropFirst()) {
			return true
		}
		for tok in devArtifactTokenSubstrings where token == tok || token.contains(tok) {
			return true
		}
		return false
	}

	private static let stopwords: Set<String> = [
		"this", "that", "with", "from", "have", "will", "your", "what", "want",
		"page", "here", "help", "more", "like", "just", "them", "they", "when",
		"some", "about", "which", "their", "there", "these", "those", "been",
		"said", "does", "make", "into", "than", "then", "time", "only", "also",
		"details", "context", "summary", "visible", "content", "specifications",
		"ratings", "specs", "smart", "review", "analyze", "inspect", "compare",
		"summarize", "extract", "describe", "open", "search", "find", "scroll",
		"please", "next", "tool", "tools",
	]

	/// Splits `text` on non-alphanumerics, lowercases, drops stopwords, drops
	/// tokens shorter than 3 chars. Used by both the validator and the stale-
	/// entity rejecter so they share definitions.
	static func contentTokens(in text: String) -> Set<String> {
		let tokens = text
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.map { $0.lowercased() }
			.filter { $0.count >= 3 && !stopwords.contains($0) }
		return Set(tokens)
	}
}
