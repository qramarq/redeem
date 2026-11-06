#!/usr/bin/env bash
# Build ventoy/ for the root of the Ventoy exFAT partition.
# The stock SystemRescue ISO is only read. Boot configs are replaced in memory
# by Ventoy's conf_replace plugin, and /redeem.yaml is injected into the initramfs.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$here/lib.sh"
load_versions

root=$(redeem_root)
out=$root/usb-root/ventoy
iso=$root/build/cache/isos/$SYSRESCUE_FILE
stock=$root/boot/systemrescue-13.02
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

extract_stock() {
    local dest=$1
    mkdir -p "$dest"
    if [[ -f $iso ]]; then
        command -v xorriso >/dev/null 2>&1 || die "xorriso is required to read $iso"
        verify_sha256 "$iso" "$SYSRESCUE_SHA256"
        if ! xorriso -osirrox on -indev "$iso" \
            -extract /boot/grub/grubsrcd.cfg "$dest/grubsrcd.cfg" \
            -extract /sysresccd/boot/syslinux/sysresccd_sys.cfg "$dest/sysresccd_sys.cfg" \
            -extract /sysresccd/boot/syslinux/sysresccd_head.cfg "$dest/sysresccd_head.cfg" \
            >/dev/null 2>&1; then
            die "xorriso could not read the SystemRescue boot configs from $iso"
        fi
        if [[ -f $stock/grubsrcd.cfg ]]; then
            cmp -s "$dest/grubsrcd.cfg" "$stock/grubsrcd.cfg" \
                || die "ISO grubsrcd.cfg does not match boot/systemrescue-13.02 (stock SystemRescue 13.02 drifted)"
            cmp -s "$dest/sysresccd_sys.cfg" "$stock/sysresccd_sys.cfg" \
                || die "ISO sysresccd_sys.cfg does not match boot/systemrescue-13.02"
            cmp -s "$dest/sysresccd_head.cfg" "$stock/sysresccd_head.cfg" \
                || die "ISO sysresccd_head.cfg does not match boot/systemrescue-13.02"
        fi
        return 0
    fi
    [[ -f $stock/grubsrcd.cfg && -f $stock/sysresccd_sys.cfg && -f $stock/sysresccd_head.cfg ]] \
        || die "missing $iso and the stock boot templates in $stock"
    cp -a "$stock/grubsrcd.cfg" "$stock/sysresccd_sys.cfg" "$stock/sysresccd_head.cfg" "$dest/"
}

extract_stock "$work/stock"

python3 - "$work" <<'PY'
import pathlib, re, sys
work = pathlib.Path(sys.argv[1])
stock = work / "stock"
grub = (stock / "grubsrcd.cfg").read_text()
syscfg = (stock / "sysresccd_sys.cfg").read_text()
head = (stock / "sysresccd_head.cfg").read_text()
param = "sysrescuecfg=/redeem.yaml"

if "archisolabel=RESCUE1302" not in grub or "archisolabel=RESCUE1302" not in syscfg:
    raise SystemExit("stock boot config is not SystemRescue 13.02 (volume label RESCUE1302)")

grub2, n = re.subn(r"set timeout=\d+", "set timeout=2", grub, count=1)
if n != 1:
    raise SystemExit("grubsrcd.cfg has no set timeout= line")
lines = grub2.splitlines(keepends=True)
seen = False
out = []
for line in lines:
    if not seen and re.match(r"\s*linux\s+/sysresccd/", line):
        if param not in line:
            line = line.rstrip("\n") + " " + param + "\n"
        seen = True
    out.append(line)
if not seen:
    raise SystemExit("default GRUB linux entry was not found in /boot/grub/grubsrcd.cfg")
(work / "grubsrcd.cfg").write_text("".join(out))

if not re.search(r"^TIMEOUT\s+\d+", head, re.M):
    raise SystemExit("sysresccd_head.cfg has no TIMEOUT (BIOS menu timeout)")
head2, n = re.subn(r"^TIMEOUT\s+\d+", "TIMEOUT 20", head, count=1, flags=re.M)
if n != 1:
    raise SystemExit("failed to set the syslinux TIMEOUT")
