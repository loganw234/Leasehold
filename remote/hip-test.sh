#!/usr/bin/env bash
# Builds and runs hip-test.hip on this machine's GPUs (leasehold.ps1 hip-test): the GPUs'
# properties, three small kernels checked exactly against the CPU, and a rough memory bandwidth.
# The same script runs on your own Radeon box and on an MI300X droplet. Exit status 0 means the
# test built for every GPU target the driver lists, and every check passed.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
WORK="$HERE/hip-test"

# A ROCm program on PATH, else in /opt/rocm/bin or a versioned ROCm folder.
rocm_bin() {
  local f
  command -v "$1" 2>/dev/null && return 0
  for f in /opt/rocm/bin/"$1" /opt/rocm/core-*/bin/"$1" /opt/rocm-*/bin/"$1"; do
    if [[ -x $f ]]; then echo "$f"; return 0; fi
  done
  return 1
}

# Every GPU's target, from the driver's topology (lib.sh's detect_gfx reads only the first).
gfx_targets() {
  local f v
  for f in /sys/class/kfd/kfd/topology/nodes/*/properties; do
    v=$(awk '$1 == "gfx_target_version" { print $2 }' "$f" 2>/dev/null)
    if [[ -n $v && $v != 0 ]]; then
      printf 'gfx%d%x%x\n' $((v / 10000)) $(((v / 100) % 100)) $((v % 100))
    fi
  done | sort -u
}

build() {  # <output> <target>...: builds hip-test.hip for the targets; the log goes to <output>.log
  local out=$1 flags=() t
  shift
  for t in "$@"; do flags+=(--offload-arch="$t"); done
  "$HIPCC" -O2 "${flags[@]}" "$WORK/hip-test.hip" -o "$out" >"$out.log" 2>&1
}

# amdgpu-install's rocm use case leaves out the HIP headers; ROCm's core SDK has them.
install_hip_headers() {
  local series pkg sudo=()
  series=$(sed -E 's/^([0-9]+\.[0-9]+).*/\1/' /opt/rocm/.info/version 2>/dev/null || true)
  if ((EUID != 0)); then
    sudo -n true 2>/dev/null ||
      die "The HIP headers are missing, and installing them needs root: sudo apt-get install amdrocm-core-sdk${series:-<version>}"
    sudo=(sudo -n)
  fi
  for pkg in "amdrocm-core-sdk$series" rocm-hip-sdk; do
    if apt-cache show "$pkg" >/dev/null 2>&1; then
      log "Installing $pkg for the HIP headers (a few GB, several minutes)"
      "${sudo[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -qq "$pkg" >/dev/null
      return 0
    fi
  done
  die "The HIP headers are missing, and apt offers neither amdrocm-core-sdk$series nor rocm-hip-sdk."
}

log "The machine"
info "$(. /etc/os-release && echo "$PRETTY_NAME"), kernel $(uname -r)"
if [[ -r /opt/rocm/.info/version ]]; then info "ROCm $(cat /opt/rocm/.info/version)"; fi
[[ -e /dev/kfd ]] || die "No /dev/kfd: the amdgpu driver isn't loaded, or there is no AMD GPU here."
[[ -r /dev/kfd && -w /dev/kfd ]] ||
  die "$(id -un) can't use the GPU. Add it to the render and video groups (sudo usermod -aG render,video $(id -un)), then log in again."
mapfile -t TARGETS < <(gfx_targets)
((${#TARGETS[@]} > 0)) || die "The driver lists no GPU target in /sys/class/kfd."
info "GPU targets: ${TARGETS[*]}"
HIPCC=$(rocm_bin hipcc) ||
  die "No hipcc here. Install ROCm first: leasehold.ps1 rocm on your own box; on a droplet, use the ROCm Software image."
# Read the whole output first: grep -m1 on a pipe stops hipcc early, and pipefail counts that.
version=$("$HIPCC" --version 2>/dev/null || true)
info "hipcc: $HIPCC ($(grep -m1 -oE 'HIP version: [^ ]+' <<<"$version" || echo 'version unknown'))"

log "Building hip-test.hip for ${TARGETS[*]}"
mkdir -p "$WORK"
cp "$HERE/hip-test.hip" "$WORK/"
sed -i 's/\r$//' "$WORK/hip-test.hip"
t0=$SECONDS
if ! build "$WORK/hip-test" "${TARGETS[@]}"; then
  if grep -q "hip_runtime.h' file not found" "$WORK/hip-test.log"; then
    install_hip_headers
    t0=$SECONDS
  fi
  if ! build "$WORK/hip-test" "${TARGETS[@]}"; then
    tail -20 "$WORK/hip-test.log" | sed 's/^/    /'
    die "hipcc could not build the test (log: $WORK/hip-test.log)."
  fi
fi
info "Built in $((SECONDS - t0)) s: $WORK/hip-test"

# A droplet's MI300X is gfx942. Building for it here too shows this ROCm can, before one is rented.
if [[ " ${TARGETS[*]} " != *" gfx942 "* ]]; then
  if build "$WORK/hip-test-gfx942" gfx942; then
    info "Also built for the MI300X (gfx942), not run here: $WORK/hip-test-gfx942"
  else
    warn "This ROCm couldn't build for gfx942; see $WORK/hip-test-gfx942.log."
  fi
fi

log "Running it"
set +e
"$WORK/hip-test" 2>&1 | sed 's/^/    /'
rc=${PIPESTATUS[0]}
set -e
((rc == 0)) || die "The HIP test failed (exit $rc)."
log "HIP works on this machine: built for ${TARGETS[*]}, and every check passed"
