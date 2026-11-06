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

bl=scripts/rescue-bitlocker.sh
bit_fix=scripts/testdata/bitlocker
bit_out=$(mktemp)
if bash "$bl" parse-dump --fixture "$bit_fix/bitlk-clear-key.txt" >"$bit_out" \
  && grep -q $'clear_key\tyes' "$bit_out" \
  && grep -q 'C1EAC1EA' "$bit_out" \
  && grep -q $'\tclear-key$' "$bit_out" \
  && grep -q 'A1B2C3D4' "$bit_out" \
  && grep -q $'\trecovery-password$' "$bit_out" \
  && grep -q $'\ttpm-pin$' "$bit_out" \
  && grep -q $'\texternal-key$' "$bit_out" \
  && ! grep -q 'deadbeefcafebabe' "$bit_out"; then
  printf 'ok bitlocker-parse-clear\n'
else
  printf 'FAIL bitlocker-parse-clear\n' >&2
  cat "$bit_out" >&2
  fail=1
fi
if bash "$bl" parse-dump --fixture "$bit_fix/bitlk-no-clear.txt" >"$bit_out" \
  && grep -q $'clear_key\tno' "$bit_out" \
  && grep -q 'D00D1234' "$bit_out" \
  && grep -q 'C0FFEE01' "$bit_out" \
  && ! grep -q 'naclshouldnotappear' "$bit_out"; then
  printf 'ok bitlocker-parse-no-clear\n'
else
  printf 'FAIL bitlocker-parse-no-clear\n' >&2
  fail=1
fi
if bash "$bl" parse-dump --fixture "$bit_fix/dislocker-metadata.txt" >"$bit_out" \
  && grep -q $'source\tdislocker-metadata' "$bit_out" \
  && grep -q 'AES-XTS-128' "$bit_out" \
  && grep -q $'\tclear-key$' "$bit_out" \
  && grep -q $'\trecovery-password$' "$bit_out" \
  && ! grep -q '00112233445566778899aabbccddeeff' "$bit_out"; then
  printf 'ok bitlocker-parse-dislocker\n'
else
  printf 'FAIL bitlocker-parse-dislocker\n' >&2
  cat "$bit_out" >&2
  fail=1
fi
if bash "$bl" inspect --fixture "$bit_fix/bitlk-clear-key.txt" --smart-health failed >"$bit_out" \
  && grep -q 'clear_key: yes' "$bit_out" \
  && grep -q 'Do not run manage-bde -off' "$bit_out" \
  && grep -q 'account.microsoft.com/devices/recoverykey' "$bit_out" \
  && grep -q 'Do not paste' "$bit_out" \
  && ! grep -q 'deadbeefcafebabe' "$bit_out"; then
  printf 'ok bitlocker-inspect-guidance\n'
else
  printf 'FAIL bitlocker-inspect-guidance\n' >&2
  fail=1
fi
if bash "$bl" version-at-least 2.3.0 2.8.7 >/dev/null \
  && ! bash "$bl" version-at-least 2.3.0 2.2.9 >/dev/null; then
  printf 'ok bitlocker-version\n'
else
  printf 'FAIL bitlocker-version\n' >&2
  fail=1
fi
secret='s3cret-value'
if bash "$bl" unlock --password "$secret" /dev/sda /mnt/x >"$bit_out" 2>&1; then
  printf 'FAIL bitlocker-password-flag (expected rejection)\n' >&2
  fail=1
elif grep -q "$secret" "$bit_out"; then
  printf 'FAIL bitlocker-password-flag echoed the secret\n' >&2
  fail=1
else
  printf 'ok bitlocker-refuse-password\n'
