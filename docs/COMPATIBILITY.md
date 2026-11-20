# Compatibility

## How the wizard decides

The check compares three files in your iDrive with the versions the bridge was reverse-engineered against
(SHA-256):

| File | SHA-256 |
|---|---|
| `/opt/conn/bin/carplay/mm-ipod` (CarPlay program) | `D3F7C8973FEFF37D512BA92BAF42D40CE8A2626FE38FDF17E7DA10DB320BB36F` (39836 bytes) |
| `/opt/conn/lib/carplay/ipod-drvr-iap2.so` (iAP2 driver) | `3512652C1D88A26512F82548327090C2A4F174680A4EAF23DFCCEAEB82AAEA4C` (752584 bytes) |
| `/opt/conn/lib/carplay/ipod-transport-bt.so` (transport) | `CEFF2F83234477C4856E34B938F2B213A46C00EAAC492ED6C54AB4F5577E7701` |

The bridge patches code inside the driver and the transport at fixed places. If either differs, the check stops
before any change. The same files are used across several NBT EVO software versions.

## Confirmed working

| Car | Software | Displays | Result | Notes |
|---|---|---|---|---|
| X3 G01 (2019) | NBTevo_Y24073J | HUD + digital cluster | Working: arrows, distance, street; survives restarts; road-tested | Dry-run, live test, permanent install and reboot test all passed |
| 5 Series G30 | NBTevo_Y21432J | - | Working | Tested by the bridge author (ftojke) |

## Not supported

- iDrive 7 and later (MGU, Live Cockpit Professional): a different head unit.
- Wired-only CarPlay: the bridge only runs in the wireless CarPlay connection.
- Lane guidance: not in this bridge.

## Report your car

Open an issue titled `Compatibility: <model> <year> <software>` with:

- model, year, iDrive software version (the check shows it), HUD yes/no, cluster type
- the check result (passed / stopped, and the reason)
- if you got that far: whether the arrows appeared in Test 2

Leave out your VIN, head-unit serial number, Wi-Fi name or password, MAC addresses and street names.
