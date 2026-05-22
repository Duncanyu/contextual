// HookExecutionSandbox.swift
//
// Quarantined hook execution runtime — DEBUG ONLY.
// NOT connected to production generated proposal execution.
// Triggered exclusively via the "Run Hook Sandbox" debug button in LocalModelStatusView.
//
// Safety constraints:
//   • Only hooks in `safeHookIds` are permitted (no computerControl, no dangerous).
//   • Does NOT trigger new screen captures — reads from the existing snapshot.
//   • Does NOT call Ollama — uses heuristic implementations in this phase.
//   • Stops on first failure; never auto-recovers with synthetic data.
//   • Never claims success if a hook did not actually run.

import Foundation

// MARK: - Step outcome

enum HookSandboxStepOutcome: Sendable, Equatable {
    /// Hook executed and produced output.
    case success(output: String)
    /// Hook needs data that is absent from the current snapshot.
    case missingInput(field: String)
    /// Hook requires a permission that is not granted.
    case missingPermission(hookId: String, level: String)
    /// Hook is in computerControl or dangerous category — permanently blocked in sandbox.
    case blockedNotSafe
    /// Hook exists in registry but isImplemented == false (production placeholder).
    case placeholderOnly
    /// Hook is not in the sandbox allowlist or has no sandbox implementation yet.
    case failed(reason: String)

    var shortLabel: String {
        switch self {
        case .success:                          return "success"
        case .missingInput(let f):              return "missing_input:\(f)"
        case .missingPermission(_, let l):      return "missing_permission:\(l)"
        case .blockedNotSafe:                   return "blocked_not_safe"
        case .placeholderOnly:                  return "placeholder_only"
        case .failed(let r):                    return "failed:\(r)"
        }
    }
}

// MARK: - Per-step result

struct HookSandboxStepResult: Sendable {
    let hookId: String
    let outcome: HookSandboxStepOutcome
    let durationMs: Int

    var succeeded: Bool {
        if case .success = outcome { return true }
        return false
    }
}

// MARK: - Overall result

enum HookSandboxMode: String, Sendable {
    case sample
    case live
}

struct HookSandboxResult: Sendable {
    let mode: HookSandboxMode
    let chain: [String]
    let steps: [HookSandboxStepResult]
    let success: Bool
    let finalOutput: String?

    var completedCount: Int { steps.filter(\.succeeded).count }
    var failedAt: String? { steps.first(where: { !$0.succeeded })?.hookId }
    var failureReason: String? { steps.first(where: { !$0.succeeded })?.outcome.shortLabel }
}

// MARK: - Mutable state bag (actor-owned)

private final class SandboxContext {
    let snapshot: CanonicalGeneratedExecutionContextSnapshot
    var accumulatedText: String?
    var outputLines: [String] = []
    var metadata: [String: String] = [:]

    init(snapshot: CanonicalGeneratedExecutionContextSnapshot) {
        self.snapshot = snapshot
    }

    /// Best available text for extraction hooks: accumulated → OCR → selected → clipboard.
    var bestAvailableText: String? {
        if let t = accumulatedText, !t.isEmpty { return t }
        if let t = snapshot.recentOCRExcerpt, !t.isEmpty { return t }
        if let t = snapshot.selectedText, !t.isEmpty { return t }
        if let t = snapshot.clipboardText, !t.isEmpty { return t }
        return nil
    }
}

// MARK: - Sandbox actor

