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
