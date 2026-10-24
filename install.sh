#!/usr/bin/env bash
# install.sh — pi-brain, fully local edition.
#
# philosophy: everything lives on the disk. the internet is only needed once.
#   1. builds llama.cpp from source (neon-optimized for your exact cpu)
#   2. downloads EVERY model in models.manifest.tsv onto the disk (models/)
#   3. leaves the picking to serve.sh — at run time it decides which model
#      actually fits in the ram available right now
#
# no ollama, no registry, no daemon. just gguf files and a server binary.
#
# usage:
#   ./install.sh                        # build + download everything
#   SKIP_BUILD=1 ./install.sh           # only (re)download models
#   MODELS="qwen3-0.6b" ./install.sh    # download a subset (space separated)
#   MODELS_DIR=/data/models ./install.sh
#
set -euo pipefail

log() { echo "[pi-brain] $*"; }
die() { echo "[pi-brain] ERROR: $*" >&2; exit 1; }

LLAMA_REF="${LLAMA_REF:-master}"
MODELS_DIR="${MODELS_DIR:-$(pwd)/models}"
MANIFEST="${MANIFEST:-$(pwd)/models.manifest.tsv}"
BUILD_DIR="${BUILD_DIR:-$(pwd)/llama.cpp}"

get_ram_mb() { awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo; }

# rows of the manifest as tab fields, comments/blank lines stripped
manifest_rows() { grep -v '^#' "$MANIFEST" | grep -v '^[[:space:]]*$'; }

# --- 1. build llama.cpp -----------------------------------------------------

install_build_deps() {
  if command -v cmake >/dev/null 2>&1 && command -v make >/dev/null 2>&1; then
    return
  fi
  log "installing build deps (cmake, build-essential)..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq build-essential cmake git curl
  else
    die "no apt-get and no cmake/make — install build-essential + cmake, or set SKIP_BUILD=1"
  fi
}

build_llama_cpp() {
  if [ -f "$BUILD_DIR/build/bin/llama-server" ]; then
    log "llama.cpp already built at $BUILD_DIR/build/bin"
    return
  fi
  if [ ! -d "$BUILD_DIR" ]; then
    log "cloning llama.cpp (${LLAMA_REF})..."
    git clone --depth 1 --branch "$LLAMA_REF" https://github.com/ggml-org/llama.cpp "$BUILD_DIR"
  fi
  log "building llama.cpp (this is the slow part; GGML_NATIVE=on so it's tuned for your cpu)..."
  cmake -S "$BUILD_DIR" -B "$BUILD_DIR/build" -DGGML_NATIVE=ON -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=ON >/dev/null
  cmake --build "$BUILD_DIR/build" --config Release -j "$(nproc)" >/dev/null
  log "built: $BUILD_DIR/build/bin/llama-server"
}

# --- 2. download every model onto the disk ---------------------------------

download_models() {
  mkdir -p "$MODELS_DIR"
  local want="${MODELS:-}"
  local total_missing=0
  while IFS=$'\t' read -r name file url size_mb min_ram kb_per_token max_ctx; do
    if [ -n "$want" ] && ! echo " $want " | grep -q " $name "; then
      log "skip $name (not in MODELS)"
      continue
    fi
    local dest="$MODELS_DIR/$file"
    if [ -f "$dest" ]; then
      local actual
      actual=$(stat -c%s "$dest" 2>/dev/null || echo 0)
      local expect=$((size_mb * 1024 * 1024))
      # allow 2% slop vs the manifest's approximate size
      if [ "$actual" -ge $((expect * 98 / 100)) ]; then
        log "have $name ($file, $((actual / 1024 / 1024))mb)"
        continue
      fi
      log "$name looks truncated ($actual bytes) — resuming download"
    fi
    log "downloading $name ($size_mb mb) to $dest..."
    curl -fL -C - --retry 5 --retry-delay 3 -o "$dest.part" "$url" || die "download failed: $url"
    mv "$dest.part" "$dest"
    log "got $name"
    total_missing=$((total_missing + 1))
  done < <(manifest_rows)
  log "model dir: $MODELS_DIR ($(du -sh "$MODELS_DIR" 2>/dev/null | cut -f1) on disk)"
}

# --- main -------------------------------------------------------------------

main() {
  if [ "$(uname -m)" != "aarch64" ] && [ "$(uname -m)" != "armv7l" ]; then
    log "warning: not an arm machine ($(uname -m)); continuing anyway (fine for a vps/test)"
  fi
  RAM_MB="$(get_ram_mb)"
  log "ram: ${RAM_MB}mb (informational — serve.sh re-checks free ram at run time)"

  if [ "${SKIP_BUILD:-0}" != "1" ]; then
    install_build_deps
    build_llama_cpp
  else
    log "SKIP_BUILD=1 — assuming llama-server is already on PATH or built"
  fi

  download_models

  log "done. run the brain with:"
  echo
  echo "  ./serve.sh            # picks the best model for current free ram and serves it on :8080"
  echo "  ./serve.sh --list     # show which model would run without starting anything"
  echo
  log "tip: everything is on the disk now — you can pull the network cable."
}

main "$@"
