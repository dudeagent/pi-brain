#!/usr/bin/env bash
# pi.sh — one command to run the pi coding agent against the local pi-brain.
#
# usage:
#   ./pi.sh "your prompt here"      # same args as pi; model pre-selected
#   ./pi.sh --setup-only            # just write the models.json entry and exit
#   PORT=9000 ./pi.sh               # serve on a different port
#
# what it does:
#   1. makes sure the local llama-server (serve.sh) is up on :$PORT
#   2. writes a "pi-brain" provider entry into ~/.pi/agent/models.json
#      pointing at http://localhost:$PORT/v1, with the model the server
#      is actually running (chosen by free ram via serve.sh --print-config)
#   3. execs `pi --model pi-brain/<model>` with any extra args passed through
#
set -euo pipefail

log() { echo "[pi-brain] $*" >&2; }
die() { echo "[pi-brain] ERROR: $*" >&2; exit 1; }

PORT="${PORT:-8080}"
BASE_URL="http://localhost:${PORT}/v1"
PROVIDER="pi-brain"
MODELS_FILE="${HOME}/.pi/agent/models.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# overridable so tests can point at a stub (resolved via PATH when bare)
SERVE_SCRIPT="${SERVE_SCRIPT:-${SCRIPT_DIR}/serve.sh}"
SERVER_LOG="${SCRIPT_DIR}/serve.log"

command -v pi >/dev/null 2>&1 || die "pi not found on PATH — install the pi coding agent first"

# --- 1. ensure the local server is running ---------------------------------

server_up() {
  curl -fsS "${BASE_URL}/models" >/dev/null 2>&1
}

start_server() {
  log "no local server on :${PORT}, starting serve.sh in the background..."
  nohup "${SERVE_SCRIPT}" >"$SERVER_LOG" 2>&1 &
  local waited=0
  while ! server_up; do
    waited=$((waited + 1))
    if [ "$waited" -ge 120 ]; then
      die "local server did not come up after 2 minutes — check ${SERVER_LOG}"
    fi
    sleep 1
  done
  log "local server is up on :${PORT} (log: ${SERVER_LOG})"
}

if ! server_up; then
  start_server
else
  log "local server already running on :${PORT}"
fi

# --- 2. write the models.json entry ----------------------------------------

# serve.sh --print-config gives: name<TAB>file<TAB>ctx
CFG="$(${SERVE_SCRIPT} --print-config)" || die "no model fits in current free ram (serve.sh picked nothing)"
MODEL_ID="$(printf '%s' "$CFG" | cut -f1)"
CTX="$(printf '%s' "$CFG" | cut -f3)"

mkdir -p "$(dirname "$MODELS_FILE")"

# merge: keep any existing providers, add/overwrite the pi-brain one.
# no jq dependency — write a fresh minimal file if there isn't a valid one.
write_fresh() {
  cat >"$MODELS_FILE" <<EOF
{
  "providers": {
    "${PROVIDER}": {
      "baseUrl": "${BASE_URL}",
      "api": "openai-completions",
      "apiKey": "pi-brain",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false
      },
      "models": [
        {
          "id": "${MODEL_ID}",
          "name": "${MODEL_ID} (local, ctx=${CTX})",
          "contextWindow": ${CTX},
          "maxTokens": ${CTX},
          "reasoning": false
        }
      ]
    }
  }
}
EOF
}

if command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp)"
  if jq --arg p "$PROVIDER" --arg url "$BASE_URL" \
        --arg id "$MODEL_ID" --arg name "${MODEL_ID} (local, ctx=${CTX})" \
        --argjson ctx "$CTX" \
        '.providers[$p] = {
           baseUrl: $url,
           api: "openai-completions",
           apiKey: "pi-brain",
           compat: { supportsDeveloperRole: false, supportsReasoningEffort: false },
           models: [ { id: $id, name: $name, contextWindow: $ctx, maxTokens: $ctx, reasoning: false } ]
         }' "$MODELS_FILE" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$MODELS_FILE"
  else
    write_fresh
  fi
else
  write_fresh
fi

log "models.json ready: ${MODELS_FILE} -> ${PROVIDER}/${MODEL_ID} (ctx=${CTX})"

[ "${1:-}" = "--setup-only" ] && exit 0

# --- 3. run pi --------------------------------------------------------------

exec pi --model "${PROVIDER}/${MODEL_ID}" "$@"
