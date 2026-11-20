# Troubleshooting

## Quick undo

| Situation | What to do |
|---|---|
| During Test 1 or Test 2 | **Restart the iDrive**: hold the volume knob about 30 seconds until it restarts. Nothing else is needed. |
| After "Install permanently" | Wizard > sign in > **Tools / Undo > Turn the bridge off**, or **Remove everything** |
| Not sure what state it's in | **Tools / Undo > Check status** |

## Messages in the wizard

| Message | Meaning and fix |
|---|---|
| "No answer from 169.254.199.119" | SSH isn't on. Use "Enable SSH" in Bavarian (a restart switches it off). Check the ENET cable and wait until the iDrive has fully started. If the laptop is also on Wi-Fi or another network, disconnect it. |
| "The head unit refused the login" | Wrong password, or SSH is off again. If the password is surely right: **Tools / Undo > Type the password in a window instead**. |
| "Stopped ... does not match" during the check | Your iDrive software has different CarPlay files than the bridge was built for. Nothing was changed. Please report it ([COMPATIBILITY.md](COMPATIBILITY.md)). |
| "another mod ... seems installed" / "NBT-AAD is running" | Another CarPlay or Android Auto cluster mod uses the same hooks. Remove or disable it first. |
| "a RAM test link is active" | A test is still running. Restart the iDrive, enable SSH again, then repeat the step. |
| "No test data yet" after a test | CarPlay hasn't reconnected since the test started. Turn the iPhone's Wi-Fi off for 15 s, then on, wait for CarPlay, then answer again. |
| "Guidance was sent but not shown" | The car accepted nothing on its displays. This car may need a different cluster path; restart the iDrive and report it. |
| "NEW watchdog report" | The iDrive reset itself during the test. Stop, restart the iDrive (or Remove everything if installed), and report it. |
| Window says "Working..." for minutes | Open the PowerShell window in the taskbar. If it asks for a password, type it there. |
| Windows says "running scripts is disabled" | Start the wizard with `Start-Wizard.cmd`, not by double-clicking the `.ps1`. |

## Stop conditions

Stop and undo if any of these happen:

- CarPlay, Bluetooth audio, calls or iDrive speed behave differently than before.
- The iDrive restarts on its own.
- The wizard reports a new watchdog report, driver fingerprints that differ, or that the iPhone rejected Identify.

## Emergency: the HMI side doesn't answer, but the other board does

Only needed after "Install permanently", if `169.254.199.119` stops answering while `169.254.199.99` still does.
With SSH enabled, in a Command Prompt:

```
ssh -o HostKeyAlgorithms=+ssh-dss,ssh-rsa -o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1 -m hmac-sha1 root@169.254.199.99
```

Then on the head unit:

```
on -f hu-omap /bin/sh
mount -uw /fs/sda0
B=/fs/sda0/opt/conn/bin/carplay
[ -f $B/mm-ipod.real ] && mv -f $B/mm-ipod.real $B/mm-ipod
rm -rf /fs/sda0/opt/aa-cp
C=/var/opt/conn/carplay/iap2_Wifi.cfg; [ -f $C.orig ] && cp $C.orig $C && rm $C.orig
mount -ur /fs/sda0
ls -l $B/mm-ipod        # must show 39836 bytes
```

**Never delete `/opt/conn/bin/carplay/mm-ipod` by hand.** Outside a test it is your real CarPlay program.

Honest limit: this project never touches the boot scripts or boot image. If a head unit ever stopped booting with
no SSH at all, recovery would need a BMW/ISTA software reflash.

## Restore from your laptop backup

If "Remove everything" can't restore the original, the command line can write your golden laptop backup back
(temporary file + rename, original owner and permissions), then read it back:

```
pwsh -ExecutionPolicy Bypass -File app\cphud.ps1 restore-from-laptop
```

## Reporting a problem

Open an issue with: car model and year, iDrive software version (from the check output), which step, and the
technical details text. **Remove** your VIN, the head-unit serial number, Wi-Fi name/password, MAC addresses and
street names first.
