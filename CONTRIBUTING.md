# Contributing

Thanks for helping. The most useful contribution is a **compatibility report** from your car. Use the
"Compatibility report" issue form; it takes two minutes.

## Before you post anything

Remove: your VIN, the head unit's serial number, your CarPlay Wi-Fi name and password, MAC addresses, phone names,
and street names from route logs. Never attach files from `Documents\BMW-CarPlay-HUD-backups`.

## Code changes

- The scripts that run on the car (the `@' ... '@` blocks in `app/cphud.ps1` and `payload/*.sh`) are the
  safety-critical part. Changes there need a test on a real car, described in the pull request:
  steps run, car, iDrive software, result.
- Keep everything ASCII. `.sh` files must have Unix line endings (LF).
- Before a pull request, run the offline checks:
  ```
  powershell -ExecutionPolicy Bypass -STA -File app\CarPlayHudWizard.ps1 -SelfTest
  pwsh -ExecutionPolicy Bypass -File app\cphud.ps1 swap -DryRun
  ```
  and update `SHA256SUMS` (one line per file: lowercase SHA-256, two spaces, path with forward slashes).
- Don't add anything that makes a change without the `CHANGE IDRIVE` confirmation, stops processes on the head
  unit, or touches boot scripts.

## Licence

By contributing you agree that your contribution is licensed under the PolyForm Noncommercial License 1.0.0
(see `LICENSE`).
