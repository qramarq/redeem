#!/bin/sh
# Ventoy calls /live_injection_7ed136ec_7a61_4b54_adc3_ae494d5106ea/hook.sh
# after it unpacks this archive into the initramfs. SystemRescue's /init
# (mkinitcpio ash) mounts the live root on /new_root and then runs
# run_latehook. Appending a copy there puts /usr/local/bin/redeem-autostart
# on the live system without writing the ISO.
PATH="/ventoy/busybox:${PATH:-/bin:/sbin}"
datadir=live_injection_7ed136ec_7a61_4b54_adc3_ae494d5106ea

if [ ! -d "/$datadir" ]; then
    exit 0
fi
if [ -f "/$datadir/sysroot.tar.gz" ]; then
    tar -xzf "/$datadir/sysroot.tar.gz" -C "/$datadir" || exit 0
    rm -f "/$datadir/sysroot.tar.gz"
fi
if [ -f "/$datadir/copy-to-newroot.sh" ] && [ -d /hooks ]; then
    cp -a "/$datadir/copy-to-newroot.sh" /hooks/redeem-copy-to-newroot.sh || exit 0
    chmod 755 /hooks/redeem-copy-to-newroot.sh 2>/dev/null || true
fi
if [ -f /init ] && grep -q run_latehook /init; then
    # Same append Ventoy's Arch live-injection hook uses. One line, after late hooks.
    sed "/run_latehook/a sh /hooks/redeem-copy-to-newroot.sh /new_root" -i /init || true
fi
exit 0
