## What this changes

## Tested how

- [ ] `app\CarPlayHudWizard.ps1 -SelfTest` passes (Windows PowerShell 5.1)
- [ ] `SHA256SUMS` updated
- [ ] If a car-side script changed: tested on a real car (model, year, iDrive software, steps, result):

## Checklist

- [ ] No change happens without the `CHANGE IDRIVE` confirmation
- [ ] No personal data (VIN, serial, Wi-Fi, MACs, street names) in code, docs or logs
- [ ] ASCII only; `.sh` files use LF line endings
