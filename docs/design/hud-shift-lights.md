# HUD rev display and shift lights (experimental)

**Status:** investigation. Lives on branch `feature/hud-shift-lights`, not in `main`, until it has been tested on a car.

## Goal

A rev band in the head-up display that turns yellow, then orange, then red as the engine approaches the shift
point in each gear, with a shift indication: the way BMW M cars do it.

## The factory feature: M View

BMW's own **M View** in the head-up display shows exactly this. BMW owner's manuals for M cars say the shift
lights appear in the head-up display only in M View, selected under Settings > Head-Up Display > Displayed
information > M View. Some M Performance cars (for example X3 M40i on iDrive 7) have had it switched on by coding
(reported parameters on iDrive 7 head units include `HUD_M`, `M_SHIFTLIGHTS` and `CB_HUD_MVIEW_SLI`).

Reports for **NBT EVO** cars with the earlier digital cluster (DKOMBI2, e.g. G30/F90 family) say the software that
M View needs isn't present, so coding alone may not be enough there. That has to be checked on the car.

## Why not through this project's bridge

The only head-up display channel this project uses is the instrument cluster's **navigation guidance** service:
turn arrow, distance, street, and later lanes. It can't draw a coloured rev band. Engine speed and gear also belong
to the engine and transmission control units. Sending fake powertrain or driver-display signals is out of scope
for safety reasons. So this feature is only pursued through BMW's own M View.

## Plan

1. **At the car, no tools:** iDrive > Settings > Head-Up Display > Displayed information. Is there an "M View",
   sport or rev-counter option? Note what each driving mode (Comfort / Sport / Sport+) shows in the HUD.
2. **Read-only coding read** (BimmerCode expert mode, or E-Sys with the ENET cable) of `HU_NBT_EVO`, the
   instrument cluster (`KOMBI`) and the head-up display (`HUD`): save a full coding backup, then look for M View /
   shift-light / SLI parameters. Nothing is changed in this step.
3. **If parameters exist:** change one at a time, parked, engine running, in neutral. Check the HUD in each
   driving mode. Every change can be undone by writing back the saved coding.
4. **If they don't exist:** stop and document "not available on NBT EVO / DKOMBI2" in `docs/COMPATIBILITY.md`.

## Deliverable on this branch

Documentation of what was found and, if it works, the exact coding values per car. No code change is planned
unless a safe path through factory software appears.

## Reference: what the X3 M (F97) has

- The X3 M (F97, 2019-2021 pre-LCI and 2021-2024 LCI) was built with **iDrive 7** (MGU head unit) and the later
  digital cluster from the start; it never had NBT EVO.
- Its head-up display has **M View**: a rev band whose fields light yellow, then red, towards the shift point,
  the gear, and the speed. BMW's M manuals say M View is active in the M driving programs (Sport / Track), and that
  shift lights move to the cluster when the HUD is off. No documented HUD difference between pre-LCI and LCI was found.
- The same software family offers cluster layouts such as "M" and "M with shift lights" (BimmerCode lists these as
  needing the later cluster generation, DKOMBI4).

## Ways to get it on an NBT EVO car (e.g. G01 X3 M40i, 2019)

| Route | What it gives | Effort / risk |
|---|---|---|
| Coding on the current hardware | M View in the HUD, if the head unit, cluster and HUD software contain it | Cheap and reversible with a coding backup. Reports suggest NBT EVO / DKOMBI2 cars lack it; check first (plan above) |
| Hardware retrofit to iDrive 7 (MGU head unit, new cluster, screen, controller, RAM module, programming) | M View with tacho and shift lights by coding, M cluster layouts, CarPlay guidance in the HUD natively (this bridge would no longer be needed) | Professional retrofit, reported cost in the thousands; not a software change this project can make |
| Drawing a rev band through this project's navigation channel | - | Not possible: the channel only shows arrows, distance, street and lanes, and faking engine data is out of scope |

## Lead: a second way to draw on the HUD (MOST HUDTerminal)

