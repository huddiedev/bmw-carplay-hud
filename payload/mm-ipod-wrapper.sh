#!/bin/sh
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# CarPlay -> BMW HUD/KOMBI: mm-ipod wrapper (deployed as /opt/conn/bin/carplay/mm-ipod by "cphud.ps1 swap").
# Based on hook/mm-ipod-wrapper.sh from https://github.com/ftojke/BMW-iDrive6-CarPlay-HUD (commit 97b9133).
#
# Connectivity launches TWO mm-ipod instances from the same path: one for Bluetooth iAP2 (iap2.cfg) and one
# for the CarPlay Wi-Fi transport (iap2_Wifi.cfg). The hook is only ever preloaded into the CarPlay Wi-Fi
# instance; the Bluetooth instance always runs byte-for-byte stock.
#
# The hook is only preloaded when /opt/aa-cp/mode contains exactly one of
#   dryrun  - hook loads in observe-only mode (NBT_CARPLAY_DRYRUN=1): logs, changes/sends nothing
#   active  - hook loads normally (route guidance to HUD/KOMBI)
# A missing, unreadable or unexpected mode file means "off": mm-ipod runs byte-for-byte stock.
#
# Upstream safety self-test kept as-is: before preloading the hook into the real mm-ipod, it is loaded into a
# throwaway /bin/uname. If the QNX loader can't map/relocate the .so, uname exits non-zero and LD_PRELOAD is
# NOT set, so mm-ipod runs stock.
#
# Binary started: the verified stock copy /fs/sda0/opt/aa-cp/bin/mm-ipod - exactly what the RAM "try" test ran
# on this car (the process keeps the name "mm-ipod"). If that copy is missing, the original stock binary kept as
# mm-ipod.real is started instead.
HOOK=/opt/aa-cp/libnbt_carplay_hud.so
MODEFILE=/opt/aa-cp/mode
MODE=off
[ -r "$MODEFILE" ] && read MODE < "$MODEFILE"
case "$MODE" in
    dryrun|active) ;;
    *) MODE=off ;;
esac
case "$*" in
    *iap2_wifi*)
        if [ "$MODE" != off ] && [ -r "$HOOK" ] && LD_PRELOAD="$HOOK" NBT_CARPLAY_SELFTEST=1 /bin/uname >/dev/null 2>&1; then
            export LD_PRELOAD="$HOOK"
            export NBT_CARPLAY_HUD=1
            export NBT_CARPLAY_LOG=/dev/shmem/cphud.log   # diagnostics; /dev/shmem is RAM (cleared every boot)
            [ "$MODE" = dryrun ] && export NBT_CARPLAY_DRYRUN=1
            # Per-packet tracing stays OFF unless /dev/shmem/cphud.debug exists (upstream: tracing on the
            # driver's bt_read thread once caused a watchdog HU reset - leave it off).
            [ -f /dev/shmem/cphud.debug ] && export NBT_CARPLAY_DEBUG=1
        fi
        ;;
esac
REAL=/opt/conn/bin/carplay/mm-ipod.real
[ -x /fs/sda0/opt/aa-cp/bin/mm-ipod ] && REAL=/fs/sda0/opt/aa-cp/bin/mm-ipod
exec "$REAL" "$@"
