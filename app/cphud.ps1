<#
.SYNOPSIS
  Staged, reversible test of the CarPlay -> BMW HUD/KOMBI bridge (ftojke/BMW-iDrive6-CarPlay-HUD @ 97b9133)
  on a G01 NBT Evo (NBTevo_Y24073J, split node, HMI/OMAP at 169.254.199.119).

.DESCRIPTION
  One step per run. Read-only steps never write to the head unit. Every step that changes anything prints
  exactly what it changes and waits for you to type CHANGE IDRIVE.

  Order:
    preflight          read-only checks + laptop backups (CarPlay connected)            - no iDrive change
    stage              adds NEW folder /fs/sda0/opt/aa-cp, self-tests on the car         - CarPlay files untouched
    try dryrun         RAM-only test link: hook observe-only; a reboot undoes it         - no file changed
    log                read-only: fetch + check the hook log
    try active         RAM-only test link: hook live; a reboot undoes it                 - no file changed
    swap               make it permanent: mm-ipod -> mm-ipod.real + wrapper, mode=off     - reboot after
    mode active        hook live from disk                                               - reboot after
    cfg-ident          OPTIONAL, only if 'active' gets no guidance                        - reboot after
    status             read-only snapshot at any time
    rollback           back to stock at any time                                         - reboot after
    verify-stock       read-only: proves the car is byte-for-byte stock again
    restore-from-laptop  LAST RESORT: writes your laptop backup of mm-ipod (and cfg) back

  -DryRun  prints every command/script without connecting.

.EXAMPLE
  .\cphud.ps1 preflight
  .\cphud.ps1 try dryrun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('preflight', 'stage', 'try', 'swap', 'mode', 'status', 'log', 'cfg-ident', 'rollback', 'verify-stock', 'restore-from-laptop')]
    [string]$Action,
    [Parameter(Position = 1)]
    [ValidateSet('off', 'dryrun', 'active')]
    [string]$Mode,
    [string]$HuIp = '169.254.199.119',
    [string]$BackupRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'BMW-CarPlay-HUD-backups'),
    [switch]$IncludeCfg,
    [switch]$Force,
    [switch]$DryRun,
    [string]$Simulate,     # offline test of this tool only: reads canned outputs from this folder, never connects
    # Used by the wizard window (CarPlayHudWizard.ps1). The wizard asks you in its own window first, then passes:
    [string]$Confirm,      # the confirmation word you typed in the wizard (must be exactly CHANGE IDRIVE)
    [ValidateSet('y', 'n')]
    [string]$Answer,       # your yes/no answer to the question a log step asks
    [switch]$Wizard,       # never wait for keyboard input; accept the head unit's host key on first use only
    [string]$OutLog        # also append everything shown on screen to this text file
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------------------
# Pinned facts (upstream repo at 97b9133, your own read-only captures, st1ng/nbtevo-carplay-advanced notes)
# ---------------------------------------------------------------------------------------------------------
$Kit = $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $Kit 'payload'))) { $Kit = Split-Path -Parent $PSScriptRoot }   # repo layout: app\cphud.ps1, payload\
$Payload = @{
    Hook        = Join-Path $Kit 'payload\libnbt_carplay_hud.so'
    Wrapper     = Join-Path $Kit 'payload\mm-ipod-wrapper.sh'
    WrapperLink = Join-Path $Kit 'payload\mm-ipod-wrapper-link.sh'
    Frag        = Join-Path $Kit 'payload\iap2_ident.cfgfrag'
}
$HookSha = 'CD1043FC10EE1CEC7BF4BEA8C555EA14A97643ED5457950F3F8B573A85A5A48E'   # upstream build/libnbt_carplay_hud_real.so
$Stock = @{
    'mm-ipod'              = 'D3F7C8973FEFF37D512BA92BAF42D40CE8A2626FE38FDF17E7DA10DB320BB36F'
    'ipod-drvr-iap2.so'    = '3512652C1D88A26512F82548327090C2A4F174680A4EAF23DFCCEAEB82AAEA4C'
    'ipod-transport-bt.so' = 'CEFF2F83234477C4856E34B938F2B213A46C00EAAC492ED6C54AB4F5577E7701'
}
$StockMmIpodSize = 39836
$RemotePath = [ordered]@{
    'mm-ipod'              = '/opt/conn/bin/carplay/mm-ipod'
    'ipod-drvr-iap2.so'    = '/opt/conn/lib/carplay/ipod-drvr-iap2.so'
    'ipod-transport-bt.so' = '/opt/conn/lib/carplay/ipod-transport-bt.so'
    'iap2_Wifi.cfg'        = '/var/opt/conn/carplay/iap2_Wifi.cfg'
}
$Ssh = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$SshOpts = @('-T', '-o', 'ConnectTimeout=10', '-o', 'HostKeyAlgorithms=+ssh-dss', '-m', 'hmac-sha1')
if ($Wizard) {
    # Host key: remembered on first use in the backups folder, and ssh refuses outright if it ever changes.
    # One password attempt per connection, so a wrong password fails fast instead of asking again in the background.
    $kh = (Join-Path $BackupRoot 'known_hosts') -replace '\\', '/'
    $SshOpts += @('-o', 'StrictHostKeyChecking=accept-new', '-o', ('UserKnownHostsFile="{0}"' -f $kh), '-o', 'NumberOfPasswordPrompts=1')
}
$ConfirmWord = 'CHANGE IDRIVE'
$StateFile = Join-Path $BackupRoot 'state.json'
$LogDir = Join-Path $BackupRoot 'logs'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# ---------------------------------------------------------------------------------------------------------
# Console helpers
# ---------------------------------------------------------------------------------------------------------
function Out-Log([string]$t) {
    if (-not $OutLog) { return }
    try { [IO.File]::AppendAllText($OutLog, $t + "`r`n", (New-Object System.Text.UTF8Encoding $false)) } catch { }
}
function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c; Out-Log $t }
function Ok([string]$t)   { Write-Host "  [ok]   $t" -ForegroundColor Green; Out-Log "  [ok]   $t" }
function Warn([string]$t) { Write-Host "  [warn] $t" -ForegroundColor Yellow; Out-Log "  [warn] $t" }
function Bad([string]$t)  { Write-Host "  [STOP] $t" -ForegroundColor Red; Out-Log "  [STOP] $t" }
function Sha([string]$p)  { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToUpperInvariant() }

function Initialize-Folders {
    foreach ($d in @($BackupRoot, $LogDir)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
    $note = Join-Path $BackupRoot 'PRIVATE-README.txt'
    if (-not (Test-Path -LiteralPath $note)) {
        Set-Content -LiteralPath $note -Encoding ASCII -Value @(
            'PRIVATE: these backups contain your car''s CarPlay Wi-Fi name and passphrase (iap2_Wifi.cfg),'
            'the head-unit serial number and BMW binaries. Do not upload, post or share this folder.'
            'Keep a second copy on a USB stick you control.')
    }
}

function Save-Text([string]$name, [string]$text) {
    if ($DryRun) { return }
    $p = Join-Path $LogDir ("{0}-{1}-{2}.txt" -f $Stamp, $Action, $name)
    [IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding $false))
}

# ---------------------------------------------------------------------------------------------------------
# Local state (which steps passed). Lives next to the backups, never on the car.
# ---------------------------------------------------------------------------------------------------------
function Get-CphudState {
    $s = @{ goldenDir = $null; lastPreflightDir = $null; lastState = $null; transportOk = $false
            stageVerified = $false; linkTried = $false; swapDone = $false; dryrunVerified = $false
            activeTried = $false; activeWorked = $false; lastMode = $null; history = @() }
    if (Test-Path -LiteralPath $StateFile) {
        $j = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { $s[$p.Name] = $p.Value }
    }
    if ($null -eq $s.history) { $s.history = @() }
    return $s
}

