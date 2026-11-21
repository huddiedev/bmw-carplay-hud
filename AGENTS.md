# Guide for AI assistants (Claude and others) helping a user with this project

This project changes software in a car's infotainment head unit (BMW NBT EVO). A mistake can leave CarPlay or the
iDrive misbehaving. Follow these rules exactly. The user is the operator; you assist.

## Rules

1. **Read first:** `README.md`, `docs/PREREQUISITES.md`, `docs/HOW-IT-WORKS.md`, `docs/TROUBLESHOOTING.md`.
2. **Read-only steps are fine to run:** `preflight`, `status`, `log`, `lanecheck`, `dataprobe`, `hudscan`, `verify-stock`.
   Tell the user what each one does before running it.
3. **Before any step that writes to the car** (`stage`, `try`, `swap`, `mode`, `rollback`, `cfg-ident`,
   `restore-from-laptop`), say plainly: "This changes files in the iDrive", list exactly what changes (the engine
   prints it) and how to undo it, and **wait for the user's explicit yes in chat**. The engine will also ask the
   user to type `CHANGE IDRIVE`: the user types it, never you.
4. **One stage at a time, in this order:** `preflight` > `stage` > `try dryrun` > `log` > `try active` > `log` >
   restart > `swap` > check CarPlay > `mode active` > `log` > restart test. After each stage that changes
   something, ask the user to test (CarPlay, music, a call, arrows on the HUD) and continue only when they confirm.
5. **Passwords:** never ask for, accept, store or repeat the head unit's root password. The user types it at ssh's
   own prompt, in a terminal they can see.
6. **Stop and undo** if the engine reports any STOP, "files do not match", a new watchdog report, driver
   fingerprints that differ, "iPhone rejected Identify", the iDrive restarting by itself, or the user reports
   anything unusual. Do not use `-Force` unless the user explicitly asks and understands why.
7. **A restart ends the test:** every iDrive restart switches SSH off, so the user must enable it again
   (Bavarian SSH client) before the next step.
8. **Parked only:** the car in P, parking brake on, engine running or a charger connected. Never run steps while
   the car is moving.
9. **Don't combine** this bridge with other CarPlay/Android Auto cluster mods (st1ng's CarPlay Advanced, a running
   NBT-AAD), and don't edit the car-side scripts (the `@' ... '@` blocks in `app/cphud.ps1`, `payload/*.sh`).
10. **Privacy:** backups in `Documents\BMW-CarPlay-HUD-backups` hold the user's CarPlay Wi-Fi password and head unit
    serial. Never put them, logs, VINs, MAC addresses or street names in an issue, pull request or chat that will
    be shared.
11. **Scope:** only the CarPlay-to-HUD bridge in `main`. Features on `feature/*` branches are experimental
    and not for use on a car.

## How to run

PowerShell 7 in the repository folder; see `docs/COMMAND-LINE.md`:

```
pwsh -ExecutionPolicy Bypass -File app\cphud.ps1 <step> [mode]
```

Add `-DryRun` to preview what a step would send without connecting.

Non-technical users should use `Start-Wizard.cmd` instead; it has the same checks and asks the user the same questions.
