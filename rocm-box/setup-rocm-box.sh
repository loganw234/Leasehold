#!/usr/bin/env bash
# Installs ROCm 10.1 and the HIP toolchain on an Ubuntu 24.04 box with a Radeon GPU (written for an
# RX 7600, gfx1102), then checks it by building and running a small HIP program.
#
# Run it with sudo from your normal account. It takes up to three runs, rebooting between them:
#   1. if the kernel is older than the HWE 7.0 kernel ROCm 10.1 supports on 24.04.5, it installs that;
#   2. it installs AMD's GPU driver and ROCm with amdgpu-install;
#   3. it verifies: rocminfo, amd-smi, and hip-smoke/vector_add.hip built and run on the GPU.
# Each run says what it did and whether to reboot. leasehold.ps1 rocm uploads and runs it for you.
#
# Commands follow AMD's "Install AMD ROCm 10.1.0" page (rocm.docs.amd.com), amdgpu-install path.
set -euo pipefail

AMDGPU_INSTALL_URL='https://repo.radeon.com/amdgpu-install/31.60/ubuntu/noble/amdgpu-install_31.60.316000-1_all.deb'
ROCM_SERIES=10.1
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "Run with sudo: sudo bash $0"
TARGET_USER=${SUDO_USER:-root}
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] ||
  die "Written for Ubuntu 24.04, the release the MI300X droplet image uses (found ${PRETTY_NAME:-unknown})."

# Finds a ROCm program on PATH or under /opt, newest version last.
find_rocm_bin() {
  command -v "$1" 2>/dev/null ||
    find /opt -maxdepth 4 -type f -name "$1" -perm -u+x 2>/dev/null | sort -V | tail -1
}

# amdgpu-install's rocm use case installs the runtime and libraries but not the HIP headers.
# The core SDK adds them (and the libraries' dev files); developer tools add rocprofv3 and rocgdb.
# About 3.3 GB.
install_sdk() {
  log "Installing the ROCm ${ROCM_SERIES} core SDK and developer tools (HIP headers, rocprofv3, rocgdb)"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    "amdrocm-core-sdk${ROCM_SERIES}" "amdrocm-developer-tools${ROCM_SERIES}" >/dev/null
}

ROCMINFO=$(find_rocm_bin rocminfo || true)

# ---------------------------------------------------------------------------------------------
if [[ -z "$ROCMINFO" ]]; then
  log "Checking the machine"
  command -v lspci >/dev/null || apt-get install -y -qq pciutils >/dev/null
  lspci -nn | grep -iE 'VGA|Display|3D' | grep -iE 'AMD|ATI' ||
    die "No AMD GPU on the PCI bus. Is the card seated and powered?"

  kernel_major=$(uname -r | cut -d. -f1)
  if ((kernel_major < 7)); then
    log "Installing the HWE kernel"
    info "ROCm 10.1 supports Ubuntu 24.04.5 on the HWE 7.0 kernel; this box runs $(uname -r)."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y linux-generic-hwe-24.04
    log "Reboot (sudo reboot), then run this script again."
    exit 0
  fi

  if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
    die "Secure Boot is on, so the amdgpu driver module would need a key enrolled at the next boot.
       Simplest for a dedicated box: turn Secure Boot off in the BIOS and run this again.
       To keep it on, run amdgpu-install by hand and enroll the key when the reboot asks."
  fi

  log "Installing prerequisites"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    wget gpg build-essential libatomic1 libquadmath0 python3.12 python3.12-venv >/dev/null

  log "Installing amdgpu-install 31.60 (ROCm 10.1)"
  tmp=$(mktemp -d)
  wget -q -O "$tmp/amdgpu-install.deb" "$AMDGPU_INSTALL_URL"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp/amdgpu-install.deb"
  rm -rf "$tmp"

  log "Installing the AMD GPU driver and ROCm (several minutes)"
  amdgpu-install -y --usecase=rocm,graphics --gfxversion=auto
  install_sdk

  if [[ "$TARGET_USER" != root ]]; then
    usermod -a -G render,video "$TARGET_USER"
    info "Added $TARGET_USER to the render and video groups (takes effect at next login)."
  fi
  log "Reboot (sudo reboot), then run this script again to verify."
  exit 0
