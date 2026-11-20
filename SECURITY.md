# Safety and security

## Report a safety problem privately

If you find something that could leave a head unit in a bad state, harm a car's other systems, or expose
users' data, please **don't open a public issue**. Use GitHub's **Report a vulnerability** button on the Security
tab of this repository (private advisory), with the steps to reproduce.

## What this project will not do

- Change anything in the car without a typed `CHANGE IDRIVE` confirmation.
- Touch boot scripts, the boot image, coding, or any control unit other than the infotainment head unit.
- Send fake data to driver-assistance or other safety-related displays or systems.
- Store or transmit your head-unit password. It stays in memory while the wizard is open.

## Your data

Backups in `Documents\BMW-CarPlay-HUD-backups` contain your CarPlay Wi-Fi password, the head unit's serial
number and BMW software. They never leave your PC unless you copy them. Don't share that folder.