include = "INCLUDE boot/syslinux/sysresccd_head.cfg"
if include not in syscfg:
    raise SystemExit("sysresccd_sys.cfg does not include boot/syslinux/sysresccd_head.cfg")
# The stock TIMEOUT lives in the included head. Inline it so the replaced
# sysresccd_sys.cfg alone shortens the BIOS menu to 2 seconds (TIMEOUT is tenths).
syscfg = syscfg.replace(include, head2.rstrip("\n") + "\n\nDEFAULT sysresccd\n", 1)
lines = syscfg.splitlines(keepends=True)
seen = False
out = []
for line in lines:
    if not seen and re.match(r"\s*APPEND\s+", line):
        if param not in line:
            line = line.rstrip("\n") + " " + param + "\n"
        seen = True
    out.append(line)
if not seen:
    raise SystemExit("default syslinux APPEND line was not found")
(work / "sysresccd_sys.cfg").write_text("".join(out))
PY

rm -rf "$out"
mkdir -p "$out" "$work/tar/usr/local/bin" \
    "$work/tar/live_injection_7ed136ec_7a61_4b54_adc3_ae494d5106ea" \
    "$work/sysroot/usr/local/bin"

install -m 0644 "$root/boot/redeem.yaml" "$work/tar/redeem.yaml"
install -m 0755 "$root/boot/redeem-autostart" "$work/tar/usr/local/bin/redeem-autostart"
install -m 0755 "$root/boot/redeem-autostart" "$work/sysroot/usr/local/bin/redeem-autostart"
install -m 0755 "$root/boot/live-injection/hook.sh" \
    "$work/tar/live_injection_7ed136ec_7a61_4b54_adc3_ae494d5106ea/hook.sh"
install -m 0755 "$root/boot/live-injection/copy-to-newroot.sh" \
    "$work/tar/live_injection_7ed136ec_7a61_4b54_adc3_ae494d5106ea/copy-to-newroot.sh"
tar -czf "$work/tar/live_injection_7ed136ec_7a61_4b54_adc3_ae494d5106ea/sysroot.tar.gz" \
    -C "$work" sysroot
tar -czf "$out/redeem-initramfs.tar.gz" -C "$work/tar" \
    redeem.yaml \
    usr \
    live_injection_7ed136ec_7a61_4b54_adc3_ae494d5106ea

install -m 0644 "$work/grubsrcd.cfg" "$out/grubsrcd.cfg"
install -m 0644 "$work/sysresccd_sys.cfg" "$out/sysresccd_sys.cfg"

# HBCD_PE_x64.iso is not injected and is not the default. When that ISO sits
# in the stick root, Ventoy lists it beside Clonezilla during the 5 second
# timeout. SystemRescue stays VTOY_DEFAULT_IMAGE.
python3 - "$out/ventoy.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
doc = {
    "control": [
        {"VTOY_DEFAULT_IMAGE": "/systemrescue-13.02-amd64.iso"},
        {"VTOY_MENU_TIMEOUT": "5"},
    ],
    "injection": [
        {
            "image": "/systemrescue-13.02-amd64.iso",
            "archive": "/ventoy/redeem-initramfs.tar.gz",
        }
    ],
    "conf_replace": [
        {
            "iso": "/systemrescue-13.02-amd64.iso",
            "org": "/boot/grub/grubsrcd.cfg",
            "new": "/ventoy/grubsrcd.cfg",
        },
        {
            "iso": "/systemrescue-13.02-amd64.iso",
            "org": "/sysresccd/boot/syslinux/sysresccd_sys.cfg",
            "new": "/ventoy/sysresccd_sys.cfg",
        },
    ],
}
path.write_text(json.dumps(doc, indent=4) + "\n")
PY

if [[ -f $iso ]]; then
    verify_sha256 "$iso" "$SYSRESCUE_SHA256"
fi

printf 'ventoy tree ready: %s\n' "$out"
find "$out" -type f | sort
