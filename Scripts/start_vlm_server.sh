#!/usr/bin/env bash
# =============================================================================
# Contextual VLM Perception Server — startup script
# =============================================================================
#
# USAGE
#   bash Scripts/start_vlm_server.sh
#
# WHAT IT DOES
#   1. Ensures Ollama is running
#   2. Pulls moondream (vision model) if not already installed
#   3. Starts vlm_server.py on localhost:8123 (restarts on crash)
#
# DEPENDENCIES
#   - ollama (brew install ollama)
#   - python3 (system or homebrew)
#
# TESTING
#   curl http://127.0.0.1:8123/health
#   curl -s -X POST http://127.0.0.1:8123/analyze \
#     -H 'Content-Type: application/json' \
#     -d '{"app":"Safari","title":"Test","image_base64":"'"$(
#       python3 -c "import base64; print(base64.b64encode(open('/tmp/test.png','rb').read()).decode())" 2>/dev/null
#     )"'"}' | python3 -m json.tool
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SERVER_PY="$SCRIPT_DIR/vlm_server.py"
PORT=8123
PREFERRED_MODEL="moondream"

log() { echo "[start_vlm_server] $*"; }

# ---------------------------------------------------------------------------
# 1. Ensure Ollama is running
# ---------------------------------------------------------------------------
if ! pgrep -x "ollama" > /dev/null 2>&1; then
    log "Ollama is not running — starting it now..."
    OLLAMA_HOST=127.0.0.1 ollama serve > /tmp/ollama.log 2>&1 &
    sleep 2
    log "Ollama started (log: /tmp/ollama.log)"
else
    log "Ollama is already running"
fi

# Verify Ollama API is reachable
if ! curl -sf http://127.0.0.1:11434/api/tags > /dev/null 2>&1; then
    log "ERROR: Ollama API not reachable at :11434 — check /tmp/ollama.log"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Pull vision model if not already installed
# ---------------------------------------------------------------------------
INSTALLED=$(curl -sf http://127.0.0.1:11434/api/tags \
    | python3 -c "import sys,json; tags=json.load(sys.stdin); print(' '.join(m['name'] for m in tags.get('models',[])))" 2>/dev/null || echo "")

if echo "$INSTALLED" | grep -q "$PREFERRED_MODEL"; then
    log "Vision model '$PREFERRED_MODEL' already installed"
else
    log "Pulling vision model '$PREFERRED_MODEL' (this may take a few minutes the first time)..."
    ollama pull "$PREFERRED_MODEL"
    log "Model '$PREFERRED_MODEL' ready"
fi

# ---------------------------------------------------------------------------
# 3. Kill any existing vlm_server on port 8123
# ---------------------------------------------------------------------------
EXISTING_PID=$(lsof -ti tcp:$PORT 2>/dev/null || true)
if [ -n "$EXISTING_PID" ]; then
    log "Killing existing process on port $PORT (PID $EXISTING_PID)"
    kill "$EXISTING_PID" 2>/dev/null || true
    sleep 1
fi

# ---------------------------------------------------------------------------
# 4. Start the Python VLM server (with restart-on-crash loop)
# ---------------------------------------------------------------------------
log "Starting vlm_server.py on http://127.0.0.1:$PORT ..."
echo "[VLMServer] starting"

_crash_count=0
while true; do
    python3 "$SERVER_PY"
    _exit=$?
    _crash_count=$((_crash_count + 1))
    if [ $_exit -ne 0 ]; then
        echo "[VLMServer] crashed exit_code=$_exit crash_count=$_crash_count"
        log "vlm_server.py crashed (exit=$_exit, crash #$_crash_count) — restarting in 3 seconds..."
    else
        echo "[VLMServer] stopped exit_code=0"
        log "vlm_server.py stopped cleanly — restarting in 3 seconds..."
    fi
    echo "[VLMServer] restarting delay_s=3 crash_count=$_crash_count"
    sleep 3
done
