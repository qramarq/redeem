#!/bin/sh
# Copies the injected sysroot tree onto SystemRescue's live root.
# Invoked from /init after /new_root is mounted and before switch_root.
vroot=${1:-}
datadir=live_injection_7ed136ec_7a61_4b54_adc3_ae494d5106ea

if [ -f "/$datadir/done" ]; then
    exit 0
fi
echo "${vroot}" >"/$datadir/done" 2>/dev/null || true
if [ -n "$vroot" ] && [ -d "$vroot/etc" ] && [ -d "/$datadir/sysroot" ]; then
    cp -a "/$datadir/sysroot/." "$vroot/" || exit 0
fi
exit 0
