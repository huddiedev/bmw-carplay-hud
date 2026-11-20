# Changelog

## v0.9.0 - first public beta

- Windows wizard (`Start-Wizard.cmd`): 12 guided steps, a typed `CHANGE IDRIVE` confirmation for every change, and a
  yes/no test question after every stage that changes something.
- Starts the Bavarian SSH client for you and continues by itself as soon as SSH is on.
- Password typed once per session (Windows ssh password helper); falls back to a console window if needed.
- Engine (`app/cphud.ps1`) with byte-for-byte version checks, golden backup, memory-only tests, self-reverting
  permanent install, watchdog and conflicting-mod checks, rollback and restore from the laptop backup.
- Permanent install starts the same verified copy of the CarPlay program that the memory-only test ran.
- Bundles the upstream bridge `libnbt_carplay_hud.so` from ftojke/BMW-iDrive6-CarPlay-HUD at `97b9133`, unchanged.

Known limits: no lane arrows yet; Waze sends no turn-by-turn data on iPhone; tested on two cars (see
`docs/COMPATIBILITY.md`).
