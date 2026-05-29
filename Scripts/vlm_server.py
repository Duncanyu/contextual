#!/usr/bin/env python3
"""
Contextual VLM Perception Server
=================================
Lightweight bridge that exposes a POST /analyze endpoint on localhost:8123
and routes image-analysis requests to a locally running Ollama vision model.

Architecture:
  Swift VLMPerceptionEngine  →  POST :8123/analyze  →  Ollama :11434/api/generate
                              ←  {caption, content_category, confidence}  ←

Model preference order (first one installed in Ollama wins):
  moondream  →  llama3.2-vision  →  llava  →  minicpm-v

Usage:
  python3 Scripts/vlm_server.py
  # or via wrapper script:
  bash Scripts/start_vlm_server.sh
"""

import json
import logging
import sys
import time
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Optional

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PORT = 8123
OLLAMA_BASE = "http://127.0.0.1:11434"
OLLAMA_TIMEOUT_S = 25         # minicpm-v first inference can be slow; 25s budget
HEALTH_OLLAMA_TIMEOUT_S = 2

# Preferred vision models in priority order.
# minicpm-v is preferred: 5.5 GB, better quality than moondream for desktop screenshots.
# moondream is the fast fallback when minicpm-v is not installed.
VISION_MODEL_PREFS = [
    "minicpm-v",
    "llama3.2-vision",
    "llava:7b",
    "llava",
    "moondream",
]

# Desktop-agent perception prompt — compact to fit moondream's 2048-token context.
# Keep this short: image tokens already consume ~300-500 of the 2048-token budget.
# No numbered lists: moondream treats them as fill-in-the-blank prompts.
PROMPT_TEMPLATE = (
    "App: {app}. Window: {title}.\n\n"
    "Describe what is visible on screen. Be specific: name the page/site/document, "
    "mention key text content and any important buttons or input fields. "
    "Write 2-3 concrete sentences.\n"
    "Answer:"
)

# Valid content categories (inferred from app name, not model output)
CATEGORIES = {"browser", "terminal", "ide", "document", "settings", "dashboard", "media", "unknown"}

# App-name → category heuristic (used when model doesn't provide CATEGORY line)
APP_CATEGORY_MAP = {
    "safari": "browser", "firefox": "browser", "chrome": "browser",
    "arc": "browser", "brave": "browser", "opera": "browser", "edge": "browser",
    "terminal": "terminal", "iterm": "terminal", "iterm2": "terminal",
    "alacritty": "terminal", "warp": "terminal", "kitty": "terminal",
    "xcode": "ide", "nova": "ide", "vscode": "ide", "cursor": "ide",
    "jetbrains": "ide", "rubymine": "ide", "pycharm": "ide",
    "pages": "document", "word": "document", "notion": "document",
    "notes": "document", "obsidian": "document", "bear": "document",
    "system preferences": "settings", "system settings": "settings",
    "spotify": "media", "vlc": "media", "quicktime": "media",
    "finder": "dashboard", "launchpad": "dashboard",
}

logging.basicConfig(
    level=logging.INFO,
    format="[VLMServer] %(asctime)s %(message)s",
    datefmt="%H:%M:%S",
    stream=sys.stdout,
)
log = logging.getLogger("vlm_server")

# ---------------------------------------------------------------------------
# Model detection (module-level state, set once at startup)
# ---------------------------------------------------------------------------

_active_model: Optional[str] = None


def detect_vision_model() -> Optional[str]:
    """Query Ollama for installed models; return first match from preference list."""
    try:
        req = urllib.request.Request(f"{OLLAMA_BASE}/api/tags", method="GET")
        with urllib.request.urlopen(req, timeout=HEALTH_OLLAMA_TIMEOUT_S) as resp:
            data = json.loads(resp.read())
            installed_names = [m["name"] for m in data.get("models", [])]
            log.info("Ollama installed models: %s", installed_names)
            for pref in VISION_MODEL_PREFS:
                for name in installed_names:
                    if pref.split(":")[0] in name:
                        return name
    except Exception as exc:
        log.warning("Cannot reach Ollama at %s: %s", OLLAMA_BASE, exc)
    return None


