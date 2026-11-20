# Prerequisites

Get these ready before you go to the car. The wizard's step 2 checks the laptop items for you.

## The car

| Item | How to check |
|---|---|
| NBT EVO head unit (iDrive 6) with **wireless** CarPlay | The iDrive's software version starts with `NBTevo_` (the wizard's check shows it) |
| Factory head-up display and/or instrument cluster that shows BMW navigation arrows | The HUD shows BMW route guidance today |
| iPhone with Google Maps (or Apple Maps) | Waze on iPhone sends no turn-by-turn data, so it can't show arrows |
| No other CarPlay/Android Auto cluster mod active | e.g. st1ng's CarPlay Advanced, or a running NBT-AAD. The check stops if it finds one |

## The laptop

| Item | Where to get it |
|---|---|
| Windows 10 or 11 | - |
| PowerShell 7 (free, Microsoft) | <https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows>, or in a Command Prompt: `winget install Microsoft.PowerShell` |
| Windows OpenSSH Client | Built in. If missing: Settings > System > Optional features > Add a feature > "OpenSSH Client" |
| Bavarian SSH client (free) | <https://ssh.bavarian-aa.uk/>. Extract it anywhere under Downloads, Desktop or Documents; the wizard finds and starts it (or use "Find Bavarian on this laptop...") |
| ENET cable (OBD-II to Ethernet RJ45) | The same cable used for BMW coding. A USB-to-Ethernet adapter works if the laptop has no network port |
| The head unit's SSH root password | Not published by this project |

Windows PowerShell 5.1 (built into Windows) runs the wizard window; PowerShell 7 runs each step on the car.

## On the day

- 30-45 minutes. Car parked in P, parking brake on, outdoors or well ventilated.
- Engine running, or a battery support charger connected.
- Laptop on the ENET cable only. If Bavarian can't find the car, disconnect Wi-Fi and other networks.
- Your iPhone connected to wireless CarPlay.

## Network details (for troubleshooting)

The laptop gets a 169.254.x.x address on the ENET cable automatically. The head unit's HMI board answers at
`169.254.199.119`, the other board at `169.254.199.99`. SSH is on port 22 only after Bavarian's "Enable SSH",
until the next iDrive restart.