function Save-CphudState($s, [string]$result) {
    $s.history = @($s.history) + @([pscustomobject]@{ time = (Get-Date).ToString('s'); action = "$Action $Mode".Trim(); result = $result })
    if ($DryRun) { return }
    $s | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Get-Manifest([string]$dir) {
    if (-not $dir) { return $null }
    $m = Join-Path $dir 'manifest.json'
    if (-not (Test-Path -LiteralPath $m)) { return $null }
    return (Get-Content -LiteralPath $m -Raw | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------------------------------------
# SSH plumbing. Binary-safe (raw stdin/stdout streams), password typed by you at ssh's own prompt.
# ---------------------------------------------------------------------------------------------------------
function ConvertTo-WinArg([string]$a) {
    if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { return $a }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $a.ToCharArray()) {
        if ($ch -eq [char]'\') { $bs++; continue }
        if ($ch -eq [char]'"') { [void]$sb.Append(('\' * ($bs * 2 + 1))); [void]$sb.Append('"') }
        else { if ($bs) { [void]$sb.Append(('\' * $bs)) }; [void]$sb.Append($ch) }
        $bs = 0
    }
    if ($bs) { [void]$sb.Append(('\' * ($bs * 2))) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-Hu {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string]$What,
        [string]$InFile,
        [byte[]]$InBytes,
        [string]$OutFile,
        [string]$SimName
    )
    $hasIn = ([bool]$InFile) -or ($null -ne $InBytes)
    if ($DryRun -or $Simulate) {
        $tag = 'dry-run'; if ($Simulate) { $tag = 'simulate' }
        Say ("  [{0}] {1}" -f $tag, $What) DarkGray
        Say ("           ssh root@{0} {1}" -f $HuIp, $Command) DarkGray
        $text = ''
        $src = $null; if ($Simulate -and $SimName) { $src = Join-Path $Simulate $SimName }
        if ($OutFile) {
            if ($src -and (Test-Path -LiteralPath $src)) { Copy-Item -LiteralPath $src -Destination $OutFile -Force }
            else { [IO.File]::WriteAllBytes($OutFile, [byte[]]@()) }
        } elseif ($src -and (Test-Path -LiteralPath $src)) {
            $text = ([IO.File]::ReadAllText($src)) -replace "`r", ''
        }
        return [pscustomobject]@{ ExitCode = 0; Text = $text }
    }
    if (-not (Test-Path -LiteralPath $Ssh)) { throw "OpenSSH client not found at $Ssh" }
    $argv = @($SshOpts)
    if (-not $hasIn) { $argv += '-n' }
    $argv += @("root@$HuIp", $Command)
    Say ">> $What" Cyan
    if ($env:SSH_ASKPASS -and $env:CPHUD_PW) { Say '   (password supplied by the wizard)' DarkGray }
    else { Say '   (type the head-unit root password at the ssh prompt; it is not shown or stored)' DarkGray }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Ssh
    $psi.Arguments = (($argv | ForEach-Object { ConvertTo-WinArg $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $false          # ssh prompts + errors stay on your console
    $psi.RedirectStandardInput = $hasIn
    if ($hasIn -and $psi.PSObject.Properties['StandardInputEncoding']) {
        $psi.StandardInputEncoding = New-Object System.Text.UTF8Encoding $false
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($OutFile) { $sink = [IO.File]::Create($OutFile) } else { $sink = New-Object IO.MemoryStream }
    $copy = $proc.StandardOutput.BaseStream.CopyToAsync($sink)
    if ($hasIn) {
        if ($proc.StandardInput.Encoding.GetPreamble().Length -gt 0) {
            try { $proc.Kill() } catch { }
            $sink.Close()
            throw 'This PowerShell would add a byte-order mark to the upload. Nothing was sent. Run the kit from PowerShell 7 (pwsh).'
        }
        $stdin = $proc.StandardInput.BaseStream
        if ($InFile) { $src = [IO.File]::OpenRead($InFile); try { $src.CopyTo($stdin) } finally { $src.Close() } }
        else { $stdin.Write($InBytes, 0, $InBytes.Length) }
        $stdin.Flush()
        $proc.StandardInput.Close()
    }
    if (-not $proc.WaitForExit(600000)) { try { $proc.Kill() } catch { }; throw "ssh timed out: $What" }
    $proc.WaitForExit()
    $copy.Wait()
    $text = ''
    if ($OutFile) { $sink.Close() }
    else { $text = ([Text.Encoding]::UTF8.GetString($sink.ToArray())) -replace "`r", ''; $sink.Close() }
    if ($proc.ExitCode -eq 255) { Bad "ssh could not connect/log in (exit 255): $What" }
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Text = $text }
}

# Shell helpers prepended to every remote script. QNX 6.5 ksh on hu-omap has no head/awk/tar/printf (st1ng's notes),
# so only ls/grep/sed/cat/cp/mv/mount/pidin/ln are relied on; sizes come from `ls -l`.
$Prelude = @'
PATH=/proc/boot:/bin:/usr/bin:/sbin:/usr/sbin:$PATH; export PATH
TMPDIR=/dev/shmem; export TMPDIR
FAILS=0
ok()   { echo "OK    $*"; }
bad()  { echo "FAIL  $*"; FAILS=$((FAILS+1)); }
info() { echo "INFO  $*"; }
die()  { echo "FAIL  $*"; echo "RESULT FAIL"; exit 1; }
sz()   { if [ -f "$1" ]; then set -- $(ls -l "$1"); echo $5; else echo -1; fi; }
flush()  { for s in /bin/sync /proc/boot/sync /usr/bin/sync /sbin/sync; do [ -x $s ] && { $s; return 0; }; done; return 0; }   # hu-omap has no sync: a read-only remount commits qnx6
finish() { if [ $FAILS -eq 0 ]; then echo "RESULT PASS"; exit 0; else echo "RESULT FAIL ($FAILS)"; exit 1; fi; }
'@

function Invoke-HuScript {
    param([string]$What, [string]$Body, [hashtable]$Vars, [string]$SimName, [switch]$Quiet)
    $text = $Prelude + "`n" + $Body
    if ($Vars) { foreach ($k in $Vars.Keys) { $text = $text.Replace("@@$k@@", [string]$Vars[$k]) } }
    if ($text -match '@@[A-Z_]+@@') { throw "internal error: unreplaced token $($Matches[0])" }
    $text = ($text -replace "`r", '') + "`n"
    if ($DryRun) {
        Say "  ----- remote script: $What -----" DarkGray
        foreach ($l in ($text -split "`n")) { Say "  | $l" DarkGray }
        Say '  ----- end of script -----' DarkGray
    }
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($text)
    # Written to RAM (/dev/shmem), syntax-checked by the car's own shell first (sh -n: a parse error can never stop it
    # half-way), run with stdin from /dev/null, then deleted. TMPDIR: some images have no /tmp for ksh here-documents.
    $cmd = 'TMPDIR=/dev/shmem; export TMPDIR; cat > /dev/shmem/cphud-run.sh && /bin/sh -n /dev/shmem/cphud-run.sh && /bin/sh /dev/shmem/cphud-run.sh </dev/null; r=$?; rm -f /dev/shmem/cphud-run.sh; exit $r'
    $res = Invoke-Hu -Command $cmd -What $What -InBytes $bytes -SimName $SimName
    if (-not $Quiet) {
        foreach ($l in ($res.Text -split "`n")) {
            if ($l -eq '') { continue }
            if ($l -match '^OK\s') { Say "    $l" Green }
            elseif ($l -match '^(FAIL|RESULT FAIL)') { Say "    $l" Red }
            elseif ($l -match '^(INFO|WARN)') { Say "    $l" Yellow }
            elseif ($l -match '^RESULT PASS') { Say "    $l" Green }
            else { Say "    $l" DarkGray }
        }
    }
    Save-Text ($What -replace '[^A-Za-z0-9]+', '-') $res.Text
    $pass = ($res.ExitCode -eq 0) -and ($res.Text -match '(?m)^RESULT PASS')
    if ($DryRun) { $pass = $true }
    $res | Add-Member -NotePropertyName Pass -NotePropertyValue $pass
    return $res
}

function Get-RemoteFile([string]$remote, [string]$local, [string]$what, [string]$simName) {
    $r = Invoke-Hu -Command "cat $remote" -What $what -OutFile $local -SimName $simName
    $len = 0; if (Test-Path -LiteralPath $local) { $len = (Get-Item -LiteralPath $local).Length }
    $sha = ''; if ($len -gt 0) { $sha = Sha $local }
    return [pscustomobject]@{ Exit = $r.ExitCode; Size = $len; Sha = $sha }
}

# Several files in ONE ssh call (one password prompt): `cat a b c`, split on the laptop by the sizes the car reported.
# A missing file or a wrong size shifts everything after it, so every hash after that point fails: fail-safe.
function Get-RemoteFiles([string[]]$Remotes, [long[]]$Sizes, [string[]]$Locals, [string[]]$SimNames, [string]$What) {
    $tmp = Join-Path $env:TEMP ('cphud-pull-' + [guid]::NewGuid().ToString('N') + '.bin')
    if ($Simulate) {
        $fs = [IO.File]::Create($tmp)
        for ($i = 0; $i -lt $Remotes.Count; $i++) {
            $src = Join-Path $Simulate $SimNames[$i]
            if (Test-Path -LiteralPath $src) { $b = [IO.File]::ReadAllBytes($src); $fs.Write($b, 0, $b.Length) }
        }
        $fs.Close()
        Say "  [simulate] $What" DarkGray
    } else {
        [void](Invoke-Hu -Command ('cat ' + ($Remotes -join ' ')) -What $What -OutFile $tmp)
    }
    $all = [IO.File]::ReadAllBytes($tmp)
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    $total = [long]0; foreach ($s in $Sizes) { $total += $s }
    $out = @(); $off = [long]0
    for ($i = 0; $i -lt $Remotes.Count; $i++) {
        $len = [long]$Sizes[$i]
        $take = [long][Math]::Max(0, [Math]::Min($len, $all.Length - $off))
        $fs = [IO.File]::Create($Locals[$i])
        if ($take -gt 0) { $fs.Write($all, [int]$off, [int]$take) }
        $fs.Close()
        $sha = ''; if ($take -gt 0) { $sha = Sha $Locals[$i] }
        $out += [pscustomobject]@{ Remote = $Remotes[$i]; Size = $take; Sha = $sha }
        $off += $len
    }
    return [pscustomobject]@{ Complete = ($all.Length -eq $total); Received = $all.Length; Expected = $total; Files = $out }
}

function Send-File([string]$local, [string]$remote, [string]$what) {
    $r = Invoke-Hu -Command "cat > $remote" -What $what -InFile $local
    if ($r.ExitCode -ne 0 -and -not $DryRun) { throw "upload failed (ssh exit $($r.ExitCode)): $what" }
}

function Test-Reach {
    if ($DryRun -or $Simulate) { return $true }
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($HuIp, 22, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(4000) -and $c.Connected) { Ok "head unit $HuIp answers on SSH port 22"; return $true }
    } catch { } finally { $c.Close() }
    Bad "head unit $HuIp is not reachable on port 22 (ignition/iDrive awake? ENET cable? laptop NIC on 169.254.x.x?)"
    return $false
}

function Confirm-Change([string[]]$Lines, [switch]$PhoneOff, [string]$Title = 'THIS STEP CHANGES THE iDRIVE HEAD UNIT:') {
    Say ''
    Say $Title Yellow
    foreach ($l in $Lines) { Say "  - $l" Yellow }
    Say 'Before you confirm: car parked in P with the parking brake on, engine running (or a battery support' Yellow
    Say 'charger connected), ENET cable plugged in, outdoors or well ventilated.' Yellow
    if ($PhoneOff) { Say 'Also: switch CarPlay off on the iPhone (or turn the phone''s Wi-Fi + Bluetooth off) for this step.' Yellow }
    if ($DryRun) { Say "[dry-run] would now ask you to type: $ConfirmWord" DarkGray; return $true }
    if ($Simulate) { Say "[simulate] auto-confirmed" DarkGray; return $true }
    if ($Confirm) {
        if ($Confirm -ceq $ConfirmWord) { Say "Confirmed in the wizard: $ConfirmWord" Cyan; return $true }
        Say 'The wizard did not pass the exact confirmation word. Nothing was changed.' Green
        return $false
    }
    if ($Wizard) { Say 'No confirmation from the wizard. Nothing was changed.' Green; return $false }
    $a = Read-Host "Type $ConfirmWord to proceed (anything else cancels)"
    if ($a -ceq $ConfirmWord) { return $true }
    Say 'Cancelled. Nothing was changed.' Green
    return $false
}

function Read-YesNo([string]$q) {
    if ($Answer) { Say "$q  -> your answer in the wizard: $Answer" Cyan; return ($Answer -eq 'y') }
    if ($Simulate) { return $true }
    if ($Wizard) { Say "$q  -> no answer from the wizard, treated as NO" Yellow; return $false }
    return ((Read-Host "$q (y/n)") -match '^[yY]')
}

function Assert-Payload {
    $okAll = $true
    foreach ($k in 'Hook', 'Wrapper', 'WrapperLink', 'Frag') {
        if (-not (Test-Path -LiteralPath $Payload[$k])) { Bad "missing kit file: $($Payload[$k])"; $okAll = $false }
    }
    if (-not $okAll) { return $false }
    if ((Sha $Payload.Hook) -ne $HookSha) { Bad 'payload\libnbt_carplay_hud.so is not the pinned upstream build (hash differs)'; $okAll = $false }
    else { Ok 'hook .so matches the pinned upstream build (97b9133)' }
    foreach ($k in 'Wrapper', 'WrapperLink', 'Frag') {
        $b = [IO.File]::ReadAllBytes($Payload[$k])
        if (@($b | Where-Object { $_ -eq 13 }).Count -gt 0) { Bad "$($Payload[$k]) has Windows CR line endings - would break on QNX"; $okAll = $false }
        elseif ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { Bad "$($Payload[$k]) starts with a UTF-8 BOM"; $okAll = $false }
    }
    if ($okAll) { Ok 'wrappers + cfg fragment have Unix line endings, no BOM' }
    return $okAll
}

function ConvertTo-OctalMode([string]$m) {
    if ($m -notmatch '^[-dlbcps][-r][-w][-xsS][-r][-w][-xsS][-r][-w][-xtT]$') { return $null }
    $v = ''
    foreach ($i in 1, 4, 7) {
        $n = 0
        if ([string]$m[$i] -ceq 'r') { $n += 4 }
        if ([string]$m[$i + 1] -ceq 'w') { $n += 2 }
        if ('xst'.Contains([string]$m[$i + 2])) { $n += 1 }
        $v += [string]$n
    }
    return $v
}

function Read-Report([string]$text) {
    $r = @{ ls = @{}; present = @{}; mode = 'none'; ramMode = 'none'; testLink = $false; testLinkLine = ''
            identCount = -1; identAny = -1; msgsCount = -1; cfgLines = -1; wdCount = -1; wd = @(); other = @(); otherBoot = 0
            mounts = @(); df = @(); procs = @(); kombi = ''; logTail = @(); logSize = ''; aadRun = -1; aadBoot = -1 }
    foreach ($l in ($text -split "`n")) {
        if ($l -match '^LS (\S+)\s+\d+\s+(\S+)\s+(\S+)\s+(\d+)\s.*\s(/\S+)$') {
            $r.ls[$Matches[5]] = @{ mode = $Matches[1]; owner = $Matches[2]; group = $Matches[3]; size = [long]$Matches[4]; line = $l.Substring(3) }
        }
        elseif ($l -match '^PRESENT (\S+)') { $r.present[$Matches[1]] = $true }
        elseif ($l -match '^ABSENT (\S+)') { $r.present[$Matches[1]] = $false }
        elseif ($l -match '^MODE (\S*)') { $r.mode = $Matches[1] }
        elseif ($l -match '^RAMMODE (\S*)') { $r.ramMode = $Matches[1] }
        elseif ($l -match '^TESTLINK none') { $r.testLink = $false }
        elseif ($l -match '^TESTLINK (.*)') { $r.testLink = $true; $r.testLinkLine = $Matches[1] }
        elseif ($l -match '^IDENTCOUNT (\d+)') { $r.identCount = [int]$Matches[1] }
        elseif ($l -match '^IDENTANY (\d+)') { $r.identAny = [int]$Matches[1] }
        elseif ($l -match '^MSGSCOUNT (\d+)') { $r.msgsCount = [int]$Matches[1] }
        elseif ($l -match '^CFGLINES (\d+)') { $r.cfgLines = [int]$Matches[1] }
        elseif ($l -match '^WDCOUNT (\d+)') { $r.wdCount = [int]$Matches[1] }
        elseif ($l -match '^WD (.*)') { $r.wd += $Matches[1] }
        elseif ($l -match '^OTHER (\S+)') { $r.other += $Matches[1] }
        elseif ($l -match '^OTHERBOOT (\d+)') { $r.otherBoot = [int]$Matches[1] }
        elseif ($l -match '^MOUNT (.*)') { $r.mounts += $Matches[1] }
        elseif ($l -match '^DF (.*)') { $r.df += $Matches[1] }
        elseif ($l -match '^PROC (.*)') { $r.procs += $Matches[1] }
        elseif ($l -match '^KOMBIPING (\S+)') { $r.kombi = $Matches[1] }
        elseif ($l -match '^LOGTAIL (.*)') { $r.logTail += $Matches[1] }
        elseif ($l -match '^LOGSIZE (\S+)') { $r.logSize = $Matches[1] }
        elseif ($l -match '^AADRUN (\d+)') { $r.aadRun = [int]$Matches[1] }
        elseif ($l -match '^AADBOOT (\d+)') { $r.aadBoot = [int]$Matches[1] }
    }
    return $r
}

function Get-Present($rep, [string]$path) { if ($rep.present.ContainsKey($path)) { return [bool]$rep.present[$path] } return $false }
function Get-Prop($obj, [string]$name, $default) {
    if ($null -eq $obj) { return $default }
    $p = $obj.PSObject.Properties[$name]
    if ($null -eq $p) { return $default }
    return $p.Value
}

# Read-only facts shared by several scripts: the RAM test link, RAM mode, watchdog reports, other mods.
$CommonProbe = @'
if [ -L /opt/conn/bin/carplay/mm-ipod ]; then echo "TESTLINK $(ls -l /opt/conn/bin/carplay/mm-ipod)"; else echo "TESTLINK none"; fi
if [ -r /dev/shmem/cphud.mode ]; then read -r m < /dev/shmem/cphud.mode; echo "RAMMODE $m"; else echo "RAMMODE none"; fi
if [ -r /opt/aa-cp/mode ]; then read -r m < /opt/aa-cp/mode; echo "MODE $m"; else echo "MODE none"; fi
n=0; for f in /var/dump/wd_err_*; do [ -e "$f" ] && n=$((n+1)); done; echo "WDCOUNT $n"
echo "AADRUN $(pidin arg 2>/dev/null | grep -e nbt-aad -e /opt/aa/ | grep -v grep | grep -c .)"
echo "AADBOOT $(grep -c -e nbt-aad -e /opt/aa/ /bin/start_screen.sh 2>/dev/null)"
'@

# Read-only snapshot used by preflight, status and verify-stock.
$SnapshotBody = $CommonProbe + "`n" + @'
for f in /opt/conn/bin/carplay/mm-ipod /fs/sda0/opt/conn/bin/carplay/mm-ipod /opt/conn/bin/carplay/mm-ipod.real \
         /opt/conn/lib/carplay/ipod-drvr-iap2.so /opt/conn/lib/carplay/ipod-transport-bt.so \
         /var/opt/conn/carplay/iap2_Wifi.cfg /opt/aa-cp/libnbt_carplay_hud.so /opt/aa-cp/mm-ipod-wrapper.sh \
         /opt/aa-cp/mm-ipod-wrapper-link.sh /opt/aa-cp/bin/mm-ipod; do
  if [ -e "$f" ]; then echo "LS $(ls -l "$f")"; else echo "NOFILE $f"; fi
done
for f in /fs/sda0/opt/aa-cp /opt/aa-cp /fs/sda0/opt/conn/bin/carplay/mm-ipod.real /opt/conn/bin/carplay/mm-ipod.real \
         /var/opt/conn/carplay/iap2_Wifi.cfg.orig /dev/shmem/cphud.debug; do
  if [ -e "$f" ]; then echo "PRESENT $f"; else echo "ABSENT $f"; fi
done
for f in /var/opt/hmi/data/rw/Plugins/CarPlayMenu /var/opt/hmi/data/rw/carplaymenu /fs/sda1/opt/hmi/data/ID5/carplaymenu /opt/aa; do
  [ -e "$f" ] && echo "OTHER $f"
done
echo "OTHERBOOT $(grep -c -e CarPlayMenu -e carplaymenu /bin/start_screen.sh 2>/dev/null)"
ls -l /var/dump 2>/dev/null | grep wd_err | sed 's/^/WD /'
C=/var/opt/conn/carplay/iap2_Wifi.cfg
echo "IDENTCOUNT $(grep -c '^\[ident\]' $C 2>/dev/null)"
echo "IDENTANY $(grep -ci 'ident' $C 2>/dev/null)"
echo "MSGSCOUNT $(grep -c 'msgs' $C 2>/dev/null)"
echo "CFGLINES $(grep -c '' $C 2>/dev/null)"
mount 2>/dev/null | grep -i sda0 | sed 's/^/MOUNT /'
df /fs/sda0 2>/dev/null | sed 's/^/DF /'
pidin arg 2>/dev/null | grep -i 'mm-ipod' | grep -v grep | sed 's/^/PROC /'
if [ -f /dev/shmem/cphud.log ]; then
  echo "LOGSIZE $(sz /dev/shmem/cphud.log)"
  tail -n 15 /dev/shmem/cphud.log 2>/dev/null | sed 's/^/LOGTAIL /'
else
  echo "LOGSIZE none"
fi
@@EXTRA@@
echo "RESULT PASS"
'@

function Show-Snapshot($rep) {
    $real = Get-Present $rep '/fs/sda0/opt/conn/bin/carplay/mm-ipod.real'
    $aacp = Get-Present $rep '/fs/sda0/opt/aa-cp'
    $orig = Get-Present $rep '/var/opt/conn/carplay/iap2_Wifi.cfg.orig'
    $mm = $null; if ($rep.ls.ContainsKey('/fs/sda0/opt/conn/bin/carplay/mm-ipod')) { $mm = $rep.ls['/fs/sda0/opt/conn/bin/carplay/mm-ipod'] }
    Say ''
    Say 'Head-unit state:' White
    if ($mm) { Say ("  mm-ipod on disk   : {0}" -f $mm.line) } else { Say '  mm-ipod on disk   : MISSING' Red }
    Say ("  mm-ipod.real      : {0}" -f $(if ($real) { 'present (launcher swapped on disk)' } else { 'absent' }))
    Say ("  RAM test link     : {0}" -f $(if ($rep.testLink) { "ACTIVE ($($rep.testLinkLine)) - gone at next reboot" } else { 'none' }))
    Say ("  RAM test mode     : {0}" -f $rep.ramMode)
    Say ("  /fs/sda0/opt/aa-cp: {0}; disk mode: {1}" -f $(if ($aacp) { 'present' } else { 'absent' }), $rep.mode)
    Say ("  cfg [ident]       : {0} section(s); iap2_Wifi.cfg.orig {1}" -f $rep.identCount, $(if ($orig) { 'present' } else { 'absent' }))
    Say ("  watchdog reports  : {0} in /var/dump" -f $rep.wdCount)
    foreach ($o in $rep.other) { Say "  other mod found   : $o" Yellow }
    foreach ($m in $rep.mounts) { Say "  mount             : $m" DarkGray }
    if ($rep.procs.Count -eq 0) { Say '  mm-ipod processes : none running right now' DarkGray }
    foreach ($p in $rep.procs) { Say "  process           : $p" DarkGray }
    if ($rep.logSize -and $rep.logSize -ne 'none') { Say ("  hook log          : {0} bytes in /dev/shmem/cphud.log (use: .\cphud.ps1 log)" -f $rep.logSize) }
}

# ---------------------------------------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------------------------------------
function Invoke-Preflight {
    $st = Get-CphudState
    Say '== PRE-FLIGHT (read-only: nothing on the car is changed) ==' White
    Say 'Have CarPlay connected (wireless) while this runs, so the CarPlay Wi-Fi process can be checked.' DarkGray
    $stop = 0; $warn = 0
    $reasons = New-Object System.Collections.ArrayList
    if (-not (Assert-Payload)) { $stop++; [void]$reasons.Add('payload') }
    if (-not (Test-Reach)) { return }
    $dir = Join-Path $BackupRoot "backup-$Stamp"
    if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    else { $dir = Join-Path $env:TEMP "cphud-dryrun-$Stamp"; New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $extra = 'if ping -c 2 160.48.199.96 </dev/null >/dev/null 2>&1; then echo "KOMBIPING ok"; else echo "KOMBIPING noreply"; fi'
    $snap = Invoke-HuScript -What 'read-only snapshot (1 of 2)' -Body $SnapshotBody -Vars @{ EXTRA = $extra } -SimName 'snapshot.out' -Quiet
    [IO.File]::WriteAllText((Join-Path $dir 'report.txt'), $snap.Text, (New-Object System.Text.UTF8Encoding $false))
    $rep = Read-Report $snap.Text

    Say ''
    Say 'Checks:' White
    if ($rep.testLink) { Bad "a RAM test link is active ($($rep.testLinkLine)). Reboot the head unit, then run preflight again."; $stop++; [void]$reasons.Add('testlink') }
    # NBT-AAD (/opt/aa) installed but idle is allowed: it shares the cluster channel only while it runs.
    $hasAad = $rep.other -contains '/opt/aa'
    $otherHard = @($rep.other | Where-Object { $_ -ne '/opt/aa' })
    if ($rep.aadRun -ne 0) {
        Bad ("NBT-AAD (/opt/aa) is running or its state could not be read (AADRUN {0}). Never test this bridge alongside it." -f $rep.aadRun)
        $stop++; [void]$reasons.Add('aad-running')
    }
    if ($hasAad -and $rep.aadBoot -ne 0) {
        Bad ("NBT-AAD is referenced in /bin/start_screen.sh or that could not be read (AADBOOT {0})." -f $rep.aadBoot)
        $stop++; [void]$reasons.Add('aad-boot')
    }
    if ($hasAad -and $rep.aadRun -eq 0 -and $rep.aadBoot -eq 0 -and $otherHard.Count -eq 0 -and $rep.otherBoot -eq 0) {
        Warn 'NBT-AAD is installed in /opt/aa but is not running and not in start_screen.sh: allowed while idle. status/log STOP and try refuses if it ever runs. Keep Android phones away during tests.'
        $warn++
    }
    elseif ($otherHard.Count -gt 0 -or $rep.otherBoot -gt 0) {
        Bad ('another mod that hooks mm-ipod / the cluster seems installed ({0}{1}). st1ng''s CarPlay Advanced and NBT-AAD use the same hooks and cluster channel: never combine them with this bridge.' -f ($rep.other -join ', '), $(if ($rep.otherBoot -gt 0) { ', start_screen.sh hook line' } else { '' }))
        $stop++; [void]$reasons.Add('other-mod')
    } elseif (-not $hasAad) { Ok 'no other CarPlay/Android Auto cluster mod found (st1ng CarPlayMenu, NBT-AAD)' }

    # copy the four files in ONE ssh call, split by the sizes the car just reported
    $names = @(); $remotes = @(); $sizes = @(); $locals = @()
    foreach ($name in $RemotePath.Keys) {
        $p = $RemotePath[$name]
        if ($rep.ls.ContainsKey($p)) { $names += $name; $remotes += $p; $sizes += $rep.ls[$p].size; $locals += (Join-Path $dir $name) }
        else { Bad "$p is missing on the car"; $stop++; [void]$reasons.Add("copy:$name") }
    }
    $files = [ordered]@{}
    if ($remotes.Count -gt 0) {
        $pull = Get-RemoteFiles -Remotes $remotes -Sizes $sizes -Locals $locals -SimNames $names -What 'copy mm-ipod, driver, transport and iap2_Wifi.cfg to the laptop (read-only) (2 of 2)'
        if (-not $pull.Complete) { Bad ("copy stream was {0} bytes, expected {1} - incomplete copy" -f $pull.Received, $pull.Expected); $stop++; [void]$reasons.Add('copy:stream') }
        for ($i = 0; $i -lt $names.Count; $i++) {
            $f = $pull.Files[$i]; $l = $rep.ls[$remotes[$i]]
            $files[$names[$i]] = [ordered]@{ remote = $remotes[$i]; size = $f.Size; sha256 = $f.Sha; ls = $l.line
                                             mode = (ConvertTo-OctalMode $l.mode); owner = $l.owner; group = $l.group }
        }
    }
    function FileSha([string]$n) { if ($files.Contains($n)) { return $files[$n].sha256 } return '' }

    $drvOk = (FileSha 'ipod-drvr-iap2.so') -eq $Stock['ipod-drvr-iap2.so']
    if ($drvOk) { Ok 'ipod-drvr-iap2.so matches the bridge''s reverse-engineered baseline' }
    else { Bad 'ipod-drvr-iap2.so differs from the baseline - the hook would disable itself; do not install'; $stop++; [void]$reasons.Add('driver') }

    $trOk = (FileSha 'ipod-transport-bt.so') -eq $Stock['ipod-transport-bt.so']
    if ($trOk) { Ok 'ipod-transport-bt.so matches the baseline (the hook also patches this module)' }
    else { Bad 'ipod-transport-bt.so differs from the baseline the bridge was built against (not fingerprint-checked by the hook)'; $stop++; [void]$reasons.Add('transport') }

    $wrapSha = Sha $Payload.Wrapper
    $mmSha = FileSha 'mm-ipod'
    $mmKind = 'unknown'
    if ($mmSha -eq $Stock['mm-ipod']) { $mmKind = 'stock'; Ok 'mm-ipod is the stock binary (matches the baseline; st1ng lists the same hash for other NBT Evo builds)' }
    elseif ($mmSha -eq $wrapSha) { $mmKind = 'wrapper'; Ok 'mm-ipod is this kit''s wrapper' }
    elseif (-not $rep.testLink) { Bad 'mm-ipod is neither stock nor this kit''s wrapper - unknown state, not touching it'; $stop++; [void]$reasons.Add('mm-ipod') }

    $a = $null; $b = $null
    if ($rep.ls.ContainsKey('/opt/conn/bin/carplay/mm-ipod')) { $a = $rep.ls['/opt/conn/bin/carplay/mm-ipod'] }
    if ($rep.ls.ContainsKey('/fs/sda0/opt/conn/bin/carplay/mm-ipod')) { $b = $rep.ls['/fs/sda0/opt/conn/bin/carplay/mm-ipod'] }
    if ($a -and $b -and ($a.size -eq $b.size) -and (($a.line -replace '\s/\S+$', '') -eq ($b.line -replace '\s/\S+$', ''))) {
        Ok '/opt/conn/... and /fs/sda0/opt/conn/... show the same mm-ipod (the install path is the one the system runs)'
    } elseif (-not $rep.testLink) { Bad 'cannot confirm /opt/conn/bin/carplay/mm-ipod is the file at /fs/sda0/opt/conn/bin/carplay/mm-ipod'; $stop++; [void]$reasons.Add('path-mapping') }

    $real = Get-Present $rep '/fs/sda0/opt/conn/bin/carplay/mm-ipod.real'
    $aacp = Get-Present $rep '/fs/sda0/opt/aa-cp'
    $orig = Get-Present $rep '/var/opt/conn/carplay/iap2_Wifi.cfg.orig'
    $state = 'unknown'
    if ($mmKind -eq 'stock' -and -not $real -and -not $aacp -and -not $orig) { $state = 'stock' }
    elseif ($mmKind -eq 'stock' -and -not $real -and $aacp) { $state = 'staged' }
    elseif ($mmKind -eq 'wrapper' -and $real -and $aacp) { $state = 'swapped' }
    if ($state -eq 'unknown') { Bad 'head-unit state does not match stock/staged/swapped - run status, then rollback if needed'; $stop++; [void]$reasons.Add('state') }
    else { Ok "head-unit state: $state" }

    if ($rep.identCount -eq 0) {
        Ok ("iap2_Wifi.cfg has no [ident] section (whole file checked: {0} lines; the earlier check only read 120)" -f $rep.cfgLines)
        if ($rep.identAny -gt 0 -or $rep.msgsCount -gt 0) { Warn 'cfg mentions ident/msgs elsewhere - open report.txt and check by eye before cfg-ident'; $warn++ }
    } elseif ($rep.identCount -gt 0) { Warn 'iap2_Wifi.cfg already has an [ident] section - the optional cfg-ident step will not be needed'; $warn++ }
    else { Warn 'could not count [ident] sections in iap2_Wifi.cfg'; $warn++ }

    $wifiProc = @($rep.procs | Where-Object { $_ -cmatch 'iap2_wifi' })
    if ($wifiProc.Count -gt 0) { Ok 'CarPlay Wi-Fi mm-ipod found and its arguments contain "iap2_wifi" (the wrapper''s trigger)' }
    elseif ($rep.procs.Count -gt 0) {
        Warn 'mm-ipod is running but no process arguments contain lowercase "iap2_wifi". The wrapper only loads the hook'
        Warn 'when that exact text is present. Connect CarPlay wirelessly and run preflight again; if it never appears,'
        Warn 'the hook would never load (safe, but it would not work) - stop and compare report.txt PROC lines.'
        $warn++
    } else { Warn 'no mm-ipod process seen - connect CarPlay (wireless) and run preflight again'; $warn++ }

    if ($rep.kombi -eq 'ok') { Ok 'instrument cluster 160.48.199.96 answers on the internal network (the bridge sends arrows there)' }
    else { Warn 'cluster 160.48.199.96 did not answer ping (it may just ignore ping; the G01 Android Auto reports used the same path)'; $warn++ }
    if ($rep.wdCount -gt 0) { Say ("         {0} earlier watchdog report(s) in /var/dump (baseline recorded; the kit flags any NEW ones)" -f $rep.wdCount) DarkGray }
    foreach ($m in $rep.mounts) { Say "         mount: $m" DarkGray }
    foreach ($d in $rep.df) { Say "         df:    $d" DarkGray }

    $manifest = [ordered]@{ time = (Get-Date).ToString('s'); huIp = $HuIp; state = $state; stop = $stop; warn = $warn
                            stopReasons = @($reasons); transportOk = $trOk; driverOk = $drvOk; wdCount = $rep.wdCount
                            files = $files; kitWrapperSha = $wrapSha; hookSha = $HookSha }
    ($manifest | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $dir 'manifest.json') -Encoding UTF8
    if ($DryRun) { Say "`n[dry-run] nothing was saved or changed." DarkGray; return }

    $st.lastPreflightDir = $dir; $st.lastState = $state; $st.transportOk = $trOk
    # A golden backup only needs complete, stock copies (a transport-hash mismatch doesn't make the copies bad).
    $copiesBad = @($reasons | Where-Object { $_ -match '^copy:|^(mm-ipod|state|path-mapping|payload|testlink)$' }).Count -gt 0
    if ($state -eq 'stock' -and -not $copiesBad -and -not $st.goldenDir) {
        $st.goldenDir = $dir
        Ok "saved as your GOLDEN stock backup: $dir"
    } elseif ($st.goldenDir) {
        $g = Get-Manifest $st.goldenDir
        if ($g -and $files.Contains('iap2_Wifi.cfg') -and $g.files.'iap2_Wifi.cfg'.sha256 -ne $files['iap2_Wifi.cfg'].sha256) {
            Warn 'iap2_Wifi.cfg differs from your golden backup (the car may have rewritten it). Newest copy is in this backup.'
        }
    }
    Save-CphudState $st ("state=$state stop=$stop warn=$warn")
    Say ''
    Say "Backup folder: $dir" White
    if ($stop -gt 0) { Bad ("PRE-FLIGHT FAILED ({0} blocking issue(s): {1}). Do not continue." -f $stop, ($reasons -join ', ')); return }
    Ok ("PRE-FLIGHT PASSED with {0} warning(s)." -f $warn)
    switch ($state) {
        'stock'   { Say 'Next: .\cphud.ps1 stage' White }
        'staged'  { Say 'Next: .\cphud.ps1 try dryrun' White }
        'swapped' { Say 'Already swapped. Use: .\cphud.ps1 status   /   mode ...   /   rollback' White }
    }
}

# ---------------------------------------------------------------------------------------------------------
# stage: new folder only, plus on-car self-tests
# ---------------------------------------------------------------------------------------------------------
$StageBody = @'
H=/dev/shmem/cphud-up-hook.so; W=/dev/shmem/cphud-up-wrapper.sh; WL=/dev/shmem/cphud-up-wrapper-link.sh
D=/fs/sda0/opt/aa-cp; S=/fs/sda0/opt/conn/bin/carplay/mm-ipod
[ "$(sz $H)" = "@@HOOK_SIZE@@" ] || die "uploaded hook is $(sz $H) bytes, expected @@HOOK_SIZE@@ (upload incomplete)"
[ "$(sz $W)" = "@@WRAP_SIZE@@" ] || die "uploaded wrapper is $(sz $W) bytes, expected @@WRAP_SIZE@@"
[ "$(sz $WL)" = "@@LINK_SIZE@@" ] || die "uploaded test wrapper is $(sz $WL) bytes, expected @@LINK_SIZE@@"
[ -e $S.real ] && die "mm-ipod.real exists: launcher already swapped - use status/mode/rollback"
[ "$(sz $S)" = "@@STOCK_SIZE@@" ] || die "the mm-ipod on disk is not the stock size - not copying it"
mount -uw /fs/sda0 || die "could not remount /fs/sda0 read-write"
if mkdir -p $D/bin && cp $H $D/libnbt_carplay_hud.so && cp $W $D/mm-ipod-wrapper.sh && cp $WL $D/mm-ipod-wrapper-link.sh \
   && cp $S $D/bin/mm-ipod && echo off > $D/mode \
   && chmod 755 $D/libnbt_carplay_hud.so $D/mm-ipod-wrapper.sh $D/mm-ipod-wrapper-link.sh $D/bin/mm-ipod && chmod 644 $D/mode; then
  flush; mount -ur /fs/sda0; ok "copied hook, both wrappers and a copy of the stock mm-ipod into $D (mode=off); /fs/sda0 back to read-only"
else
  rm -rf $D; flush; mount -ur /fs/sda0; die "copy failed - $D removed again, nothing else touched"
fi
rm -f $H $W $WL
mount | grep -i sda0 | sed 's/^/INFO  mount: /'
[ "$(sz /opt/aa-cp/libnbt_carplay_hud.so)" = "@@HOOK_SIZE@@" ] && ok "hook visible at /opt/aa-cp (path mapping as expected)" || bad "hook not visible at /opt/aa-cp"
[ "$(sz /opt/aa-cp/bin/mm-ipod)" = "@@STOCK_SIZE@@" ] && ok "stock mm-ipod copy in /opt/aa-cp/bin" || bad "stock mm-ipod copy has the wrong size"
read -r m < /opt/aa-cp/mode; [ "$m" = off ] && ok "disk mode file = off" || bad "disk mode file is '$m'"
for w in mm-ipod-wrapper.sh mm-ipod-wrapper-link.sh; do
  sh -n /opt/aa-cp/$w </dev/null && ok "$w passes this car's shell syntax check" || bad "$w has a syntax error on this car's shell"
done
out=$(LD_PRELOAD=/opt/aa-cp/libnbt_carplay_hud.so NBT_CARPLAY_SELFTEST=1 /bin/uname </dev/null 2>&1); rc=$?
if [ $rc -eq 0 ] && [ "$out" = QNX ]; then ok "hook self-test: the QNX loader maps the hook (uname -> $out, rc=0)"; else bad "hook self-test failed (rc=$rc, output '$out')"; fi
# Wrapper logic tests, entirely in RAM. No mm-ipod is ever started; the hook stays inert (SELFTEST=1).
T=/dev/shmem/cphud-wt
echo 'echo "R|${LD_PRELOAD:-unset}|${NBT_CARPLAY_HUD:-unset}|${NBT_CARPLAY_DRYRUN:-unset}|$*"' > $T-real
L=/opt/aa-cp/libnbt_carplay_hud.so
wt() {
  if [ "$2" = none ]; then rm -f $T-mode; else echo "$2" > $T-mode; fi
  got=$(NBT_CARPLAY_SELFTEST=1 /bin/sh $T-wrapper.sh $3 </dev/null 2>&1 | grep '^R|')
  if [ "$got" = "$4" ]; then ok "$W0 logic: $1"; else bad "$W0 logic: $1 - expected '$4' got '$got'"; fi
}
for W0 in mm-ipod-wrapper.sh mm-ipod-wrapper-link.sh; do
  sed -e "s#^exec [^ ]*#exec /bin/sh $T-real#" -e "s#^MODEFILE=.*#MODEFILE=$T-mode#" /opt/aa-cp/$W0 > $T-wrapper.sh
  grep "^exec /bin/sh $T-real" $T-wrapper.sh >/dev/null || bad "could not build the RAM test copy of $W0"
  wt "no mode file -> stock"                    none   "-x iap2_wifi" "R|unset|unset|unset|-x iap2_wifi"
  wt "mode off -> stock"                        off    "-x iap2_wifi" "R|unset|unset|unset|-x iap2_wifi"
  wt "unexpected mode text -> stock"            banana "-x iap2_wifi" "R|unset|unset|unset|-x iap2_wifi"
  wt "dryrun, Bluetooth instance -> stock"      dryrun "-x iap2_bt"   "R|unset|unset|unset|-x iap2_bt"
  wt "active, Bluetooth instance -> stock"      active "-x iap2_bt"   "R|unset|unset|unset|-x iap2_bt"
  wt "dryrun, Wi-Fi instance -> observe-only"   dryrun "-x iap2_wifi" "R|$L|1|1|-x iap2_wifi"
  wt "active, Wi-Fi instance -> hook active"    active "-x iap2_wifi" "R|$L|1|unset|-x iap2_wifi"
done
rm -f $T-wrapper.sh $T-real $T-mode
finish
'@

function Invoke-Stage {
    $st = Get-CphudState
    Say '== STAGE: add the bridge files in a new folder (CarPlay files untouched) ==' White
    if (-not (Assert-Payload)) { return }
    $m = Get-Manifest $st.lastPreflightDir
    if (-not $st.goldenDir -and -not $DryRun) { Bad 'no golden stock backup yet - run .\cphud.ps1 preflight first (on a stock car)'; return }
    if (-not $m -and -not $DryRun) { Bad 'run .\cphud.ps1 preflight first'; return }
    if ($m) {
        $reasons = @($m.stopReasons)
        $onlyTransport = ($reasons.Count -eq 1) -and ($reasons[0] -eq 'transport')
        if ($m.stop -gt 0 -and -not ($Force -and $onlyTransport)) {
            Bad ('the last preflight had blocking issues ({0}). Fix them and run preflight again.' -f ($reasons -join ', '))
            if ($onlyTransport) { Say '  (the transport hash is the only issue; to accept that risk knowingly, add -Force)' DarkGray }
            return
        }
        if ($m.state -notin @('stock', 'staged')) { Bad "last preflight state is '$($m.state)' - stage only runs on a stock or staged unit"; return }
        if (((Get-Date) - [datetime]$m.time).TotalHours -gt 12) { Bad 'last preflight is older than 12 hours - run preflight again'; return }
    }
    if (-not (Test-Reach)) { return }
    $hookSize = (Get-Item -LiteralPath $Payload.Hook).Length
    $wrapSize = (Get-Item -LiteralPath $Payload.Wrapper).Length
    $linkSize = (Get-Item -LiteralPath $Payload.WrapperLink).Length
    $go = Confirm-Change @(
        'Creates the NEW folder /fs/sda0/opt/aa-cp with: the hook, the permanent wrapper, the test wrapper, a copy of the stock mm-ipod (bin/mm-ipod) and mode (= off).',
        'Does NOT touch mm-ipod, iap2_Wifi.cfg or any other CarPlay/iDrive file - CarPlay keeps running stock.',
        '/fs/sda0 is remounted read-write for a few seconds, then back to read-only. No reboot needed.',
        'Then on the car: hook loader self-test (throwaway uname) and a logic test of both wrappers in RAM (/dev/shmem).',
        'Undo at any time: .\cphud.ps1 rollback   (deletes /fs/sda0/opt/aa-cp)')
    if (-not $go) { return }
    Send-File $Payload.Hook '/dev/shmem/cphud-up-hook.so' 'upload hook to RAM (/dev/shmem) - 1 of 3'
    Send-File $Payload.Wrapper '/dev/shmem/cphud-up-wrapper.sh' 'upload permanent wrapper to RAM - 2 of 3'
    Send-File $Payload.WrapperLink '/dev/shmem/cphud-up-wrapper-link.sh' 'upload test wrapper to RAM - 3 of 3'
    $r = Invoke-HuScript -What 'stage files + self-tests' -Body $StageBody -SimName 'stage.out' `
        -Vars @{ HOOK_SIZE = $hookSize; WRAP_SIZE = $wrapSize; LINK_SIZE = $linkSize; STOCK_SIZE = $StockMmIpodSize }
    if (-not $r.Pass) { Bad 'stage did not pass. CarPlay files were not touched. Run .\cphud.ps1 rollback to remove /fs/sda0/opt/aa-cp.'; Save-CphudState $st 'FAIL'; return }
    $tmp = Join-Path $env:TEMP "cphud-readback-$Stamp"; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $rb = Get-RemoteFiles -What 'read back all four staged files from the car (verifies every byte)' `
        -Remotes @('/opt/aa-cp/libnbt_carplay_hud.so', '/opt/aa-cp/mm-ipod-wrapper.sh', '/opt/aa-cp/mm-ipod-wrapper-link.sh', '/opt/aa-cp/bin/mm-ipod') `
        -Sizes @($hookSize, $wrapSize, $linkSize, $StockMmIpodSize) `
        -Locals @((Join-Path $tmp 'hook'), (Join-Path $tmp 'w'), (Join-Path $tmp 'wl'), (Join-Path $tmp 'mm')) `
        -SimNames @('readback-hook', 'readback-wrapper', 'readback-wrapper-link', 'mm-ipod')
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    $want = @($HookSha, (Sha $Payload.Wrapper), (Sha $Payload.WrapperLink), $Stock['mm-ipod'])
    $label = @('hook', 'permanent wrapper', 'test wrapper', 'stock mm-ipod copy')
    $allOk = $rb.Complete
    if (-not $rb.Complete) { Bad ("read-back stream was {0} bytes, expected {1}" -f $rb.Received, $rb.Expected) }
    for ($i = 0; $i -lt 4; $i++) {
        if ($rb.Files[$i].Sha -eq $want[$i]) { Ok "$($label[$i]) on the car is byte-identical to the expected file" }
        else { Bad "$($label[$i]) read back from the car does not match"; $allOk = $false }
    }
    if ($DryRun) { return }
    if ($allOk) {
        $st.stageVerified = $true; $st.lastState = 'staged'; Save-CphudState $st 'PASS'
        Ok 'STAGE PASSED. CarPlay is still 100% stock.'
        Say 'Next: .\cphud.ps1 try dryrun' White
    } else { Save-CphudState $st 'FAIL'; Bad 'Do not continue. Run .\cphud.ps1 rollback, then preflight again.' }
}

# ---------------------------------------------------------------------------------------------------------
# try: RAM-only test through a path-manager link. A reboot removes the link and the mode: 100% stock again.
# ---------------------------------------------------------------------------------------------------------
$TryBody = @'
P=/opt/conn/bin/carplay/mm-ipod; D=/fs/sda0/opt/aa-cp; W=$D/mm-ipod-wrapper-link.sh
case "@@MODE@@" in off|dryrun|active) ;; *) die "bad mode";; esac
a=$(pidin arg 2>/dev/null | grep -e nbt-aad -e /opt/aa/ | grep -v grep | grep -c .)
[ "$a" = 0 ] || [ "@@MODE@@" = off ] || die "NBT-AAD (/opt/aa) is running or could not be checked ($a) - not testing alongside it"
[ -f $W ] && [ -f $D/bin/mm-ipod ] && [ -f $D/libnbt_carplay_hud.so ] || die "not staged - run stage first"
[ "$(sz $D/bin/mm-ipod)" = "@@STOCK_SIZE@@" ] || die "the stock mm-ipod copy has the wrong size"
[ "$(sz $W)" = "@@LINK_SIZE@@" ] || die "the test wrapper has the wrong size"
[ -e /fs/sda0/opt/conn/bin/carplay/mm-ipod.real ] && die "the launcher is swapped on disk - test links are only for before swap (use mode)"
if [ -L $P ]; then
  case "$(ls -l $P)" in *aa-cp*) ;; *) die "$P is a link that is not ours - not touching it";; esac
fi
echo @@MODE@@ > /dev/shmem/cphud.mode || die "cannot write /dev/shmem/cphud.mode"
read -r m < /dev/shmem/cphud.mode; [ "$m" = "@@MODE@@" ] && ok "RAM test mode = $m" || die "RAM mode reads back as '$m'"
if [ -f /dev/shmem/cphud.log ]; then mv -f /dev/shmem/cphud.log /dev/shmem/cphud.log.prev; info "previous hook log kept as /dev/shmem/cphud.log.prev"; fi
if [ -L $P ]; then
  info "the test link is already in place"
else
  [ "$(sz $P)" = "@@STOCK_SIZE@@" ] || die "$P is not the stock binary - not linking over it"
  ln -sP $W $P || die "ln -sP failed - nothing linked"
  ok "path-manager link made (RAM only): $P -> $W"
fi
unlink_test() { if [ -L $P ]; then case "$(ls -l $P)" in *aa-cp*) rm -f $P;; esac; fi; die "$1 - test link removed again"; }
[ -L $P ] || unlink_test "the link is not visible"
read -r first < $P; [ "$first" = "#!/bin/sh" ] || unlink_test "$P does not resolve to the test wrapper"
ls -l $P | sed 's/^/INFO  /'
ok "from the next CarPlay connection, mm-ipod starts through the test wrapper (a reboot undoes everything)"
finish
'@

function Invoke-Try {
    $st = Get-CphudState
    if (-not $Mode) { Bad 'say which mode: .\cphud.ps1 try dryrun | active | off'; return }
    Say "== TRY ($Mode): test with NO CarPlay file changed - a head-unit reboot undoes it ==" White
    if (-not $DryRun) {
        if (-not $st.stageVerified) { Bad 'stage has not passed yet - run .\cphud.ps1 stage first'; return }
        if ($st.swapDone) { Bad 'the launcher is already swapped on disk - use .\cphud.ps1 mode instead'; return }
        if ($Mode -eq 'active' -and -not $st.dryrunVerified -and -not $Force) {
            Bad 'dry-run has not been verified yet (try dryrun, reconnect CarPlay, then .\cphud.ps1 log). Override: -Force'
            return
        }
    }
    if (-not (Test-Reach)) { return }
    $desc = switch ($Mode) {
        'off'    { 'Writes "off" to /dev/shmem/cphud.mode (RAM): from the next CarPlay connection the test wrapper starts stock mm-ipod without the hook.' }
        'dryrun' { 'Writes "dryrun" to /dev/shmem/cphud.mode (RAM): the hook loads into the CarPlay Wi-Fi mm-ipod in OBSERVE-ONLY mode (logs; changes and sends nothing).' }
        'active' { 'Writes "active" to /dev/shmem/cphud.mode (RAM): the hook is live in the CarPlay Wi-Fi mm-ipod (declares route guidance to the iPhone, sends arrows to the HUD/cluster).' }
    }
    $go = Confirm-Change -Title 'THIS STEP CHANGES WHAT RUNS IN THE iDRIVE (RAM ONLY - NO FILE IS CHANGED):' @(
        $desc,
        'If not already there: a path-manager link (RAM only) so /opt/conn/bin/carplay/mm-ipod runs /fs/sda0/opt/aa-cp/mm-ipod-wrapper-link.sh, which starts the verified stock copy /fs/sda0/opt/aa-cp/bin/mm-ipod.',
        'The real mm-ipod and iap2_Wifi.cfg are not touched. A head-unit reboot removes the link and the mode: back to 100% stock.',
        'Takes effect at the next CarPlay connection.')
    if (-not $go) { return }
    $r = Invoke-HuScript -What "RAM test link, mode $Mode" -Body $TryBody -SimName 'try.out' `
        -Vars @{ MODE = $Mode; STOCK_SIZE = $StockMmIpodSize; LINK_SIZE = (Get-Item -LiteralPath $Payload.WrapperLink).Length }
    if ($DryRun) { return }
    if ($r.Pass) {
        $st.linkTried = $true; $st.lastMode = $Mode
        if ($Mode -eq 'active') { $st.activeTried = $false; $st.activeWorked = $false }
        Save-CphudState $st 'PASS'
        Ok "test mode $Mode is set (RAM only)."
        Say ''
        Say 'Now make CarPlay reconnect so a new mm-ipod starts: on the iPhone turn Wi-Fi off, wait 15 s, turn it on' White
        Say '(or Settings > General > CarPlay > your car, switch CarPlay off and on). Wait until CarPlay is back.' White
        switch ($Mode) {
            'dryrun' { Say 'Use CarPlay 2-3 minutes, start a Google Maps route, then:  .\cphud.ps1 log' White }
            'active' { Say 'Start a Google Maps route WHILE PARKED, look at the HUD + cluster, then:  .\cphud.ps1 log' White }
            'off'    { Say 'The hook is not loaded at the next connection. A reboot removes the test link completely.' White }
        }
        Say 'Anything odd at any point: reboot the head unit (hold the knob ~30 s). That alone restores stock.' Yellow
    } else { Save-CphudState $st 'FAIL'; Bad 'try failed - see output above. Nothing on disk was changed; reboot the head unit to be sure.' }
}

# ---------------------------------------------------------------------------------------------------------
# swap: make it permanent - wrapper in front of the stock mm-ipod (mode off), self-verify, auto-revert on doubt
# ---------------------------------------------------------------------------------------------------------
$SwapBody = @'
B=/fs/sda0/opt/conn/bin/carplay; D=/fs/sda0/opt/aa-cp; P=/opt/conn/bin/carplay
[ -L $P/mm-ipod ] && die "a RAM test link is active - reboot the head unit first (that clears it), then swap"
[ -f $D/mm-ipod-wrapper.sh ] && [ -f $D/libnbt_carplay_hud.so ] || die "not staged - run stage first"
[ "$(sz $D/mm-ipod-wrapper.sh)" = "@@WRAP_SIZE@@" ] || die "staged wrapper has an unexpected size"
[ -e $B/mm-ipod.real ] && die "mm-ipod.real already exists - launcher already swapped (run status)"
[ "$(sz $B/mm-ipod)" = "@@STOCK_SIZE@@" ] || die "mm-ipod is not the stock size - not touching it"
[ "$(sz $D/bin/mm-ipod)" = "@@STOCK_SIZE@@" ] && [ -x $D/bin/mm-ipod ] || die "the verified stock copy $D/bin/mm-ipod is missing or wrong - run preflight + stage again"
grep 'REAL=/fs/sda0/opt/aa-cp/bin/mm-ipod' $D/mm-ipod-wrapper.sh >/dev/null || die "staged wrapper is the old version - run preflight + stage again"
mount -uw /fs/sda0 || die "could not remount /fs/sda0 read-write"
revert() {
  rm -f $B/mm-ipod.cphud-new
  if [ -f $B/mm-ipod.real ]; then rm -f $B/mm-ipod; mv -f $B/mm-ipod.real $B/mm-ipod; fi
  flush; mount -ur /fs/sda0
  ls -l $B/mm-ipod | sed 's/^/INFO  /'
  die "$1 - REVERTED: mm-ipod is the stock binary again"
}
echo off > $D/mode || revert "could not write the mode file"
cp $D/mm-ipod-wrapper.sh $B/mm-ipod.cphud-new && chmod 755 $B/mm-ipod.cphud-new || revert "could not prepare the wrapper"
mv $B/mm-ipod $B/mm-ipod.real || revert "could not rename the stock mm-ipod"
mv $B/mm-ipod.cphud-new $B/mm-ipod || revert "could not put the wrapper in place"
flush
[ "$(sz $P/mm-ipod.real)" = "@@STOCK_SIZE@@" ] || revert "stock binary is not visible as $P/mm-ipod.real"
[ "$(sz $P/mm-ipod)" = "@@WRAP_SIZE@@" ] || revert "wrapper is not visible as $P/mm-ipod"
[ -x $P/mm-ipod ] || revert "wrapper is not executable"
read -r first < $P/mm-ipod; [ "$first" = "#!/bin/sh" ] || revert "wrapper does not start with #!/bin/sh"
sh -n $P/mm-ipod </dev/null || revert "wrapper failed the shell syntax check"
read -r m < /opt/aa-cp/mode; [ "$m" = off ] || revert "mode is not off"
[ -x /fs/sda0/opt/aa-cp/bin/mm-ipod ] || revert "the verified stock copy is not executable"
mount -ur /fs/sda0
mount | grep -i sda0 | sed 's/^/INFO  mount: /'
ls -l $P/mm-ipod $P/mm-ipod.real /opt/aa-cp/bin/mm-ipod | sed 's/^/INFO  /'
ok "launcher swapped; mode=off, so the wrapper simply starts the verified stock copy (exactly as in the try test)"
finish
'@

function Invoke-Swap {
    $st = Get-CphudState
    Say '== SWAP: make it permanent - wrapper in front of the stock CarPlay launcher (hook OFF at first) ==' White
    if (-not $DryRun) {
        if (-not $st.goldenDir) { Bad 'no golden stock backup - run preflight first'; return }
        if (-not $st.stageVerified) { Bad 'stage has not passed yet - run .\cphud.ps1 stage first'; return }
        if (-not $st.activeWorked -and -not $Force) {
            Bad 'prove it first without changing files: try dryrun -> log -> try active -> log (arrows seen on the HUD).'
            Say '  Override only if you know why: add -Force' DarkGray
            return
        }
    }
    if (-not (Assert-Payload)) { return }
    if (-not (Test-Reach)) { return }
    $go = Confirm-Change -PhoneOff @(
        'Renames /fs/sda0/opt/conn/bin/carplay/mm-ipod to mm-ipod.real (the stock binary is kept byte-for-byte).',
        'Puts the wrapper script at /fs/sda0/opt/conn/bin/carplay/mm-ipod (atomic rename, so mm-ipod never goes missing).',
        'Forces disk mode=off: the wrapper just starts the verified stock copy /fs/sda0/opt/aa-cp/bin/mm-ipod (what the try test ran) - CarPlay should behave exactly as today.',
        'Self-checks on the car; if any check fails it reverts to stock on the spot and stops.',
        'Refuses while a RAM test link is active (reboot first). Undo at any time: .\cphud.ps1 rollback')
    if (-not $go) { return }
    $r = Invoke-HuScript -What 'swap launcher (mode off)' -Body $SwapBody -SimName 'swap.out' `
        -Vars @{ WRAP_SIZE = (Get-Item -LiteralPath $Payload.Wrapper).Length; STOCK_SIZE = $StockMmIpodSize }
    if ($DryRun) { return }
    if ($r.Pass) {
        $st.swapDone = $true; $st.lastState = 'swapped'; $st.lastMode = 'off'; Save-CphudState $st 'PASS'
        Ok 'SWAP PASSED.'
        Say ''
        Say 'Now:' White
        Say '  1. Turn CarPlay back on (iPhone Wi-Fi on) and wait until it is back. No reboot needed yet.' White
        Say '  2. Use it a few minutes: CarPlay, Bluetooth audio, a phone call. Everything must be exactly as before.' White
        Say '  3. .\cphud.ps1 status        -> "a wrapper chain is in use" (aa-cp/bin/mm-ipod processes listed).' White
        Say '  If anything is off: .\cphud.ps1 rollback (works now, SSH is still on).' White
        Say '  Only when all is normal: .\cphud.ps1 mode active' White
    } else {
        Save-CphudState $st 'FAIL'
        Bad 'Swap did not complete. The script reverts to stock on failure; confirm with .\cphud.ps1 status.'
    }
}

# ---------------------------------------------------------------------------------------------------------
# mode off | dryrun | active  (disk mode file, used by the permanent wrapper after swap)
# ---------------------------------------------------------------------------------------------------------
$ModeBody = @'
D=/fs/sda0/opt/aa-cp
case "@@MODE@@" in off|dryrun|active) ;; *) die "bad mode";; esac
[ -f $D/libnbt_carplay_hud.so ] || die "not staged"
[ -f /fs/sda0/opt/conn/bin/carplay/mm-ipod.real ] || info "launcher not swapped yet - the disk mode has no effect until swap (use try for testing)"
mount -uw /fs/sda0 || die "could not remount /fs/sda0 read-write"
if echo @@MODE@@ > $D/mode; then flush; mount -ur /fs/sda0; else mount -ur /fs/sda0; die "could not write the mode file"; fi
mount | grep -i sda0 | sed 's/^/INFO  mount: /'
read -r m < /opt/aa-cp/mode; [ "$m" = "@@MODE@@" ] && ok "disk mode is now @@MODE@@" || bad "mode reads back as '$m'"
finish
'@

function Invoke-Mode {
    $st = Get-CphudState
    if (-not $Mode) { Bad 'say which mode: .\cphud.ps1 mode off | dryrun | active'; return }
    Say "== MODE (disk, permanent wrapper): $Mode ==" White
    if (-not $DryRun) {
        if ($Mode -ne 'off' -and -not $st.swapDone) { Bad 'swap has not passed yet (to test before that, use: .\cphud.ps1 try ...)'; return }
        if ($Mode -eq 'active' -and -not $st.dryrunVerified -and -not $Force) {
            Bad 'dry-run has not been verified yet (try dryrun or mode dryrun, then .\cphud.ps1 log). Override: -Force'
            return
        }
    }
    if (-not (Test-Reach)) { return }
    $desc = switch ($Mode) {
        'off'    { 'Writes "off" to /fs/sda0/opt/aa-cp/mode: after reboot the hook is not loaded (wrapper starts stock mm-ipod).' }
        'dryrun' { 'Writes "dryrun" to /fs/sda0/opt/aa-cp/mode: after reboot the hook loads OBSERVE-ONLY into the CarPlay Wi-Fi process.' }
        'active' { 'Writes "active" to /fs/sda0/opt/aa-cp/mode: after reboot the hook is live in the CarPlay Wi-Fi process at every drive.' }
    }
    $go = Confirm-Change @($desc, '/fs/sda0 is remounted read-write for a moment, then read-only. Reboot the head unit afterwards.',
                           'Undo: .\cphud.ps1 mode off  (or rollback)')
    if (-not $go) { return }
    $r = Invoke-HuScript -What "set disk mode $Mode" -Body $ModeBody -Vars @{ MODE = $Mode } -SimName 'mode.out'
    if ($DryRun) { return }
    if ($r.Pass) {
        $st.lastMode = $Mode
        Save-CphudState $st 'PASS'
        Ok "disk mode set to $Mode."
        Say 'Next: make CarPlay reconnect (iPhone Wi-Fi off 15 s, then on), start a Google Maps route while parked, then  .\cphud.ps1 log' White
        Say 'Then the reboot test: reboot the head unit, re-enable SSH with Bavarian, .\cphud.ps1 status, and check arrows again.' White
    } else { Save-CphudState $st 'FAIL'; Bad 'mode change failed - see the output above.' }
}

# ---------------------------------------------------------------------------------------------------------
# status / log
# ---------------------------------------------------------------------------------------------------------
function Invoke-Status {
    Say '== STATUS (read-only) ==' White
    if (-not (Test-Reach)) { return }
    $st = Get-CphudState
    $r = Invoke-HuScript -What 'read-only status' -Body $SnapshotBody -Vars @{ EXTRA = '' } -SimName 'snapshot.out' -Quiet
    $rep = Read-Report $r.Text
    Show-Snapshot $rep
    $realProcs = @($rep.procs | Where-Object { $_ -match 'mm-ipod\.real|aa-cp/bin/mm-ipod' })
    if ($realProcs.Count -gt 0) { Ok 'a wrapper chain is in use (mm-ipod.real or the staged copy is running)' }
    $base = [int](Get-Prop (Get-Manifest $st.lastPreflightDir) 'wdCount' -1)
    if ($base -ge 0 -and $rep.wdCount -gt $base) { Bad ("{0} NEW watchdog report(s) in /var/dump since preflight - the head unit reset itself. Stop and roll back unless you know the cause." -f ($rep.wdCount - $base)) }
    if ($rep.aadRun -ne 0) { Bad ("NBT-AAD (/opt/aa) is running or its state could not be read (AADRUN {0}) - stop the test: reboot the head unit." -f $rep.aadRun) } else { Ok 'NBT-AAD is not running' }
    foreach ($t in $rep.logTail) { Say "  log: $t" DarkGray }
}

$LogBody = $CommonProbe + "`n" + @'
echo "----CPHUD-LOG-BEGIN----"
[ -f /dev/shmem/cphud.log ] && cat /dev/shmem/cphud.log
echo "----CPHUD-LOG-END----"
echo "RESULT PASS"
'@

function Invoke-Log {
    $st = Get-CphudState
    Say '== HOOK LOG (read-only) ==' White
    if (-not (Test-Reach)) { return }
    $r = Invoke-HuScript -What 'fetch /dev/shmem/cphud.log + state (read-only)' -Body $LogBody -SimName 'log.out' -Quiet
    $head = $r.Text; $cut = $r.Text.IndexOf('----CPHUD-LOG-BEGIN----'); if ($cut -ge 0) { $head = $r.Text.Substring(0, $cut) }
    $rep = Read-Report $head
    $t = ''
    $mm = [regex]::Match($r.Text, '(?s)----CPHUD-LOG-BEGIN----\n(.*?)----CPHUD-LOG-END----')
    if ($mm.Success) { $t = $mm.Groups[1].Value }
    $full = $t
    # The log is appended per CarPlay session until a reboot: judge only the newest session.
    $idx = $t.LastIndexOf('cp_hook: armed for CarPlay Wi-Fi instance')
    if ($idx -gt 0) { $t = $t.Substring($t.LastIndexOf("`n", $idx) + 1) }
    Say ("  test link: {0}   RAM mode: {1}   disk mode: {2}   watchdog reports: {3}" -f $(if ($rep.testLink) { 'active' } else { 'none' }), $rep.ramMode, $rep.mode, $rep.wdCount) DarkGray
    $base = [int](Get-Prop (Get-Manifest $st.lastPreflightDir) 'wdCount' -1)
    $wdNew = 0; if ($base -ge 0 -and $rep.wdCount -ge 0) { $wdNew = $rep.wdCount - $base }
    if ($wdNew -gt 0) { Bad "$wdNew NEW watchdog report(s) in /var/dump since preflight - the head unit reset itself during the test." }
    $aadBad = ($rep.aadRun -ne 0)
    if ($aadBad) { Bad ("NBT-AAD (/opt/aa) is running or its state could not be read (AADRUN {0}) - results are not valid; reboot the head unit." -f $rep.aadRun) }
    if ($t.Trim() -eq '') {
        Warn 'no hook log on the car. Either the mode is off, CarPlay (wireless) has not reconnected since the mode was set,'
        Warn 'or the wrapper''s self-test refused the hook (then mm-ipod ran stock). Reconnect CarPlay and try log again; check: .\cphud.ps1 status'
        return
    }
    if (-not $DryRun) {
        $p = Join-Path $LogDir "$Stamp-cphud.log"
        [IO.File]::WriteAllText($p, $full, (New-Object System.Text.UTF8Encoding $false))
        Say "Saved: $p  (may contain street names from your route - redact before sharing)" DarkGray
    }
    function Has([string]$s) { return $t.Contains($s) }
    $dry = Has 'DRYRUN'
    Say ''
    Say ("Log checks ({0} mode):" -f $(if ($dry) { 'dry-run' } else { 'active' })) White
    $fatal = 0
    if ($wdNew -gt 0) { $fatal++ }
    if ($aadBad) { $fatal++ }
    if (Has 'armed for CarPlay Wi-Fi instance') { Ok 'hook loaded into the CarPlay Wi-Fi mm-ipod only' } else { Bad 'hook never armed'; $fatal++ }
    if (Has 'driver fingerprints differ') { Bad 'driver fingerprints differ - hook disabled itself (stock). Stop here and roll back.'; $fatal++ }
    if (Has 'missing packet_* exports') { Bad 'driver exports missing - hook disabled itself'; $fatal++ }
    if (Has 'driver recv seam installed') { Ok 'driver receive seam installed (fingerprints passed)' } else { Bad 'driver receive seam not installed'; $fatal++ }
    if (Has 'transport write seam installed') { Ok 'transport write seam installed' } else { Bad 'transport write seam not installed'; $fatal++ }
    # The 2017 iAP2 driver leaks the buffer of every message it doesn't know and stops reading the link after ~20
    # route-guidance messages (st1ng's finding). The bridge prevents that by registering the message group.
    if (Has 'iap2_ctrl_msg_table symbol not found') { Bad 'driver message table not found - route guidance would stall CarPlay after ~20 messages. Do not run active.'; $fatal++ }
    if (-not $dry) {
        if (Has 'iap2_ctrl_msg_table[0x52] registered') { Ok 'route-guidance message group registered in the driver (prevents the stock driver''s link stall)' }
        else { Bad 'route-guidance message group NOT registered - CarPlay could stall after ~20 guidance messages'; $fatal++ }
    }
    $mi = [regex]::Matches($t, 'cp_ident_patch=(-?\d+)')
    if ($mi.Count -gt 0) {
        $v = [int]$mi[$mi.Count - 1].Groups[1].Value
        if ($v -gt 0) { Ok "Identify packet can be extended safely (cp_ident_patch=$v)" } else { Bad "Identify packet could not be extended (cp_ident_patch=$v)"; $fatal++ }
    }
    if (Has '0x10DA seen') { Ok 'iPhone authentication completed with the hook loaded' }
    elseif ($dry) { Warn 'no 0x10DA yet - was CarPlay connected wirelessly for a minute or two?' }
    if (Has 'ident: rewritten') { Ok 'Identify packet extended with the route-guidance declarations' }
    if (Has 'identify ACCEPTED') { Ok 'iPhone accepted the extended Identify' }
    if (Has 'iPhone rejected Identify') { Bad 'iPhone REJECTED the extended Identify - hook fell back to stock for this session'; $fatal++ }
    foreach ($x in [regex]::Matches($t, 'link_send_message\(0x5200\) rc=(-?\d+)')) {
        if ($x.Groups[1].Value -eq '0') { Ok 'route-guidance subscription (0x5200) acknowledged' } else { Warn "0x5200 send returned rc=$($x.Groups[1].Value)" }
    }
    foreach ($x in [regex]::Matches($t, "nav source: app='([^']*)' sourceSupportsRG=(\w+)")) {
        if ($x.Groups[2].Value -eq 'YES') { Ok "nav app '$($x.Groups[1].Value)' sends turn-by-turn data" } else { Warn "nav app '$($x.Groups[1].Value)' does NOT send turn-by-turn data (app limitation)" }
    }
    $pushed = Has 'guidance ON -> KOMBI'
    if ($pushed) { Ok 'guidance was pushed to the cluster/HUD' }
    foreach ($l in ($t -split "`n")) { if ($l -match 'kombi' -and $l -notmatch 'client created') { Say "         $l" DarkGray } }
    if ($DryRun) { return }
    Say ''
    if (-not $st.swapDone -and -not $st.linkTried) { Warn 'this kit has no record of a try or swap - log reviewed, nothing recorded'; return }
    if ($dry) {
        if ($st.lastMode -ne 'dryrun') { Warn "the kit last set mode '$($st.lastMode)', not dryrun - log reviewed, nothing recorded"; return }
        if ($fatal -eq 0) {
            if (Read-YesNo 'Did wireless CarPlay, Bluetooth audio and calls all work normally during this dry-run?') {
                $st.dryrunVerified = $true; Save-CphudState $st 'dryrun PASS'
                Ok ('DRY-RUN VERIFIED. Next (when ready): .\cphud.ps1 {0} active' -f $(if ($st.swapDone) { 'mode' } else { 'try' }))
            } else { Save-CphudState $st 'dryrun user-reported problem'; Bad 'Then stop here: reboot the head unit (and rollback if swapped).' }
        } else { Save-CphudState $st 'dryrun FAIL'; Bad 'Dry-run found a blocking problem. Reboot the head unit; run .\cphud.ps1 rollback if anything was swapped.' }
    } else {
        $st.activeTried = $true
        if ($fatal -gt 0) { Save-CphudState $st "active FAIL fatal=$fatal"; Bad 'Active mode has a problem. Reboot the head unit (test link) or run mode off / rollback (swapped).'; return }
        if ($pushed) {
            if (Read-YesNo 'Did the turn arrow, distance and street appear on the HUD and in the cluster?') {
                $st.activeWorked = $true; Save-CphudState $st 'active PASS (arrows seen)'
                if ($st.swapDone) { Ok 'WORKING from disk. Done - keep the backup folder.' }
                else { Ok 'WORKING in the RAM test. To make it permanent: reboot the head unit (clears the test link), then .\cphud.ps1 swap' }
            } else { Save-CphudState $st 'active: guidance sent, nothing seen'; Warn 'Guidance was sent but not shown: the KOMBI path differs on this car. Reboot (or rollback) and report it.' }
        } elseif (-not (Has 'nav source:')) {
            Save-CphudState $st 'active: no RG data'
            Warn 'No route-guidance data arrived from the phone. If a Google Maps route was running, the optional .\cphud.ps1 cfg-ident step is the next thing to try.'
        } else { Save-CphudState $st 'active: RG data, no push yet'; Warn 'Route data arrived but nothing was pushed yet - keep the route running a minute, then log again.' }
    }
}

# ---------------------------------------------------------------------------------------------------------
# cfg-ident (optional)
# ---------------------------------------------------------------------------------------------------------
$CfgBody = @'
C=/var/opt/conn/carplay/iap2_Wifi.cfg
[ -f $C ] || die "iap2_Wifi.cfg missing"
[ -e $C.orig ] && die "iap2_Wifi.cfg.orig already exists - not overwriting the on-car backup"
[ "$(grep -c '^\[ident\]' $C)" = 0 ] || die "cfg already has an [ident] section - nothing to do"
[ "$(sz $C)" = "@@CFG_SIZE@@" ] || die "cfg is $(sz $C) bytes but your laptop backup is @@CFG_SIZE@@ - run preflight again"
mount -uw /fs/sda0 2>/dev/null
cp $C $C.orig && [ "$(sz $C.orig)" = "$(sz $C)" ] || { rm -f $C.orig; mount -ur /fs/sda0 2>/dev/null; die "could not make the on-car backup $C.orig"; }
cat >> $C <<'CPHUD_FRAGMENT_END'
@@FRAG@@
CPHUD_FRAGMENT_END
flush
if [ "$(grep -c '^\[ident\]' $C)" = 1 ] && [ "$(grep -c '^sendmsgs=0x5200,0x5203' $C)" = 1 ]; then
  ok "appended [ident] (route-guidance message ids); stock copy kept as $C.orig"
else
  cp $C.orig $C && rm -f $C.orig; flush; mount -ur /fs/sda0 2>/dev/null; die "append could not be verified - cfg restored from .orig"
fi
mount -ur /fs/sda0 2>/dev/null
finish
'@

function Invoke-CfgIdent {
    $st = Get-CphudState
    Say '== OPTIONAL: declare route guidance in iap2_Wifi.cfg ==' White
    Say 'Only needed if active mode got no route-guidance data from the phone. The hook already adds the same' DarkGray
    Say 'declarations on the wire, so try active mode WITHOUT this first.' DarkGray
    $m = Get-Manifest $st.lastPreflightDir
    if (-not $DryRun) {
        if (-not $st.swapDone -and -not $st.linkTried) { Bad 'try (or swap) has not run yet'; return }
        if (-not $st.activeTried -and -not $Force) { Bad 'try active first (and .\cphud.ps1 log). Override: -Force'; return }
        if (-not $m) { Bad 'run preflight first'; return }
    }
    if (-not (Test-Reach)) { return }
    $cfgSize = 0; $cfgSha = ''
    if ($m) { $cfgSize = $m.files.'iap2_Wifi.cfg'.size; $cfgSha = $m.files.'iap2_Wifi.cfg'.sha256 }
    $tmp = Join-Path $env:TEMP "cphud-cfg-$Stamp"; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $now = Get-RemoteFile $RemotePath['iap2_Wifi.cfg'] (Join-Path $tmp 'cfg') 'fresh copy of iap2_Wifi.cfg (read-only)' 'iap2_Wifi.cfg'
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $DryRun -and $now.Sha -ne $cfgSha) { Bad 'iap2_Wifi.cfg on the car differs from your last preflight backup - run preflight again first'; return }
    $frag = ([IO.File]::ReadAllText($Payload.Frag)) -replace "`r", ''
    $go = Confirm-Change -PhoneOff @(
        'Copies /var/opt/conn/carplay/iap2_Wifi.cfg to iap2_Wifi.cfg.orig (on the car; your laptop backup also exists).',
        'Appends the upstream [ident] section: sendmsgs=0x5200,0x5203 and recvmsgs=0x5201,0x5202,0x5204.',
        'This one IS a file change (it survives reboots). Undo: .\cphud.ps1 rollback  (restores the cfg from .orig).')
    if (-not $go) { return }
    $r = Invoke-HuScript -What 'append [ident] to iap2_Wifi.cfg' -Body $CfgBody -Vars @{ CFG_SIZE = $cfgSize; FRAG = $frag.TrimEnd("`n") } -SimName 'cfg.out'
    if ($DryRun) { return }
    if ($r.Pass) { Save-CphudState $st 'PASS'; Ok 'Done. Make CarPlay reconnect (or reboot if swapped), start a route while parked, then .\cphud.ps1 log' }
    else { Save-CphudState $st 'FAIL'; Bad 'cfg change failed and was undone - see output above.' }
}

# ---------------------------------------------------------------------------------------------------------
# rollback / verify-stock / restore-from-laptop
# ---------------------------------------------------------------------------------------------------------
$RollbackBody = @'
B=/fs/sda0/opt/conn/bin/carplay; C=/var/opt/conn/carplay/iap2_Wifi.cfg; P=/opt/conn/bin/carplay/mm-ipod
# the RAM test link first: only a link that points into aa-cp (never the real file, which is not a link)
if [ -L $P ]; then
  case "$(ls -l $P)" in
    *aa-cp*) rm -f $P && ok "RAM test link removed" || bad "could not remove the RAM test link (a reboot clears it)" ;;
    *) bad "$P is a link that is not ours - not touched (a reboot clears RAM links)" ;;
  esac
fi
rm -f /dev/shmem/cphud.mode
mount -uw /fs/sda0 || die "could not remount /fs/sda0 read-write"
if [ -f $B/mm-ipod.real ]; then
  if [ "$(sz $B/mm-ipod.real)" = "@@STOCK_SIZE@@" ]; then
    mv -f $B/mm-ipod.real $B/mm-ipod && ok "stock mm-ipod restored from mm-ipod.real" || bad "could not move mm-ipod.real back"
  else
    bad "mm-ipod.real is $(sz $B/mm-ipod.real) bytes (not stock) - left in place; use restore-from-laptop"
  fi
else
  info "no mm-ipod.real - the launcher was not swapped (or is already restored)"
fi
rm -f $B/mm-ipod.cphud-new
if [ -e /fs/sda0/opt/aa-cp ]; then rm -rf /fs/sda0/opt/aa-cp && ok "removed /fs/sda0/opt/aa-cp" || bad "could not remove /fs/sda0/opt/aa-cp"; fi
if [ -f $C.orig ]; then
  if cp $C.orig $C && [ "$(sz $C)" = "$(sz $C.orig)" ]; then rm -f $C.orig; ok "iap2_Wifi.cfg restored from .orig"; else bad "cfg restore failed (.orig kept)"; fi
fi
rm -f /dev/shmem/cphud.debug /dev/shmem/cphud-up-hook.so /dev/shmem/cphud-up-wrapper.sh /dev/shmem/cphud-up-wrapper-link.sh
flush
mount -ur /fs/sda0
mount | grep -i sda0 | sed 's/^/INFO  mount: /'
ls -l $B/mm-ipod | sed 's/^/INFO  /'
[ "$(sz $B/mm-ipod)" = "@@STOCK_SIZE@@" ] && ok "mm-ipod on disk has the stock size" || bad "mm-ipod on disk does not have the stock size"
finish
'@

function Invoke-Rollback {
    $st = Get-CphudState
    Say '== ROLLBACK to stock ==' White
    if (-not (Test-Reach)) {
        Say 'If 169.254.199.119 is down but the other board answers, see docs\TROUBLESHOOTING.md section "Emergency".' Yellow
        return
    }
    $go = Confirm-Change -PhoneOff @(
        'Removes the RAM test link (if any) and the RAM test mode.',
        'If present: renames mm-ipod.real back to mm-ipod (the original stock binary).',
        'Deletes /fs/sda0/opt/aa-cp (hook, wrappers, stock copy, mode file).',
        'If present: restores iap2_Wifi.cfg from iap2_Wifi.cfg.orig.',
        'Reboot the head unit afterwards, then run: .\cphud.ps1 verify-stock')
    if (-not $go) { return }
    $r = Invoke-HuScript -What 'rollback to stock' -Body $RollbackBody -Vars @{ STOCK_SIZE = $StockMmIpodSize } -SimName 'rollback.out'
    if ($DryRun) { return }
    $st.stageVerified = $false; $st.linkTried = $false; $st.swapDone = $false; $st.dryrunVerified = $false
    $st.activeTried = $false; $st.activeWorked = $false; $st.lastMode = $null
    $st.lastState = 'rolled-back (unverified)'
    Save-CphudState $st $(if ($r.Pass) { 'PASS' } else { 'FAIL' })
    if ($r.Pass) { Ok 'ROLLBACK DONE. Reboot the head unit (hold the knob ~30 s), then: .\cphud.ps1 verify-stock' }
    else { Bad 'Rollback reported a problem (see above). Next: .\cphud.ps1 restore-from-laptop' }
}

function Invoke-VerifyStock {
    $st = Get-CphudState
    Say '== VERIFY STOCK (read-only) ==' White
    if (-not (Test-Reach)) { return }
    $ref = Get-Manifest $st.lastPreflightDir
    $gold = Get-Manifest $st.goldenDir
    $r = Invoke-HuScript -What 'read-only status (1 of 2)' -Body $SnapshotBody -Vars @{ EXTRA = '' } -SimName 'snapshot.out' -Quiet
    $rep = Read-Report $r.Text
    $fail = 0
    if ($rep.testLink) { Bad 'a RAM test link is still active - reboot the head unit and run verify-stock again'; $fail++ }
    $mmP = '/fs/sda0/opt/conn/bin/carplay/mm-ipod'; $cfgP = $RemotePath['iap2_Wifi.cfg']
    if ($rep.ls.ContainsKey($mmP) -and $rep.ls.ContainsKey($cfgP)) {
        $tmp = Join-Path $env:TEMP "cphud-verify-$Stamp"; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        $pull = Get-RemoteFiles -What 'copy mm-ipod + iap2_Wifi.cfg (read-only) (2 of 2)' -Remotes @($mmP, $cfgP) `
            -Sizes @($rep.ls[$mmP].size, $rep.ls[$cfgP].size) -Locals @((Join-Path $tmp 'mm'), (Join-Path $tmp 'cfg')) -SimNames @('mm-ipod', 'iap2_Wifi.cfg')
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        if ($pull.Files[0].Sha -eq $Stock['mm-ipod']) { Ok 'mm-ipod is byte-for-byte stock' } else { Bad 'mm-ipod is NOT stock'; $fail++ }
        $cfgRefs = @()
        if ($ref) { $cfgRefs += $ref.files.'iap2_Wifi.cfg'.sha256 }
        if ($gold) { $cfgRefs += $gold.files.'iap2_Wifi.cfg'.sha256 }
        if ($cfgRefs -contains $pull.Files[1].Sha) { Ok 'iap2_Wifi.cfg is byte-for-byte identical to your backup' }
        elseif ($cfgRefs.Count -eq 0) { Warn 'no laptop backup of iap2_Wifi.cfg to compare with' }
        else { Bad 'iap2_Wifi.cfg differs from your backups'; $fail++ }
    } else { Bad 'mm-ipod or iap2_Wifi.cfg is missing on the car'; $fail++ }
    foreach ($p in '/fs/sda0/opt/aa-cp', '/fs/sda0/opt/conn/bin/carplay/mm-ipod.real', '/var/opt/conn/carplay/iap2_Wifi.cfg.orig') {
        if (Get-Present $rep $p) { Bad "$p still exists"; $fail++ } else { Ok "$p is gone" }
    }
    if ($DryRun) { return }
    if ($fail -eq 0) {
        $st.lastState = 'stock'; $st.stageVerified = $false; $st.linkTried = $false; $st.swapDone = $false
        $st.dryrunVerified = $false; $st.activeTried = $false; $st.activeWorked = $false
        Save-CphudState $st 'PASS'; Ok 'The head unit is back to stock for everything this kit touches.'
    } else { Save-CphudState $st 'FAIL'; Bad 'Not fully stock. Next: .\cphud.ps1 rollback, or .\cphud.ps1 restore-from-laptop' }
}

$RestoreBody = @'
B=/fs/sda0/opt/conn/bin/carplay; U=/dev/shmem/cphud-restore-mm-ipod; P=/opt/conn/bin/carplay/mm-ipod
[ "$(sz $U)" = "@@STOCK_SIZE@@" ] || die "uploaded mm-ipod has the wrong size"
if [ -L $P ]; then case "$(ls -l $P)" in *aa-cp*) rm -f $P && ok "RAM test link removed";; esac; fi
mount -uw /fs/sda0 || die "could not remount /fs/sda0 read-write"
if cp $U $B/mm-ipod.cphud-tmp && chmod @@MM_MODE@@ $B/mm-ipod.cphud-tmp; then
  if [ -n "@@MM_OWN@@" ]; then chown @@MM_OWN@@ $B/mm-ipod.cphud-tmp || info "chown failed (continuing)"; fi
  if mv -f $B/mm-ipod.cphud-tmp $B/mm-ipod; then ok "stock mm-ipod written"; else bad "rename failed"; fi
else
  rm -f $B/mm-ipod.cphud-tmp; bad "could not write the temp copy - mm-ipod untouched"
fi
if [ $FAILS -eq 0 ]; then
  rm -f $B/mm-ipod.real $B/mm-ipod.cphud-new; rm -rf /fs/sda0/opt/aa-cp
  ok "removed mm-ipod.real and /fs/sda0/opt/aa-cp (if they existed)"
fi
if [ "@@DO_CFG@@" = yes ] && [ $FAILS -eq 0 ]; then
  C=/var/opt/conn/carplay/iap2_Wifi.cfg; U2=/dev/shmem/cphud-restore-cfg
  if [ "$(sz $U2)" = "@@CFG_SIZE@@" ] && cp $U2 $C.cphud-tmp && chmod @@CFG_MODE@@ $C.cphud-tmp; then
    if [ -n "@@CFG_OWN@@" ]; then chown @@CFG_OWN@@ $C.cphud-tmp || info "chown failed (continuing)"; fi
    if mv -f $C.cphud-tmp $C; then rm -f $C.orig; ok "iap2_Wifi.cfg restored from laptop"; else bad "cfg rename failed"; fi
  else
    rm -f $C.cphud-tmp; bad "cfg not restored (size or copy problem)"
  fi
fi
rm -f /dev/shmem/cphud-restore-mm-ipod /dev/shmem/cphud-restore-cfg /dev/shmem/cphud.mode
flush; mount -ur /fs/sda0
ls -l $B/mm-ipod | sed 's/^/INFO  /'
finish
'@

function Invoke-RestoreFromLaptop {
    $st = Get-CphudState
    Say '== LAST RESORT: write your laptop backup back to the car ==' White
    $g = Get-Manifest $st.goldenDir
    if (-not $g) { Bad 'no golden backup recorded in state.json'; return }
    $mmFile = Join-Path $st.goldenDir 'mm-ipod'
    $cfgFile = Join-Path $st.goldenDir 'iap2_Wifi.cfg'
    if ((Sha $mmFile) -ne $Stock['mm-ipod']) { Bad "golden mm-ipod backup does not hash to stock: $mmFile"; return }
    $mmMode = $g.files.'mm-ipod'.mode; if (-not $mmMode) { $mmMode = '755'; Warn 'original mm-ipod permissions unknown - using 755' }
    $mmOwn = "$($g.files.'mm-ipod'.owner):$($g.files.'mm-ipod'.group)"; if ($mmOwn -eq ':') { $mmOwn = '' }
    $cfgMode = $g.files.'iap2_Wifi.cfg'.mode; $cfgOwn = "$($g.files.'iap2_Wifi.cfg'.owner):$($g.files.'iap2_Wifi.cfg'.group)"
    if ($IncludeCfg -and ((Sha $cfgFile) -ne $g.files.'iap2_Wifi.cfg'.sha256)) { Bad 'golden cfg backup file does not match its manifest'; return }
    if (-not (Test-Reach)) { return }
    $lines = @("Writes $mmFile to /fs/sda0/opt/conn/bin/carplay/mm-ipod (mode $mmMode, owner $mmOwn), via a temp file + rename.",
               'Removes the RAM test link if any; deletes mm-ipod.real and /fs/sda0/opt/aa-cp if they exist.')
    if ($IncludeCfg) { $lines += "Writes $cfgFile to /var/opt/conn/carplay/iap2_Wifi.cfg (mode $cfgMode, owner $cfgOwn) and deletes iap2_Wifi.cfg.orig." }
    else { $lines += 'iap2_Wifi.cfg is NOT touched (add -IncludeCfg to restore it too).' }
    $lines += 'Reboot afterwards, then .\cphud.ps1 verify-stock'
    if (-not (Confirm-Change -PhoneOff $lines)) { return }
    Send-File $mmFile '/dev/shmem/cphud-restore-mm-ipod' 'upload stock mm-ipod to RAM'
    if ($IncludeCfg) { Send-File $cfgFile '/dev/shmem/cphud-restore-cfg' 'upload iap2_Wifi.cfg backup to RAM' }
    if (-not $cfgMode) { $cfgMode = '777'; if ($IncludeCfg) { Warn 'original cfg permissions unknown - using 777 (as seen on your car)' } }
    if ($cfgOwn -eq ':') { $cfgOwn = '' }
    $vars = @{ STOCK_SIZE = $StockMmIpodSize; MM_MODE = $mmMode; MM_OWN = $mmOwn; DO_CFG = $(if ($IncludeCfg) { 'yes' } else { 'no' })
               CFG_SIZE = $g.files.'iap2_Wifi.cfg'.size; CFG_MODE = $cfgMode; CFG_OWN = $cfgOwn }
    $r = Invoke-HuScript -What 'restore from laptop backup' -Body $RestoreBody -Vars $vars -SimName 'restore.out'
    $tmp = Join-Path $env:TEMP "cphud-restore-$Stamp"; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $mm = Get-RemoteFile '/fs/sda0/opt/conn/bin/carplay/mm-ipod' (Join-Path $tmp 'mm-ipod') 'read back mm-ipod' 'mm-ipod'
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($DryRun) { return }
    if ($r.Pass -and $mm.Sha -eq $Stock['mm-ipod']) { Save-CphudState $st 'PASS'; Ok 'Restored and read back byte-for-byte. Reboot, then .\cphud.ps1 verify-stock' }
    else { Save-CphudState $st 'FAIL'; Bad 'Restore not confirmed. Do not reboot repeatedly; see docs\TROUBLESHOOTING.md "Emergency".' }
}

# ---------------------------------------------------------------------------------------------------------
if (-not $DryRun) { Initialize-Folders }
if ($DryRun) { Say '*** DRY-RUN: nothing will connect to the car; scripts are printed instead ***' Magenta }
if ($Simulate) { Say "*** SIMULATION from $Simulate - never connects ***" Magenta }
switch ($Action) {
    'preflight'           { Invoke-Preflight }
    'stage'               { Invoke-Stage }
    'try'                 { Invoke-Try }
    'swap'                { Invoke-Swap }
    'mode'                { Invoke-Mode }
    'status'              { Invoke-Status }
    'log'                 { Invoke-Log }
    'cfg-ident'           { Invoke-CfgIdent }
    'rollback'            { Invoke-Rollback }
    'verify-stock'        { Invoke-VerifyStock }
    'restore-from-laptop' { Invoke-RestoreFromLaptop }
}
