# CarPlay HUD for BMW NBT EVO

**Google Maps turn arrows from Apple CarPlay on your BMW's own head-up display and instrument cluster.**

A step-by-step Windows wizard installs the open-source
[BMW-iDrive6-CarPlay-HUD](https://github.com/ftojke/BMW-iDrive6-CarPlay-HUD) bridge by ftojke, with a check
before every change, two tests that a restart undoes, and a one-click undo.

> Not made, approved or supported by BMW, Apple or Google. You change software in your car's head unit at your
> own risk. Keep the car parked during every step. Non-commercial use only (see [LICENSE](LICENSE)).

---

## Will it work on my car?

| You need | Notes |
|---|---|
| BMW with an **NBT EVO** head unit (iDrive 6) and **wireless CarPlay** | For example G30 5 Series and G01 X3 / G02 X4 before about 2020. Cars with iDrive 7 (Live Cockpit, MGU) are **not** supported |
| A factory **head-up display** and/or **instrument cluster** that shows BMW navigation arrows | The arrows are drawn by the car's own displays (tested with HUD + digital cluster) |
| An **iPhone** with Google Maps | Other CarPlay maps apps work if they share turn-by-turn data with the car |

**Tested and working:**

| Car | iDrive software | Result |
|---|---|---|
| X3 G01 (2019), factory HUD + digital cluster | NBTevo_Y24073J | Works: arrows, distance and street on the HUD; survives restarts; road-tested |
| 5 Series G30 | NBTevo_Y21432J | Works (tested by the bridge author) |

**Other cars:** the wizard's first check compares your iDrive's CarPlay files byte-for-byte with the versions the
bridge was built for. If they don't match, it **stops before changing anything**. So you can safely try the check on
any NBT EVO car. Please report your result (see [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)).

## What you need

- A **Windows 10 or 11 laptop** with:
  - **PowerShell 7** (free, from Microsoft; the wizard links to it if it's missing)
  - the **OpenSSH Client** (built into Windows; the wizard tells you if it's switched off)
- An **ENET cable** (OBD-II to Ethernet), the same kind used for BMW coding.
- The free **Bavarian SSH client** from <https://ssh.bavarian-aa.uk/>. It switches on SSH until the next iDrive
  restart. It's a separate tool and isn't included here. Extract it under Downloads, Desktop or Documents, and
  the wizard finds it and starts it for you.
- Your head unit's **SSH root password**. This project doesn't publish it.
- **30-45 minutes**, with the car parked, engine running or a battery charger connected.

Details and download links: [docs/PREREQUISITES.md](docs/PREREQUISITES.md).

## Install it, step by step

1. **Download:** open **Releases** (right-hand side of this page) and download the latest ZIP. Or use the green
   **Code** button > **Download ZIP**.
2. **Unblock:** right-click the ZIP > **Properties** > tick **Unblock** > **OK**. Then right-click > **Extract All**.
3. **Start:** in the extracted folder, double-click **`Start-Wizard.cmd`**.
   If Windows shows "Windows protected your PC", click **More info** > **Run anyway**. It's a plain-text script
   you can open in Notepad and read.
4. **Follow the wizard.** Every step says exactly what it does, and Next only unlocks when the step has passed:
   - Anything that changes the iDrive asks you to type `CHANGE IDRIVE` first.
   - After every stage that changes something, the wizard asks you to test (CarPlay, music, calls, arrows), and
     only continues when you confirm it works.
   - When SSH is needed, the wizard starts Bavarian. You click "Enable SSH" there, and the wizard carries on by
     itself as soon as SSH is on.

| Step | What happens | Changes in the car | You test |
|---|---|---|---|
| 1-2. Welcome, Get ready | Checklist for the car and the laptop | Nothing | - |
| 3. Connect | Starts Bavarian, waits for SSH; you sign in once | Nothing | - |
| 4. Check the car | Compares your CarPlay files with known-good versions; saves a backup on the laptop | Nothing | - |
| 5. Copy test files | Adds one new folder, `/fs/sda0/opt/aa-cp`; tests it on the car | New folder only | CarPlay still normal |
| 6. Test 1: watch only | The bridge listens, sends nothing | Memory only (a restart removes it) | CarPlay, music, calls |
| 7. Test 2: live | Arrows on your HUD while parked | Memory only (a restart removes it) | Arrow + distance on the HUD |
| 8. Restart the iDrive | Removes the test; checks SSH still works | Nothing | CarPlay reconnects by itself |
| 9. Install permanently | Your CarPlay program is kept as `mm-ipod.real`; a small starter takes its place. Bridge still OFF | One rename + one script | CarPlay, music, calls |
| 10. Switch on | Bridge ON for every drive | One switch file | Arrows on the HUD |
| 11. Final check | Restart: arrows must come back on their own | Nothing | Arrows without the laptop |
| 12. Done | Drive-test checklist | Nothing | On the road |

Your backups go to `Documents\BMW-CarPlay-HUD-backups`. **Keep that folder private:** it contains your CarPlay
Wi-Fi password and the head unit's serial number.

## Turn it off or remove it

Switch on SSH with Bavarian, start the wizard, sign in (step 3), then click **Tools / Undo**:

- **Turn the bridge off**: it stays installed but does nothing.
- **Remove everything**: puts your original CarPlay program back and deletes the folder. Then use **Check files are
  original**.

**Before a BMW dealer software update, use Remove everything.**

## Good to know

- It only runs inside the **wireless CarPlay** connection. Bluetooth, BMW navigation and everything else stay original.
- Don't run a BMW navigation route and a Google Maps route at the same time. The bridge doesn't step aside for BMW navigation.
- No lane guidance (the bridge doesn't support it yet).
- If something misbehaves while driving, end the route in Google Maps, or turn the iPhone's Wi-Fi off once you've
  stopped safely. Restarting the iDrive does **not** turn the installed bridge off; use Tools / Undo for that.
- Don't combine it with other CarPlay or Android Auto cluster mods (st1ng's CarPlay Advanced, or a running NBT-AAD).
  The check stops if it finds one active.

## More

- [docs/PREREQUISITES.md](docs/PREREQUISITES.md): everything you need, with links
- [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md): what is changed where, and every safety check
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md): error messages, stop conditions, emergency recovery
- [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md): known-good file versions; how to report your car
- [docs/COMMAND-LINE.md](docs/COMMAND-LINE.md): the same steps without the wizard, for advanced users
- [NOTICE.md](NOTICE.md): credits, licence and trademarks
- [CHANGELOG.md](CHANGELOG.md) | [CONTRIBUTING.md](CONTRIBUTING.md) | [SECURITY.md](SECURITY.md)

Status: **v0.9.0 beta**, tested on two cars. Please send a compatibility report from yours (Issues > New issue).
