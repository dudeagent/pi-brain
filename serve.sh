#!/usr/bin/env bash
# serve.sh — decide which brain to run, then run it.
#
# every model file is already on the disk (see install.sh). this script checks
# the ram available RIGHT NOW and picks the biggest model that actually fits,
# sizing the context window to whatever ram is left over. no internet needed.
#
# usage:
#   ./serve.sh               # pick + serve on :8080 (openai-compatible)
#   ./serve.sh --list        # just show what would run for current free ram
#   ./serve.sh --print-config  # print 'name<TAB>file<TAB>ctx' and exit (for scripts/tests)
#   MODEL_FILE=models/xyz.gguf ./serve.sh    # force a specific file
#   PORT=9000 ./serve.sh
#
set -euo pipefail

log() { echo "[pi-brain] $*" >&2; }
die() { echo "[pi-brain] ERROR: $*" >&2; exit 1; }

MODELS_DIR="${MODELS_DIR:-$(pwd)/models}"
MANIFEST="${MANIFEST:-$(pwd)/models.manifest.tsv}"
SERVER_OVERHEAD_MB="${SERVER_OVERHEAD_MB:-700}"   # llama-server + compute buffers + system
MIN_CTX="${MIN_CTX:-512}"
PORT="${PORT:-8080}"

# ram available right now (not total!) — overridable for tests
get_mem_available_mb() {
  if [ -n "${MEM_AVAILABLE_MB:-}" ]; then echo "$MEM_AVAILABLE_MB"; return; fi
  awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo
}

manifest_rows() { grep -v '^#' "$MANIFEST" | grep -v '^[[:space:]]*$'; }

# size of a model file in mb: prefer the real file on disk, fall back to manifest
file_size_mb() {
  local dest="$MODELS_DIR/$1" manifest_mb="$2"
  if [ -f "$dest" ]; then echo $(( $(stat -c%s "$dest") / 1024 / 1024 )); else echo "$manifest_mb"; fi
}

# pick the biggest model that fits: prints 'name<TAB>file<TAB>ctx' or returns 1.
pick_model() {
  local avail_mb="$1"
  local picked
  # reverse order = try the biggest brain first; capture the first (biggest) row that fits
  picked="$(tac < <(manifest_rows) | while IFS=$'\t' read -r name file url size_mb min_ram kb_per_token max_ctx; do
    local gguf_mb ctx
    gguf_mb=$(file_size_mb "$file" "$size_mb")
    # is there room for the model + our overhead at all?
    [ $((gguf_mb + SERVER_OVERHEAD_MB)) -le "$avail_mb" ] || continue
    ctx=$(( (avail_mb - gguf_mb - SERVER_OVERHEAD_MB) * 1024 / kb_per_token ))
    [ "$ctx" -gt "$max_ctx" ] && ctx="$max_ctx"
    [ "$ctx" -ge "$MIN_CTX" ] || continue
    printf '%s\t%s\t%s\n' "$name" "$file" "$ctx"
    break
  done)"
  if [ -z "$picked" ]; then
    return 1
  fi
  printf '%s\n' "$picked"
}

# --- main -------------------------------------------------------------------

main() {
  [ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST (run ./install.sh first)"

  if [ "${1:-}" = "--list" ] || [ "${1:-}" = "--print-config" ]; then
    MODE="$1"
  else
    MODE=""
  fi

  AVAIL_MB="$(get_mem_available_mb)"

  if [ -n "${MODEL_FILE:-}" ]; then
    # forced file: find its row and size the ctx the usual way
    while IFS=$'\t' read -r name file url size_mb min_ram kb_per_token max_ctx; do
      if [ "$file" = "$(basename "$MODEL_FILE")" ] || [ "$file" = "$MODEL_FILE" ]; then
        PICKED_NAME="$name"; PICKED_FILE="$file"; PICKED_KB="$kb_per_token"; PICKED_MAX="$max_ctx"
      fi
    done < <(manifest_rows)
    [ -n "${PICKED_NAME:-}" ] || die "MODEL_FILE=$MODEL_FILE not found in manifest"
    PICKED_CTX=$(( (AVAIL_MB - $(file_size_mb "$PICKED_FILE" 0) - SERVER_OVERHEAD_MB) * 1024 / PICKED_KB ))
    [ "$PICKED_CTX" -gt "$PICKED_MAX" ] && PICKED_CTX="$PICKED_MAX"
    [ "$PICKED_CTX" -ge "$MIN_CTX" ] || die "not enough ram for $MODEL_FILE (${AVAIL_MB}mb available)"
  else
    if ! PICKED="$(pick_model "$AVAIL_MB")"; then
      die "no model fits in ${AVAIL_MB}mb of free ram (need at least ~${SERVER_OVERHEAD_MB} + smallest gguf). close things, add swap, or get a bigger pi."
    fi
    PICKED_NAME="$(echo "$PICKED" | cut -f1)"
    PICKED_FILE="$(echo "$PICKED" | cut -f2)"
    PICKED_CTX="$(echo "$PICKED" | cut -f3)"
  fi

  if [ "$MODE" = "--list" ]; then
    log "free ram: ${AVAIL_MB}mb"
    echo "would run: $PICKED_NAME ($PICKED_FILE) with ctx=$PICKED_CTX"
    exit 0
  fi

  if [ "$MODE" = "--print-config" ]; then
    printf '%s\t%s\t%s\n' "$PICKED_NAME" "$PICKED_FILE" "$PICKED_CTX"
    exit 0
  fi

  MODEL_PATH="$MODELS_DIR/$PICKED_FILE"
  [ -f "$MODEL_PATH" ] || die "model file missing: $MODEL_PATH (run ./install.sh first)"

  # locate the server binary: LLAMA_SERVER env > PATH > local build
  if [ -n "${LLAMA_SERVER:-}" ]; then
    LLAMA_SERVER_BIN="$LLAMA_SERVER"
  elif command -v llama-server >/dev/null 2>&1; then
    LLAMA_SERVER_BIN="llama-server"
  elif [ -x "$(pwd)/llama.cpp/build/bin/llama-server" ]; then
    LLAMA_SERVER_BIN="$(pwd)/llama.cpp/build/bin/llama-server"
  else
    die "llama-server not found (build it with ./install.sh or set LLAMA_SERVER=...)"
  fi

  log "free ram: ${AVAIL_MB}mb -> running $PICKED_NAME (ctx=$PICKED_CTX) on port $PORT"
  log "api: http://localhost:$PORT/v1"

  exec "$LLAMA_SERVER_BIN" \
    -m "$MODEL_PATH" \
    -c "$PICKED_CTX" \
    -t "$(nproc)" \
    --parallel 1 \
    --host 127.0.0.1 \
    --port "$PORT" \
    --jinja
}

main "$@"
