# Contextual VLM Perception Server

Local-only image-analysis server that powers `[VLMPerception]` and `[VLMCaption]` logs
in the DirectAgentRuntime.

## Architecture

```
Swift VLMPerceptionEngine
  → GET  :8123/health        (300 ms timeout, cached 30 s)
  → POST :8123/analyze       (2.5 s timeout)
        ↓
  Scripts/vlm_server.py
        ↓
  Ollama :11434/api/generate
        ↓
  moondream (or llava / llama3.2-vision)
```

No cloud APIs. No GPU required (Apple Silicon Neural Engine / CPU only).

---

## Install dependencies

```bash
# 1. Ollama (manages local model weights)
brew install ollama

# 2. Pull the preferred vision model (~1.7 GB, one-time download)
ollama pull moondream
```

`vlm_server.py` uses only Python stdlib — no pip dependencies needed.

---

## Start the server

```bash
# Starts Ollama if not running, pulls moondream if missing, then serves
bash Scripts/start_vlm_server.sh
```

The script runs in the foreground and auto-restarts on crash. Run it in a
separate terminal or add it to Login Items.

---

## Test with curl

### Health check

```bash
curl -s http://127.0.0.1:8123/health | python3 -m json.tool
```

Expected response:
```json
{
  "ok": true,
  "model": "moondream:latest",
  "loaded": true,
  "ollama": "http://127.0.0.1:11434"
}
```

### Analyze a screenshot

```bash
# Capture the current screen to PNG
screencapture -x /tmp/test_screen.png

# Encode and analyze
IMAGE_B64=$(base64 -i /tmp/test_screen.png)

curl -s -X POST http://127.0.0.1:8123/analyze \
  -H 'Content-Type: application/json' \
  -d "{
    \"app\": \"Safari\",
    \"title\": \"Test Page\",
    \"image_base64\": \"$IMAGE_B64\"
  }" | python3 -m json.tool
```

Expected response:
```json
{
  "caption": "A macOS Safari window showing a web page with navigation bar...",
  "content_category": "browser",
  "confidence": 0.75,
  "latency_ms": 1240,
  "model": "moondream:latest"
}
```

---

## Expected Contextual logs when working

```
[VLMPerception] enabled=yes endpoint=http://127.0.0.1:8123/analyze
[VLMPerception] health_ok=yes model=moondream:latest
[VLMPerception] completed caption_chars=142 latency_ms=1340 model=moondream:latest
[VLMCaption] caption="A macOS desktop showing GitHub profile page with pinned repositories..."
```

## Expected logs when server is down

```
[VLMPerception] enabled=yes endpoint=http://127.0.0.1:8123/analyze
[VLMPerception] health_ok=no reason=server_unavailable
[VLMPerception] skipped reason=server_unavailable
```

The `DirectAgentLoop` continues normally — VLM is additive, never blocking.

---

## Alternative vision models

If `moondream` is unavailable, the server auto-selects the first installed model
from this preference list:

| Model | Size | Notes |
|---|---|---|
| `moondream` | ~1.7 GB | Best for screen description |
| `llama3.2-vision` | ~8 GB | Higher quality, slower |
| `llava:7b` | ~4 GB | General-purpose |
| `minicpm-v` | ~5.5 GB | Good quality |

```bash
# Install alternatives
ollama pull llama3.2-vision
ollama pull llava:7b
```

---

## Tuning

| Variable | Default | Description |
|---|---|---|
| `CONTEXTUAL_VLM_ENDPOINT` | `http://127.0.0.1:8123/analyze` | Override analyze URL |
| `CONTEXTUAL_VLM_ENABLED` | `1` | Set to `0` to disable VLM entirely |

Health cache TTL is 30 s (hardcoded in `VLMPerceptionEngine.swift`).
Analyze timeout is 2.5 s — VLM inference is skipped if exceeded.
