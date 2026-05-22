import re

with open('Intelligence/HookExecutionSandbox.swift', 'r') as f:
    sandbox = f.read()

# Fix 1: gather
sandbox = sandbox.replace("workflowType: ctx.snapshot.inferredWorkflow,", "workflowType: .debugging,")
sandbox = sandbox.replace(
    "if let result = try? await scheduler.collectVisualContext(request: req), let desc = result.visualDescription {",
    "let result = await scheduler.collect(request: req, budgetSnapshot: ctx.budgetSnapshot ?? .idle)\n            if let desc = result.visualDescription {"
)

# Fix 2: ocr
sandbox = sandbox.replace(
    "if let result = try? await scheduler.collectVisualContext(request: req), let ocr = result.ocrText {",
    "let result = await scheduler.collect(request: req, budgetSnapshot: ctx.budgetSnapshot ?? .idle)\n            if let ocr = result.ocrText {"
)

with open('Intelligence/HookExecutionSandbox.swift', 'w') as f:
    f.write(sandbox)
print("Fixed sandbox calls.")