def ollama_generate(model: str, prompt: str, image_b64: str) -> str:
    """
    Call Ollama /api/generate with a single image.
    Returns the raw response text (may be empty string on failure).
    """
    body = json.dumps({
        "model": model,
        "prompt": prompt,
        "images": [image_b64],
        "stream": False,
        "options": {
            "num_predict": 220,   # enough for 2-4 rich sentences
            "temperature": 0.15,
            "top_p": 0.90,
            "repeat_penalty": 1.1,
        },
    }).encode()

    req = urllib.request.Request(
        f"{OLLAMA_BASE}/api/generate",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        print("[VLMServer] inference_started", flush=True)
        t0 = time.time()
        with urllib.request.urlopen(req, timeout=OLLAMA_TIMEOUT_S) as resp:
            result = json.loads(resp.read())
            raw = result.get("response", "").strip()
            elapsed_ms = int((time.time() - t0) * 1000)
            print(f"[VLMServer] inference_completed latency_ms={elapsed_ms} chars={len(raw)}", flush=True)
            return raw
    except urllib.error.URLError as exc:
        reason = "timeout" if "timed out" in str(exc).lower() else "connection_error"
        print(f"[VLMServer] inference_failed reason={reason} detail={exc}", flush=True)
        log.error("Ollama generate failed: %s", exc)
        return ""
    except Exception as exc:
        print(f"[VLMServer] inference_failed reason=unexpected_error detail={exc}", flush=True)
        log.error("Ollama generate unexpected error: %s", exc)
        return ""


def infer_category_from_app(app_name: str) -> str:
    """Heuristic: map active-app name to a content category."""
    lower = app_name.lower()
    for key, cat in APP_CATEGORY_MAP.items():
        if key in lower:
            return cat
    return "unknown"


def parse_vlm_response(raw: str, app_name: str = "") -> tuple[str, str]:
    """
    Extract (caption, category) from VLM output.

    The new prompt does NOT require a CATEGORY line, so we:
    1. Use the full response as the caption (primary path).
    2. If the model happens to include "CATEGORY: <x>", extract it and strip it.
    3. Fall back to app-name heuristic for category.
    4. Never emit a caption that is only the CATEGORY line itself.
    """
    caption = raw.strip()
    category = infer_category_from_app(app_name)

    # Optional: model may still emit "CATEGORY: ..." at the end.
    upper = raw.upper()
    if "CATEGORY:" in upper:
        idx = upper.index("CATEGORY:")
        caption_part = raw[:idx].strip()
        cat_part     = raw[idx + len("CATEGORY:"):].strip().lower()

        # Only use caption_part if it contains a real description (≥ 20 chars).
        if len(caption_part) >= 20:
            caption = caption_part

        # Extract explicit category if provided.
        for c in CATEGORIES:
            if c in cat_part:
                category = c
                break

    # Guard: if caption still looks like only a CATEGORY tag, keep the full raw.
    if caption.upper().startswith("CATEGORY:") or len(caption.strip()) < 10:
        caption = raw.strip()

    # Truncate to safe length.
    caption = caption[:400] if caption else raw[:400]
    return caption, category


# ---------------------------------------------------------------------------
# HTTP Handler
# ---------------------------------------------------------------------------

class VLMHandler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):  # suppress default request log noise
        pass

    # ---- GET /health -------------------------------------------------------

    def do_GET(self):  # noqa: N802
        if self.path == "/health":
            self._health()
        else:
            self._json(404, {"error": "not found"})

    def _health(self):
        ok = _active_model is not None
        self._json(200, {
            "ok": ok,
            "model": _active_model or "none",
            "loaded": ok,
            "ollama": OLLAMA_BASE,
        })

    # ---- POST /analyze -----------------------------------------------------

    def do_POST(self):  # noqa: N802
        if self.path != "/analyze":
            self._json(404, {"error": "not found"})
            return
        self._analyze()

    def _analyze(self):
        # Read body
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length))
        except Exception:
            self._json(400, {"error": "invalid JSON body"})
            return

        app_name   = body.get("app", "unknown")
        title      = body.get("title", "")
        image_b64  = body.get("image_base64", "")

        if not image_b64:
            self._json(400, {"error": "missing image_base64"})
            return

        if not _active_model:
            log.warning("No vision model available — returning 503")
            self._json(503, {"error": "no vision model available", "hint": "ollama pull moondream"})
            return

        # Build prompt and call Ollama
        prompt = PROMPT_TEMPLATE.format(app=app_name, title=title)
        t0 = time.time()
        raw_response = ollama_generate(_active_model, prompt, image_b64)
        latency_ms = int((time.time() - t0) * 1000)

        # Log raw model output BEFORE parsing so we can debug model quality vs parser issues.
        raw_preview = raw_response[:200].replace("\n", " ") if raw_response else ""
        print(f'[VLMRawResponse] text="{raw_preview}"', flush=True)

        if not raw_response:
            print("[VLMServer] inference_failed reason=empty_response", flush=True)
            self._json(503, {"error": "ollama generate returned empty response"})
            return

        caption, category = parse_vlm_response(raw_response, app_name=app_name)

        log.info("analyzed app=%s latency_ms=%d category=%s caption_chars=%d",
                 app_name, latency_ms, category, len(caption))

        self._json(200, {
            "caption": caption,
            "content_category": category,
            "confidence": 0.75,
            "latency_ms": latency_ms,
            "model": _active_model,
        })

    # ---- helpers -----------------------------------------------------------

    def _json(self, status: int, obj: dict):
        payload = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    global _active_model

    log.info("Starting Contextual VLM Perception Server on port %d", PORT)
    log.info("Detecting vision model from Ollama at %s ...", OLLAMA_BASE)

    _active_model = detect_vision_model()

    if _active_model:
        log.info("Model selected: %s", _active_model)
    else:
        log.warning("No vision model found in Ollama.")
        log.warning("Install one with:  ollama pull moondream")
        log.warning("Server will start but /analyze returns 503 until a model is available.")

    server = HTTPServer(("127.0.0.1", PORT), VLMHandler)
    log.info("Listening on http://127.0.0.1:%d", PORT)
    log.info("Endpoints:  GET /health   POST /analyze")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Stopped.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
