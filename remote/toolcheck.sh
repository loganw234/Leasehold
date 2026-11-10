#!/usr/bin/env bash
# Checks how reliably the loaded model calls tools: picking the right one of three with the right
# arguments, leaving them alone when no tool is needed, and using a tool's result in its answer.
# Cases go through the OpenAI-style API that Pi uses; two also go through the Anthropic-style API
# that Claude Code uses. Each case runs REPEATS times with the model's own sampling settings.
#
# Usage: bash toolcheck.sh <model> [repeats=2]
# (leasehold.ps1 toolcheck uploads and runs it.)
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HERE/lib.sh"

MODEL=${1:?usage: toolcheck.sh <model> [repeats]}
REPEATS=${2:-2}
[[ "$REPEATS" =~ ^[1-9][0-9]*$ ]] || die "repeats must be a positive integer."
server_up || die "Lemonade is not answering on $BASE_URL."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

TOOLS='[
 {"type": "function", "function": {"name": "get_weather", "description": "Current weather for a city.",
   "parameters": {"type": "object", "properties": {"city": {"type": "string"},
     "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]}}, "required": ["city"]}}},
 {"type": "function", "function": {"name": "convert_currency", "description": "Converts an amount between currencies.",
   "parameters": {"type": "object", "properties": {"amount": {"type": "number"},
     "from": {"type": "string", "description": "ISO 4217 code, e.g. USD"},
     "to": {"type": "string", "description": "ISO 4217 code, e.g. EUR"}}, "required": ["amount", "from", "to"]}}},
 {"type": "function", "function": {"name": "search_files", "description": "Searches file contents under a folder.",
   "parameters": {"type": "object", "properties": {"pattern": {"type": "string"},
     "path": {"type": "string"}}, "required": ["pattern"]}}}
]'

# Each case: a name, the user's message, and a jq test over {calls: [{name, args}], text}.
CASES=(
  'weather|What is the weather in Paris right now?|any(.calls[]; .name == "get_weather" and (.args.city | test("paris"; "i")))'
  'currency|How much is 250 US dollars in euros?|any(.calls[]; .name == "convert_currency" and .args.amount == 250 and (.args.from | ascii_upcase) == "USD" and (.args.to | ascii_upcase) == "EUR")'
  'currency2|Convert 99.5 GBP to JPY.|any(.calls[]; .name == "convert_currency" and .args.amount == 99.5 and (.args.from | ascii_upcase) == "GBP" and (.args.to | ascii_upcase) == "JPY")'
  'search|Find the files under src that mention TODO.|any(.calls[]; .name == "search_files" and (.args.pattern | test("TODO")))'
  'two-cities|Is it colder in Oslo or in Helsinki right now?|any(.calls[]; .name == "get_weather" and (.args.city | test("oslo|helsinki"; "i")))'
  'no-tool-math|What is 17 times 23? Answer with the number.|(.calls | length) == 0 and (.text | test("391"))'
  'no-tool-poem|Write a two-line poem about the sea.|(.calls | length) == 0 and (.text | length) > 10'
)

# OpenAI-style request; leaves {calls, text} in $tmp/r.json. Thinking stays as the model's default.
openai() {  # <messages json>
  jq -n --arg m "$MODEL" --argjson msgs "$1" --argjson tools "$TOOLS" \
    '{model: $m, max_tokens: 4096, messages: $msgs, tools: $tools}' >"$tmp/body.json"
  curl -sS --max-time 600 "$BASE_URL/v1/chat/completions" -H 'Content-Type: application/json' \
    -d @"$tmp/body.json" >"$tmp/raw.json" 2>/dev/null
  jq '{calls: [(.choices[0].message.tool_calls // [])[] | {name: .function.name,
         args: (.function.arguments | (try fromjson catch {}))}],
       text: (.choices[0].message.content // ""), raw_message: .choices[0].message}' \
    "$tmp/raw.json" >"$tmp/r.json" 2>/dev/null || echo '{"calls": [], "text": "", "error": true}' >"$tmp/r.json"
}

# Anthropic-style request, as Claude Code sends it; same shape in $tmp/r.json.
anthropic() {  # <user text>
  jq -n --arg m "$MODEL" --arg u "$1" --argjson tools "$TOOLS" \
    '{model: $m, max_tokens: 4096, messages: [{role: "user", content: $u}],
      tools: [$tools[] | .function | {name, description, input_schema: .parameters}]}' >"$tmp/body.json"
  curl -sS --max-time 600 "$BASE_URL/v1/messages" -H 'Content-Type: application/json' \
    -H 'anthropic-version: 2023-06-01' -H 'x-api-key: lemonade' -d @"$tmp/body.json" >"$tmp/raw.json" 2>/dev/null
  jq '{calls: [(.content // [])[] | select(.type == "tool_use") | {name, args: .input}],
       text: ([(.content // [])[] | select(.type == "text") | .text] | join(""))}' \
    "$tmp/raw.json" >"$tmp/r.json" 2>/dev/null || echo '{"calls": [], "text": "", "error": true}' >"$tmp/r.json"
}

passes=0 total=0
declare -A score
log "Tool calling: $MODEL, each case $REPEATS times"
for c in "${CASES[@]}"; do
  IFS='|' read -r name text test <<<"$c"
  for ((i = 1; i <= REPEATS; i++)); do
    openai "$(jq -n --arg u "$text" '[{role: "user", content: $u}]')"
    total=$((total + 1))
    if jq -e "$test" "$tmp/r.json" >/dev/null 2>&1; then
      passes=$((passes + 1)); score[$name]=$((${score[$name]:-0} + 1))
    else
      info "$name #$i missed: $(jq -c '{calls, text: (.text[0:120])}' "$tmp/r.json" 2>/dev/null | head -c 300)"
    fi
  done
done

# The round trip: the model asks for the weather, gets an answer, and must use it.
for ((i = 1; i <= REPEATS; i++)); do
  first='[{"role": "user", "content": "What is the weather in Tokyo? Use the tool, then tell me."}]'
  openai "$first"
  total=$((total + 1))
  call=$(jq -c '.raw_message.tool_calls[0] // empty' "$tmp/r.json" 2>/dev/null)
  if [[ -z "$call" ]]; then
    info "round-trip #$i missed: no tool call in the first turn"
    continue
  fi
  msgs=$(jq -n --argjson first "$first" --argjson call "$call" '$first + [
    {role: "assistant", content: "", tool_calls: [$call]},
    {role: "tool", tool_call_id: $call.id, content: "{\"temp_c\": 18, \"conditions\": \"light rain\"}"}]')
  openai "$msgs"
  if jq -e '(.calls | length) == 0 and (.text | test("18")) and (.text | test("rain"; "i"))' "$tmp/r.json" >/dev/null 2>&1; then
    passes=$((passes + 1)); score[round-trip]=$((${score[round-trip]:-0} + 1))
  else
    info "round-trip #$i missed: $(jq -c '{calls, text: (.text[0:120])}' "$tmp/r.json" 2>/dev/null | head -c 300)"
  fi
done

# The same tool choice through /v1/messages.
for c in "${CASES[0]}" "${CASES[1]}"; do
  IFS='|' read -r name text test <<<"$c"
  for ((i = 1; i <= REPEATS; i++)); do
    anthropic "$text"
    total=$((total + 1))
    if jq -e "$test" "$tmp/r.json" >/dev/null 2>&1; then
      passes=$((passes + 1)); score[messages-$name]=$((${score[messages-$name]:-0} + 1))
    else
      info "messages-$name #$i missed: $(jq -c '{calls, text: (.text[0:120])}' "$tmp/r.json" 2>/dev/null | head -c 300)"
    fi
  done
done

for k in weather currency currency2 search two-cities no-tool-math no-tool-poem round-trip messages-weather messages-currency; do
  printf '    %-20s %d/%d\n' "$k" "${score[$k]:-0}" "$REPEATS"
done
info "$MODEL: $passes of $total passed"
