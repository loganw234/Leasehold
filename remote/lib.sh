# Shared helpers for Leasehold's remote scripts. Sourced by the other scripts, not run directly.

# The .deb installs its binaries under /opt/bin, which a non-login shell may not have on PATH.
export PATH="$PATH:/opt/bin"

LEMONADE_PORT="${LEMONADE_PORT:-13305}"
BASE_URL="http://127.0.0.1:${LEMONADE_PORT}"

# Each step's heading carries the time since the script started, so a log shows what each step took.
log()  { printf '\n\033[1;36m==> %s\033[0m  [%d:%02d]\n' "$*" $((SECONDS / 60)) $((SECONDS % 60)); }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [[ ${EUID} -eq 0 ]] || die "Run as root (the droplet's default login)."; }

# Prints the gfx target of the first GPU node in the KFD topology (e.g. gfx942).
# gfx_target_version is major*10000 + minor*100 + stepping; minor and stepping print as hex.
detect_gfx() {
  local f v
  for f in /sys/class/kfd/kfd/topology/nodes/*/properties; do
    v=$(awk '$1 == "gfx_target_version" { print $2 }' "$f" 2>/dev/null)
    [[ -n "$v" && "$v" != "0" ]] || continue
    printf 'gfx%d%x%x\n' $((v / 10000)) $(((v / 100) % 100)) $((v % 100))
    return 0
  done
  return 1
}

# Waits while another process (cloud-init, unattended-upgrades) holds apt's or dpkg's locks, for
# up to 30 minutes: Ubuntu's daily unattended upgrade, a new kernel included, took 24 minutes on
# the test box. It checks who holds the lock files rather than process names: Ubuntu's
# always-running unattended-upgrade-shutdown helper shares the name "unattended-upgr" with a real
# upgrade.
wait_for_apt() {
  local i pids names
  local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock)
  for ((i = 0; i < 360; i++)); do
    if command -v fuser >/dev/null; then
      pids=$(fuser "${locks[@]}" 2>/dev/null | xargs) || true
    else
      pids=$(pgrep -x 'apt|apt-get|dpkg' | xargs) || true
    fi
    [[ -z "$pids" ]] && return 0
    if ((i % 60 == 0)); then
      names=$(ps -o comm= -p "${pids// /,}" 2>/dev/null | sort -u | paste -sd, -) || true
      info "Waiting for ${names:-another apt/dpkg process} to let go of apt ($((i / 12)) min so far)..."
    fi
    sleep 5
  done
  warn "apt is still busy after 30 minutes; continuing anyway."
}

# Refreshes apt's package lists, retrying because an Ubuntu mirror in the middle of a sync makes
# `apt-get update` fail ("File has unexpected size ... Mirror sync in progress?"). A list that
# still fails to refresh only matters if a package is missing, and then apt_install fails loudly.
apt_update() {
  local i
  wait_for_apt
  for ((i = 1; i <= 3; i++)); do
    apt-get -o DPkg::Lock::Timeout=600 update -qq && return 0
    ((i < 3)) && { warn "apt-get update failed (try $i of 3); retrying in 20 s."; sleep 20; }
  done
  warn "apt-get update kept failing; continuing with the package lists already on the machine."
  return 0
}

apt_install() {
  wait_for_apt
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -qq "$@" >/dev/null
}

# Finds the systemd unit the Lemonade package installed (lemond.service on current packages).
lemond_unit() {
  systemctl list-unit-files --type=service --no-legend 2>/dev/null |
    awk '{ print $1 }' | grep -m1 -E '^(lemond|lemonade-server|lemonade)\.service$' || true
}

server_up() {
  curl -fsS --max-time 5 "${BASE_URL}/v1/health" >/dev/null 2>&1 ||
    curl -fsS --max-time 5 "${BASE_URL}/api/v1/health" >/dev/null 2>&1
}

wait_for_server() {  # [timeout_seconds]
  local timeout=${1:-180} i
  for ((i = 0; i < timeout; i += 3)); do
    server_up && return 0
    sleep 3
  done
  return 1
}

# VRAM across AMD GPUs, in GB, from amdgpu's sysfs counters: vram_gb used, or vram_gb total.
vram_gb() {
  local f total=0
  for f in /sys/class/drm/card*/device/mem_info_vram_"$1"; do
    [[ -r "$f" ]] && total=$((total + $(cat "$f")))
  done
  awk -v b="$total" 'BEGIN { printf "%.1f", b / 1e9 }'
}
vram_used_gb() { vram_gb used; }

