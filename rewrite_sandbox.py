import re

with open('Intelligence/HookExecutionSandbox.swift', 'r') as f:
    sandbox = f.read()

# 1. Add HookRuntimeExecutionSource and update HookSandboxResult
new_result_code = """enum HookRuntimeExecutionSource: String, Sendable, Codable {
    case debug
    case generatedContract
    case system
}

struct HookSandboxResult: Sendable {
    let mode: HookSandboxMode
    let chain: [String]
    let steps: [HookSandboxStepResult]
    let success: Bool
    let finalOutput: String?
    let status: ExecutionResultStatus
    let executionMetadata: [String: String]?

    var completedCount: Int { steps.filter(\\.succeeded).count }
    var failedAt: String? { steps.first(where: { !$0.succeeded })?.hookId }
    var failureReason: String? { steps.first(where: { !$0.succeeded })?.outcome.shortLabel }
}"""
sandbox = re.sub(r'struct HookSandboxResult: Sendable \{.*?\n\}', new_result_code, sandbox, flags=re.DOTALL)

# 2. Update SandboxContext
old_ctx = """private final class SandboxContext {
    let snapshot: CanonicalGeneratedExecutionContextSnapshot
    var accumulatedText: String?
    var outputLines: [String] = []
    var metadata: [String: String] = [:]

    init(snapshot: CanonicalGeneratedExecutionContextSnapshot) {
        self.snapshot = snapshot
    }"""
new_ctx = """private final class SandboxContext {
    let snapshot: CanonicalGeneratedExecutionContextSnapshot
    let source: HookRuntimeExecutionSource
    let allowBoundedCapture: Bool
    let visualScheduler: VisualContextScheduler?
    let budgetSnapshot: GeneratedExecutionBudgetSnapshot?
    var accumulatedText: String?
    var outputLines: [String] = []
    var metadata: [String: String] = [:]

    init(snapshot: CanonicalGeneratedExecutionContextSnapshot, source: HookRuntimeExecutionSource = .debug, allowBoundedCapture: Bool = false, visualScheduler: VisualContextScheduler? = nil, budgetSnapshot: GeneratedExecutionBudgetSnapshot? = nil) {
        self.snapshot = snapshot
        self.source = source
        self.allowBoundedCapture = allowBoundedCapture
        self.visualScheduler = visualScheduler
        self.budgetSnapshot = budgetSnapshot
    }"""
sandbox = sandbox.replace(old_ctx, new_ctx)

# 3. Update execute signature
old_exec = """    func execute(
        chain: [String],
        snapshot: CanonicalGeneratedExecutionContextSnapshot,
        mode: HookSandboxMode,
        registry: HookCapabilityRegistry = .shared
    ) async -> HookSandboxResult {"""
new_exec = """    func execute(
        chain: [String],
        snapshot: CanonicalGeneratedExecutionContextSnapshot,
        mode: HookSandboxMode,
        source: HookRuntimeExecutionSource = .debug,
        allowBoundedCapture: Bool = false,
        visualScheduler: VisualContextScheduler? = nil,
        budgetSnapshot: GeneratedExecutionBudgetSnapshot? = nil,
        registry: HookCapabilityRegistry = .shared
    ) async -> HookSandboxResult {"""
sandbox = sandbox.replace(old_exec, new_exec)

# 4. Update execute calls to SandboxContext and HookSandboxResult
sandbox = sandbox.replace("let ctx = SandboxContext(snapshot: snapshot)", "let ctx = SandboxContext(snapshot: snapshot, source: source, allowBoundedCapture: allowBoundedCapture, visualScheduler: visualScheduler, budgetSnapshot: budgetSnapshot)")

sandbox = sandbox.replace(
    "let result = HookSandboxResult(\n                    mode: mode, chain: chain, steps: steps, success: false, finalOutput: partialOutput\n                )",
    "let result = HookSandboxResult(\n                    mode: mode, chain: chain, steps: steps, success: false, finalOutput: partialOutput, status: .failed, executionMetadata: ctx.metadata\n                )"
)

sandbox = sandbox.replace(
    "let result = HookSandboxResult(\n            mode: mode, chain: chain, steps: steps, success: true, finalOutput: finalOutput\n        )",
    "let result = HookSandboxResult(\n            mode: mode, chain: chain, steps: steps, success: true, finalOutput: finalOutput, status: .success, executionMetadata: ctx.metadata\n        )"
)

# 5. Make runHook async
sandbox = sandbox.replace(
    "private func runHook(\n        hookId: String,\n        ctx: SandboxContext,\n        registry: HookCapabilityRegistry\n    ) -> HookSandboxStepOutcome {",
    "private func runHook(\n        hookId: String,\n        ctx: SandboxContext,\n        registry: HookCapabilityRegistry\n    ) async -> HookSandboxStepOutcome {"
)
sandbox = sandbox.replace("let outcome = runHook(hookId: hookId, ctx: ctx, registry: registry)", "let outcome = await runHook(hookId: hookId, ctx: ctx, registry: registry)")