The community iDrive app "HUD Gauges" (ID6 apps) draws live gauges on the factory HUD through a different channel
than the navigation guidance service: the HUD's MOST "HUDTerminal" (82/00 at node 0101), fed with real engine data
read from the engine control unit through the gateway (read-only diagnostic requests, the same way MHD-style apps
read live data). So a rev band with shift lights drawn from real RPM might be possible after all, on cars where
the HUD exposes that terminal. It uses real data, not faked signals.

Known problems to solve before it's usable:
- On a G01 (Y24073J), HUD Gauges **froze the iDrive** (live drawing faster than the iDrive's message loop keeps up;
  apps refreshing every 100 ms were stable), and a saved "Show HUD gauges" starts its worker at every boot.
- Polling RPM through the gateway may be too slow for shift lights (they need to react within about 50-100 ms).
- It hasn't been shown that the G01's HUD accepts HUDTerminal drawing at all (the app was tested on an F30 340i).

Next step: read-only. Check whether the HUDTerminal exists on this car, and study how HUD Gauges draws and why it
freezes. Nothing is installed until a stable, low-rate version has been tested parked.

### Where on the HUD can it be drawn? (from the NBT-AAD HUDTerminal source)

- Drawing happens only **inside the factory navigation panel** (frame handle 1), the area where BMW navigation
  draws its turn picture. The app reuses the objects BMW's software creates there: two picture buffers, a route
  overlay, a lane strip and three text boxes. It can't create new ones.
- Inside that panel, shapes can go **anywhere**: polygons use x/y coordinates on a canvas of roughly 200 x 130
  units, verified on a 6WA cluster. So a rev band could be an arc across the top of the panel, a bar along its
  bottom, and so on.
- It **can't be moved outside the panel**, for example to an unused corner of the HUD. The protocol names
  create/position commands (`CreateInstance`, `FrameAddItem`, `ImageSetPositionRotation`), but their formats are
  unknown and the implementation refuses to send them. The panel's place on the windscreen is fixed by the HUD.
- **Colours are palette numbers**, not RGB. Known so far: 4 = navigation main colour (white, or orange depending on
  the cluster's scheme), 3 = light grey, 7 = black. Yellow, orange and red for the shift sequence would need a parked
  colour sweep on the car; the HUD might not offer all three.
- The panel **belongs to factory navigation**: while BMW navigation shows guidance, the drawing app must step aside
  and stays hidden.
- Verified only on F-series 6WA (F20). Whether a G01's HUD exposes this MOST terminal at all is still unknown.

## Plan: decode the "create / add / position" HUD commands

NBT-AAD names these commands (`CreateInstance` 0x200, `FrameAddItem` 0x22B, `ImageSetPositionRotation` 0xC06,
`ImageAddBitmap` 0xC05, ...) but never worked out their format. BMW's own iDrive software must send them, because
it builds the navigation panel in the HUD at every start-up. So the format can be learned from BMW's code and
traffic, the same way NBT-AAD learned the drawing commands.

1. **Find the code (read-only, at the car):** `cphud.ps1 hudscan` lists MOST/HUD processes, devices and PPS objects,
   and names the iDrive program files that contain HUD-terminal code. If nothing turns up, this car's HUD is
   driven only by the cluster over Ethernet, and this path ends there.
2. **Copy those files to the laptop (read-only)** and analyse them with a disassembler/decompiler (Ghidra). Find
   where each command's message is built, and record the field layout: handle, object type, x/y, width/height,
   rotation, z-order. BMW binaries stay private: never committed, never shared.
3. **Confirm with real traffic, if needed:** a passive logger of the iDrive's own HUD messages at start-up and
   during BMW navigation (needs the QNX build setup).
4. **Replay test, parked, memory only:** first send an exact copy of a factory message (it should change nothing
   visible), then one small change at a time: a tiny shape in a new position. A restart clears everything.

### Safety rules for this work

- Never draw over the speed, warnings (collision, pedestrian, ACC, speed-limit) or anything else BMW shows. Hide
  immediately whenever factory content takes over the area.
- Only real data (actual RPM). Nothing that imitates a warning or a driver-assistance display.
- Parked only until a stable version has passed parked tests; no use while driving before that.
- One command type at a time; anything unexpected (iDrive lag, HUD flicker, restart) stops the work.