# True if an AMD GPU drives a desktop: a screen connected to one of its outputs and a display
# server running. Such a GPU needs VRAM for the desktop too: when the compositor asks for some and
# none is free, the driver moves other buffers into system RAM, which on an 8 GB card got
# llama-server killed by the OOM killer. A text console alone doesn't (tested with GDM stopped).
gpu_drives_display() {
  local f card
  pgrep -x 'Xorg|Xwayland|gnome-shell|kwin_wayland|sway|weston|mutter|cage|labwc' >/dev/null ||
    systemctl is-active --quiet display-manager 2>/dev/null || return 1
  for f in /sys/class/drm/card*-*/status; do
    [[ -r "$f" && "$(cat "$f")" == connected ]] || continue
    card=${f%/status}
    card=${card%%-*}
    [[ "$(cat "$card/device/vendor" 2>/dev/null)" == 0x1002 ]] && return 0
  done
  return 1
}

# One OpenAI-style chat request. Prints the reply; returns non-zero if nothing came back.
# Reasoning models may answer only in reasoning_content when max_tokens runs out, so either counts.
smoke_chat() {
  local model=$1 out reply
  out=$(curl -sS --max-time 1200 "${BASE_URL}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg m "$model" '{model: $m, max_tokens: 512,
          messages: [{role: "user", content: "Reply with exactly: LEMONADE OK"}]}')") || return 1
  reply=$(jq -r '.choices[0].message.content // .choices[0].message.reasoning_content // empty' <<<"$out" 2>/dev/null)
  if [[ -n "$reply" ]]; then
    printf '%s\n' "$reply" | head -c 400; echo
  else
    printf '%s\n' "$out" | head -c 2000; echo
    return 1
  fi
}

# One Anthropic-style /v1/messages request with a tool, the way Claude Code talks to Lemonade.
# Prints the tool call; returns non-zero if no tool_use block came back.
smoke_messages_tool() {
  local model=$1 out
  out=$(curl -sS --max-time 1200 "${BASE_URL}/v1/messages" \
    -H 'Content-Type: application/json' -H 'anthropic-version: 2023-06-01' -H 'x-api-key: lemonade' \
    -d "$(jq -n --arg m "$model" '{model: $m, max_tokens: 1024,
          tools: [{name: "get_weather", description: "Get the current weather for a city.",
                   input_schema: {type: "object", properties: {city: {type: "string"}}, required: ["city"]}}],
          messages: [{role: "user", content: "What is the weather in Paris right now? Use the tool."}]}')") || return 1
  if jq -e '.content[]? | select(.type == "tool_use")' <<<"$out" >/dev/null 2>&1; then
    jq -c '.content[] | select(.type == "tool_use") | {name, input}' <<<"$out"
  else
    printf '%s\n' "$out" | head -c 2000; echo
    return 1
  fi
}

# Rough end-to-end generation speed from one long reply (prefill included, so it reads a bit low).
# Prints "<tokens> tokens in <s> s = <tok/s> tok/s".
measure_tps() {
  local model=$1 t0 t1 out n
  t0=$(date +%s.%N)
  out=$(curl -sS --max-time 1800 "${BASE_URL}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg m "$model" '{model: $m, max_tokens: 768, temperature: 0,
          messages: [{role: "user", content: "Write the numbers from 1 to 300 in words, separated by commas. No other text."}]}')") || return 1
  t1=$(date +%s.%N)
  n=$(jq -r '.usage.completion_tokens // 0' <<<"$out" 2>/dev/null)
  [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] || { printf '%s\n' "$out" | head -c 1000; echo; return 1; }
  awk -v n="$n" -v a="$t0" -v b="$t1" 'BEGIN { s = b - a; printf "%d tokens in %.1f s = %.1f tok/s\n", n, s, n / s }'
}
