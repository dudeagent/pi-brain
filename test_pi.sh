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

# minimal toolset for pi.sh's PATH — /usr/bin:/bin would leak the host's real
# node/npm (they exist on this system) into tests that expect them missing
basics="$tmp/basics"; mkdir -p "$basics"
for t in bash sh cat mkdir chmod touch dirname basename cut grep head tail sed awk uname tar sleep nohup env stat true false; do
  p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$basics/$t"
done

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
# basics dir provides everything pi.sh needs without leaking host node/npm
STUBBED_ENV="PATH=$fakebin:$basics HOME=$home PI_ARGS_OUT=$PI_ARGS_OUT SERVE_SCRIPT=serve.sh"

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
# node stub so ensure_node sees node present and skips its own install
cat >"$fakebin2/node" <<'EOF'
#!/usr/bin/env bash
echo "v20.0.0"
EOF
chmod +x "$fakebin2/node"
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
out2="$(env PATH="$fakebin2:$basics" HOME="$home" PI_ARGS_OUT="$PI_ARGS_OUT" SERVE_SCRIPT="$fakebin2/serve.sh" bash "$PI_SH" "after install" 2>&1)"
echo "$out2" | grep -q "pi not found" && pass "detects missing pi" || fail "should log pi missing (got: $out2)"
echo "$out2" | grep -q "pi installed" && pass "installs pi via npm" || fail "should log pi installed"
[ -x "$npmglobal/bin/pi" ] && pass "pi created in npm prefix" || fail "no pi in npm prefix"
args2="$(cat "$PI_ARGS_OUT")"
[ "$args2" = "--model pi-brain/qwen3-1.7b after install" ] && pass "pi runs after install" || fail "pi not invoked after install: $args2"

# 6. no node/npm either -> ensure_node fails at download, clear error
fakebin3="$tmp/bin3"; mkdir -p "$fakebin3"
cp "$fakebin/serve.sh" "$fakebin3/serve.sh"
cp "$fakebin/curl" "$fakebin3/curl"
out3="$(env PATH="$fakebin3:$basics" HOME="$home" PI_ARGS_OUT="$PI_ARGS_OUT" SERVE_SCRIPT="$fakebin3/serve.sh" bash "$PI_SH" "x" 2>&1 || true)"
echo "$out3" | grep -q "install node manually" && pass "clear error without node/npm" || fail "should error clearly without node/npm (got: $out3)"

# 7. ensure_node via apt-get: fake apt installs node+npm stubs, pi.sh proceeds
fakebin4="$tmp/bin4"; mkdir -p "$fakebin4"
cp "$fakebin/serve.sh" "$fakebin4/serve.sh"
cp "$fakebin/curl" "$fakebin4/curl"
# apt-get stub so ensure_node's 'command -v apt-get' check succeeds
# (the sudo stub below intercepts the actual calls)
cat >"$fakebin4/apt-get" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fakebin4/apt-get"
apt_installed="$tmp/apt-installed"
cat >"$fakebin4/sudo" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "apt-get" ]; then
  printf '#!/usr/bin/env bash\necho "v20.0.0"\n' > "$fakebin4/node"
  printf '#!/usr/bin/env bash\necho "fake npm via apt"\n' > "$fakebin4/npm"
  chmod +x "$fakebin4/node" "$fakebin4/npm"
  touch "$apt_installed"
  exit 0
fi
exec "$@"
EOF
chmod +x "$fakebin4/sudo"
: > "$PI_ARGS_OUT"
out4="$(env PATH="$fakebin4:$basics" HOME="$home" PI_ARGS_OUT="$PI_ARGS_OUT" SERVE_SCRIPT="$fakebin4/serve.sh" bash "$PI_SH" "x" 2>&1 || true)"
echo "$out4" | grep -q "node installed via apt" && pass "ensure_node installs node via apt" || fail "should install node via apt (got: $out4)"
[ -f "$apt_installed" ] && pass "apt-get was called" || fail "apt-get not called"

# 8. ensure_node: node present but npm missing -> still triggers install path
fakebin5="$tmp/bin5"; mkdir -p "$fakebin5"
cp "$fakebin/serve.sh" "$fakebin5/serve.sh"
cp "$fakebin/curl" "$fakebin5/curl"
cat >"$fakebin5/node" <<'EOF'
#!/usr/bin/env bash
echo "v20.0.0"
EOF
chmod +x "$fakebin5/node"
out5="$(env PATH="$fakebin5:$basics" HOME="$home" PI_ARGS_OUT="$PI_ARGS_OUT" SERVE_SCRIPT="$fakebin5/serve.sh" bash "$PI_SH" "x" 2>&1 || true)"
echo "$out5" | grep -q "node/npm not found" && pass "node-only still triggers ensure_node" || fail "node without npm should trigger install (got: $out5)"

# 9. ensure_node: static binary fallback when apt is absent
fakebin6="$tmp/bin6"; mkdir -p "$fakebin6"
cp "$fakebin/serve.sh" "$fakebin6/serve.sh"
# fake tar: succeeds without unpacking (curl stub writes the files itself)
cat >"$fakebin6/tar" <<'TAR'
#!/usr/bin/env bash
exit 0
TAR
chmod +x "$fakebin6/tar"
cat >"$fakebin6/curl" <<EOF
#!/usr/bin/env bash
if [[ "\$@" == *"nodejs.org"* ]]; then
  node_dest="$home/.pi-brain/node"
  mkdir -p "\$node_dest/bin"
  printf '#!/usr/bin/env bash\necho "v20.0.0-static"\n' > "\$node_dest/bin/node"
  printf '#!/usr/bin/env bash\necho "fake npm static"\n' > "\$node_dest/bin/npm"
  chmod +x "\$node_dest/bin/node" "\$node_dest/bin/npm"
  exit 0
fi
echo '{"data":[]}'
EOF
chmod +x "$fakebin6/curl"
out6="$(env PATH="$fakebin6:$basics" HOME="$home" PI_ARGS_OUT="$PI_ARGS_OUT" SERVE_SCRIPT="$fakebin6/serve.sh" bash "$PI_SH" "x" 2>&1 || true)"
echo "$out6" | grep -q "installed at" && pass "ensure_node static fallback installs node" || fail "should install node via static binary (got: $out6)"
[ -x "$home/.pi-brain/node/bin/npm" ] && pass "static node created" || fail "no static node"

if [ "$failures" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "$failures test(s) FAILED"; exit 1; fi
