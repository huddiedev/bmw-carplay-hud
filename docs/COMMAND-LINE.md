# Command line (advanced)

The wizard runs these same steps. Without it, open PowerShell 7 in the repository folder:

```
pwsh -ExecutionPolicy Bypass -File app\cphud.ps1 <step> [mode]
```

ssh asks for the head-unit root password at each connection. Every change asks you to type `CHANGE IDRIVE`.
Add `-DryRun` to any step to see exactly what it would run, without connecting.

| # | Command | Changes in the iDrive | Must say |
|---|---|---|---|
| 1 | `preflight` (CarPlay connected wirelessly) | Nothing; backup to the laptop | `PRE-FLIGHT PASSED` |
| 2 | `stage` | New folder `/fs/sda0/opt/aa-cp` | `STAGE PASSED` |
| 3 | `try dryrun`, reconnect CarPlay, use it, then `log` | RAM only | `DRY-RUN VERIFIED` |
| 4 | `try active`, reconnect, route while parked, then `log` | RAM only | arrows seen, recorded |
| - | restart the iDrive, enable SSH again, `status` | Nothing | `RAM test link: none` |
| 5 | `swap` (CarPlay off on the phone first) | `mm-ipod` -> `mm-ipod.real` + starter, mode off | `SWAP PASSED` |
| 6 | CarPlay on, check music/calls, then `status` | Nothing | `a wrapper chain is in use` |
| 7 | `mode active`, reconnect, route, then `log` | `mode` = active | arrows seen |
| 8 | restart, route (arrows on their own), enable SSH, `status` | Nothing | no new watchdog report |

Other commands:

| Command | What it does |
|---|---|
| `status` | Read-only state of the head unit |
| `mode off` / `mode dryrun` / `mode active` | Set the switch file (after `swap`) |
| `rollback` | Remove the test link, put `mm-ipod.real` back, delete `/fs/sda0/opt/aa-cp`, restore the cfg from `.orig` |
| `verify-stock` | Byte-for-byte comparison with your golden backup |
| `restore-from-laptop [-IncludeCfg]` | Write the golden laptop backup back (temp file + rename, original owner and permissions) |
| `cfg-ident` | Optional: append `[ident]` to `iap2_Wifi.cfg` (only if Test 2 gets no guidance data) |

Options: `-HuIp` (default `169.254.199.119`), `-BackupRoot` (default `Documents\BMW-CarPlay-HUD-backups`),
`-Force` (override a gate knowingly), `-DryRun`, `-Simulate <folder>` (offline test with canned outputs).

Wizard-only options (`-Wizard`, `-Confirm`, `-Answer`, `-OutLog`) let the wizard answer prompts from its own window.

## Testing the wizard without a car

```
powershell -ExecutionPolicy Bypass -STA -File app\CarPlayHudWizard.ps1 -Demo        # click through, nothing connects
powershell -ExecutionPolicy Bypass -STA -File app\CarPlayHudWizard.ps1 -SelfTest    # automatic run of every page
```
