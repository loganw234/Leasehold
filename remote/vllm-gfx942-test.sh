#!/usr/bin/env bash
# Tests Lemonade's vLLM backend on an MI300X (gfx942) and collects evidence for an upstream PR.
#
#   1. Builds lemonade-sdk/lemonade from source with vllm-enable-gfx942.patch applied (it adds
#      gfx942 to the vLLM support list) and runs the vLLM CDNA unit test.
#   2. Regenerates Lemonade's generated docs so the change passes CI, and saves the full diff.
#   3. Runs the patched server in place of the packaged one. For each vLLM-ROCm release under
#      test: install it, load a small model, chat. The first release that works also gets the
#      big FP8 model with chat, tool-call and speed tests.
#   4. Writes everything to /root/vllm-gfx942-report/, then restarts the packaged server.
#
# Run as root after setup-lemonade.sh. leasehold.ps1 vllm-test uploads it and runs it detached.
# Expect about an hour: a source build, about 4 GB per vLLM release, and a 36 GB model.
#
# Settings (environment variables):
#   LEMONADE_REF     branch or tag of lemonade-sdk/lemonade to build     (default: main)
#   PINS             vLLM-ROCm releases to test, space-separated. "builtin" is Lemonade's own
#                    default for gfx942 (vllm0.19.1-rocm7.13.0-gfx942 as of Nov 2026).
#                    (default: builtin, then the Aug 2026 nightly gfx942 release)
#   SMALL_MODEL      quick model tried on every release            (default: Qwen3.5-0.8B-FP16-vLLM)
#   BIG_MODEL        model for the first release that works; set to empty to skip
#                                                                  (default: Qwen3.6-35B-A3B-FP8-vLLM-lowconc)
#   KEEP_DEV_SERVER=1  leave the patched server running on port 13305 afterwards, so you can
#                    point Claude Code at the vLLM model through the tunnel
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HERE/lib.sh"

NIGHTLY_GFX942='vllm0.23.1.dev0+rocm7.15.0a20260721.g0fc695fc6.d20260723-rocm7.15.0-gfx942'
LEMONADE_REF=${LEMONADE_REF:-main}
PINS=${PINS:-"builtin $NIGHTLY_GFX942"}
SMALL_MODEL=${SMALL_MODEL:-Qwen3.5-0.8B-FP16-vLLM}
BIG_MODEL=${BIG_MODEL-Qwen3.6-35B-A3B-FP8-vLLM-lowconc}
KEEP_DEV_SERVER=${KEEP_DEV_SERVER:-0}
PATCH=${PATCH:-$HERE/vllm-enable-gfx942.patch}

SRC=/root/lemonade-src
REPORT=/root/vllm-gfx942-report
SUMMARY=$REPORT/summary.md
DEV_UNIT=lemond-dev
LCLI=$SRC/build/lemonade

require_root
mkdir -p "$REPORT"
exec > >(tee -a "$REPORT/run.log") 2>&1

