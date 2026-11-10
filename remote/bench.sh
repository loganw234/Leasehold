#!/usr/bin/env bash
# Measures how generation speed scales with simultaneous requests on the local Lemonade server:
# one request on its own, then N at once, each asked for the same number of tokens. Use it to see
# what -Slots buys before running several agents against one model.
#
# Usage: bash bench.sh <model> [concurrency=4] [max_tokens=256]
# (leasehold.ps1 bench uploads and runs it.)
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HERE/lib.sh"

MODEL=${1:?usage: bench.sh <model> [concurrency] [max_tokens]}
N=${2:-4}
MAXT=${3:-256}
[[ "$N" =~ ^[1-9][0-9]*$ && "$MAXT" =~ ^[1-9][0-9]*$ ]] || die "concurrency and max_tokens must be positive integers."
server_up || die "Lemonade is not answering on $BASE_URL."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

request() {  # out_file max_tokens
  curl -sS --max-time 1800 "${BASE_URL}/v1/chat/completions" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg m "$MODEL" --argjson t "$2" '{model: $m, max_tokens: $t, temperature: 0.7,
          messages: [{role: "user", content: "Write a long, detailed story about a lighthouse keeper. Keep going until you are stopped."}]}')" \
    >"$1"
}

batch() {  # concurrency
  local c=$1 i n total=0 t0 t1
  t0=$(date +%s.%N)
  for ((i = 0; i < c; i++)); do request "$tmp/r$c-$i" "$MAXT" & done
  wait
  t1=$(date +%s.%N)
  for ((i = 0; i < c; i++)); do
    n=$(jq -r '.usage.completion_tokens // 0' "$tmp/r$c-$i" 2>/dev/null || echo 0)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    total=$((total + n))
  done
  awk -v c="$c" -v n="$total" -v a="$t0" -v b="$t1" 'BEGIN {
    s = b - a
    printf "    %2d at once: %5d tokens in %5.1f s = %6.1f tok/s in total, %5.1f per request\n", c, n, s, n / s, n / s / c
  }'
}

log "Generation speed for $MODEL ($MAXT tokens per request)"
# A short warm-up, so loading the model on first use doesn't count against the first batch.
request "$tmp/warmup" 8
opts=$(lemonade status --json 2>/dev/null |
  jq -c --arg m "$MODEL" '.models[] | select(.model_name == $m) | .recipe_options' 2>/dev/null)
info "loaded with: ${opts:-unknown}"
batch 1
batch "$N"