actor HookExecutionSandbox {
    static let shared = HookExecutionSandbox()

    // MARK: Safe allowlist

    /// Hook IDs permitted in the sandbox.
    /// computerControl and dangerous are permanently excluded.
    static let safeHookIds: Set<String> = [
        // Observation
        "observe_current_context",
        "gather_visible_context_once",
        "run_ocr_once",
        "read_selected_text",
        "inspect_recent_titles",
        "inspect_window_title",
        // Extraction (heuristic — no LLM in sandbox)
        "extract_entities",
        "extract_product_attributes",
        "extract_error_messages",
        "extract_tasks",
        // Presentation
        "present_result",
    ]

    /// Fixed test chain for the "Run Hook Sandbox" debug button.
    /// Uses existing snapshot data — does NOT trigger new captures.
    static let defaultTestChain: [String] = [
        "observe_current_context",
        "gather_visible_context_once",
        "run_ocr_once",
        "extract_product_attributes",
        "present_result",
    ]

    /// Seeded sample snapshot used to test hook chaining deterministically.
    /// Does not require any permissions; the sandbox reads only from this snapshot.
    static func seededSampleSnapshot(referenceTime: Date = Date()) -> CanonicalGeneratedExecutionContextSnapshot {
        CanonicalGeneratedExecutionContextSnapshot(
            activeApp: "Firefox",
            windowTitle: "Spigen Rugged Armor Designed for AirPods 4 Case - Matte Black",
            bundleIdentifier: "org.mozilla.firefox",
            inferredWorkflow: .browsing,
            selectedText: nil,
            clipboardText: nil,
            recentOCRExcerpt: "Spigen Rugged Armor AirPods 4 Case Matte Black. Price $19.99. Rating 4.6 stars. Compatible with AirPods 4.",
            contextSummary: "Amazon product page showing AirPods case listing, price, rating, product image, and shopping controls.",
            workflowConfidence: 0.74,
            availableContextTypes: [.workflowContext, .textSnippet, .fusedVisual],
            permissionAvailability: [.screenRecording: false, .accessibility: false, .clipboard: false],
            generatedAt: referenceTime,
            freshnessScore: 0.72
        )
    }

    // MARK: - Execute

    /// Run a hook chain sequentially against the provided snapshot.
    /// Stops on the first failure and reports the reason honestly.
    func execute(
        chain: [String],
        snapshot: CanonicalGeneratedExecutionContextSnapshot,
        mode: HookSandboxMode,
        registry: HookCapabilityRegistry = .shared
    ) async -> HookSandboxResult {
        let chainStr = chain.joined(separator: "→")
        print("[HookRuntimeSandbox] mode=\(mode.rawValue) started chain=[\(chainStr)]")
        print("[HookRuntimeSandbox] seeded_context app=\(snapshot.activeApp) title=\"\(String(snapshot.windowTitle.prefix(80)))\" wf=\(snapshot.inferredWorkflow.rawValue) ocr=\(snapshot.recentOCRExcerpt != nil ? "yes" : "no") visual=\(snapshot.visualContextAvailability.visualSummaryExcerpt != nil ? "yes" : "no")")

        let ctx = SandboxContext(snapshot: snapshot)
        var steps: [HookSandboxStepResult] = []

        for hookId in chain {
            print("[HookRuntimeSandbox] running hook=\(hookId)")
            let t0 = Date()
            let outcome = runHook(hookId: hookId, ctx: ctx, registry: registry)
            let durationMs = Int(Date().timeIntervalSince(t0) * 1000)
            let step = HookSandboxStepResult(hookId: hookId, outcome: outcome, durationMs: durationMs)
            steps.append(step)

            switch outcome {
            case .success(let out):
                let preview = String(out.prefix(120)).replacingOccurrences(of: "\n", with: "↵")
                print("[HookRuntimeSandbox] completed hook=\(hookId) output=\"\(preview)\" elapsed_ms=\(durationMs)")
            default:
                print("[HookRuntimeSandbox] failed hook=\(hookId) reason=\(step.outcome.shortLabel) elapsed_ms=\(durationMs)")
                let partialOutput = ctx.outputLines.isEmpty ? nil : ctx.outputLines.joined(separator: "\n")
                let result = HookSandboxResult(
                    mode: mode, chain: chain, steps: steps, success: false, finalOutput: partialOutput
                )
                print("[HookRuntimeSandbox] result=failure completed=\(result.completedCount) failed=\(hookId) reason=\(step.outcome.shortLabel)")
                return result
            }
        }

        let finalOutput = ctx.outputLines.isEmpty
            ? ctx.accumulatedText.map { String($0.prefix(500)) }
            : ctx.outputLines.joined(separator: "\n")

        let result = HookSandboxResult(
            mode: mode, chain: chain, steps: steps, success: true, finalOutput: finalOutput
        )
        let finalPreview = (finalOutput ?? "").prefix(120).replacingOccurrences(of: "\n", with: "↵")
        print("[HookRuntimeSandbox] result=success completed=\(result.completedCount) output_len=\(finalOutput?.count ?? 0) final_output=\"\(finalPreview)\"")
        return result
    }

    // MARK: - Per-hook dispatch

    private func runHook(
        hookId: String,
        ctx: SandboxContext,
        registry: HookCapabilityRegistry
    ) -> HookSandboxStepOutcome {
        // Block hooks outside the safe allowlist.
        guard Self.safeHookIds.contains(hookId) else {
            if let def = registry.definition(for: hookId) {
                if def.category == .computerControl || def.category == .dangerous {
                    return .blockedNotSafe
                }
            }
            return .failed(reason: "hook_not_in_sandbox_allowlist")
        }

        // Unknown hook IDs (typos, future additions not yet in registry).
        guard let def = registry.definition(for: hookId) else {
            return .failed(reason: "unknown_hook_id")
        }

        switch hookId {
        case "observe_current_context":   return runObserveCurrentContext(ctx: ctx)
        case "gather_visible_context_once": return runGatherVisibleContextOnce(ctx: ctx)
        case "run_ocr_once":              return runOCROnce(ctx: ctx)
        case "read_selected_text":        return runReadSelectedText(ctx: ctx)
        case "inspect_window_title":      return runInspectWindowTitle(ctx: ctx)
        case "inspect_recent_titles":     return runInspectRecentTitles(ctx: ctx)
        case "extract_entities":          return runExtractEntities(ctx: ctx)
        case "extract_product_attributes": return runExtractProductAttributes(ctx: ctx)
        case "extract_error_messages":    return runExtractErrorMessages(ctx: ctx)
        case "extract_tasks":             return runExtractTasks(ctx: ctx)
        case "present_result":            return runPresentResult(ctx: ctx)
        default:
            // In safeHookIds but no sandbox implementation yet.
            return def.isImplemented
                ? .failed(reason: "no_sandbox_implementation_yet")
                : .placeholderOnly
        }
    }

    // MARK: - Hook implementations (observation)

    /// Read app/window/workflow metadata from snapshot. Always succeeds.
    private func runObserveCurrentContext(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let s = ctx.snapshot
        let parts: [String] = [
            "app=\(s.activeApp)",
            "title=\(s.windowTitle.isEmpty ? "(none)" : String(s.windowTitle.prefix(60)))",
            "wf=\(s.inferredWorkflow.rawValue)",
            "ocr=\(s.recentOCRExcerpt != nil ? "yes" : "no")",
            "sel=\(s.selectedText != nil ? "yes" : "no")",
            "clip=\(s.clipboardText != nil ? "yes" : "no")",
            "visual=\(s.visualContextAvailability.visualSummaryExcerpt != nil ? "yes" : "no")",
        ]
        let output = parts.joined(separator: " ")
        ctx.metadata["context_meta"] = output
        ctx.outputLines.append("Context: \(output)")
        return .success(output: output)
    }

    /// Read visual/OCR/selected text already in snapshot. Does NOT trigger new capture.
    private func runGatherVisibleContextOnce(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let visual = ctx.snapshot.visualContextAvailability.visualSummaryExcerpt
        let ocr = ctx.snapshot.recentOCRExcerpt
        let sel = ctx.snapshot.selectedText

        if let text = visual ?? ocr ?? sel, !text.isEmpty {
            ctx.accumulatedText = text
            let src = visual != nil ? "visual_descriptor" : (ocr != nil ? "ocr_excerpt" : "selected_text")
            return .success(output: "gathered \(text.utf8.count) bytes from \(src) (sandbox: read-only, no new capture)")
        }
        return .missingInput(field: "no_visual_ocr_or_selected_text_in_snapshot")
    }

    /// Read recentOCRExcerpt from snapshot. Does NOT run new OCR.
    private func runOCROnce(ctx: SandboxContext) -> HookSandboxStepOutcome {
        if let ocr = ctx.snapshot.recentOCRExcerpt, !ocr.isEmpty {
            ctx.accumulatedText = ocr
            return .success(output: "ocr_excerpt \(ocr.utf8.count) bytes (sandbox: read-only)")
        }
        return .missingInput(field: "recentOCRExcerpt_not_in_snapshot")
    }

    private func runReadSelectedText(ctx: SandboxContext) -> HookSandboxStepOutcome {
        if let sel = ctx.snapshot.selectedText, !sel.isEmpty {
            ctx.accumulatedText = sel
            return .success(output: "selected_text \(sel.utf8.count) bytes")
        }
        return .missingInput(field: "selectedText_not_in_snapshot")
    }

    private func runInspectWindowTitle(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let title = ctx.snapshot.windowTitle
        let output = title.isEmpty ? "(no title)" : title
        ctx.outputLines.append("Window title: \(output)")
        return .success(output: output)
    }

    private func runInspectRecentTitles(ctx: SandboxContext) -> HookSandboxStepOutcome {
        // recentTitles not stored in snapshot; use contextSummary excerpt if available.
        let summary = ctx.snapshot.contextSummary.map { String($0.prefix(120)) } ?? "(no context summary)"
        return .success(output: "context_summary=\(summary)")
    }

    // MARK: - Hook implementations (extraction — heuristic, no LLM)

    private func runExtractEntities(ctx: SandboxContext) -> HookSandboxStepOutcome {
        guard let text = ctx.bestAvailableText else {
            return .missingInput(field: "no_text_available_for_extraction")
        }
        let entities = heuristicExtractEntities(from: text)
        guard !entities.isEmpty else {
            return .failed(reason: "no_entities_detected")
        }
        let output = entities.joined(separator: ", ")
        ctx.outputLines.append("Entities: \(output)")
        ctx.accumulatedText = output
        return .success(output: output)
    }

    private func runExtractProductAttributes(ctx: SandboxContext) -> HookSandboxStepOutcome {
        guard let text = ctx.bestAvailableText else {
            return .missingInput(field: "no_text_available_for_extraction")
        }
        var attrs: [String] = []
        let nsText = text as NSString
        // Prices
        if let re = try? NSRegularExpression(pattern: #"\$[\d,]+(\.\d{2})?"#) {
            re.matches(in: text, range: NSRange(location: 0, length: nsText.length)).forEach {
                attrs.append(nsText.substring(with: $0.range))
            }
        }
        // Ratings
        if let re = try? NSRegularExpression(pattern: #"\d+(\.\d+)?(/5|/10|\s*stars?)"#, options: .caseInsensitive) {
            re.matches(in: text, range: NSRange(location: 0, length: nsText.length)).forEach {
                attrs.append(nsText.substring(with: $0.range))
            }
        }
        guard !attrs.isEmpty else { return .missingInput(field: "no_product_attributes_detected") }
        let output = attrs.joined(separator: ", ")
        ctx.outputLines.append("Attributes: \(output)")
        return .success(output: output)
    }

    private func runExtractErrorMessages(ctx: SandboxContext) -> HookSandboxStepOutcome {
        guard let text = ctx.bestAvailableText else {
            return .missingInput(field: "no_text_available_for_extraction")
        }
        let errorKeywords = ["error", "exception", "fatal", "failed", "failure", "crash",
                             "panic", "abort", "nil", "null", "undefined", "cannot", "does not"]
        let errorLines = text.components(separatedBy: .newlines).filter { line in
            let lower = line.lowercased()
            return errorKeywords.contains { lower.contains($0) }
        }
        guard !errorLines.isEmpty else { return .missingInput(field: "no_error_patterns_detected") }
        let output = String(errorLines.prefix(3).joined(separator: "; ").prefix(300))
        ctx.outputLines.append("Errors: \(output)")
        return .success(output: output)
    }

    private func runExtractTasks(ctx: SandboxContext) -> HookSandboxStepOutcome {
        guard let text = ctx.bestAvailableText else {
            return .missingInput(field: "no_text_available_for_extraction")
        }
        let taskLines = text.components(separatedBy: .newlines).filter { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            let upper = s.uppercased()
            return s.hasPrefix("- ") || s.hasPrefix("* ") ||
                   upper.hasPrefix("TODO") || upper.hasPrefix("ACTION:") ||
                   upper.hasPrefix("[ ]") || upper.hasPrefix("[X]")
        }
        guard !taskLines.isEmpty else { return .missingInput(field: "no_task_patterns_detected") }
        let output = String(taskLines.prefix(5).joined(separator: "; ").prefix(300))
        ctx.outputLines.append("Tasks: \(output)")
        return .success(output: output)
    }

    // MARK: - Hook implementations (presentation)

    private func runPresentResult(ctx: SandboxContext) -> HookSandboxStepOutcome {
        if ctx.outputLines.isEmpty {
            let fallback = ctx.metadata["context_meta"] ?? "(sandbox produced no output)"
            return .success(output: fallback)
        }
        return .success(output: ctx.outputLines.joined(separator: "\n"))
    }

    // MARK: - Heuristics

    private func heuristicExtractEntities(from text: String) -> [String] {
        var entities: Set<String> = []
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // Version numbers (v1.2.3, 1.0.0)
        if let re = try? NSRegularExpression(pattern: #"v?\d+\.\d+(\.\d+)?"#) {
            re.matches(in: text, range: fullRange).forEach {
                entities.insert(nsText.substring(with: $0.range))
            }
        }
        // URLs / domains
        if let re = try? NSRegularExpression(pattern: #"https?://[^\s<>\"]{3,50}"#) {
            re.matches(in: text, range: fullRange).forEach {
                var s = nsText.substring(with: $0.range)
                if s.count > 50 { s = String(s.prefix(50)) + "…" }
                entities.insert(s)
            }
        }
        // Capitalized phrases (proper nouns)
        let stopwords: Set<String> = ["The", "This", "That", "With", "From", "For", "And",
                                      "Are", "Was", "Has", "Have", "Its", "In", "To", "A",
                                      "An", "As", "At", "By", "Be", "If", "Of", "Or"]
        let words = text.components(separatedBy: .whitespaces)
        var i = 0
        while i < words.count {
            let word = words[i].trimmingCharacters(in: .punctuationCharacters)
            guard word.count >= 2,
                  let first = word.first, first.isUppercase,
                  !word.allSatisfy(\.isUppercase),
                  !stopwords.contains(word) else { i += 1; continue }
            var phrase = word
            var j = i + 1
            while j < min(i + 3, words.count) {
                let next = words[j].trimmingCharacters(in: .punctuationCharacters)
                guard next.count >= 2, let f = next.first, f.isUppercase else { break }
                phrase += " " + next
                j += 1
            }
            if phrase.count >= 3 { entities.insert(phrase) }
            i += 1
        }
        let filtered = entities.filter { $0.count >= 3 && !stopwords.contains($0) }
        return Array(filtered).sorted().prefix(10).map { $0 }
    }
}
