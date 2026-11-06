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
  mapfile -t scripts < <(
    find scripts boot -type f \( -name '*.sh' -o -name 'rescue-ai' -o -name 'autorun' -o -name 'redeem-autostart' \) -print
    find build -maxdepth 1 -type f -name '*.sh' -print
    find usb-root -maxdepth 1 -type f \( -name '*.sh' -o -name '*.command' \) -print
  )
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

if grep -q -- '--slim' build/fetch-models.sh && grep -q -- '--slim' build/assemble-ai.sh; then
  printf 'ok slim-flag\n'
else
  printf 'FAIL --slim is missing from the model fetch or assemble script\n' >&2
  fail=1
fi
check fetch-models-help bash build/fetch-models.sh --help
check assemble-ai-help bash build/assemble-ai.sh --help

check assemble-ventoy bash build/assemble-ventoy.sh
ventoy=usb-root/ventoy
if python3 - "$ventoy/ventoy.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["control"][0]["VTOY_DEFAULT_IMAGE"] == "/systemrescue-13.02-amd64.iso"
assert doc["control"][1]["VTOY_MENU_TIMEOUT"] == "5"
assert doc["injection"][0]["image"] == "/systemrescue-13.02-amd64.iso"
assert doc["injection"][0]["archive"] == "/ventoy/redeem-initramfs.tar.gz"
assert doc["conf_replace"][0]["org"] == "/boot/grub/grubsrcd.cfg"
assert doc["conf_replace"][0]["new"] == "/ventoy/grubsrcd.cfg"
assert doc["conf_replace"][1]["org"] == "/sysresccd/boot/syslinux/sysresccd_sys.cfg"
assert doc["conf_replace"][1]["new"] == "/ventoy/sysresccd_sys.cfg"
PY
then
  printf 'ok ventoy-json\n'
else
  printf 'FAIL ventoy.json\n' >&2
  fail=1
fi

list=$(mktemp)
tar -tzf "$ventoy/redeem-initramfs.tar.gz" >"$list"
if grep -qx 'redeem.yaml' "$list" && grep -qx 'usr/local/bin/redeem-autostart' "$list"; then
  printf 'ok initramfs-members\n'
else
  printf 'FAIL initramfs is missing redeem.yaml or redeem-autostart\n' >&2
  fail=1
fi
rm -f "$list"
yaml=$(mktemp)
tar -xOf "$ventoy/redeem-initramfs.tar.gz" redeem.yaml >"$yaml"
if grep -q 'dostartx: true' "$yaml" && grep -q 'ar_nowait: true' "$yaml" \
  && grep -q 'ar_ignorefail: true' "$yaml" && grep -q 'ar_disable: false' "$yaml" \
  && grep -q '/usr/local/bin/redeem-autostart' "$yaml" \
  && ! grep -Eq '^[[:space:]]*tty1:' "$yaml"; then
  printf 'ok redeem-yaml\n'
else
  printf 'FAIL redeem.yaml\n' >&2
  fail=1
fi
rm -f "$yaml"
if grep -q 'sysrescuecfg=/redeem.yaml' "$ventoy/grubsrcd.cfg" \
  && grep -q 'set timeout=2' "$ventoy/grubsrcd.cfg" \
  && grep -q 'archisolabel=RESCUE1302' "$ventoy/grubsrcd.cfg" \
  && grep -q 'sysrescuecfg=/redeem.yaml' "$ventoy/sysresccd_sys.cfg" \
  && grep -q 'TIMEOUT 20' "$ventoy/sysresccd_sys.cfg" \
  && grep -q 'archisolabel=RESCUE1302' "$ventoy/sysresccd_sys.cfg"; then
  printf 'ok boot-conf-replace\n'
else
  printf 'FAIL replaced boot configs\n' >&2
  fail=1
fi

watcher_out=$(mktemp)
watcher_home=$(mktemp -d)
expect_reject() {
  local name=$1
  shift
  if "$@" >"$watcher_out" 2>&1; then
    printf 'FAIL %s (expected rejection)\n' "$name" >&2
    cat "$watcher_out" >&2
    fail=1
  else
    printf 'ok %s\n' "$name"
  fi
}
expect_reject watcher-empty-uuid env HOME="$watcher_home" bash scripts/host/install-watcher.sh --os linux --dry-run --uuid ''
expect_reject watcher-star-uuid env HOME="$watcher_home" bash scripts/host/install-watcher.sh --os linux --dry-run --uuid '*'
expect_reject watcher-word-uuid env HOME="$watcher_home" bash scripts/host/install-watcher.sh --os linux --dry-run --uuid 'any'
expect_reject watcher-bad-uuid env HOME="$watcher_home" bash scripts/host/install-watcher.sh --os linux --dry-run --uuid 'not-a-uuid'
expect_reject watcher-nil-uuid env HOME="$watcher_home" bash scripts/host/install-watcher.sh --os linux --dry-run --uuid '00000000-0000-0000-0000-000000000000'

pinned=550e8400-e29b-41d4-a716-446655440000
if env HOME="$watcher_home" bash scripts/host/install-watcher.sh --os linux --dry-run --uuid "$pinned" >"$watcher_out" \
  && grep -q "$pinned" "$watcher_out" \
  && grep -q 'ID_FS_UUID' "$watcher_out" \
  && grep -q 'Start-Redeem-Linux.sh' "$watcher_out" \
  && ! find "$watcher_home" -type f | grep -q . \
  && [[ ! -e /etc/udev/rules.d/99-redeem-usb.rules ]] \
  && [[ ! -e $HOME/.config/systemd/user/redeem-usb.service ]]; then
  printf 'ok watcher-linux-dry-run\n'
else
  printf 'FAIL watcher-linux-dry-run\n' >&2
  cat "$watcher_out" >&2
  fail=1
fi
if env HOME="$watcher_home" bash scripts/host/install-watcher.sh --os macos --dry-run --uuid 'abcd-1234' >"$watcher_out" \
  && grep -q 'ABCD-1234' "$watcher_out" \
  && grep -q 'StartOnMount' "$watcher_out" \
  && grep -q 'Start-Redeem-macOS.command' "$watcher_out" \
  && ! find "$watcher_home" -type f | grep -q .; then
  printf 'ok watcher-macos-dry-run\n'
else
  printf 'FAIL watcher-macos-dry-run\n' >&2
  cat "$watcher_out" >&2
  fail=1
fi
if env HOME="$watcher_home" bash scripts/host/install-watcher.sh --os linux --dry-run --uuid 'abcd1234' >"$watcher_out" \
  && grep -q 'ABCD-1234' "$watcher_out"; then
  printf 'ok watcher-exfat-serial\n'
else
  printf 'FAIL watcher-exfat-serial\n' >&2
  fail=1
fi
rm -rf "$watcher_out" "$watcher_home"

exit "$fail"
