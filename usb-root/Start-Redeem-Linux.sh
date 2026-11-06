#!/usr/bin/env bash
# One click on a Linux desktop that is already running. --lan stays off.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=$root/ai/scripts/rescue-ai
if [[ ! -f $script ]]; then
    printf 'redeem: %s is missing. Assemble the USB payload first.\n' "$script" >&2
    exit 1
fi

cd /tmp
if [[ -n ${DISPLAY:-} || -n ${WAYLAND_DISPLAY:-} ]]; then
    export BROWSER=${BROWSER:-firefox}
    exec bash "$script"
fi
exec bash "$script" --cli
