# Shared helpers for Leasehold's remote scripts. Sourced by the other scripts, not run directly.

# The .deb installs its binaries under /opt/bin, which a non-login shell may not have on PATH.
export PATH="$PATH:/opt/bin"

LEMONADE_PORT="${LEMONADE_PORT:-13305}"
BASE_URL="http://127.0.0.1:${LEMONADE_PORT}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
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

# Waits for apt/dpkg locks held by cloud-init or unattended-upgrades on a fresh droplet.
wait_for_apt() {
  local i
  for ((i = 0; i < 120; i++)); do
    pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null || return 0
    ((i == 0)) && info "Waiting for another apt/dpkg process to finish..."
    sleep 5
  done
  warn "apt is still busy after 10 minutes; continuing anyway."
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

# Total VRAM in use across AMD GPUs, in GB, read from amdgpu's sysfs counters.
vram_used_gb() {
  local f total=0
  for f in /sys/class/drm/card*/device/mem_info_vram_used; do
    [[ -r "$f" ]] && total=$((total + $(cat "$f")))
  done
  awk -v b="$total" 'BEGIN { printf "%.1f", b / 1e9 }'
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
