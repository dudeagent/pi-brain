#!/usr/bin/env bash
# test.sh — tests for pi-brain scripts (all stubbed; no real installs or downloads)
set -euo pipefail
cd "$(dirname "$0")"

fail=0
ok()   { echo "ok: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }
check_eq() { # desc got want
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3' got '$2')"; fi
}

# syntax check everything
for f in install.sh serve.sh install-ollama.sh; do
  bash -n "$f" && ok "syntax: $f" || bad "syntax: $f"
done

# --- 1. ollama edition: select_model tiers -----------------------------------

eval "$(sed -n '/^log()/,/^# --- main/p' install-ollama.sh | head -n -2)"
for spec in "8192:qwen3:1.7b" "7000:qwen3:1.7b" "6999:qwen3:0.6b" "4096:qwen3:0.6b" "1024:qwen3:0.6b"; do
  ram="${spec%%:*}"; want="${spec#*:}"
  check_eq "ollama select_model ram=${ram}mb" "$(select_model "$ram")" "$want"
done

# --- 2. serve.sh: pick_model ---------------------------------------------------

eval "$(sed -n '/^log()/,/^# --- main/p' serve.sh | head -n -1)"
export MODELS_DIR="$PWD/models" MANIFEST="$PWD/models.manifest.tsv"

# biggest brain that fits wins; manifest sizes used when no files on disk
check_eq "pick 8192mb free -> smollm3-3b, ctx clamped to 8192" \
  "$(MEM_AVAILABLE_MB=8192 pick_model 8192)" \
  "$(printf 'smollm3-3b\tSmolLM3-Q4_K_M.gguf\t8192')"

# mid ram: 3b still fits (1860+700 <= 4000); ctx clamped to the manifest max
check_eq "pick 4000mb free -> smollm3-3b, ctx clamped" \
  "$(pick_model 4000)" \
  "$(printf 'smollm3-3b\tSmolLM3-Q4_K_M.gguf\t8192')"

# just under the 3b threshold -> 1.7b, ctx shrunk to what's left (759mb over budget)
check_eq "pick 2559mb free -> qwen3-1.7b with shrunk ctx" \
  "$(pick_model 2559)" \
  "$(printf 'qwen3-1.7b\tQwen_Qwen3-1.7B-Q4_K_M.gguf\t%d' $(( (2559-1100-700)*1024/112 )))"

# tiny box: nothing fits
if pick_model 1000 >/dev/null 2>&1; then bad "pick 1000mb free should fail"; else ok "pick 1000mb free -> nothing fits"; fi

# --- 3. serve.sh: --print-config end to end -----------------------------------

out="$(MEM_AVAILABLE_MB=3000 bash serve.sh --print-config)"
check_eq "--print-config 3000mb" "$out" "$(printf 'smollm3-3b\tSmolLM3-Q4_K_M.gguf\t%d' $(( (3000-1860-700)*1024/74 )))"

out="$(MEM_AVAILABLE_MB=12000 bash serve.sh --list 2>/dev/null)"
case "$out" in *"would run: smollm3-3b"*) ok "--list 12000mb -> smollm3-3b";; *) bad "--list 12000mb ($out)";; esac

if MEM_AVAILABLE_MB=500 bash serve.sh --print-config 2>/dev/null; then
  bad "--print-config 500mb should exit nonzero"
else
  ok "--print-config 500mb -> graceful failure"
fi

# forced MODEL_FILE
mkdir -p "$PWD/models" && : > "$PWD/models/.keep"
out="$(MEM_AVAILABLE_MB=8192 MODEL_FILE="Qwen_Qwen3-1.7B-Q4_K_M.gguf" bash serve.sh --print-config)"
case "$out" in qwen3-1.7b*) ok "forced MODEL_FILE -> qwen3-1.7b";; *) bad "forced MODEL_FILE ($out)";; esac

# --- 4. install.sh: download_models with a stubbed curl -----------------------

rm -rf /tmp/pi-brain-test && mkdir -p /tmp/pi-brain-test
cat > /tmp/pi-brain-test/fake-manifest.tsv <<'EOF'
# name	file	url	size_mb	min_ram	kb_per_token	max_ctx
fake-a	fake-a.gguf	https://example.invalid/a.gguf	1	999	1	4096
fake-b	fake-b.gguf	https://example.invalid/b.gguf	2	999	1	4096
EOF
cat > /tmp/pi-brain-test/curl <<'EOF'
#!/usr/bin/env bash
out=""
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
echo "fake gguf data" > "${out:?no -o target}"
EOF
chmod +x /tmp/pi-brain-test/curl

eval "$(sed -n '/^log()/,/^# --- main/p' install.sh | head -n -2)"
MANIFEST=/tmp/pi-brain-test/fake-manifest.tsv MODELS_DIR=/tmp/pi-brain-test/models PATH="/tmp/pi-brain-test:$PATH" download_models
for f in fake-a.gguf fake-b.gguf; do
  [ -f "/tmp/pi-brain-test/models/$f" ] && ok "download_models wrote $f" || bad "download_models missing $f"
done
# second pass: everything already on disk, no .part files left
MANIFEST=/tmp/pi-brain-test/fake-manifest.tsv MODELS_DIR=/tmp/pi-brain-test/models PATH="/tmp/pi-brain-test:$PATH" download_models >/dev/null
[ -z "$(ls /tmp/pi-brain-test/models | grep part)" ] && ok "no .part leftovers on re-run" || bad ".part leftovers"

# manifest hygiene: every row has 7 tab-separated fields
while IFS= read -r line; do
  n=$(echo "$line" | awk -F'\t' '{print NF}')
  [ "$n" = "7" ] || bad "manifest row has $n fields (want 7): $line"
done < <(grep -v '^#' models.manifest.tsv | grep -v '^[[:space:]]*$')
ok "manifest rows all well-formed"

rm -rf /tmp/pi-brain-test

if [ "$fail" -ne 0 ]; then echo "FAILURES"; exit 1; fi
echo "all pi-brain tests passed"
