#!/usr/bin/env bash
# Headless QEMU boot of a redeem test image. The drive is the image file.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$here/lib.sh"

root=$(redeem_root)
IMAGE=${1:-$root/build/cache/rescue-test.img}
LOG=$root/artifacts/qemu-serial.log
SECONDS_LIMIT=${QEMU_SECONDS:-75}

assert_safe_image "$IMAGE"
[[ -f $IMAGE ]] || die "missing image $IMAGE (run build/make-test-image.sh)"
mkdir -p "$root/artifacts"

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  die "qemu-system-x86_64 is not installed"
fi

accel=tcg
if [[ -r /dev/kvm ]]; then
  accel=kvm:tcg
fi

printf 'qemu boot test of %s (accel %s, %ss)\n' "$IMAGE" "$accel" "$SECONDS_LIMIT"
# timeout returns 124 when the guest is still running. That is the expected stop.
set +e
timeout --signal=TERM "$SECONDS_LIMIT" qemu-system-x86_64 \
  -machine "pc,accel=${accel}" \
  -cpu max \
  -m 2048 \
  -no-reboot \
  -nographic \
  -serial mon:stdio \
  -drive "file=${IMAGE},format=raw,if=ide,media=disk" \
  -boot c \
  < /dev/null >"$LOG" 2>&1
rc=$?
set -e
printf 'qemu exit %s, log %s (%s bytes)\n' "$rc" "$LOG" "$(wc -c <"$LOG" | tr -d ' ')"

if grep -Eiq 'ventoy|gnu grub|systemrescue|seabios|booting from' "$LOG"; then
  printf 'boot log contains a firmware or bootloader marker\n'
  grep -Ei 'ventoy|gnu grub|systemrescue|seabios|booting from' "$LOG" | head -n 20 || true
  exit 0
fi

printf 'no firmware or bootloader marker in the serial log\n' >&2
tail -n 40 "$LOG" >&2 || true
exit 1
