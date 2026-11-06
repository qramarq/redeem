#!/usr/bin/env bash
# Started by the UUID-pinned udev rule. Locates that one volume and runs the
# Linux launcher. Any other disk never reaches this script: the udev match is
# ENV{ID_FS_UUID}=="<pinned>".
set -euo pipefail

uuid=${1:-}
if [[ -z $uuid ]]; then
    printf 'redeem: linux-usb-launch.sh needs the pinned UUID\n' >&2
    exit 2
fi

lock=${REDEEM_LOCK:-/tmp/redeem-usb-launch.lock}
if command -v flock >/dev/null 2>&1; then
    exec 9>"$lock"
    if ! flock -n 9; then
        exit 0
    fi
fi

norm() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -d '-'
}
want=$(norm "$uuid")

dev=""
if [[ -e /dev/disk/by-uuid/$uuid ]]; then
    dev=$(readlink -f "/dev/disk/by-uuid/$uuid")
else
    for link in /dev/disk/by-uuid/*; do
        [[ -e $link ]] || continue
        name=$(basename -- "$link")
        if [[ $(norm "$name") == "$want" ]]; then
            dev=$(readlink -f "$link")
            break
        fi
    done
fi
if [[ -z $dev || ! -b $dev ]]; then
    printf 'redeem: pinned volume %s is not present\n' "$uuid" >&2
    exit 0
fi

got=$(blkid -o value -s UUID "$dev" 2>/dev/null || true)
if [[ $(norm "$got") != "$want" ]]; then
    printf 'redeem: %s UUID %s does not match %s\n' "$dev" "${got:-missing}" "$uuid" >&2
    exit 0
fi

mp=$(findmnt -nro TARGET -S "$dev" 2>/dev/null | head -n 1 || true)
owned=0
if [[ -z $mp ]]; then
    if command -v udisksctl >/dev/null 2>&1; then
        udisksctl mount -b "$dev" --options ro >/dev/null
        mp=$(findmnt -nro TARGET -S "$dev" 2>/dev/null | head -n 1 || true)
    fi
fi
if [[ -z $mp ]]; then
    mp=$(mktemp -d /tmp/redeem-usb-XXXXXX)
    mount -o ro "$dev" "$mp"
    owned=1
fi

launcher=$mp/Start-Redeem-Linux.sh
if [[ ! -f $launcher ]]; then
    printf 'redeem: %s has no Start-Redeem-Linux.sh\n' "$mp" >&2
    if [[ $owned -eq 1 ]]; then
        umount "$mp" 2>/dev/null || true
        rmdir "$mp" 2>/dev/null || true
    fi
    exit 1
fi

if [[ -z ${DISPLAY:-} && -S /tmp/.X11-unix/X0 ]]; then
    export DISPLAY=:0
fi
if [[ ! -t 1 ]]; then
    if command -v gnome-terminal >/dev/null 2>&1; then
        exec gnome-terminal -- bash "$launcher"
    fi
    if command -v konsole >/dev/null 2>&1; then
        exec konsole -e bash "$launcher"
    fi
    if command -v xfce4-terminal >/dev/null 2>&1; then
        exec xfce4-terminal --command "bash $launcher"
    fi
    if command -v x-terminal-emulator >/dev/null 2>&1; then
        exec x-terminal-emulator -e bash "$launcher"
    fi
    if command -v xterm >/dev/null 2>&1; then
        exec xterm -e bash "$launcher"
    fi
fi
exec bash "$launcher"
