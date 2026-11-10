#!/usr/bin/env bash
# Measures the loaded model deep into its context. For each size it sends one long prompt, a made-up
# weather log with an access code hidden halfway down, and records how long the model took to read
# it, whether it found the code, and how fast it then generates at that depth. Last, it sends a
# prompt longer than one slot's context, to show what an agent gets when it overruns.
#
# Usage: bash depth.sh <model> [tokens ...]   (default sizes: 8000 32000 64000 120000)
# (leasehold.ps1 depth uploads and runs it.)
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HERE/lib.sh"

MODEL=${1:?usage: depth.sh <model> [tokens ...]}
shift
SIZES=("$@")
((${#SIZES[@]})) || SIZES=(8000 32000 64000 120000)
for s in "${SIZES[@]}"; do
  [[ "$s" =~ ^[1-9][0-9]*$ ]] || die "Sizes must be positive integers (got '$s')."
done
server_up || die "Lemonade is not answering on $BASE_URL."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

CODE="AMBER-$((RANDOM % 9000 + 1000))"
NEEDLE="Note from the archivist: the access code for the archive is $CODE."
ASK_CODE='What is the access code for the archive mentioned in the log above? Reply with the code only.'
ASK_LONG='In about 300 words, describe the weather this log suggests.'

# A made-up weather log; the numbers vary, so no line repeats. Each size gets its own seed, so one
# prompt can't reuse another's cached tokens.
log_lines() {  # count seed file
  awk -v n="$1" -v seed="$2" 'BEGIN {
    srand(seed)
    for (i = 1; i <= n; i++)
      printf "Log %06d: station %d reported %d.%d degrees, wind %d km/h from %d degrees, pressure %d hPa.\n",
        i, int(rand() * 900) + 100, int(rand() * 40) - 5, int(rand() * 10), int(rand() * 60),
        int(rand() * 360), int(rand() * 60) + 980
  }' >"$3"
}

count_tokens() {  # file
  jq -n --rawfile c "$1" --arg m "$MODEL" '{model: $m, content: $c}' |
    curl -sS --max-time 120 "$BASE_URL/api/v1/tokenize" -H 'Content-Type: application/json' -d @- |
    jq -r '.tokens | length' 2>/dev/null
}

# One chat request without thinking: <prompt file> <question> <max_tokens>. The response (or the
# error) lands in $tmp/out.json; prints the HTTP status.
chat() {
  jq -n --rawfile hay "$1" --arg q "$2" --arg m "$MODEL" --argjson t "$3" \
    '{model: $m, max_tokens: $t, temperature: 0, chat_template_kwargs: {enable_thinking: false},
      messages: [{role: "user", content: ($hay + "\n" + $q)}]}' >"$tmp/body.json"
  rm -f "$tmp/out.json"
  curl -sS --max-time 3600 -o "$tmp/out.json" -w '%{http_code}' "$BASE_URL/v1/chat/completions" \
    -H 'Content-Type: application/json' -d @"$tmp/body.json"
  [[ -s "$tmp/out.json" ]] || echo '(no response body)' >"$tmp/out.json"
}

# System RAM still available, in GB. llama.cpp keeps earlier prompts' KV cache in system RAM
# (--cache-ram, 8 GiB by default), which a small machine can run out of.
ram_free_gb() { awk '/^MemAvailable:/ { printf "%.1f", $2 / 1048576 }' /proc/meminfo; }

# Builds a prompt of about <tokens> tokens with the code halfway down: <tokens> <file>.
build_prompt() {
  local n half
  n=$(awk -v t="$1" -v s="$SAMPLE_TOKENS" 'BEGIN { printf "%d", t * 400 / s }')
  log_lines "$n" "$1" "$tmp/lines.txt"
  half=$((n / 2))
  { head -n "$half" "$tmp/lines.txt"; echo "$NEEDLE"; tail -n +"$((half + 1))" "$tmp/lines.txt"; } >"$2"
}

log "Context depth for $MODEL"
echo 'Warming up.' >"$tmp/tiny.txt"
code=$(chat "$tmp/tiny.txt" 'Reply with OK.' 8)
[[ "$code" == 200 ]] || die "The warm-up request failed (HTTP $code): $(head -c 500 "$tmp/out.json")"

opts=$(lemonade status --json 2>/dev/null |
  jq -c --arg m "$MODEL" '.models[] | select(.model_name == $m) | .recipe_options' 2>/dev/null)
[[ -n "$opts" ]] || opts='{}'
ctx=$(jq -r '.ctx_size // 0' <<<"$opts" 2>/dev/null)
slots=$(jq -r '.llamacpp_args // ""' <<<"$opts" 2>/dev/null | grep -oE -- '--parallel [0-9]+' | awk '{ print $2 }')
[[ "$ctx" =~ ^[0-9]+$ ]] || ctx=0
slots=${slots:-1}
per_slot=$((ctx / slots))
if ((ctx > 0)); then
  info "loaded with $ctx tokens of context, $slots slot(s): $per_slot tokens per request"
else
  info "couldn't read the context size from lemonade status"
fi

log_lines 400 1 "$tmp/sample.txt"
SAMPLE_TOKENS=$(count_tokens "$tmp/sample.txt")
[[ "$SAMPLE_TOKENS" =~ ^[0-9]+$ && "$SAMPLE_TOKENS" -gt 0 ]] ||
  die "Couldn't count tokens through $BASE_URL/api/v1/tokenize."

info "system RAM available before: $(ram_free_gb) GB"
printf '    %8s  %8s  %13s  %-6s  %-24s  %s\n' Tokens 'Read in' 'Read speed' Code 'Generation at that depth' 'RAM free'
for target in "${SIZES[@]}"; do
  if ((per_slot > 0 && target + 300 > per_slot)); then
    info "$target tokens: skipped, more than one request's $per_slot"
    continue
  fi
  build_prompt "$target" "$tmp/prompt.txt"
  code=$(chat "$tmp/prompt.txt" "$ASK_CODE" 24)
  if [[ "$code" != 200 ]]; then
    printf '    %8s  HTTP %s: %s\n' "$target" "$code" "$(head -c 300 "$tmp/out.json")"
    continue
  fi
  read -r total pn pms <<<"$(jq -r '"\(.usage.prompt_tokens // 0) \(.timings.prompt_n // 0) \(.timings.prompt_ms // 0)"' "$tmp/out.json")"
  found=missed
  grep -qi -- "$CODE" <<<"$(jq -r '.choices[0].message.content // ""' "$tmp/out.json")" && found=found
  # Same prompt, another question: the prompt comes from the cache, so this times generation alone.
  code=$(chat "$tmp/prompt.txt" "$ASK_LONG" 256)
  gen=$(jq -r '.timings.predicted_per_second // 0' "$tmp/out.json" 2>/dev/null)
  awk -v t="$total" -v n="$pn" -v ms="$pms" -v f="$found" -v g="$gen" -v c="$code" -v r="$(ram_free_gb)" 'BEGIN {
    gs = (c == 200) ? sprintf("%.1f tok/s", g) : "HTTP " c
    printf "    %8d  %7.1fs  %7.0f tok/s  %-6s  %-24s  %s GB\n", t, ms / 1000, (ms > 0 ? n * 1000 / ms : 0), f, gs, r
  }'
done

if ((per_slot > 0)); then
  over=$((per_slot + 4000))
  build_prompt "$over" "$tmp/prompt.txt"
  code=$(chat "$tmp/prompt.txt" "$ASK_CODE" 24)
  msg=$(jq -r '.error.message // .error // .choices[0].message.content // empty' "$tmp/out.json" 2>/dev/null | head -c 300)
  info "About $over tokens, more than one request's $per_slot: HTTP $code: ${msg:-$(head -c 300 "$tmp/out.json")}"
fi
info "VRAM in use: $(vram_gb used) GB of $(vram_gb total) GB"