fi

# ---------------------------------------------------------------------------------------------
log "Verifying ROCm"
ROCM_BIN=$(dirname "$ROCMINFO")
export PATH="$PATH:$ROCM_BIN"
info "rocminfo: $ROCMINFO"

GFX=$("$ROCMINFO" 2>/dev/null | grep -oE 'gfx[0-9a-f]{3,4}' | head -1 || true)
[[ -n "$GFX" ]] || die "rocminfo sees no GPU. Did you reboot after the install? Check: dmesg | grep -i amdgpu"
"$ROCMINFO" 2>/dev/null | grep -E 'Marketing Name' | sort -u | sed 's/^ */    /'
info "GPU target: $GFX"
[[ "$GFX" == gfx1102 ]] || warn "Expected gfx1102 (RX 7600); found $GFX. Continuing."

AMDSMI=$(find_rocm_bin amd-smi || true)
if [[ -n "$AMDSMI" ]]; then "$AMDSMI" version || true; else warn "amd-smi not found."; fi

if [[ "$TARGET_USER" != root ]] && ! id -nG "$TARGET_USER" | grep -qw render; then
  warn "$TARGET_USER is not in the render group yet; log out and back in (or reboot) before using the GPU."
fi

log "Building and running hip-smoke/vector_add.hip"
# Boxes installed before the SDK step was added have hipcc but no HIP headers.
if [[ ! -e /opt/rocm/include/hip/hip_runtime.h ]]; then install_sdk; fi
HIPCC=$(find_rocm_bin hipcc || true)
[[ -n "$HIPCC" ]] || die "hipcc not found under PATH or /opt. Is the ROCm SDK installed (amdgpu-install --usecase=rocm)?"
"$HIPCC" --version | head -3 | sed 's/^/    /'

SMOKE="$TARGET_HOME/hip-smoke"
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$SMOKE"
install -o "$TARGET_USER" -g "$TARGET_USER" -m 644 "$HERE/hip-smoke/vector_add.hip" "$SMOKE/"
sudo -u "$TARGET_USER" "$HIPCC" -O2 --offload-arch="$GFX" "$SMOKE/vector_add.hip" -o "$SMOKE/vector_add" ||
  die "hipcc could not build the test for $GFX."
sudo -u "$TARGET_USER" "$SMOKE/vector_add" || die "The HIP test failed on the GPU (output above)."

# The same source cross-compiles for the MI300X, to run on the droplet later.
if sudo -u "$TARGET_USER" "$HIPCC" -O2 --offload-arch=gfx942 "$SMOKE/vector_add.hip" \
  -o "$SMOKE/vector_add-gfx942" 2>/dev/null; then
  info "Also built $SMOKE/vector_add-gfx942 for the MI300X."
else
  info "Cross-compiling for gfx942 needs that target's ROCm packages; skipped."
fi

# Put the ROCm tools on PATH for future logins if they aren't there already.
if ! sudo -u "$TARGET_USER" bash -lc 'command -v hipcc' >/dev/null 2>&1; then
  printf 'export PATH="$PATH:%s"\n' "$ROCM_BIN" >/etc/profile.d/rocm-path.sh
  info "Added $ROCM_BIN to PATH for login shells (/etc/profile.d/rocm-path.sh)."
fi

log "ROCm and HIP are working"
cat <<EOF
HIP test program: $SMOKE (build again with: hipcc --offload-arch=$GFX vector_add.hip -o vector_add)

To rehearse the droplet setup on this box with a model that fits in 8 GB, from your PC:
  leasehold.ps1 setup -Ip <this-box-ip> -User $TARGET_USER -Model Qwen3.5-4B-GGUF
EOF
