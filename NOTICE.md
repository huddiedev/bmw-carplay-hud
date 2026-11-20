# Notices and credits

## Licence

Everything in this repository is under the **PolyForm Noncommercial License 1.0.0** (see `LICENSE`):
personal, hobby and other non-commercial use only. Selling it, or selling installs of it, is not allowed.
If you pass on any part of it, include `LICENSE` with all of its `Required Notice:` lines.

## Credits

- **ftojke - [BMW-iDrive6-CarPlay-HUD](https://github.com/ftojke/BMW-iDrive6-CarPlay-HUD)**: the CarPlay -> HUD bridge
  itself. `payload/libnbt_carplay_hud.so` is the upstream prebuilt hook (`build/libnbt_carplay_hud_real.so`),
  unchanged, pinned to commit `97b9133` and SHA-256 `CD1043FC...A5A48E`. `payload/mm-ipod-wrapper.sh` is based on the
  upstream wrapper (kept for reference in `upstream/`).
- **nanaisu - [NBT-AAD](https://github.com/Sq00ky/Supra-iDrive6-Android-Auto)**: the upstream bridge includes work
  from this project (it is a copyright holder in the upstream licence) and uses the same instrument-cluster
  navigation service.
- **st1ng - [nbtevo-carplay-advanced](https://github.com/st1ng/nbtevo-carplay-advanced)**: the memory-only test method
  (a path-manager link that a restart removes) and practical notes about the head unit (the iAP2 driver stall, missing
  tools, watchdog resets). No code from that project is included.
- **Bavarian SSH client - <https://ssh.bavarian-aa.uk/>**: switches on SSH until the next iDrive restart. It is a
  separate, free tool that is **not** included here; download it from its own website. Its authors state it must
  not be sold or bundled with anything sold.

## Trademarks and affiliation

BMW, iDrive, Apple, CarPlay, iPhone, Google and Google Maps are trademarks of their owners. This project is not
made, approved or supported by BMW, Apple or Google. Names are used only to describe compatibility.

## No warranty

The software is provided "as is", without warranty of any kind. You use it at your own risk. It changes software
in your car's infotainment head unit; keep the car parked during every step.
