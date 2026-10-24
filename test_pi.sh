#!/usr/bin/env bash
# tests for pi.sh — no real server or pi install required.
# pi.sh is run with a stubbed PATH (serve.sh/curl/pi faked) in "warm start"
# mode (server already up), which exercises the config-writing, install-if-missing
# and pi-launch logic. the boot-wait path is trivial and skipped.
set -uo pipefail
failures=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PI_SH="$SCRIPT_DIR/pi.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fakebin="$tmp/bin"; mkdir -p "$fakebin"
home="$tmp/home"; mkdir -p "$home/.pi/agent"

# stub serve.sh: --print-config returns a fixed pick
cat >"$fakebin/serve.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--print-config" ]; then printf 'qwen3-1.7b\tq.gguf\t4096\n'; exit 0; fi
sleep 300
EOF
chmod +x "$fakebin/serve.sh"

# stub curl: server always "up"
cat >"$fakebin/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"data":[]}'
EOF
chmod +x "$fakebin/curl"

# stub pi: records its args, exits 0
cat >"$fakebin/pi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$PI_ARGS_OUT"
EOF
chmod +x "$fakebin/pi"

export SERVER_READY="$tmp/ready"
export PI_ARGS_OUT="$tmp/pi_args"
# /usr/bin:/bin needed: pi.sh uses cat/mktemp and grep-free shell builtins
STUBBED_ENV="PATH=$fakebin:/usr/bin:/bin HOME=$home PI_ARGS_OUT=$PI_ARGS_OUT SERVE_SCRIPT=serve.sh"

# 1. warm start + config write + pi launch
out="$(env $STUBBED_ENV bash "$PI_SH" "hello world" 2>&1)"
echo "$out" | grep -q "already running" && pass "detects running server" || fail "should detect existing server (got: $out)"
echo "$out" | grep -q "models.json ready" && pass "writes models.json" || fail "should log models.json ready"

grep -q '"pi-brain"' "$home/.pi/agent/models.json" && pass "models.json has provider" || fail "models.json missing provider"
grep -q '"baseUrl": "http://localhost:8080/v1"' "$home/.pi/agent/models.json" && pass "correct baseUrl" || fail "wrong baseUrl"
grep -q '"id": "qwen3-1.7b"' "$home/.pi/agent/models.json" && pass "correct model id" || fail "wrong model id"
grep -q '"contextWindow": 4096' "$home/.pi/agent/models.json" && pass "correct ctx" || fail "wrong ctx"
grep -q '"supportsDeveloperRole": false' "$home/.pi/agent/models.json" && pass "compat set" || fail "missing compat"
grep -q '"reasoning": false' "$home/.pi/agent/models.json" && pass "reasoning false" || fail "reasoning should be false"

# 2. pi got the model arg + prompt passthrough
args="$(cat "$PI_ARGS_OUT")"
[ "$args" = "--model pi-brain/qwen3-1.7b hello world" ] && pass "pi invoked with --model + passthrough" || fail "pi args wrong: $args"

# 3. --setup-only does not launch pi
: > "$PI_ARGS_OUT"
env $STUBBED_ENV bash "$PI_SH" --setup-only >/dev/null 2>&1
[ ! -s "$PI_ARGS_OUT" ] && pass "--setup-only does not exec pi" || fail "setup-only launched pi: $(cat "$PI_ARGS_OUT")"

# 4. idempotent rerun keeps a valid provider entry
env $STUBBED_ENV bash "$PI_SH" --setup-only >/dev/null 2>&1
grep -q '"pi-brain"' "$home/.pi/agent/models.json" && pass "rerun keeps provider" || fail "rerun broke models.json"

# 5. pi missing -> installer runs (fake npm), pi lands in PATH and is used
fakebin2="$tmp/bin2"; mkdir -p "$fakebin2"
cp "$fakebin/serve.sh" "$fakebin2/serve.sh"
cp "$fakebin/curl" "$fakebin2/curl"
npmglobal="$home/.npm-global"; mkdir -p "$npmglobal/bin"
cat >"$fakebin2/npm" <<EOF
#!/usr/bin/env bash
# fake npm: on install -g, drop a pi stub into the configured prefix
if [ "\$1" = "install" ] && [ "\$2" = "-g" ]; then
  mkdir -p "$npmglobal/bin"
  printf '#!/bin/bash\nprintf "%%s\\n" "\$*" > "$PI_ARGS_OUT"\n' > "$npmglobal/bin/pi"
  chmod +x "$npmglobal/bin/pi"
  exit 0
fi
if [ "\$1" = "prefix" ] && [ "\$2" = "-g" ]; then echo "$npmglobal"; exit 0; fi
exit 1
EOF
chmod +x "$fakebin2/npm"
: > "$PI_ARGS_OUT"
out2="$(env PATH="$fakebin2:/usr/bin:/bin" HOME="$home" PI_ARGS_OUT="$PI_ARGS_OUT" SERVE_SCRIPT="$fakebin2/serve.sh" bash "$PI_SH" "after install" 2>&1)"
echo "$out2" | grep -q "pi not found" && pass "detects missing pi" || fail "should log pi missing (got: $out2)"
echo "$out2" | grep -q "pi installed" && pass "installs pi via npm" || fail "should log pi installed"
[ -x "$npmglobal/bin/pi" ] && pass "pi created in npm prefix" || fail "no pi in npm prefix"
args2="$(cat "$PI_ARGS_OUT")"
[ "$args2" = "--model pi-brain/qwen3-1.7b after install" ] && pass "pi runs after install" || fail "pi not invoked after install: $args2"

# 6. no npm either -> clear error, no install
fakebin3="$tmp/bin3"; mkdir -p "$fakebin3"
cp "$fakebin/serve.sh" "$fakebin3/serve.sh"
cp "$fakebin/curl" "$fakebin3/curl"
out3="$(env PATH="$fakebin3:/usr/bin:/bin" HOME="$home" PI_ARGS_OUT="$PI_ARGS_OUT" SERVE_SCRIPT="$fakebin3/serve.sh" bash "$PI_SH" "x" 2>&1 || true)"
echo "$out3" | grep -q "no npm/bun found" && pass "clear error without npm/bun" || fail "should error clearly without npm (got: $out3)"

if [ "$failures" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "$failures test(s) FAILED"; exit 1; fi
