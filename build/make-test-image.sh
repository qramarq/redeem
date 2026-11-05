#!/usr/bin/env bash
# Build a sparse raw disk IMAGE and install Ventoy into that file.
# Never accepts a real block device. Loop devices are attached only to the
# image file and checked before Ventoy2Disk.sh runs.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$here/lib.sh"
load_versions

root=$(redeem_root)
IMAGE=$root/build/cache/rescue-test.img
SIZE=16G
SERIAL=0
REFUSE_TEST=0
LOOP=""
MNT=""
EFI_MNT=""
KEEPER=""

usage() {
  cat <<'EOF'
usage: make-test-image.sh [--image FILE] [--size 16G] [--serial-console]
                          [--refuse-test]

Creates a sparse raw image and installs Ventoy into it with -I -g -s.
ISOs from build/cache/isos and the assembled ai/ tree are copied onto the
exFAT partition. --serial-console rewrites the image's GRUB config so a
headless QEMU run can log the menu. Do not use that flag for a stick a
person will boot on real hardware.

This script refuses /dev/* and any path that is a block or character device.
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --image)
      IMAGE=${2:-}
      shift 2
      ;;
    --size)
      SIZE=${2:-}
      shift 2
      ;;
    --serial-console)
      SERIAL=1
      shift
      ;;
    --refuse-test)
      REFUSE_TEST=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if [[ $REFUSE_TEST -eq 1 ]]; then
  if target_is_safe_image /dev/sda; then
    die "refuse-test failed: /dev/sda was treated as safe"
  fi
  if target_is_safe_image /dev/nvme0n1; then
    die "refuse-test failed: /dev/nvme0n1 was treated as safe"
  fi
  sample=$(mktemp)
  if ! target_is_safe_image "$sample"; then
    rm -f "$sample"
    die "refuse-test failed: a regular file was rejected"
  fi
  rm -f "$sample"
  printf 'refuse-test ok\n'
  exit 0
fi

if [[ ! $SIZE =~ ^[0-9]+[KMGT]$ ]]; then
  die "size must look like 16G, not a path"
fi
assert_safe_image "$IMAGE"
mkdir -p "$(dirname -- "$IMAGE")"

if [[ -e $IMAGE && ! -f $IMAGE ]]; then
  die "refusing to replace non-file $IMAGE"
fi

truncate -s "$SIZE" "$IMAGE"
assert_safe_image "$IMAGE"
if [[ -b $IMAGE || -c $IMAGE ]]; then
  die "truncate produced a device node"
fi

for tool in mkfs.vfat udevadm losetup partprobe; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    die "missing $tool (install dosfstools and udev). redeem will not invent partition devices."
  fi
done

tarball=$root/build/cache/ventoy/$VENTOY_FILE
[[ -f $tarball ]] || die "missing $tarball (run build/fetch-isos.sh)"
verify_sha256 "$tarball" "$VENTOY_SHA256"
vdir=$root/build/cache/ventoy/ventoy-$VENTOY_VERSION
if [[ ! -f $vdir/Ventoy2Disk.sh ]]; then
  tar -xzf "$tarball" -C "$root/build/cache/ventoy"
fi
[[ -f $vdir/Ventoy2Disk.sh ]] || die "Ventoy2Disk.sh not in $vdir"

cleanup() {
  if [[ -n $KEEPER ]]; then
    sudo kill "$KEEPER" 2>/dev/null || true
    KEEPER=""
  fi
  if [[ -n $EFI_MNT && -d $EFI_MNT ]]; then
    sudo umount "$EFI_MNT" 2>/dev/null || true
    rmdir "$EFI_MNT" 2>/dev/null || true
  fi
  if [[ -n $MNT && -d $MNT ]]; then
    sudo umount "$MNT" 2>/dev/null || true
    rmdir "$MNT" 2>/dev/null || true
  fi
  if [[ -n $LOOP ]]; then
    sudo losetup -d "$LOOP" 2>/dev/null || true
  fi
}
trap cleanup EXIT

LOOP=$(sudo losetup --find --show --partscan "$IMAGE")
assert_loop_backs_image "$LOOP" "$IMAGE"

printf 'installing Ventoy %s onto loop %s backed by %s\n' "$VENTOY_VERSION" "$LOOP" "$IMAGE"
# This environment's udev does not recreate loop partition nodes after Ventoy
# re-reads the table. Re-add them with partx, and only for this loop.
keeper=$(mktemp)
cat >"$keeper" <<'EOF'
#!/bin/bash
loop=$1
while true; do
  if [[ ! -b ${loop}p1 || ! -b ${loop}p2 ]]; then
    partx -a "$loop" >/dev/null 2>&1 || partx -u "$loop" >/dev/null 2>&1 || true
  fi
  sleep 0.4
done
EOF
chmod +x "$keeper"
sudo "$keeper" "$LOOP" >/dev/null 2>&1 &
KEEPER=$!
# The only device argument is the loop we just checked. y/y answers Ventoy's
# two prompts. There is no path here that selects a physical disk.
(
  cd "$vdir"
  printf 'y\ny\n' | sudo ./Ventoy2Disk.sh -I -g -s "$LOOP"
)
sudo kill "$KEEPER" 2>/dev/null || true
wait "$KEEPER" 2>/dev/null || true
KEEPER=""
rm -f "$keeper"
assert_loop_backs_image "$LOOP" "$IMAGE"

sudo partx -a "$LOOP" 2>/dev/null || sudo partx -u "$LOOP" 2>/dev/null || true
sleep 1
if [[ ! -b ${LOOP}p1 ]]; then
  sudo losetup -d "$LOOP"
  LOOP=$(sudo losetup --find --show "$IMAGE")
  assert_loop_backs_image "$LOOP" "$IMAGE"
  sudo partx -a "$LOOP"
fi
[[ -b ${LOOP}p1 ]] || die "Ventoy data partition ${LOOP}p1 did not appear"
assert_loop_backs_image "$LOOP" "$IMAGE"

if [[ ! -x $root/ai/scripts/rescue-ai ]]; then
  "$root/build/assemble-ai.sh"
fi

MNT=$(mktemp -d)
if ! sudo mount -t exfat "${LOOP}p1" "$MNT" 2>/dev/null; then
  fuse=$vdir/tool/x86_64/mount.exfat-fuse
  [[ -x $fuse ]] || die "cannot mount exFAT on ${LOOP}p1"
  sudo "$fuse" "${LOOP}p1" "$MNT"
fi
shopt -s nullglob
isos=("$root/build/cache/isos"/*.iso)
if [[ ${#isos[@]} -eq 0 ]]; then
  printf 'warning: no ISOs in build/cache/isos\n'
else
  # exFAT via FUSE rejects ownership preservation. The bytes are what matter.
  sudo cp -r --no-preserve=mode,ownership "${isos[@]}" "$MNT/"
fi
shopt -u nullglob
sudo mkdir -p "$MNT/ai"
sudo cp -r --no-preserve=mode,ownership "$root/ai/." "$MNT/ai/"
printf 'payload on image:\n'
sudo ls -lh "$MNT" "$MNT/ai" "$MNT/ai/bin" "$MNT/ai/models" || true

if [[ $SERIAL -eq 1 && -b ${LOOP}p2 ]]; then
  # The build kernel may not have vfat. mtools edits the FAT image directly.
  if ! command -v mcopy >/dev/null 2>&1; then
    die "mtools is required to patch the EFI filesystem for a serial console"
  fi
  # Partition devices have no HDIO_GETGEO. mtools refuses them unless this is set.
  grep -q mtools_skip_check "$HOME/.mtoolsrc" 2>/dev/null || echo 'mtools_skip_check=1' >>"$HOME/.mtoolsrc"
  sudo bash -c 'grep -q mtools_skip_check /root/.mtoolsrc 2>/dev/null || echo mtools_skip_check=1 >> /root/.mtoolsrc'
  src=$(mktemp)
  patched=$(mktemp)
  sudo mcopy -i "${LOOP}p2" ::/grub/grub.cfg "$src"
  if ! grep -q 'terminal_output serial' "$src"; then
    {
      printf '%s\n' 'serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1'
      printf '%s\n' 'terminal_input serial console'
      printf '%s\n' 'terminal_output serial console'
      cat "$src"
    } >"$patched"
    sudo mcopy -i "${LOOP}p2" -o "$patched" ::/grub/grub.cfg
    printf 'serial console prepended to grub/grub.cfg on the image EFI partition\n'
  fi
  rm -f "$src" "$patched"
fi

sudo sync
sudo umount "$MNT"
rmdir "$MNT"
MNT=""
if [[ -n $EFI_MNT ]]; then
  sudo umount "$EFI_MNT"
  rmdir "$EFI_MNT"
  EFI_MNT=""
fi
sudo losetup -d "$LOOP"
LOOP=""
trap - EXIT

printf 'test image ready: %s\n' "$IMAGE"
ls -lh "$IMAGE"