fi
expect_reject bitlocker-refuse-rw bash "$bl" unlock --rw /dev/sda /mnt/x
expect_reject bitlocker-refuse-key bash "$bl" unlock --key hunter2 /dev/sda
expect_reject bitlocker-refuse-shaped bash "$bl" unlock /dev/sda 111111-222222-333333-444444-555555-666666-777777-888888
expect_reject bitlocker-refuse-volume-key bash "$bl" inspect --dump-volume-key /dev/sda
stub=$(mktemp -d)
cat >"$stub/cryptsetup" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$stub/called"
exit 99
EOF
cat >"$stub/dislocker" <<EOF
#!/bin/sh
printf '%s\n' "dislocker \$*" >>"$stub/called"
exit 99
EOF
cat >"$stub/dislocker-metadata" <<EOF
#!/bin/sh
printf '%s\n' "meta \$*" >>"$stub/called"
exit 99
EOF
cat >"$stub/mount" <<EOF
#!/bin/sh
printf '%s\n' "mount \$*" >>"$stub/called"
exit 99
EOF
chmod +x "$stub"/*
if PATH="$stub:$PATH" bash "$bl" inspect --dry-run /dev/sda >"$bit_out" \
  && PATH="$stub:$PATH" bash "$bl" unlock --dry-run --clearkey /dev/nvme0n1p3 /mnt/ro-test >>"$bit_out" \
  && grep -q 'cryptsetup bitlkDump' "$bit_out" \
  && grep -q 'cryptsetup open --type bitlk --readonly' "$bit_out" \
  && grep -q 'dislocker -r -V' "$bit_out" \
  && grep -q -- '--clearkey' "$bit_out" \
  && grep -q 'mount -o ro,nodev,nosuid,noexec' "$bit_out" \
  && grep -q 'mount -o loop,ro,nodev,nosuid,noexec' "$bit_out" \
  && [[ ! -e $stub/called ]]; then
  printf 'ok bitlocker-dry-run-no-exec\n'
else
  printf 'FAIL bitlocker-dry-run-no-exec\n' >&2
  cat "$bit_out" >&2
  [[ -e $stub/called ]] && cat "$stub/called" >&2
  fail=1
fi
rm -rf "$stub" "$bit_out"

if bash build/fetch-isos.sh --help | grep -q -- '--with-winpe' \
  && bash build/fetch-isos.sh --help | grep -q -- '--winpe-iso' \
  && grep -q '8c4c670c9c84d6c4b5a9c32e0aa5a55d8c23de851d259207d54679ea774c2498' build/versions.env; then
  printf 'ok fetch-winpe-flags\n'
else
  printf 'FAIL fetch-winpe-flags\n' >&2
  fail=1
fi
expect_reject fetch-winpe-dev bash build/fetch-isos.sh --winpe-iso /dev/sda
expect_reject fetch-winpe-nvme bash build/fetch-isos.sh --winpe-iso /dev/nvme0n1
fake_iso=$(mktemp --suffix=.iso)
printf 'not-an-iso\n' >"$fake_iso"
expect_reject fetch-winpe-unverified bash build/fetch-isos.sh --winpe-iso "$fake_iso"
bad_sum=$(printf 'ab%.0s' {1..32})
expect_reject fetch-winpe-bad-sum bash build/fetch-isos.sh --winpe-iso "$fake_iso" --winpe-sha256 "$bad_sum"
rm -f "$fake_iso"

ai_tmp=$(mktemp -d)
if bash build/assemble-ai.sh "$ai_tmp" >"$ai_tmp/log" \
  && [[ -x $ai_tmp/scripts/redeem-bitlocker ]] \
  && [[ -f $ai_tmp/scripts/rescue-bitlocker.sh ]] \
  && [[ -f $ai_tmp/scripts/bitlocker-windows.ps1 ]] \
  && cmp -s scripts/rescue-bitlocker.sh "$ai_tmp/scripts/redeem-bitlocker" \
  && [[ -f usb-root/BitLocker-Windows.bat ]]; then
  printf 'ok assemble-bitlocker\n'
else
  printf 'FAIL assemble-bitlocker\n' >&2
  cat "$ai_tmp/log" >&2
  fail=1
fi
rm -rf "$ai_tmp"

fw_diag=$(mktemp)
if bash scripts/collect-diag.sh --out "$fw_diag" --max-bytes 12000 >/dev/null \
  && grep -q '## firmware' "$fw_diag" \
  && grep -q 'Secure Boot:' "$fw_diag" \
  && grep -q 'tpm' "$fw_diag"; then
  printf 'ok collect-diag-firmware\n'
else
  printf 'FAIL collect-diag-firmware\n' >&2
  fail=1
fi
rm -f "$fw_diag"

exit "$fail"
