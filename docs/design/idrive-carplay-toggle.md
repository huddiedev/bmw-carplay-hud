# iDrive on/off switch for CarPlay maps in the HUD (experimental)

**Status:** design. Lives on branch `feature/idrive-carplay-toggle`, not in `main`, until tested on a car.

## Goal

A checkbox in the iDrive, **"Enable CarPlay maps in HUD"**, that turns the bridge on and off without a laptop.
It should survive restarts and work the same way for every user.

## Where it can live

BMW's own "Head-Up Display" settings menu is part of BMW's iDrive software; adding an item there would mean patching
factory files per software version. Not done. Instead: an iDrive app in **My Vehicle** (the same place as BoostDeck,
MHD+ and HUD Gauges), built with the community **ID6 apps** framework (MIT licence) that already runs on NBT EVO cars.
The framework has a checkbox control: HUD Gauges' own "Show HUD gauges" is exactly that, and it is what the car showed.

## How the switch reaches the bridge

Found by reading the strings of the HUD Gauges library (`libHudTest.so`): the checkbox state is saved in a small file,
`/var/opt/hmi/data/ID5/Plugins/<app>/hud-enabled`, restored at every start ("Starting saved HUD gauges"), and a
worker program in the same folder is started when it is ticked and stopped when it is cleared.

Design: **the file is the switch.**

| Piece | Change |
|---|---|
| iDrive app | HUD Gauges' menu library, with the label changed in its XML to "Enable CarPlay maps in HUD" (the XML is plain text). Its worker is replaced by a tiny do-nothing script that just stays running, so the app shows as started, and **never draws on the HUD**. |
| Permanent starter (`mm-ipod-wrapper.sh`) | New rule: the bridge loads only if the disk mode is `active` **and**, when the app is installed, its `hud-enabled` file exists. Missing app = behaves exactly as today. |
| Takes effect | At the next CarPlay connection (iPhone Wi-Fi off 15 s and on), with no restart. |
| Wizard | A final optional step installs the app (parked, one folder copied into `Plugins`, then an iDrive restart) and explains it. |

If a hand-built native library turns out to be cleaner (own name, own messages), the same design works with a small
library built from the framework's source (needs the QNX build setup).

## Risks, and why this is a test-first feature

- **Freezes.** HUD Gauges, ShiftDeck and BoostDeck froze this car's iDrive when they redrew fast or started their
  worker at boot. This app never draws and does nothing at boot except exist, which should avoid that, but it must be
  proven: install parked, restart, watch for lag.
- **Menu texts.** The library's own messages still say "HUD gauges enabled" etc. (cosmetic; the label we control is
  the checkbox text). A built library would fix that.
- **Unknown:** whether a script can be the worker (the library calls it with its own arguments), and whether the app
  keeps working with its original menu title. Both are small parked tests.
- **Fail-safe:** if the file is missing or unreadable, the starter treats it as "no app" or "off", so the iDrive app can
  never make CarPlay worse than stock. Removing the app folder returns to disk-mode control.

## Test plan

1. Parked: copy the app folder into `Plugins` (a copy of the official HUD Gauges package with the two edits above).
   Restart the iDrive. My Vehicle shows the checkbox. No lag over 10 minutes.
2. Tick/untick several times; confirm `hud-enabled` appears and disappears (read-only SSH check).
3. With the new starter staged: reconnect CarPlay with the box ticked (arrows show) and unticked (no arrows).
4. Restart the iDrive: the state is remembered.
5. Only then: wizard step, docs, release.

## Related

Camera alerts, if built, get their own switch in the same app (see `feature/speed-camera-alerts`).
