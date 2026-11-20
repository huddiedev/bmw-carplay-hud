# How it works

## The pieces

- **The bridge** (`payload/libnbt_carplay_hud.so`, by ftojke): a small library loaded into the iDrive's CarPlay
  program (`mm-ipod`) for the **wireless CarPlay** connection only. It:
  - asks the iPhone for route guidance (iAP2 `StartRouteGuidanceUpdates`, 0x5200)
  - registers that message group in the iDrive's 2017 iAP2 driver, so the driver doesn't stall after about 20
    guidance messages (a known problem found by st1ng)
  - sends turn arrow, distance and street to the instrument cluster (KOMBI, SOME/IP 0xB006 at 160.48.199.96:30502),
    which shows them on the cluster and the head-up display

  Before it changes anything it checks the iDrive's driver against fingerprints. If they differ it stays passive.
- **The starters** (`payload/mm-ipod-wrapper*.sh`): tiny shell scripts that start your **original** CarPlay program,
  and load the bridge only when:
  - it is the **wireless CarPlay** instance (its arguments contain `iap2_wifi`; Bluetooth always runs original)
  - the switch file says `dryrun` (watch only) or `active`. Missing, unreadable or anything else means OFF.
  - the bridge passes a load test in a throwaway program first (upstream safety check)
- **The engine** (`app/cphud.ps1`): every check and change, step by step, over SSH.
- **The wizard** (`app/CarPlayHudWizard.ps1`): the window. It asks you, then runs one engine step.

## What each step changes

| Step | Exactly what changes in the head unit | How to undo |
|---|---|---|
| Check the car (`preflight`) | Nothing. Copies `mm-ipod`, `ipod-drvr-iap2.so`, `ipod-transport-bt.so` and `iap2_Wifi.cfg` to the laptop with owner, permissions and SHA-256 | - |
| Copy test files (`stage`) | New folder `/fs/sda0/opt/aa-cp`: the bridge, both starters, `bin/mm-ipod` (a copy of **your** stock program, made on the car), `mode` = `off` | Remove everything |
| Test 1 / Test 2 (`try dryrun` / `try active`) | RAM only: `/dev/shmem/cphud.mode`, and a path-manager link (`ln -sP`) that makes `/opt/conn/bin/carplay/mm-ipod` start the test starter | Restart the iDrive |
| Install permanently (`swap`) | `/fs/sda0/opt/conn/bin/carplay/mm-ipod` renamed to `mm-ipod.real`; the permanent starter takes its place by atomic rename; `mode` forced to `off` | Remove everything |
| Switch on (`mode active`) | `/fs/sda0/opt/aa-cp/mode` = `active` | Turn the bridge off |
| Optional (`cfg-ident`, command line only) | Appends `[ident]` to `iap2_Wifi.cfg` (backup `.orig` first). Not needed on the tested cars | Remove everything |

The permanent starter runs the same verified copy (`/fs/sda0/opt/aa-cp/bin/mm-ipod`) that the tests ran, so the
CarPlay program keeps its usual name. If that copy is ever missing, it starts `mm-ipod.real`.

Never changed: the boot scripts, the boot image, BMW navigation, Bluetooth, coding, any other ECU.

## Safety checks

- **Byte-for-byte versions:** `mm-ipod`, the iAP2 driver and the transport must match the SHA-256 values the bridge
  was built against (see [COMPATIBILITY.md](COMPATIBILITY.md)). Otherwise: stop before any change.
- **The bridge file is pinned:** the laptop copy must match SHA-256 `CD1043FC...A5A48E` before anything is uploaded.
- **Every upload is read back** byte-for-byte and hashed on the laptop.
- **The car's own shell checks the syntax** of every script before a single line runs.
- **The starters are logic-tested on the car** (14 cases, in RAM) before they are used.
- **Order is enforced:** test 2 needs a passed test 1; the permanent install needs arrows seen in test 2; it refuses
  while a test is still running.
- **Self-reverting install:** `swap` checks the result and restores the original on the spot if anything looks wrong.
- **Watchdog resets:** the number of iDrive reset reports (`/var/dump/wd_err_*`) is recorded at the check. Status
  and test results STOP if a new one appears.
- **Other mods:** stops if st1ng's CarPlay Advanced is installed, or if NBT-AAD is running or in the boot script.
  An installed but idle NBT-AAD gives only a warning.
- **The car's processes are never stopped.** Stopping Connectivity makes its watchdog reset the unit, so changes
  take effect at the next CarPlay connection or restart.
- **Backups first:** the first clean check is kept as your golden backup on the laptop. Restore it with
  `restore-from-laptop` (command line).

## Passwords and host keys

- You type the password once per wizard session. It stays in memory, and is handed only to the engine step being
  run, through Windows' built-in ssh password helper (`SSH_ASKPASS`). The helper (`app/askpass.cs`) is compiled on
  your PC by Windows PowerShell. It answers only ssh's password question, and refuses anything else.
- If that doesn't work on your PC, use **Tools / Undo > Type the password in a window instead**. A console window then
  asks for it at each step.
- The head unit's SSH host key is remembered on first use, in `Documents\BMW-CarPlay-HUD-backups\known_hosts`. ssh
  refuses to connect if it ever changes.

## Files on the laptop

- `Documents\BMW-CarPlay-HUD-backups\`: golden backup, later backups, `state.json` (which steps passed),
  `logs\` (bridge logs; may contain street names). **Private.**
- `%LOCALAPPDATA%\CarPlayHudWizard\`: the compiled password helper and per-step technical logs.
