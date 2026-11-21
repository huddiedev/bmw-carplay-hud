# Lane arrows on the HUD (experimental)

**Status:** design. Lives on branch `feature/lane-arrows`, not in `main`, until tested on a car.

## Finding: only the decoding is missing

ftojke's bridge already has the whole path for lanes except the decoder:

| Step | Upstream state |
|---|---|
| iPhone sends lane message `0x5204` | arrives; `onLane()` only counts it |
| lanes into the guidance state | `kombiLanes()` returns false ("until layout is confirmed") |
| state to the KOMBI sender | `cp_maneuver_t` already has `lane_count`, `lane_kind[]`, `lane_arrow[]` (max 8) |
| KOMBI lane row (model `0x1B`, method `0x0010`) | encoder exists, in the reused NBT-AAD code; layout decoded from 126 BMW frames, never run on a car |

st1ng's project (`rghook.c`, `kombi.h`) contains a working decoder for the iPhone side. Porting it means filling in
`onLane()` and `kombiLanes()` in `src/cp_rgi_state.hpp`: roughly 50 to 100 lines, plus a small mapping function.

## What st1ng decodes (paraphrased from his source)

- `0x5204` is a list of TLVs: `1` LaneGuidanceIndex, `2` LaneInformation (one per lane, repeated), `3` description
  (ignored).
- Inside each `2`: sub-id `0` position (big-endian, starts a new lane, sorted left to right), `1` status (1 byte:
  0 not good, 1 good, 2 preferred), `2` lane angles (s16, up to 4), `3` highlight angle (s16, 1000 = none).
- Up to 8 lanes. State is kept per guidance index.

## Mapping to the KOMBI lane row

- Kind: any non-zero status = "take" (1); status 0 = "other" (2).
- Arrow: the highlight angle if set, else the first angle; none = drop the row. Buckets of the absolute angle:
  up to 20 degrees straight (1); to 60 half-left/right (2/3); to 120 left/right (6/7); to 170 tight-left/right (4/5);
  beyond that U-turn (8/9). More than 8 lanes = no lane row.
- NBT-AAD's car-verified arrow values are 1, 2, 6, 7 (and 10 for destination). **3, 4, 5, 8, 9 are not car-verified.**

## Evidence level

The decoder follows a community MIB2 implementation (libesoiap2's `parseLaneInformation`); no iPhone capture or named
app is cited. st1ng's lane output was verified in a car only on his MINI F54's MOST HUD, not on a G-series KOMBI.
**So nothing here is proven for the G01.** Step 1 below is what proves whether it's worth building.

## Plan

1. **Does Google Maps / Apple Maps send `0x5204` at all?** Run the read-only `lanecheck` at the car near a multi-lane
   junction (and `dataprobe` is unrelated). If no app sends lanes, stop.
2. **Capture one real message** (a recorder build, or his debug build) to confirm the layout on this iPhone, with no
   personal data kept.
3. **Port** the decoder and mapping into `cp_rgi_state.hpp`, with host tests using the captured, de-identified message.
4. **Build** with the QNX 6.5 cross-compiler (GCC 8.5.0; this laptop can't run it yet: virtualization is off, so
   either enable it, or use GitHub Actions). Compare an unchanged rebuild with the shipped hook first.
5. **Test parked, memory only** via the existing `try` step with the new hook, then a drive with a passenger watching.
6. If the KOMBI rejects the lane row, the code falls back to arrows only (upstream already does this for rejected
   in-place updates), so the worst case is "no lanes".

## Licence and credit

Both projects are PolyForm Noncommercial 1.0.0. Ported code must carry the licence terms and the `Required Notice:`
lines of its origin: for st1ng's code, "Copyright 2026 nbtevo-carplay-advanced contributors"; for the KOMBI code,
the NBT-AAD line (nanaisu), both of which `NOTICE.md` and `LICENSE` here must list before any release.
His `rghook.c` carries no per-file notice; his `NOTICE` says it falls under the project licence. Write the decoder
from the layout above (clean re-implementation) rather than copying his file, and credit him in `NOTICE.md`.
