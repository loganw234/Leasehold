#!/usr/bin/env bash
# Saves a machine's Lemonade records in one archive, before its lease ends:
#   summary.txt          the machine, the versions that ran, each model with the Hugging Face
#                        revision it was pulled at, and token usage per model from the server log
#   lemonade/            config, saved load options, and the server's health, stats, models and
#                        system info from its API
#   logs/                the lemond journal and the setup log
#   vllm-gfx942-report/  the vLLM test's report, if there is one
# It changes nothing on the machine except the archive it writes.
# leasehold.ps1 collect runs it; leasehold.ps1 down runs it before destroying a droplet.
#
# Usage: sudo bash collect.sh <archive.tar.gz> [owner]
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HERE/lib.sh"

OUT=${1:?usage: collect.sh <archive.tar.gz> [owner]}
OWNER=${2:-}
require_root

work=$(mktemp -d)
R="$work/records"
mkdir -p "$R/lemonade" "$R/logs"
STATE=/var/lib/lemonade   # where the Debian/Ubuntu package's service keeps its config and models
UNIT=$(lemond_unit)
api() { curl -fsS --max-time 15 "${BASE_URL}$1" 2>/dev/null; }

for f in config.json recipe_options.json user_models.json; do
  [[ -f "$STATE/$f" ]] && cp "$STATE/$f" "$R/lemonade/"
done
if server_up; then
  for p in health stats models system-info; do
    api "/api/v1/$p" >"$R/lemonade/$p.json" || rm -f "$R/lemonade/$p.json"
  done
  lemonade status --json >"$R/lemonade/status.json" 2>/dev/null || rm -f "$R/lemonade/status.json"
fi
lemonade backends --all >"$R/lemonade/backends.txt" 2>&1 || true
if [[ -n "$UNIT" ]]; then
  journalctl -u "$UNIT" --no-pager -o short-iso >"$R/logs/lemond.journal.log" 2>/dev/null
fi
[[ -f /root/lemonade-setup.log ]] && cp /root/lemonade-setup.log "$R/logs/"
[[ -d /root/vllm-gfx942-report ]] && cp -r /root/vllm-gfx942-report "$R/"

{
  echo "collected (UTC): $(date -u +%FT%TZ)"
  echo "host: $(hostname), up since $(uptime -s)"
  echo "os: $(. /etc/os-release && echo "$PRETTY_NAME"), kernel $(uname -r)"
  echo "gpu: $(detect_gfx || echo none), $(vram_gb total) GB VRAM"
  if command -v rocminfo >/dev/null; then
    rocminfo 2>/dev/null | grep -m1 -E 'Marketing Name:.*(Radeon|Instinct)' | sed 's/^ *Marketing Name: */gpu name: /'
  fi
  if command -v amd-smi >/dev/null; then
    echo "system rocm: $(amd-smi version 2>/dev/null | grep -oE 'ROCm version: [^|]+' | sed 's/ROCm version: //; s/ *$//')"
  elif [[ -r /opt/rocm/.info/version ]]; then
    echo "system rocm: $(cat /opt/rocm/.info/version)"
  fi
  echo "lemonade-server package: $(dpkg-query -W -f='${Version}' lemonade-server 2>/dev/null || echo not installed)"
  for v in /var/cache/lemonade/bin/*/*/version.txt; do
    [[ -r "$v" ]] && echo "backend $(awk -F/ '{print $(NF-2) "/" $(NF-1)}' <<<"$v"): $(tr -d '\n' <"$v")"
  done
  echo
  echo "models in the cache, with the Hugging Face revision each was pulled at:"
  found=0
  for d in "$STATE"/.cache/huggingface/hub/models--*; do
    [[ -d "$d" ]] || continue
    found=1
    echo "  $(basename "$d" | sed 's/^models--//; s/--/\//g') @ $(cat "$d/refs/main" 2>/dev/null || echo unknown)"
  done
  ((found)) || echo "  none"
  echo
  echo "usage by model, from the server's log:"
  if [[ -s "$R/logs/lemond.journal.log" ]]; then
    grep 'Inference completed' "$R/logs/lemond.journal.log" |
      sed -E 's/.*model=([^,]+), tokens=[0-9]+ \(in=([0-9]+), out=([0-9]+)\).*tps=([0-9.]+).*/\1 \2 \3 \4/' |
      awk '{ n[$1]++; i[$1] += $2; o[$1] += $3; t[$1] += $4; c++ }
           END {
             for (m in n) printf "  %s: %d requests, %d tokens in, %d out, %.1f tok/s on average\n", m, n[m], i[m], o[m], t[m] / n[m]
             if (c == 0) print "  none recorded"
           }'
  else
    echo "  no server log"
  fi
} >"$R/summary.txt"

tar -czf "$OUT" -C "$work" records
[[ -n "$OWNER" ]] && chown "$OWNER" "$OUT"
cat "$R/summary.txt"
echo
echo "Records: $(du -h "$OUT" | cut -f1) in $OUT"
rm -rf "$work"
