#!/bin/sh
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# CarPlay -> BMW HUD/KOMBI: TEST-ONLY mm-ipod wrapper, used through a path-manager link (ln -sP, RAM only):
#   /opt/conn/bin/carplay/mm-ipod -> /fs/sda0/opt/aa-cp/mm-ipod-wrapper-link.sh
# The link and /dev/shmem are forgotten at every reboot, so a reboot always returns the head unit to 100% stock.
# No CarPlay file on disk is changed. Same pattern as st1ng/nbtevo-carplay-advanced (car-tested on the same mm-ipod build).
#
# It starts a verified copy of the stock mm-ipod (/fs/sda0/opt/aa-cp/bin/mm-ipod, same name so the system still sees
# "mm-ipod"); exec'ing the linked path itself would start this wrapper again.
# The hook is preloaded only into the CarPlay Wi-Fi instance, and only when /dev/shmem/cphud.mode says dryrun or active;
# anything else means byte-for-byte stock behaviour. Upstream loader self-test kept (throwaway /bin/uname).
HOOK=/opt/aa-cp/libnbt_carplay_hud.so
MODEFILE=/dev/shmem/cphud.mode
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
            export NBT_CARPLAY_LOG=/dev/shmem/cphud.log
            [ "$MODE" = dryrun ] && export NBT_CARPLAY_DRYRUN=1
            [ -f /dev/shmem/cphud.debug ] && export NBT_CARPLAY_DEBUG=1
        fi
        ;;
esac
exec /fs/sda0/opt/aa-cp/bin/mm-ipod "$@"
