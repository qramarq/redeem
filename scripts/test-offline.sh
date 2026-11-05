#!/usr/bin/env bash
# Checks that do not need a model: shellcheck, the rubric, retrieval, the
# read-only collector, and the image-script device refusal.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
fail=0

check() {
  local name=$1
  shift
  if "$@"; then
    printf 'ok %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name" >&2
    fail=1
  fi
}

if command -v shellcheck >/dev/null 2>&1; then
  mapfile -t scripts < <(find scripts boot -type f \( -name '*.sh' -o -name 'rescue-ai' -o -name 'autorun' \) -print; find build -maxdepth 1 -type f -name '*.sh' -print)
  check shellcheck shellcheck --shell=bash "${scripts[@]}"
else
  printf 'skip shellcheck (not installed)\n'
fi

check score-self-test python3 bench/score.py --self-test

tmp=$(mktemp)
check kb-retrieve awk -f scripts/kb-retrieve.awk -v queryfile=bench/scenarios/05-bitlocker/diag.txt -v maxbytes=1500 kb/bitlocker.md kb/smart-attributes.md >"$tmp"
if grep -q 'bitlocker.md' "$tmp"; then
  printf 'ok kb-retrieve-bitlocker\n'
else
  printf 'FAIL kb-retrieve did not return bitlocker.md\n' >&2
  fail=1
fi
rm -f "$tmp"

check refuse-test bash build/make-test-image.sh --refuse-test

diag=$(mktemp)
check collect-diag bash scripts/collect-diag.sh --out "$diag" --max-bytes 8000
bytes=$(wc -c <"$diag" | tr -d ' ')
if ((bytes <= 8200)) && grep -q '## lsblk' "$diag" && grep -q '## bitlocker' "$diag"; then
  printf 'ok collect-diag-shape (%s bytes)\n' "$bytes"
else
  printf 'FAIL collect-diag shape (%s bytes)\n' "$bytes" >&2
  fail=1
fi
rm -f "$diag"

if grep -n 'ntfsfix' scripts/collect-diag.sh | grep -E 'as_root|sudo' | grep -v -- '--no-action' >/dev/null; then
  printf 'FAIL ntfsfix is invoked without --no-action\n' >&2
  fail=1
else
  printf 'ok ntfsfix-dry-run-only\n'
fi

if grep -R -n -E 'of=/dev/(sd|nvme|vd|mmc)' scripts build --include='*.sh' --include='rescue-ai' >/dev/null; then
  printf 'FAIL a script writes to a real-looking device path\n' >&2
  fail=1
else
  printf 'ok no-device-writes-in-scripts\n'
fi

kb_bytes=$(find kb -type f -name '*.md' -printf '%s\n' | awk '{s+=$1} END {print s+0}')
if ((kb_bytes < 1000000)); then
  printf 'ok kb-size %s bytes\n' "$kb_bytes"
else
  printf 'FAIL knowledge pack is %s bytes\n' "$kb_bytes" >&2
  fail=1
fi

exit "$fail"
