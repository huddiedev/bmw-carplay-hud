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
