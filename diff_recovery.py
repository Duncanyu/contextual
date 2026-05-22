import json

log_path = "/Users/duncanyu/.gemini/antigravity/brain/e585ee1c-0b6f-469a-9acc-4d27bd763f8b/.system_generated/logs/transcript.jsonl"
with open(log_path, "r") as f:
    for line in f:
        data = json.loads(line)
        content = json.dumps(data)
        if "Showing lines 1 to 800" in content and "HookExecutionSandbox.swift" in content:
            with open("recovered_sandbox_1_800.txt", "w") as out:
                out.write(content)
            print("Found!")
            break
