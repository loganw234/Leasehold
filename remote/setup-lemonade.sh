#!/usr/bin/env bash
# Sets up Lemonade on a fresh AMD Developer Cloud MI300X droplet (Ubuntu 24.04, "ROCm Software" image)
# and serves one model through the llama.cpp ROCm backend. Safe to re-run; finished steps are skipped.
#
# Run as root on the droplet:   bash setup-lemonade.sh
# (leasehold.ps1 setup uploads and runs this for you.)
#
# Settings (environment variables):
#   MODEL         Lemonade model to pull and load            (default: Qwen3.6-35B-A3B-GGUF)
#   SLOTS         requests the model serves at once          (default: 1, Lemonade's own default)
#   CTX_PER_SLOT  context per slot when SLOTS > 1            (default: 131072)
#                 With SLOTS=1, Lemonade picks the largest context that fits.
#   MAX_MODELS    LLMs kept loaded at the same time          (default: 2)
#   SKIP_TESTS=1  skip the smoke tests at the end
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HERE/lib.sh"

MODEL=${MODEL:-Qwen3.6-35B-A3B-GGUF}
SLOTS=${SLOTS:-1}
CTX_PER_SLOT=${CTX_PER_SLOT:-131072}
MAX_MODELS=${MAX_MODELS:-2}
SKIP_TESTS=${SKIP_TESTS:-0}

require_root
[[ "$SLOTS" =~ ^[1-9][0-9]*$ ]] || die "SLOTS must be a positive integer (got '$SLOTS')."
exec > >(tee -a /root/lemonade-setup.log) 2>&1

log "Checking the GPU"
GFX=$(detect_gfx) || die "No AMD GPU in /sys/class/kfd. Is this the ROCm image on an MI300X droplet?"
info "GPU target: $GFX"
[[ "$GFX" == gfx942 ]] || warn "Expected gfx942 (MI300X) but found $GFX. Continuing anyway."
[[ -r /opt/rocm/.info/version ]] && info "System ROCm: $(cat /opt/rocm/.info/version)"
info "Free disk on /: $(df -h --output=avail / | tail -1 | tr -d ' ')"

log "Installing Lemonade from the stable PPA"
apt_update
apt_install software-properties-common curl jq
if ! dpkg -s lemonade-server >/dev/null 2>&1; then
  wait_for_apt
  # -n skips add-apt-repository's own apt update, which doesn't retry; apt_update does.
  add-apt-repository -y -n ppa:lemonade-team/stable >/dev/null
  apt_update
  apt_install lemonade-server
fi
command -v lemonade >/dev/null || die "The lemonade CLI is not on PATH after install (looked in PATH and /opt/bin)."
info "$(lemonade --version 2>&1 | head -1)"

log "Starting the Lemonade service"
UNIT=$(lemond_unit)
[[ -n "$UNIT" ]] || die "No Lemonade systemd unit found. Check: systemctl list-unit-files | grep -i lemon"
# The service runs as the 'lemonade' user, which needs the render/video groups to open /dev/kfd and /dev/dri.
if id lemonade >/dev/null 2>&1; then
  for g in render video; do
    getent group "$g" >/dev/null && usermod -aG "$g" lemonade
  done
fi
systemctl enable "$UNIT" >/dev/null 2>&1 || true
systemctl restart "$UNIT"
wait_for_server 180 || die "Lemonade did not come up. Check: journalctl -u $UNIT -n 100"
info "$UNIT is up on 127.0.0.1:$LEMONADE_PORT"

log "Configuring Lemonade"
# host stays on localhost: your PC reaches the server through an SSH tunnel, so nothing is exposed.
lemonade config set host=localhost max_loaded_models="$MAX_MODELS" llamacpp.backend=rocm
systemctl restart "$UNIT"
wait_for_server 180 || die "Lemonade did not come back after the config change. Check: journalctl -u $UNIT -n 100"

log "Installing the llama.cpp ROCm backend"
lemonade backends install llamacpp:rocm
lemonade backends 2>&1 | grep -iE 'llamacpp|vllm' || true

log "Downloading $MODEL (resumes if a previous run was interrupted)"
lemonade pull "$MODEL"

log "Loading $MODEL"
# --parallel goes in the server-wide llamacpp.rocm_args setting. As the model's own llamacpp_args
# it would replace the sampler settings Lemonade applies per model architecture (for Qwen3.5:
# --temp 1.0 --top-p 0.95 --top-k 20 and preserve_thinking), which this way are kept.
if ((SLOTS > 1)); then
  lemonade config set "llamacpp.rocm_args=--parallel $SLOTS" >/dev/null
  # llama.cpp splits the context across slots, so give it slots x per-slot context.
  ctx=$((SLOTS * CTX_PER_SLOT))
  info "$SLOTS slots x $CTX_PER_SLOT tokens = $ctx tokens of context"
else
  lemonade config set "llamacpp.rocm_args=" >/dev/null
  ctx=-1   # Lemonade picks the largest context that fits
fi
lemonade load "$MODEL" --llamacpp rocm "--ctx-size=$ctx" --save-options
lemonade status --json | jq '.models[] | {model_name, recipe, status, recipe_options}'
info "VRAM in use: $(vram_gb used) GB of $(vram_gb total) GB"

if [[ "$SKIP_TESTS" != 1 ]]; then
  log "Smoke test 1/3: chat completion"
  smoke_chat "$MODEL" || die "The chat request failed (output above)."
  log "Smoke test 2/3: /v1/messages with a tool (the API Claude Code uses)"
  smoke_messages_tool "$MODEL" ||
    warn "No tool call came back. Claude Code's tool use may not work with this model."
  log "Smoke test 3/3: rough generation speed"
  measure_tps "$MODEL" || warn "Speed test failed (output above)."
fi

log "Done"
cat <<EOF
Lemonade is serving $MODEL on 127.0.0.1:$LEMONADE_PORT; it is not reachable from the internet.
On your PC, open the tunnel in one terminal:   leasehold.ps1 tunnel -Ip <droplet-ip>
then start Pi from your project:               leasehold.ps1 pi -Model $MODEL
Full log: /root/lemonade-setup.log

The droplet bills until you DESTROY it. Powering it off does not stop billing.
EOF