# Appends one row to the results table: release, step, result, detail.
row() {
  local detail
  detail=$(printf '%s' "${4:-}" | tr '\n\r|' '   ' | cut -c1-240)
  printf '| %s | %s | %s | %s |\n' "$1" "$2" "$3" "$detail" >>"$SUMMARY"
}
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-80; }
short() { local p=$1; ((${#p} > 44)) && p="${p:0:30}...${p: -11}"; printf '%s' "$p"; }

# Imports the installed vLLM bundle's Python packages directly, outside Lemonade, so a broken
# bundle shows its own error. Best effort: skipped if the bundle layout isn't recognised.
bundle_check() {
  local exe py
  exe=$(find /root/.cache/lemonade /var/cache/lemonade -type f -name vllm-server 2>/dev/null | head -1 || true)
  [[ -n "$exe" ]] || { echo "vllm-server not found under the cache dirs; skipped"; return 0; }
  py=$(head -1 "$exe" | sed -n 's|^#! *\([^ ]*python[^ ]*\).*|\1|p')
  [[ -x "$py" ]] || py=$(find "$(dirname "$exe")" "$(dirname "$(dirname "$exe")")" -maxdepth 2 \
    -type f -name 'python3*' -perm -u+x 2>/dev/null | head -1 || true)
  [[ -x "$py" ]] || { echo "bundled python not found next to $exe; skipped"; return 0; }
  echo "bundle: $exe"
  PYTHONNOUSERSITE=1 timeout 600 "$py" -c '
import importlib
for name in ("torch", "tokenizers", "transformers", "vllm"):
    try:
        mod = importlib.import_module(name)
        print(name, getattr(mod, "__version__", "?"), "ok")
    except Exception as exc:
        print(name, "FAILED:", type(exc).__name__, str(exc)[:300])
' 2>&1 | tail -8
}

save_server_log() {  # pin since
  journalctl -u "$DEV_UNIT" --since "$2" --no-pager >"$REPORT/server-$(slug "$1").log" 2>&1 || true
  grep -m6 -E 'undefined symbol|ImportError|ModuleNotFoundError|tokenizers|Traceback|HIP error|out of memory' \
    "$REPORT/server-$(slug "$1").log" || true
}

restore() {
  if [[ "$KEEP_DEV_SERVER" == 1 ]]; then
    info "KEEP_DEV_SERVER=1: the patched server stays up on port $LEMONADE_PORT."
    info "Stop it with: systemctl stop $DEV_UNIT && systemctl start ${PKG_UNIT:-lemond.service}"
    return
  fi
  systemctl stop "$DEV_UNIT" >/dev/null 2>&1 || true
  pkill -9 -f 'VLLM::EngineCor' 2>/dev/null || true
  if [[ -n "${PKG_UNIT:-}" ]]; then systemctl start "$PKG_UNIT" || true; fi
}

# ---------------------------------------------------------------------------------------------
log "Preflight"
GFX=$(detect_gfx) || die "No AMD GPU found in /sys/class/kfd."
[[ "$GFX" == gfx942 ]] || die "This test is for gfx942 (MI300X); this GPU is $GFX."
[[ -f "$PATCH" ]] || die "Patch not found: $PATCH"
sed -i 's/\r$//' "$PATCH"
avail_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
((avail_gb >= 120)) || die "Need about 120 GB free on / for builds, bundles and models (have ${avail_gb} GB)."
PKG_UNIT=$(lemond_unit)

cat >"$SUMMARY" <<EOF
# vLLM on MI300X (gfx942): Lemonade test results

| Release | Step | Result | Detail |
|---|---|---|---|
EOF
{
  echo "date (UTC): $(date -u +%FT%TZ)"
  echo "gpu: $GFX"
  command -v rocminfo >/dev/null && rocminfo 2>/dev/null | grep -E 'Marketing Name:.*(MI|Instinct)' | sort -u | sed 's/^ */rocminfo /'
  echo "kernel: $(uname -r)"
  echo "os: $(. /etc/os-release && echo "$PRETTY_NAME")"
  [[ -r /opt/rocm/.info/version ]] && echo "system rocm: $(cat /opt/rocm/.info/version)"
  echo "packaged lemonade: $(lemonade --version 2>&1 | head -1)"
} >"$REPORT/env.txt"
cat "$REPORT/env.txt"

log "Baseline: what the packaged Lemonade says about vLLM here"
if server_up; then
  lemonade backends --all 2>&1 | grep -i vllm | tee "$REPORT/backends-packaged.txt" || true
  lemonade unload >/dev/null 2>&1 || true
else
  info "The packaged server is not running; skipping the baseline."
fi

# ---------------------------------------------------------------------------------------------
log "Installing build dependencies"
wait_for_apt
apt-get -o DPkg::Lock::Timeout=600 update -qq
apt_install git cmake ninja-build build-essential pkg-config curl jq python3 \
  libcurl4-openssl-dev libssl-dev zlib1g-dev libsystemd-dev libdrm-dev libcap-dev libwebsockets-dev
info "$(cmake --version | head -1)"

log "Fetching lemonade-sdk/lemonade ($LEMONADE_REF)"
if [[ -d "$SRC/.git" ]]; then
  git -C "$SRC" fetch -q --depth 1 origin "$LEMONADE_REF"
  git -C "$SRC" checkout -qf FETCH_HEAD
  git -C "$SRC" clean -qfdx -e build
else
  git clone -q --depth 1 --branch "$LEMONADE_REF" https://github.com/lemonade-sdk/lemonade.git "$SRC"
fi
BASE_SHA=$(git -C "$SRC" rev-parse HEAD)
echo "lemonade base: $BASE_SHA ($LEMONADE_REF)" | tee -a "$REPORT/env.txt"

log "Applying $(basename "$PATCH")"
git -C "$SRC" apply "$PATCH" ||
  die "The patch no longer applies to $LEMONADE_REF; upstream changed these lines. Re-make the patch."
git -C "$SRC" diff --stat

log "Building Lemonade (several minutes)"
t0=$SECONDS
if ! (cd "$SRC" && cmake --preset default && cmake --build --preset default -j "$(nproc)") \
  >"$REPORT/build.log" 2>&1; then
  tail -40 "$REPORT/build.log"
  die "Build failed; full log in $REPORT/build.log"
fi
row "-" "build" "ok" "$(((SECONDS - t0) / 60)) min, base $BASE_SHA"
info "Built in $(((SECONDS - t0) / 60)) min"

log "Unit test: test_vllm_cdna_gating"
TEST_BIN=$(find "$SRC/build" -type f -name test_vllm_cdna_gating -perm -u+x | head -1 || true)
if [[ -z "$TEST_BIN" ]]; then
  row "-" "unit test" "not built" "test_vllm_cdna_gating missing (BUILD_TESTING off?)"
elif "$TEST_BIN" >"$REPORT/unit-test.txt" 2>&1; then
  row "-" "unit test" "pass" "$(grep -c '^PASS' "$REPORT/unit-test.txt") checks"
else
  row "-" "unit test" "FAIL" "$(grep '^FAIL' "$REPORT/unit-test.txt" | head -3)"
fi
grep -E '^FAIL|gfx942' "$REPORT/unit-test.txt" 2>/dev/null || true

log "Regenerating Lemonade's generated docs (its CI checks them)"
if (cd "$SRC" && python3 docs/tools/gen_backend_boilerplate.py --lemond build/lemond) \
  >"$REPORT/gen-docs.log" 2>&1; then
  row "-" "docs regenerated" "ok" "$(git -C "$SRC" diff --stat | tail -1)"
else
  row "-" "docs regenerated" "FAIL" "see gen-docs.log"
fi
git -C "$SRC" diff >"$REPORT/full.patch"
git -C "$SRC" diff --stat

# ---------------------------------------------------------------------------------------------
log "Swapping in the patched server"
trap restore EXIT
if [[ -n "$PKG_UNIT" ]]; then systemctl stop "$PKG_UNIT"; fi
systemctl stop "$DEV_UNIT" >/dev/null 2>&1 || true
systemctl reset-failed "$DEV_UNIT" >/dev/null 2>&1 || true
systemd-run --unit="$DEV_UNIT" --collect --setenv=HOME=/root \
  "$SRC/build/lemond" --host 127.0.0.1 --port "$LEMONADE_PORT" >/dev/null
wait_for_server 180 || die "The patched server did not start. Check: journalctl -u $DEV_UNIT -n 100"
"$LCLI" backends --all 2>&1 | grep -i vllm | tee "$REPORT/backends-patched.txt" || true

first_ok=""
for pin in $PINS; do
  label=$(short "$pin")
  log "vLLM release: $pin"
  since=$(date '+%F %T')
  "$LCLI" unload >/dev/null 2>&1 || true
  pkill -9 -f 'VLLM::EngineCor' 2>/dev/null || true
  "$LCLI" backends uninstall vllm:rocm >/dev/null 2>&1 || true
  if ! out=$("$LCLI" config set "vllm.rocm_bin=$pin" 2>&1); then
    row "$label" "set vllm.rocm_bin" "FAIL" "$out"
    continue
  fi

  t0=$SECONDS
  if out=$("$LCLI" backends install vllm:rocm 2>&1); then
    row "$label" "install" "ok" "$((SECONDS - t0)) s"
  else
    printf '%s\n' "$out" | tail -20
    row "$label" "install" "FAIL" "$(tail -3 <<<"$out")"
    save_server_log "$pin" "$since"
    continue
  fi
  "$LCLI" backends --all 2>&1 | grep -i vllm >>"$REPORT/backends-patched.txt" || true

  info "Importing the bundle's packages directly:"
  bundle_out=$(bundle_check 2>&1 || true)
  printf '%s\n' "$bundle_out" | tee "$REPORT/bundle-$(slug "$pin").txt"
  row "$label" "bundle imports" "$(grep -q FAILED <<<"$bundle_out" && echo FAIL || echo ok)" \
    "$(grep -E 'FAILED|vllm ' <<<"$bundle_out" | head -2)"

  "$LCLI" pull "$SMALL_MODEL" >/dev/null 2>&1 || true
  t0=$SECONDS
  if ! out=$(timeout 2400 "$LCLI" load "$SMALL_MODEL" 2>&1); then
    printf '%s\n' "$out" | tail -20
    row "$label" "load $SMALL_MODEL" "FAIL" "$(tail -3 <<<"$out")"
    row "$label" "server log" "-" "$(save_server_log "$pin" "$since" | head -3)"
    continue
  fi
  row "$label" "load $SMALL_MODEL" "ok" "$((SECONDS - t0)) s"
  if r=$(smoke_chat "$SMALL_MODEL" 2>&1); then
    row "$label" "chat $SMALL_MODEL" "ok" "$r"
  else
    row "$label" "chat $SMALL_MODEL" "FAIL" "$r"
    save_server_log "$pin" "$since" >/dev/null
    continue
  fi

  if [[ -z "$first_ok" ]]; then
    first_ok=$pin
    if [[ -n "$BIG_MODEL" ]]; then
      log "Big model on $label: $BIG_MODEL"
      "$LCLI" unload >/dev/null 2>&1 || true
      t0=$SECONDS
      "$LCLI" pull "$BIG_MODEL" || warn "pull reported an error; trying to load anyway"
      row "$label" "download $BIG_MODEL" "-" "$((SECONDS - t0)) s"
      t0=$SECONDS
      if out=$(timeout 3600 "$LCLI" load "$BIG_MODEL" 2>&1); then
        row "$label" "load $BIG_MODEL" "ok" "$((SECONDS - t0)) s, VRAM $(vram_used_gb) GB"
        if r=$(smoke_chat "$BIG_MODEL" 2>&1); then s=ok; else s=FAIL; fi
        row "$label" "chat $BIG_MODEL" "$s" "$r"
        if r=$(smoke_messages_tool "$BIG_MODEL" 2>&1); then s=ok; else s=FAIL; fi
        row "$label" "/v1/messages tool call" "$s" "$r"
        if r=$(measure_tps "$BIG_MODEL" 2>&1); then s=ok; else s=FAIL; fi
        row "$label" "speed (1 request)" "$s" "$r"
      else
        printf '%s\n' "$out" | tail -20
        row "$label" "load $BIG_MODEL" "FAIL" "$(tail -3 <<<"$out")"
      fi
    fi
  fi
  save_server_log "$pin" "$since" >/dev/null
done

# ---------------------------------------------------------------------------------------------
{
  echo
  echo "Base commit: $BASE_SHA ($LEMONADE_REF). Full diff, including regenerated docs: full.patch"
  if [[ -n "$first_ok" && "$first_ok" != builtin ]]; then
    echo
    echo "Next change for the PR: set vllm.rocm_arch_overrides.gfx942 in src/cpp/resources/backend_versions.json"
    echo "to \"${first_ok%-gfx942}\" and update the matching expectation in test/cpp/test_vllm_cdna_gating.cpp."
  elif [[ -z "$first_ok" ]]; then
    echo
    echo "No release served a model. See server-*.log and bundle-*.txt."
  fi
} >>"$SUMMARY"

log "Results"
cat "$SUMMARY"
info "Report folder: $REPORT  (leasehold.ps1 report copies it to your PC)"
