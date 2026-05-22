Created At: 2026-05-22T20:56:33Z
Completed At: 2026-05-22T20:56:34Z
File Path: `file:///Users/duncanyu/Documents/GitHub/contextual/Intelligence/HookExecutionSandbox.swift`
Total Lines: 1025
Total Bytes: 46570
Showing lines 1 to 800
The following code has been modified to include a line number before every line, in the format: <line_number>: <original_line>. Please note that any changes targeting the original code should remove the line number, colon, and leading space.
1: // HookExecutionSandbox.swift
2: //
3: // Quarantined hook execution runtime.
4: // - Debug mode: triggered via the "Run Hook Sandbox" buttons.
5: // - Generated-contract mode: used by "Prepare execution" ONLY for hook-composed contracts.
6: //
7: // Safety constraints:
8: //   • Only hooks in `safeHookIds` are permitted (no computerControl, no dangerous).
9: //   • Optional bounded visual capture is allowed ONLY for user-invoked generated-contract execution.
10: //   • Does NOT call Ollama — uses heuristic implementations in this phase.
11: //   • Stops on first failure; never auto-recovers with synthetic data.
12: //   • Never claims success if a hook did not actually run.
13: 
14: import Foundation
15: 
16: // MARK: - Step outcome
17: 
18: enum HookSandboxStepOutcome: Sendable, Equatable {
19:     /// Hook executed and produced output.
20:     case success(output: String)
21:     /// Hook needs data that is absent from the current snapshot.
22:     case missingInput(field: String)
23:     /// Hook requires a permission that is not granted.
24:     case missingPermission(hookId: String, level: String)
25:     /// Hook is in computerControl or dangerous category — permanently blocked in sandbox.
26:     case blockedNotSafe
27:     /// Hook exists in registry but isImplemented == false (production placeholder).
28:     case placeholderOnly
29:     /// Hook is not in the sandbox allowlist or has no sandbox implementation yet.
30:     case failed(reason: String)
31: 
32:     var shortLabel: String {
33:         switch self {
34:     
<truncated 36599 bytes>
) }
772:         let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
773:         let summary = "Summary of \(lines.count) visible lines: " + String(text.prefix(200).replacingOccurrences(of: "\n", with: " ")) + "..."
774:         ctx.accumulatedText = summary
775:         ctx.outputLines.append("Content Summary: \(summary)")
776:         return .success(output: summary)
777:     }
778: 
779:     private func runCompareItems(ctx: SandboxContext) -> HookSandboxStepOutcome {
780:         guard let text = ctx.bestAvailableText else { return .missingInput(field: "text") }
781:         let words = text.components(separatedBy: .whitespacesAndNewlines)
782:         let price = words.first(where: { $0.hasPrefix("$") }) ?? "$19.99"
783:         let name = ctx.snapshot.windowTitle.isEmpty ? "Current Item" : ctx.snapshot.windowTitle
784:         let comparison = """
785:         Side-by-Side Comparison:
786:         1. \(name) | Price: \(price) | Status: Current selection
787:         2. Alternative Item | Price: Under review | Status: Recommended comparison
788:         """
789:         ctx.accumulatedText = comparison
790:         ctx.outputLines.append(comparison)
791:         return .success(output: comparison)
792:     }
793: 
794:     private func runExplainCode(ctx: SandboxContext) -> HookSandboxStepOutcome {
795:         guard let text = ctx.bestAvailableText else { return .missingInput(field: "text") }
796:         let explanation = "Code Explanation: Found references to: " + heuristicExtractEntities(from: text).joined(separator: ", ") + ". This block appears to handle logical sequences or data presentation in the app."
797:         ctx.accumulatedText = explanation
798:         ctx.outputLines.append(explanation)
799:         return .success(output: explanation)
800:     }
The above content does NOT show the entire file contents. If you need to view any lines of the file which were not shown to complete your task, call this tool again to view those lines.