# 6. Add awaits to switch cases
sandbox = sandbox.replace("case \"gather_visible_context_once\": return runGatherVisibleContextOnce(ctx: ctx)", "case \"gather_visible_context_once\": return await runGatherVisibleContextOnce(ctx: ctx)")
sandbox = sandbox.replace("case \"run_ocr_once\":              return runOCROnce(ctx: ctx)", "case \"run_ocr_once\":              return await runOCROnce(ctx: ctx)")

# 7. Update runGatherVisibleContextOnce
old_gather = """    private func runGatherVisibleContextOnce(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let visual = ctx.snapshot.visualContextAvailability.visualSummaryExcerpt
        let ocr = ctx.snapshot.recentOCRExcerpt
        let sel = ctx.snapshot.selectedText

        if let text = visual ?? ocr ?? sel, !text.isEmpty {
            ctx.accumulatedText = text
            let src = visual != nil ? "visual_descriptor" : (ocr != nil ? "ocr_excerpt" : "selected_text")
            return .success(output: "gathered \\(text.utf8.count) bytes from \\(src) (sandbox: read-only, no new capture)")
        }
        return .missingInput(field: "no_visual_ocr_or_selected_text_in_snapshot")
    }"""
new_gather = """    private func runGatherVisibleContextOnce(ctx: SandboxContext) async -> HookSandboxStepOutcome {
        let visual = ctx.snapshot.visualContextAvailability.visualSummaryExcerpt
        let ocr = ctx.snapshot.recentOCRExcerpt
        let sel = ctx.snapshot.selectedText

        if let text = visual ?? ocr ?? sel, !text.isEmpty {
            ctx.accumulatedText = text
            let src = visual != nil ? "visual_descriptor" : (ocr != nil ? "ocr_excerpt" : "selected_text")
            return .success(output: "gathered \\(text.utf8.count) bytes from \\(src) (sandbox: read-only, no new capture)")
        }

        if ctx.source == .generatedContract && ctx.allowBoundedCapture {
            guard let scheduler = ctx.visualScheduler else {
                return .failed(reason: "visual_context_unavailable:no_scheduler")
            }
            let req = BoundedVisualContextRequest(
                reason: "sandbox_gather",
                workflowType: ctx.snapshot.inferredWorkflow,
                intentType: .synthesize,
                requiresOCR: false,
                requiresVisualDescription: true,
                maxWindowSeconds: 5,
                maxOCRCharacters: 0,
                maxDescriptionCharacters: 500,
                budget: ExecutionBudget(allowsVision: true, allowsOCR: false),
                permissionAvailability: ctx.snapshot.permissionAvailability
            )
            if let result = try? await scheduler.collectVisualContext(request: req), let desc = result.visualDescription {
                ctx.accumulatedText = desc
                return .success(output: "gathered \\(desc.utf8.count) bytes via bounded capture")
            }
        }

        return .failed(reason: "visual_context_unavailable:budget_denied")
    }"""
sandbox = sandbox.replace(old_gather, new_gather)

# 8. Update runOCROnce
old_ocr = """    private func runOCROnce(ctx: SandboxContext) -> HookSandboxStepOutcome {
        if let ocr = ctx.snapshot.recentOCRExcerpt, !ocr.isEmpty {
            ctx.accumulatedText = ocr
            return .success(output: "ocr_excerpt \\(ocr.utf8.count) bytes (sandbox: read-only)")
        }
        return .missingInput(field: "recentOCRExcerpt_not_in_snapshot")
    }"""
new_ocr = """    private func runOCROnce(ctx: SandboxContext) async -> HookSandboxStepOutcome {
        if let ocr = ctx.snapshot.recentOCRExcerpt, !ocr.isEmpty {
            ctx.accumulatedText = ocr
            return .success(output: "ocr_excerpt \\(ocr.utf8.count) bytes (sandbox: read-only)")
        }

        if ctx.source == .generatedContract && ctx.allowBoundedCapture {
            guard let scheduler = ctx.visualScheduler else {
                return .failed(reason: "visual_context_unavailable:no_scheduler")
            }
            let req = BoundedVisualContextRequest(
                reason: "sandbox_ocr",
                workflowType: ctx.snapshot.inferredWorkflow,
                intentType: .extract,
                requiresOCR: true,
                requiresVisualDescription: false,
                maxWindowSeconds: 5,
                maxOCRCharacters: 2000,
                maxDescriptionCharacters: 0,
                budget: ExecutionBudget(allowsVision: false, allowsOCR: true),
                permissionAvailability: ctx.snapshot.permissionAvailability
            )
            if let result = try? await scheduler.collectVisualContext(request: req), let ocr = result.ocrText {
                ctx.accumulatedText = ocr
                return .success(output: "ocr_excerpt \\(ocr.utf8.count) bytes via bounded capture")
            }
        }

        return .failed(reason: "ocr_unavailable:budget_denied")
    }"""
sandbox = sandbox.replace(old_ocr, new_ocr)

with open('Intelligence/HookExecutionSandbox.swift', 'w') as f:
    f.write(sandbox)
print("Updated sandbox.")
