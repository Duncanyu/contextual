import re

with open('Intelligence/HookExecutionSandbox.swift', 'r') as f:
    sandbox = f.read()

sandbox = sandbox.replace("if let desc = result.visualDescription {", "if let desc = result.visualSummary {")
sandbox = sandbox.replace("if let ocr = result.ocrText {", "if let ocr = result.ocrExcerpt {")

with open('Intelligence/HookExecutionSandbox.swift', 'w') as f:
    f.write(sandbox)
print("Fixed sandbox fields.")
