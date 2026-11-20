#Requires -Version 5.1
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# CarPlay HUD Wizard: a step-by-step window around cphud.ps1 (the engine that does every check and change).
# Start it with Start-Wizard.cmd. The wizard never changes the car itself: it asks you, then runs one engine step.
# Every change to the iDrive needs you to type CHANGE IDRIVE in a confirmation box first.
[CmdletBinding()]
param(
    [string]$BackupRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'BMW-CarPlay-HUD-backups'),
    [switch]$Demo,         # click through the wizard without a car: no connection, every step pretends to pass
    [switch]$SelfTest      # for developers: runs the whole demo flow without showing the window, prints PASS/FAIL
)
if ($SelfTest) { $Demo = $true }

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$AppDir      = $PSScriptRoot
$Engine      = Join-Path $AppDir 'cphud.ps1'
$AskSrc      = Join-Path $AppDir 'askpass.cs'
$HuIp        = '169.254.199.119'
$BavarianUrl = 'https://ssh.bavarian-aa.uk/'
$PwshUrl     = 'https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows'
$ConfirmWord = 'CHANGE IDRIVE'
$WorkDir     = Join-Path $env:LOCALAPPDATA 'CarPlayHudWizard'
$SshExe      = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$StateFile   = Join-Path $BackupRoot 'state.json'
$Tick        = [string][char]0x2713

# ------------------------------------------------------------------------------------------------------------
# Session state (memory only)
# ------------------------------------------------------------------------------------------------------------
$script:Pw         = $null      # SecureString, only while the wizard is open
$script:UseConsole = $false     # true: you type the password in a console window instead
$script:AskPass    = $null
$script:SignedIn   = $false
$script:Car        = $null
$script:Flags      = @{}
$script:Proc       = $null
$script:OnDone     = $null
$script:LogPath    = $null
$script:LogPos     = 0
$script:HistBefore = 0
$script:RunAction  = ''
$script:Busy       = $false
$script:Page       = 0
$script:LastTry    = ''

function Find-Pwsh {
    $c = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Path }
    foreach ($p in @((Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'), (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'))) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}
$script:Pwsh = Find-Pwsh

function Q([string]$s) { return '"' + $s + '"' }

function Read-State {
    if (Test-Path -LiteralPath $StateFile) {
        try { return (Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json) } catch { }
    }
    return $null
}
function Get-StateFlag([string]$n) {
    $s = Read-State
    if ($s -and ($s.PSObject.Properties.Name -contains $n)) { return [bool]$s.$n }
    return $false
}
function Get-History {
    $s = Read-State
    if ($s -and ($s.PSObject.Properties.Name -contains 'history')) { return @($s.history) }
    return @()
}
function Get-NewResults([int]$before) {
    $h = @(Get-History)
    if ($h.Count -le $before) { return @() }
    return @($h[$before..($h.Count - 1)] | ForEach-Object { [string]$_.result })
}

function Get-PlainPw {
    if (-not $script:Pw) { return '' }
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:Pw)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

# Compiles askpass.cs once with Windows PowerShell's built-in compiler (no download). If anything fails, the wizard
# falls back to a console window where you type the password yourself.
function Initialize-AskPass {
    try {
        if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null }
        $exe = Join-Path $WorkDir 'cphud-askpass.exe'
        $stamp = Join-Path $WorkDir 'cphud-askpass.sha256'
        $srcHash = (Get-FileHash -LiteralPath $AskSrc -Algorithm SHA256).Hash
        if ((Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $stamp) -and ((Get-Content -LiteralPath $stamp -Raw).Trim() -eq $srcHash)) { return $exe }
        Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
        $ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $cmd = "Add-Type -Path '{0}' -OutputAssembly '{1}' -OutputType ConsoleApplication" -f ($AskSrc -replace "'", "''"), ($exe -replace "'", "''")
        & $ps51 -NoProfile -NonInteractive -Command $cmd | Out-Null
        if (Test-Path -LiteralPath $exe) { Set-Content -LiteralPath $stamp -Value $srcHash -Encoding ASCII; return $exe }
    } catch { }
    return $null
}

function Test-Port22 {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($HuIp, 22, $null, $null)
        return ($iar.AsyncWaitHandle.WaitOne(3000) -and $c.Connected)
    } catch { return $false } finally { $c.Close() }
}

# ------------------------------------------------------------------------------------------------------------
# Bavarian SSH client: found on this PC (or picked once), started by the wizard. It has no command line, so you
# still click "Enable SSH" in its window; the wizard then notices SSH coming up by itself.
# ------------------------------------------------------------------------------------------------------------
$SettingsFile = Join-Path $WorkDir 'settings.json'
function Get-Setting([string]$name) {
    try {
        if (Test-Path -LiteralPath $SettingsFile) {
            $j = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
            if ($j.PSObject.Properties.Name -contains $name) { return [string]$j.$name }
        }
    } catch { }
    return ''
}
function Set-Setting([string]$name, [string]$value) {
    try {
        if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null }
        $h = @{}
        if (Test-Path -LiteralPath $SettingsFile) {
            $j = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $h[$p.Name] = $p.Value }
        }
        $h[$name] = $value
        $h | ConvertTo-Json | Set-Content -LiteralPath $SettingsFile -Encoding UTF8
    } catch { }
}
function Find-Bavarian {
    $saved = Get-Setting 'BavarianPath'
    if ($saved -and (Test-Path -LiteralPath $saved)) { return $saved }
    $roots = @((Join-Path $env:USERPROFILE 'Downloads'), (Join-Path $env:USERPROFILE 'Desktop'),
               [Environment]::GetFolderPath('MyDocuments'), (Join-Path $env:LOCALAPPDATA 'Programs'), $env:ProgramFiles)
    foreach ($r in $roots) {
        if (-not $r -or -not (Test-Path -LiteralPath $r)) { continue }
        $f = Get-ChildItem -LiteralPath $r -Recurse -Depth 3 -Filter 'bavarian-ssh-client*.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { Set-Setting 'BavarianPath' $f.FullName; return $f.FullName }
    }
    return $null
}
function Select-Bavarian {
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Title = 'Where is the Bavarian SSH client (bavarian-ssh-client.exe)?'
    $d.Filter = 'Bavarian SSH client|bavarian-ssh-client*.exe|Programs (*.exe)|*.exe'
    $d.InitialDirectory = Join-Path $env:USERPROFILE 'Downloads'
    if ($d.ShowDialog($Form) -eq 'OK') { Set-Setting 'BavarianPath' $d.FileName; return $d.FileName }
    return $null
}
$script:BavPath = $null
$script:BavSearched = $false

$SshTimer = New-Object System.Windows.Forms.Timer
$SshTimer.Interval = 2000
$script:SshWaitUntil = [datetime]::MinValue
$script:OnSshUp = $null
function Start-BavarianAndWait([scriptblock]$OnUp) {
    if ($Demo) { Set-Result "$Tick [demo] SSH is on." 'ok'; if ($OnUp) { & $OnUp }; return }
    if (Test-Port22) { Set-Result "$Tick SSH is already on ($HuIp)." 'ok'; if ($OnUp) { & $OnUp }; return }
    if (-not $script:BavPath -or -not (Test-Path -LiteralPath $script:BavPath)) { $script:BavPath = Find-Bavarian }
    if (-not $script:BavPath) { $script:BavPath = Select-Bavarian }
    if (-not $script:BavPath) { Set-Result 'Bavarian was not found. Download it from its website (button in step 2), then try again.' 'warn'; return }
    try { Start-Process -FilePath $script:BavPath -WorkingDirectory (Split-Path -Parent $script:BavPath) | Out-Null }
    catch { Set-Result ("Could not start Bavarian: {0}" -f $_.Exception.Message) 'bad'; return }
    $script:OnSshUp = $OnUp
    $script:SshWaitUntil = (Get-Date).AddMinutes(4)
    Set-Result 'Bavarian is starting. In its window click "Enable SSH". This wizard continues by itself as soon as SSH is on...' 'info'
    $SshTimer.Start()
}
$SshTimer.Add_Tick({
    try {
        if (Test-Port22) {
            $SshTimer.Stop()
            Set-Result "$Tick SSH is on ($HuIp). You can close Bavarian." 'ok'
            $cb = $script:OnSshUp; $script:OnSshUp = $null
            if ($cb) { & $cb }
            Update-Nav
        } elseif ((Get-Date) -gt $script:SshWaitUntil) {
            $SshTimer.Stop()
            Set-Result 'SSH did not come up within 4 minutes. In Bavarian, click "Enable SSH" (leave the IP blank), check the ENET cable, then try again.' 'warn'
        }
    } catch { $SshTimer.Stop(); Show-Error $_ }
})

function Read-CarStatus([string]$t) {
    $c = @{
        Ok           = ($t -match 'Head-unit state:')
        Swapped      = ($t -match 'mm-ipod\.real\s+: present')
        Staged       = ($t -match 'aa-cp: present')
        TestLink     = ($t -match 'RAM test link\s+: ACTIVE')
        DiskMode     = 'none'
        NewWatchdog  = ($t -match 'NEW watchdog')
        WrapperInUse = ($t -match 'a wrapper chain is in use')
        AadRunning   = ($t -match 'NBT-AAD \(/opt/aa\) is running')
    }
    $m = [regex]::Match($t, 'disk mode: (\S+)')
    if ($m.Success) { $c.DiskMode = $m.Groups[1].Value }
    return $c
}

function Get-StopLines([string]$t) {
    return @(($t -split "`r?`n") | Where-Object { $_ -match '\[STOP\]' } | ForEach-Object { ($_ -replace '^\s*\[STOP\]\s*', '').Trim() })
}

# ------------------------------------------------------------------------------------------------------------
# Window
# ------------------------------------------------------------------------------------------------------------
$Form = New-Object System.Windows.Forms.Form
$Form.Text = 'CarPlay HUD Wizard - Google Maps arrows on your BMW head-up display'
if ($Demo) { $Form.Text += '   [DEMO - not connected to a car]' }
$Form.ClientSize = New-Object System.Drawing.Size(1000, 720)
$Form.MinimumSize = New-Object System.Drawing.Size(900, 680)
$Form.StartPosition = 'CenterScreen'
$Form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)

$Steps = New-Object System.Windows.Forms.ListBox
$Steps.Location = New-Object System.Drawing.Point(10, 10)
$Steps.Size = New-Object System.Drawing.Size(235, 650)
$Steps.Anchor = 'Top,Bottom,Left'
$Steps.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$Steps.IntegralHeight = $false
$Steps.SelectionMode = 'None'
$Form.Controls.Add($Steps)

$Title = New-Object System.Windows.Forms.Label
$Title.Location = New-Object System.Drawing.Point(258, 10)
$Title.Size = New-Object System.Drawing.Size(730, 34)
$Title.Anchor = 'Top,Left,Right'
$Title.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$Form.Controls.Add($Title)

$Body = New-Object System.Windows.Forms.TextBox
$Body.Location = New-Object System.Drawing.Point(258, 48)
$Body.Size = New-Object System.Drawing.Size(730, 250)
$Body.Anchor = 'Top,Left,Right'
$Body.Multiline = $true
$Body.ReadOnly = $true
$Body.ScrollBars = 'Vertical'
$Body.BorderStyle = 'None'
$Body.BackColor = $Form.BackColor
$Body.Font = New-Object System.Drawing.Font('Segoe UI', 10.5)
$Body.TabStop = $false
$Form.Controls.Add($Body)

$Actions = New-Object System.Windows.Forms.FlowLayoutPanel
$Actions.Location = New-Object System.Drawing.Point(258, 302)
$Actions.Size = New-Object System.Drawing.Size(730, 160)
$Actions.Anchor = 'Top,Left,Right'
$Actions.AutoScroll = $true
$Actions.WrapContents = $true
$Form.Controls.Add($Actions)

$Result = New-Object System.Windows.Forms.Label
$Result.Location = New-Object System.Drawing.Point(258, 466)
$Result.Size = New-Object System.Drawing.Size(730, 56)
$Result.Anchor = 'Top,Left,Right'
$Result.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$Form.Controls.Add($Result)

$OutLabel = New-Object System.Windows.Forms.Label
$OutLabel.Location = New-Object System.Drawing.Point(258, 524)
$OutLabel.Size = New-Object System.Drawing.Size(730, 18)
$OutLabel.Anchor = 'Top,Left,Right'
$OutLabel.Text = 'Technical details (what the wizard checks on the car):'
$OutLabel.ForeColor = [System.Drawing.Color]::DimGray
$Form.Controls.Add($OutLabel)

$Output = New-Object System.Windows.Forms.TextBox
$Output.Location = New-Object System.Drawing.Point(258, 544)
$Output.Size = New-Object System.Drawing.Size(730, 120)
$Output.Anchor = 'Top,Bottom,Left,Right'
$Output.Multiline = $true
$Output.ReadOnly = $true
$Output.ScrollBars = 'Both'
$Output.WordWrap = $false
$Output.Font = New-Object System.Drawing.Font('Consolas', 9)
$Form.Controls.Add($Output)

$BackBtn = New-Object System.Windows.Forms.Button
$BackBtn.Text = '< Back'
$BackBtn.Location = New-Object System.Drawing.Point(258, 676)
$BackBtn.Size = New-Object System.Drawing.Size(100, 32)
$BackBtn.Anchor = 'Bottom,Left'
$Form.Controls.Add($BackBtn)

$NextBtn = New-Object System.Windows.Forms.Button
$NextBtn.Text = 'Next >'
$NextBtn.Location = New-Object System.Drawing.Point(366, 676)
$NextBtn.Size = New-Object System.Drawing.Size(100, 32)
$NextBtn.Anchor = 'Bottom,Left'
$Form.Controls.Add($NextBtn)

$StatusLbl = New-Object System.Windows.Forms.Label
$StatusLbl.Location = New-Object System.Drawing.Point(478, 683)
$StatusLbl.Size = New-Object System.Drawing.Size(390, 22)
$StatusLbl.Anchor = 'Bottom,Left,Right'
$StatusLbl.ForeColor = [System.Drawing.Color]::DimGray
$Form.Controls.Add($StatusLbl)

$ToolsBtn = New-Object System.Windows.Forms.Button
$ToolsBtn.Text = 'Tools / Undo'
$ToolsBtn.Location = New-Object System.Drawing.Point(878, 676)
$ToolsBtn.Size = New-Object System.Drawing.Size(110, 32)
$ToolsBtn.Anchor = 'Bottom,Right'
$Form.Controls.Add($ToolsBtn)

$Timer = New-Object System.Windows.Forms.Timer
$Timer.Interval = 400

# ------------------------------------------------------------------------------------------------------------
# UI helpers
# ------------------------------------------------------------------------------------------------------------
function Show-Error($err) {
    [void][System.Windows.Forms.MessageBox]::Show($Form, ("Something went wrong in the wizard:`r`n`r`n{0}" -f $err), 'CarPlay HUD Wizard', 'OK', 'Error')
}
function Add-Output([string]$t) {
    $Output.AppendText(($t -replace "`r?`n", "`r`n"))
    if (-not $t.EndsWith("`n")) { $Output.AppendText("`r`n") }
}
function Set-Result([string]$t, [string]$kind = 'info') {
    $Result.Text = $t
    switch ($kind) {
        'ok'   { $Result.ForeColor = [System.Drawing.Color]::ForestGreen }
        'bad'  { $Result.ForeColor = [System.Drawing.Color]::Firebrick }
        'warn' { $Result.ForeColor = [System.Drawing.Color]::DarkOrange }
        default { $Result.ForeColor = [System.Drawing.Color]::MidnightBlue }
    }
}
function Add-Action([string]$text, [scriptblock]$onClick, [int]$width = 340) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Size = New-Object System.Drawing.Size($width, 36)
    $b.Tag = $onClick
    $b.Add_Click({ param($s, $e) try { & $s.Tag } catch { Show-Error $_ } })
    $Actions.Controls.Add($b)
    return $b
}
function Add-Check([string]$text, [string]$key) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text
    $c.AutoSize = $true
    $c.Tag = $key
    $c.Checked = [bool]$script:Flags[$key]
    $c.Add_CheckedChanged({ param($s, $e) $script:Flags[[string]$s.Tag] = $s.Checked; Update-Nav })
    $Actions.Controls.Add($c)
    $Actions.SetFlowBreak($c, $true)
    return $c
}
function Add-Break {
    $l = New-Object System.Windows.Forms.Label
    $l.Size = New-Object System.Drawing.Size(1, 4)
    $Actions.Controls.Add($l)
    $Actions.SetFlowBreak($l, $true)
}
function Set-Busy([bool]$b) {
    $script:Busy = $b
    $Actions.Enabled = -not $b
    $ToolsBtn.Enabled = -not $b
    if ($b) {
        $Form.Cursor = [System.Windows.Forms.Cursors]::AppStarting
        if ($script:UseConsole) { $StatusLbl.Text = 'Working... type the password in the black window when it asks.' }
        else { $StatusLbl.Text = 'Working... talking to the head unit. Stuck over a minute? Open the PowerShell window in the taskbar.' }
    } else {
        $Form.Cursor = [System.Windows.Forms.Cursors]::Default
        $StatusLbl.Text = ''
    }
    Update-Nav
}

# Typed confirmation for every change to the iDrive.
function Confirm-IDrive([string]$title, [string[]]$lines) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $title
    $f.ClientSize = New-Object System.Drawing.Size(640, 400)
    $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.Font = $Form.Font
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point(12, 12)
    $t.Size = New-Object System.Drawing.Size(616, 250)
    $t.Multiline = $true
    $t.ReadOnly = $true
    $t.ScrollBars = 'Vertical'
    $t.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $t.Text = "THIS CHANGES YOUR iDRIVE HEAD UNIT:`r`n`r`n" + ((@($lines) | ForEach-Object { '- ' + $_ }) -join "`r`n") +
        "`r`n`r`nCar parked in P, parking brake on, engine running (or a battery charger connected), ENET cable plugged in."
    $f.Controls.Add($t)
    $l = New-Object System.Windows.Forms.Label
    $l.Location = New-Object System.Drawing.Point(12, 272)
    $l.Size = New-Object System.Drawing.Size(616, 22)
    $l.Text = "To allow this change, type  $ConfirmWord  (capital letters) and click the button:"
    $f.Controls.Add($l)
    $in = New-Object System.Windows.Forms.TextBox
    $in.Location = New-Object System.Drawing.Point(12, 298)
    $in.Size = New-Object System.Drawing.Size(250, 26)
    $f.Controls.Add($in)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Change my iDrive'
    $ok.Location = New-Object System.Drawing.Point(12, 345)
    $ok.Size = New-Object System.Drawing.Size(180, 36)
    $ok.Enabled = $false
    $ok.DialogResult = 'OK'
    $f.Controls.Add($ok)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point(204, 345)
    $cancel.Size = New-Object System.Drawing.Size(120, 36)
    $cancel.DialogResult = 'Cancel'
    $f.Controls.Add($cancel)
    $f.CancelButton = $cancel
    $in.Tag = $ok
    $in.Add_TextChanged({ param($s, $e) $s.Tag.Enabled = ($s.Text -ceq $script:ConfirmWord) })
    $r = $f.ShowDialog($Form)
    $f.Dispose()
    return ($r -eq [System.Windows.Forms.DialogResult]::OK)
}

function Ask-YesNo([string]$q) {
    return ([System.Windows.Forms.MessageBox]::Show($Form, $q, 'CarPlay HUD Wizard', 'YesNo', 'Question') -eq 'Yes')
}

# ------------------------------------------------------------------------------------------------------------
# Running one engine step
# ------------------------------------------------------------------------------------------------------------
function Get-DemoRun([string]$action, [string]$mode, [string]$answer) {
    $res = @()
    $text = "[demo] cphud.ps1 $action $mode".Trim()
    switch ($action) {
        'status' {
            $text += "`r`nHead-unit state:`r`n  mm-ipod.real      : " + $(if ($script:Flags['SwapOk']) { 'present (launcher swapped on disk)' } else { 'absent' })
            $text += "`r`n  RAM test link     : none`r`n  /fs/sda0/opt/aa-cp: " + $(if ($script:Flags['StageOk']) { 'present' } else { 'absent' })
            $text += '; disk mode: ' + $(if ($script:Flags['OnOk']) { 'active' } else { 'off' })
            if ($script:Flags['SwapOk']) { $text += "`r`n  [ok]   a wrapper chain is in use" }
        }
        'preflight' { $res = @('state=stock stop=0 warn=1'); $text += "`r`n  [ok]   PRE-FLIGHT PASSED" }
        'log' {
            if ($answer -eq 'n') { $res = @('user-reported problem') }
            elseif ($script:LastTry -eq 'dryrun' -and -not $script:Flags['DryOk']) { $res = @('dryrun PASS') }
            else { $res = @('active PASS (arrows seen)') }
        }
        default { $res = @('PASS') }
    }
    return [pscustomobject]@{ Action = "$action $mode".Trim(); ExitCode = 0; Text = $text; Results = $res; LoginFailed = $false }
}

function Start-Engine {
    param([string]$Action, [string]$Mode = '', [switch]$Confirmed, [string]$Answer = '', [scriptblock]$OnDone)
    if ($script:Busy) { return }
    $script:RunAction = ("$Action $Mode").Trim()
    Add-Output ("`r`n=== {0}   {1} ===" -f $script:RunAction, (Get-Date -Format 'HH:mm:ss'))
    if ($Demo) {
        $res = Get-DemoRun $Action $Mode $Answer
        Add-Output $res.Text
        if ($OnDone) { & $OnDone $res }
        Update-Steps
        Update-Nav
        return
    }
    if (-not $script:Pwsh) { Set-Result 'PowerShell 7 is missing on this laptop - see step 2.' 'bad'; return }
    if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null }
    $script:LogPath = Join-Path $WorkDir ('run-{0}-{1}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ($Action -replace '[^a-z-]', ''))
    $script:LogPos = 0
    $script:HistBefore = @(Get-History).Count
    $script:OnDone = $OnDone
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Q $Engine), $Action)
    if ($Mode) { $argv += $Mode }
    $argv += @('-Wizard', '-OutLog', (Q $script:LogPath), '-BackupRoot', (Q $BackupRoot))
    if ($Confirmed) { $argv += @('-Confirm', (Q $ConfirmWord)) }
    if ($Answer) { $argv += @('-Answer', $Answer) }
    $useAsk = (-not $script:UseConsole) -and $script:AskPass -and $script:Pw
    try {
        if ($useAsk) {
            # Only the engine started below (and the ssh it runs) inherits these; they are removed again right away.
            $env:SSH_ASKPASS = $script:AskPass
            $env:SSH_ASKPASS_REQUIRE = 'force'
            $env:CPHUD_PW = Get-PlainPw
            $style = 'Minimized'     # not hidden: if ssh ever asks anyway, you can open it from the taskbar and type
        } else {
            $style = 'Normal'
        }
        $script:Proc = Start-Process -FilePath $script:Pwsh -ArgumentList ($argv -join ' ') -WindowStyle $style -PassThru
        $null = $script:Proc.Handle
    } finally {
        Remove-Item Env:CPHUD_PW -ErrorAction SilentlyContinue
        Remove-Item Env:SSH_ASKPASS -ErrorAction SilentlyContinue
        Remove-Item Env:SSH_ASKPASS_REQUIRE -ErrorAction SilentlyContinue
    }
    Set-Busy $true
    $Timer.Start()
}

function Read-NewLog {
    if (-not $script:LogPath -or -not (Test-Path -LiteralPath $script:LogPath)) { return }
    $fs = [IO.File]::Open($script:LogPath, 'Open', 'Read', 'ReadWrite')
    try {
        if ($fs.Length -gt $script:LogPos) {
            [void]$fs.Seek($script:LogPos, 'Begin')
            $buf = New-Object byte[] ([int]($fs.Length - $script:LogPos))
            $n = $fs.Read($buf, 0, $buf.Length)
            $script:LogPos += $n
            if ($n -gt 0) { Add-Output ([Text.Encoding]::UTF8.GetString($buf, 0, $n)) }
        }
    } finally { $fs.Close() }
}

$Timer.Add_Tick({
    try {
        Read-NewLog
        if ($script:Proc -and $script:Proc.HasExited) {
            $Timer.Stop()
            Read-NewLog
            $text = ''
            if ($script:LogPath -and (Test-Path -LiteralPath $script:LogPath)) { $text = [IO.File]::ReadAllText($script:LogPath) }
            $res = [pscustomobject]@{
                Action      = $script:RunAction
                ExitCode    = $script:Proc.ExitCode
                Text        = $text
                Results     = @(Get-NewResults $script:HistBefore)
                LoginFailed = ($text -match 'could not connect/log in \(exit 255\)')
            }
            $script:Proc = $null
            Set-Busy $false
            $cb = $script:OnDone
            $script:OnDone = $null
            if ($res.LoginFailed) {
                $msg = 'The head unit refused the login. Check: SSH enabled in Bavarian (it switches off at every iDrive restart), ENET cable, and the password.'
                if (-not $script:UseConsole) { $msg += ' If the password is surely right: Tools / Undo > "Type the password in a window instead".' }
                Set-Result $msg 'bad'
            } elseif ($cb) {
                & $cb $res
            }
            Update-Steps
            Update-Nav
        }
    } catch { $Timer.Stop(); Set-Busy $false; Show-Error $_ }
})

function Test-Result($res, [string]$pattern) {
    foreach ($r in @($res.Results)) { if ($r -match $pattern) { return $true } }
    return $false
}

# ------------------------------------------------------------------------------------------------------------
# The steps
# ------------------------------------------------------------------------------------------------------------
$Pages = @(
    @{  Title = 'Welcome'
        Text = @(
            'This wizard shows Google Maps turn arrows from Apple CarPlay on your BMW''s own head-up display and instrument cluster.',
            'It uses the open-source bridge by ftojke (BMW-iDrive6-CarPlay-HUD) and works in small steps, each one checked:',
            '',
            '  1. Check your car - changes nothing. It stops if your iDrive''s files don''t exactly match versions known to work.',
            '  2. Copy test files into a new folder - nothing existing is changed.',
            '  3. Two tests that run from memory only - restarting the iDrive undoes them.',
            '  4. Only after you have seen the arrows: install permanently. One click undoes it.',
            '',
            'Tested on: BMW X3 G01 (NBT EVO ID6, software Y24073J) and 5 Series G30 (Y21432J, by the bridge author).',
            'It needs CarPlay to be wireless, an NBT EVO head unit, and a factory head-up display or digital cluster.',
            '',
            'Not made, approved or supported by BMW. You use it at your own risk. Keep the car parked during every step.')
        Build = { Add-Check 'I understand: this changes software in my car''s iDrive, at my own risk, and I keep the car parked.' 'understand' | Out-Null }
        Done = { [bool]$script:Flags['understand'] } }

    @{  Title = 'Get ready'
        Text = @(
            'You need: a Windows laptop, an ENET (OBD-to-Ethernet) cable, an iPhone with wireless CarPlay and Google Maps,',
            'the free Bavarian SSH client to switch on SSH, and your head unit''s root password.',
            '',
            'Plan 30-45 minutes. The steps restart CarPlay a few times; the iDrive keeps working throughout.',
            '',
            'Tick each item when it is true:')
        Build = {
            Add-Check 'Car in P, parking brake on, outdoors or in a well-ventilated place' 'rd_park' | Out-Null
            Add-Check 'Engine running, or a battery charger connected' 'rd_power' | Out-Null
            Add-Check 'ENET cable plugged into the car''s OBD port and this laptop' 'rd_enet' | Out-Null
            Add-Check 'iDrive fully started, and the iPhone connected to wireless CarPlay' 'rd_idrive' | Out-Null
            if (-not $script:BavSearched -and -not $Demo) { $script:BavPath = Find-Bavarian; $script:BavSearched = $true }
            if (-not $script:BavPath) { Add-Check 'I will start the Bavarian SSH client myself (not found on this laptop)' 'rd_bav' | Out-Null }
            Add-Break
            Add-Action 'Open the Bavarian website' { Start-Process $BavarianUrl } 240 | Out-Null
            Add-Action 'Find Bavarian on this laptop...' { $p = Select-Bavarian; if ($p) { $script:BavPath = $p; Show-Page $script:Page } } 260 | Out-Null
            if (-not $script:Pwsh) { Add-Action 'Get PowerShell 7 (free, from Microsoft)' { Start-Process $PwshUrl } 300 | Out-Null }
            if (-not (Test-Path -LiteralPath $SshExe)) { Add-Action 'Add the Windows OpenSSH Client' { Start-Process 'ms-settings:optionalfeatures' } 300 | Out-Null }
            Add-Action 'Check this laptop again' { $script:Pwsh = Find-Pwsh; Show-Page $script:Page } 240 | Out-Null
            $msg = @()
            if ($script:Pwsh) { $msg += "$Tick PowerShell 7 found" } else { $msg += 'PowerShell 7 is missing: install it, then click "Check this laptop again".' }
            if (Test-Path -LiteralPath $SshExe) { $msg += "$Tick Windows OpenSSH Client found" } else { $msg += 'Windows OpenSSH Client is missing: Settings > System > Optional features > Add "OpenSSH Client".' }
            if ($script:BavPath) { $msg += "$Tick Bavarian found (the wizard starts it for you)" } elseif (-not $Demo) { $msg += 'Bavarian not found: download it, or tick the box if you start it yourself.' }
            $kind = 'ok'; if (-not $script:Pwsh -or -not (Test-Path -LiteralPath $SshExe)) { $kind = 'bad' }
            Set-Result ($msg -join '     ') $kind
        }
        Done = {
            $all = $true
            foreach ($k in 'rd_park', 'rd_power', 'rd_enet', 'rd_idrive') { if (-not $script:Flags[$k]) { $all = $false } }
            $bav = $Demo -or [bool]$script:BavPath -or [bool]$script:Flags['rd_bav']
            $all -and $bav -and [bool]$script:Pwsh -and (Test-Path -LiteralPath $SshExe)
        } }

    @{  Title = 'Connect'
        Text = @(
            '1. Click "Start Bavarian and wait for SSH". In the Bavarian window click "Enable SSH" (leave the IP empty).',
            '   Bavarian only opens SSH until the iDrive restarts; nothing is stored in the car. This wizard notices by itself',
            '   when SSH is on (you can also click "Check connection").',
            '2. Type the head unit''s root password and click "Sign in". The wizard keeps it in memory only, while this window is open,',
            '   and never writes it anywhere. Signing in only reads the car''s state.')
        Build = {
            Add-Action 'Start Bavarian and wait for SSH' { Start-BavarianAndWait { if ($script:PwBox) { [void]$script:PwBox.Focus() } } } 280 | Out-Null
            Add-Action 'Check connection' {
                if ($Demo -or (Test-Port22)) { Set-Result "$Tick The head unit answers on SSH ($HuIp)." 'ok' }
                else { Set-Result "No answer from $HuIp. Is SSH enabled in Bavarian? Is the ENET cable plugged in and the iDrive fully started?" 'bad' }
            } 200 | Out-Null
            Add-Break
            $l = New-Object System.Windows.Forms.Label
            $l.Text = 'Root password:'
            $l.AutoSize = $true
            $l.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
            $Actions.Controls.Add($l)
            $script:PwBox = New-Object System.Windows.Forms.TextBox
            $script:PwBox.UseSystemPasswordChar = $true
            $script:PwBox.Width = 220
            $Actions.Controls.Add($script:PwBox)
            Add-Action 'Sign in (reads only)' {
                if (-not $script:UseConsole -and -not $Demo) {
                    if (-not $script:PwBox.Text) { Set-Result 'Type the password first.' 'warn'; return }
                    $script:Pw = ConvertTo-SecureString $script:PwBox.Text -AsPlainText -Force
                    $script:PwBox.Text = ''
                    if (-not $script:AskPass) { $script:AskPass = Initialize-AskPass }
                    if (-not $script:AskPass) {
                        $script:UseConsole = $true
                        Set-Result 'The password helper could not be prepared on this PC, so a black window will ask for the password at each step.' 'warn'
                    }
                }
                Start-Engine -Action 'status' -OnDone {
                    param($res)
                    $script:Car = Read-CarStatus $res.Text
                    if (-not $script:Car.Ok) { Set-Result 'Could not read the car''s state - see the technical details below.' 'bad'; return }
                    $script:SignedIn = $true
                    $st = Read-State
                    $script:Flags['StageOk'] = (Get-StateFlag 'stageVerified') -and $script:Car.Staged
                    $script:Flags['DryOk'] = (Get-StateFlag 'dryrunVerified') -and $script:Car.Staged
                    $script:Flags['ActiveOk'] = (Get-StateFlag 'activeWorked') -and $script:Car.Staged
                    $script:Flags['SwapOk'] = $script:Car.Swapped
                    $script:Flags['SwapChecked'] = $script:Car.Swapped
                    $script:Flags['OnOk'] = $script:Car.Swapped -and ($script:Car.DiskMode -eq 'active')
                    $script:Flags['ActiveLogOk'] = $script:Flags['OnOk']
                    if ($script:Car.Swapped -and $script:Car.DiskMode -eq 'active') {
                        Set-Result "$Tick Signed in. The bridge is already installed and switched on. Use Next to run the final check, or Tools / Undo." 'ok'
                    } elseif ($script:Car.Swapped) {
                        Set-Result "$Tick Signed in. The bridge is installed but switched off. Continue at ""Switch on""." 'ok'
                    } elseif ($script:Car.TestLink) {
                        Set-Result "$Tick Signed in. A test from earlier is still running in memory. Continue where you left off, or restart the iDrive to clear it." 'ok'
                    } else {
                        Set-Result "$Tick Signed in. Your car is ready for the check. Click Next." 'ok'
                    }
                }
            } 200 | Out-Null
        }
        Done = { $script:SignedIn } }

    @{  Title = 'Check the car'
        Text = @(
            'Reads your iDrive''s CarPlay files and compares them byte-for-byte with versions known to work.',
            'It also copies them to this laptop as your backup (Documents\BMW-CarPlay-HUD-backups - keep that folder private:',
            'it contains your CarPlay Wi-Fi password and the head unit''s serial number).',
            '',
            'This step changes nothing in the car. Keep CarPlay connected while it runs (about a minute).')
        Build = {
            Add-Action 'Run the check (changes nothing)' {
                Start-Engine -Action 'preflight' -OnDone {
                    param($res)
                    if (Test-Result $res 'stop=0') {
                        $script:Flags['PreflightOk'] = $true
                        Set-Result "$Tick Check passed. Your files match a known-good version and your backup is saved. Click Next." 'ok'
                    } else {
                        $s = Get-StopLines $res.Text
                        $first = 'see the technical details below'
                        if ($s.Count -gt 0) { $first = $s[0] }
                        Set-Result ("Stopped - nothing was changed. Reason: {0}" -f $first) 'bad'
                    }
                }
            } | Out-Null
        }
        Done = { [bool]$script:Flags['PreflightOk'] -or [bool]$script:Flags['SwapOk'] } }

    @{  Title = 'Copy test files'
        Text = @(
            'Adds ONE new folder to the iDrive: /fs/sda0/opt/aa-cp. It holds the bridge, two small starter scripts,',
            'a copy of your own CarPlay program, and a switch file set to OFF.',
            '',
            'Nothing that already exists is changed, and CarPlay keeps working exactly as before.',
            'Then the files are tested on the car and read back byte-for-byte.',
            '',
            'Undo: Tools / Undo > Remove everything.')
        Build = {
            Add-Action 'Copy the test files' {
                $ok = Confirm-IDrive 'Copy test files' @(
                    'Creates the new folder /fs/sda0/opt/aa-cp: the bridge (libnbt_carplay_hud.so), two starter scripts, a copy of your stock mm-ipod, and mode = off.',
                    'Does not touch mm-ipod, iap2_Wifi.cfg or any other CarPlay or iDrive file.',
                    'The storage is writable for a few seconds, then read-only again. No restart needed.',
                    'Undo at any time: Tools / Undo > Remove everything.')
                if (-not $ok) { Set-Result 'Cancelled. Nothing was changed.' 'info'; return }
                Start-Engine -Action 'stage' -Confirmed -OnDone {
                    param($res)
                    if (Test-Result $res '^PASS$') { $script:Flags['StageOk'] = $true; Set-Result 'Test files copied and verified. Now test: play music over CarPlay for a moment, then answer below.' 'info'; Show-Page $script:Page }
                    else { Set-Result 'This step did not pass. CarPlay files were not touched. See the details below; Tools / Undo > Remove everything removes the folder.' 'bad' }
                }
            } | Out-Null
            if ($script:Flags['StageOk'] -and -not $script:Flags['StageChecked'] -and -not $script:Flags['SwapOk']) {
                Add-Break
                Add-Action 'CarPlay still works normally' { $script:Flags['StageChecked'] = $true; Set-Result "$Tick Good - CarPlay is still 100% original. Click Next." 'ok'; Update-Steps; Update-Nav } 300 | Out-Null
                Add-Action 'Something is wrong' { Set-Result 'This step changes no CarPlay file, so restart the iDrive (hold the volume knob ~30 s) and check again. If it persists: Tools / Undo > Remove everything.' 'bad' } 220 | Out-Null
            }
        }
        Done = { ([bool]$script:Flags['StageOk'] -and [bool]$script:Flags['StageChecked']) -or [bool]$script:Flags['SwapOk'] } }

    @{  Title = 'Test 1: watch only'
        Text = @(
            'Runs the bridge in WATCH-ONLY mode, from memory only: it listens to CarPlay and sends nothing anywhere.',
            'No file is changed. Restarting the iDrive (hold the volume knob ~30 s) removes the test completely.',
            '',
            'After you click Start:',
            '  1. On the iPhone, turn Wi-Fi off, wait 15 seconds, turn it on again. Wait until CarPlay is back.',
            '  2. Use CarPlay for 2-3 minutes: play music, make a short call, start a Google Maps route.',
            '  3. Answer the question below.')
        Build = {
            Add-Action 'Start test 1 (watch only)' {
                $ok = Confirm-IDrive 'Test 1: watch only' @(
                    'Memory only: writes "dryrun" to /dev/shmem/cphud.mode and adds a temporary link so CarPlay starts through the test starter.',
                    'No file on the iDrive is changed. Restarting the iDrive removes the link and the mode.')
                if (-not $ok) { Set-Result 'Cancelled. Nothing was changed.' 'info'; return }
                $script:LastTry = 'dryrun'
                Start-Engine -Action 'try' -Mode 'dryrun' -Confirmed -OnDone {
                    param($res)
                    if (Test-Result $res '^PASS$') { $script:Flags['DryStarted'] = $true; Set-Result 'Test 1 is on. Reconnect CarPlay (iPhone Wi-Fi off 15 s, then on), use it 2-3 minutes, then answer below.' 'info'; Show-Page $script:Page }
                    else { Set-Result 'Test 1 could not start - nothing was changed. See the details below.' 'bad' }
                }
            } | Out-Null
            if ($script:Flags['DryStarted']) {
                Add-Break
                Add-Action 'YES - CarPlay, music and calls worked normally' {
                    Start-Engine -Action 'log' -Answer 'y' -OnDone {
                        param($res)
                        if (Test-Result $res '^dryrun PASS') { $script:Flags['DryOk'] = $true; Set-Result "$Tick Test 1 passed: the bridge works on your car without disturbing anything. Click Next." 'ok' }
                        elseif ($res.Text -match 'no hook log') { Set-Result 'No test data yet: CarPlay has not reconnected since the test started. Turn the iPhone''s Wi-Fi off 15 s and on, wait, then answer again.' 'warn' }
                        else { Set-Result 'Test 1 found a problem - restart the iDrive (hold the volume knob ~30 s) to remove the test. See the details below.' 'bad' }
                    }
                } 420 | Out-Null
                Add-Action 'NO - something did not work' {
                    Start-Engine -Action 'log' -Answer 'n' -OnDone { param($res) Set-Result 'Stop here: restart the iDrive (hold the volume knob ~30 s). That removes the test and everything is original again.' 'bad' }
                } 300 | Out-Null
            }
        }
        Done = { [bool]$script:Flags['DryOk'] -or [bool]$script:Flags['SwapOk'] } }

    @{  Title = 'Test 2: arrows on the HUD'
        Text = @(
            'Now the bridge is LIVE, still from memory only: Google Maps directions go to your head-up display and cluster.',
            'Restarting the iDrive removes the test completely.',
            '',
            'After you click Start:',
            '  1. Turn the iPhone''s Wi-Fi off for 15 seconds, then on again. Wait until CarPlay is back.',
            '  2. Start a Google Maps route WHILE PARKED. Do not start a BMW navigation route at the same time.',
            '  3. Look at the head-up display and the cluster, then answer below.')
        Build = {
            Add-Action 'Start test 2 (live)' {
                $ok = Confirm-IDrive 'Test 2: live' @(
                    'Memory only: writes "active" to /dev/shmem/cphud.mode. CarPlay keeps starting through the test starter.',
                    'The bridge declares route guidance to the iPhone and sends turn arrows to the instrument cluster / head-up display.',
                    'No file on the iDrive is changed. Restarting the iDrive removes the test.')
                if (-not $ok) { Set-Result 'Cancelled. Nothing was changed.' 'info'; return }
                $script:LastTry = 'active'
                Start-Engine -Action 'try' -Mode 'active' -Confirmed -OnDone {
                    param($res)
                    if (Test-Result $res '^PASS$') { $script:Flags['ActStarted'] = $true; Set-Result 'Test 2 is on. Reconnect CarPlay, start a Google Maps route while parked, look at the HUD, then answer below.' 'info'; Show-Page $script:Page }
                    else { Set-Result 'Test 2 could not start. See the details below.' 'bad' }
                }
            } | Out-Null
            if ($script:Flags['ActStarted']) {
                Add-Break
                Add-Action 'YES - I saw the arrow and distance on the HUD' {
                    Start-Engine -Action 'log' -Answer 'y' -OnDone {
                        param($res)
                        if (Test-Result $res '^active PASS') { $script:Flags['ActiveOk'] = $true; Set-Result "$Tick Test 2 passed: arrows on your HUD. Click Next." 'ok' }
                        elseif ($res.Text -match 'no hook log') { Set-Result 'No test data yet: reconnect CarPlay (Wi-Fi off 15 s, on), start a route, then answer again.' 'warn' }
                        else { Set-Result 'The car did not report guidance yet. Keep the route running a minute and answer again; if it keeps failing, restart the iDrive.' 'warn' }
                    }
                } 420 | Out-Null
                Add-Action 'NO - no arrows' {
                    Start-Engine -Action 'log' -Answer 'n' -OnDone { param($res) Set-Result 'Then this car is not supported yet. Restart the iDrive (hold the volume knob ~30 s) to remove the test, and please report it (see README).' 'bad' }
                } 220 | Out-Null
            }
        }
        Done = { [bool]$script:Flags['ActiveOk'] -or [bool]$script:Flags['SwapOk'] } }

    @{  Title = 'Restart the iDrive'
        Text = @(
            'This removes the test, so the permanent install starts from a clean, original state.',
            '',
            '  1. Hold the iDrive volume knob for about 30 seconds until the screen goes dark and the iDrive restarts.',
            '  2. Wait until it has fully started and CarPlay is back.',
            '  3. Click "Start Bavarian and wait for SSH" and click "Enable SSH" in Bavarian (a restart always switches SSH off).',
            '     The wizard then checks by itself that the test is gone (reads only).',
            '  4. Answer the question that appears.')
        Build = {
            $check = {
                Start-Engine -Action 'status' -OnDone {
                    param($res)
                    $script:Car = Read-CarStatus $res.Text
                    if (-not $script:Car.Ok) { Set-Result 'Could not read the car''s state - see the details below.' 'bad'; return }
                    if ($script:Car.TestLink) { Set-Result 'The test is still active, so the iDrive has not restarted yet. Hold the volume knob ~30 s, wait, enable SSH again, then check again.' 'warn'; return }
                    if ($script:Car.NewWatchdog) { Set-Result 'The iDrive reported a new reset (watchdog). Stop here and report it; Tools / Undo > Remove everything takes the test files away.' 'bad'; return }
                    $script:Flags['RestartSeen'] = $true
                    Set-Result 'The test is gone and SSH works after the restart. Now test: answer below.' 'info'
                    Show-Page $script:Page
                }
            }
            $script:RestartCheck = $check
            Add-Action 'Start Bavarian and wait for SSH' { Start-BavarianAndWait { & $script:RestartCheck } } 280 | Out-Null
            Add-Action 'Check the test is gone (reads only)' { & $script:RestartCheck } | Out-Null
            if ($script:Flags['RestartSeen'] -and -not $script:Flags['RestartOk']) {
                Add-Break
                Add-Action 'YES - CarPlay reconnected by itself after the restart' { $script:Flags['RestartOk'] = $true; Set-Result "$Tick Clean restart, CarPlay normal, SSH works. Click Next." 'ok'; Update-Steps; Update-Nav } 420 | Out-Null
                Add-Action 'NO - CarPlay did not come back' { Set-Result 'Wait one more minute and reconnect on the iPhone (Settings > General > CarPlay). If it still fails: Tools / Undo > Remove everything, then restart the iDrive.' 'bad' } 300 | Out-Null
            }
        }
        Done = { [bool]$script:Flags['RestartOk'] -or [bool]$script:Flags['SwapOk'] } }

    @{  Title = 'Install permanently'
        Text = @(
            'Makes the bridge survive restarts. Your CarPlay program is kept byte-for-byte as mm-ipod.real, and a small starter',
            'takes its place. The bridge stays OFF in this step, so CarPlay should behave exactly as before.',
            'If any check fails, the step puts everything back by itself.',
            '',
            'FIRST: switch CarPlay off on the iPhone (or turn its Wi-Fi off). Then click Install.',
            'Afterwards: turn CarPlay back on and check music and a call.')
        Build = {
            Add-Action 'Install permanently' {
                $ok = Confirm-IDrive 'Install permanently' @(
                    'Renames /fs/sda0/opt/conn/bin/carplay/mm-ipod to mm-ipod.real (your original, kept byte-for-byte).',
                    'Puts the starter script in its place (atomic rename, so CarPlay''s program is never missing).',
                    'Sets the switch to OFF: the starter just runs your original CarPlay program.',
                    'Checks itself on the car; on any doubt it restores the original on the spot.',
                    'Undo at any time: Tools / Undo > Remove everything.')
                if (-not $ok) { Set-Result 'Cancelled. Nothing was changed.' 'info'; return }
                Start-Engine -Action 'swap' -Confirmed -OnDone {
                    param($res)
                    if (Test-Result $res '^PASS$') { $script:Flags['SwapOk'] = $true; Set-Result 'Installed, bridge OFF. Turn CarPlay back on, play music and make a short call, then answer below.' 'info'; Show-Page $script:Page }
                    else { Set-Result 'Install did not complete and was reverted. See the details below; Tools / Undo > Check status shows the state.' 'bad' }
                }
            } | Out-Null
            if ($script:Flags['SwapOk'] -and -not $script:Flags['SwapChecked']) {
                Add-Break
                Add-Action 'Everything works normally' {
                    Start-Engine -Action 'status' -OnDone {
                        param($res)
                        $script:Car = Read-CarStatus $res.Text
                        if ($script:Car.Ok -and $script:Car.Swapped -and -not $script:Car.NewWatchdog) {
                            $script:Flags['SwapChecked'] = $true
                            $w = ''; if (-not $script:Car.WrapperInUse) { $w = ' (CarPlay was not connected while checking - that is fine.)' }
                            Set-Result ("$Tick Installed and CarPlay is normal. Click Next to switch the bridge on.{0}" -f $w) 'ok'
                        } else { Set-Result 'Something looks wrong - see the details. Tools / Undo > Remove everything puts the original back.' 'bad' }
                    }
                } 300 | Out-Null
                Add-Action 'Something is wrong' {
                    Set-Result 'Use Tools / Undo > Remove everything (SSH is still on). It puts your original CarPlay program back.' 'bad'
                } 220 | Out-Null
            }
        }
        Done = { [bool]$script:Flags['SwapChecked'] } }

    @{  Title = 'Switch on'
        Text = @(
            'Switches the bridge ON permanently: from now on every CarPlay connection sends Google Maps arrows to your HUD.',
            '',
            'After you click Switch on:',
            '  1. Turn the iPhone''s Wi-Fi off for 15 seconds, then on. Wait until CarPlay is back.',
            '  2. Start a Google Maps route while parked and look at the HUD.',
            '  3. Answer below.')
        Build = {
            Add-Action 'Switch the bridge on' {
                $ok = Confirm-IDrive 'Switch on' @(
                    'Writes "active" to /fs/sda0/opt/aa-cp/mode. Nothing else.',
                    'From the next CarPlay connection, and after every restart, the bridge sends turn arrows to the HUD.',
                    'Undo: Tools / Undo > Turn the bridge off (or Remove everything).')
                if (-not $ok) { Set-Result 'Cancelled. Nothing was changed.' 'info'; return }
                Start-Engine -Action 'mode' -Mode 'active' -Confirmed -OnDone {
                    param($res)
                    if (Test-Result $res '^PASS$') { $script:Flags['OnOk'] = $true; Set-Result 'Switched on. Reconnect CarPlay, start a route while parked, then answer below.' 'info'; Show-Page $script:Page }
                    else { Set-Result 'Could not switch on - see the details below.' 'bad' }
                }
            } | Out-Null
            if ($script:Flags['OnOk'] -and -not $script:Flags['ActiveLogOk']) {
                Add-Break
                Add-Action 'YES - arrows on the HUD' {
                    Start-Engine -Action 'log' -Answer 'y' -OnDone {
                        param($res)
                        if (Test-Result $res '^active PASS') { $script:Flags['ActiveLogOk'] = $true; Set-Result "$Tick Working. Click Next for the final restart test." 'ok' }
                        elseif ($res.Text -match 'no hook log') { Set-Result 'No data yet: reconnect CarPlay (Wi-Fi off 15 s, on), start a route, then answer again.' 'warn' }
                        else { Set-Result 'The car did not report guidance yet. Keep the route running a minute, then answer again.' 'warn' }
                    }
                } 300 | Out-Null
                Add-Action 'NO arrows' {
                    Start-Engine -Action 'log' -Answer 'n' -OnDone { param($res) Set-Result 'Use Tools / Undo > Turn the bridge off, and please report it (see README).' 'bad' }
                } 220 | Out-Null
            }
        }
        Done = { [bool]$script:Flags['ActiveLogOk'] } }

    @{  Title = 'Final check'
        Text = @(
            'Proves it survives a restart, and that you can still get in to undo it:',
            '',
            '  1. Hold the iDrive volume knob ~30 seconds to restart it. Wait until it has fully started and CarPlay is back.',
            '  2. Start a Google Maps route: the arrows should appear on the HUD without the laptop doing anything.',
            '  3. Click "Start Bavarian and wait for SSH" and click "Enable SSH" in Bavarian, then click the button below.')
        Build = {
            Add-Action 'Start Bavarian and wait for SSH' { Start-BavarianAndWait $null } 280 | Out-Null
            Add-Action 'Arrows came back - run the final check' {
                Start-Engine -Action 'status' -OnDone {
                    param($res)
                    $script:Car = Read-CarStatus $res.Text
                    if ($script:Car.Ok -and $script:Car.Swapped -and $script:Car.DiskMode -eq 'active' -and -not $script:Car.NewWatchdog) {
                        $script:Flags['FinalOk'] = $true
                        Set-Result "$Tick All done: installed, switched on, survives restarts, and SSH still works for undo. Click Next." 'ok'
                    } elseif ($script:Car.NewWatchdog) { Set-Result 'The iDrive reported a new reset (watchdog). Turn the bridge off (Tools / Undo) and report it.' 'bad' }
                    else { Set-Result 'Not as expected - see the details below.' 'bad' }
                }
            } | Out-Null
            Add-Action 'No arrows after the restart' {
                Set-Result 'Run Tools / Undo > Check status. If it shows the bridge installed and on, reconnect CarPlay and try a route again; otherwise turn it off and report it.' 'warn'
            } 260 | Out-Null
        }
        Done = { [bool]$script:Flags['FinalOk'] } }

    @{  Title = 'Done - drive test'
        Text = @(
            'Unplug the ENET cable and put the laptop away before you drive.',
            '',
            'Drive test (daylight, a familiar 15-20 minute route with a few turns, a roundabout and a motorway exit):',
            '  - Set the Google Maps destination while parked. No BMW navigation route at the same time.',
            '  - Check: the arrow matches each turn, the distance counts down, a deliberate wrong turn reroutes,',
            '    the arrow clears when you arrive, music and calls still work, the iDrive stays responsive.',
            '',
            'If something misbehaves while driving: end the route in Google Maps. If needed, once safely stopped, turn the',
            'iPhone''s Wi-Fi off - that ends CarPlay, the only place the bridge runs. Restarting the iDrive does NOT turn it off.',
            '',
            'To turn it off for good: enable SSH in Bavarian, start this wizard, sign in, then Tools / Undo.',
            'Before a BMW dealer software update: Tools / Undo > Remove everything.')
        Build = { Add-Action 'Open my backups folder' { if (Test-Path -LiteralPath $BackupRoot) { Start-Process explorer.exe $BackupRoot } } 240 | Out-Null }
        Done = { $true } }
)

function Update-Steps {
    $Steps.BeginUpdate()
    $Steps.Items.Clear()
    for ($i = 0; $i -lt $Pages.Count; $i++) {
        $mark = '    '
        if ($i -eq $script:Page) { $mark = '>  ' }
        elseif ($i -lt $Pages.Count - 1 -and (& $Pages[$i].Done)) { $mark = "$Tick  " }
        [void]$Steps.Items.Add(("{0}{1}. {2}" -f $mark, ($i + 1), $Pages[$i].Title))
    }
    $Steps.EndUpdate()
}

function Update-Nav {
    $BackBtn.Enabled = (-not $script:Busy) -and ($script:Page -gt 0)
    $done = $false
    try { $done = [bool](& $Pages[$script:Page].Done) } catch { $done = $false }
    $NextBtn.Enabled = (-not $script:Busy) -and ($script:Page -lt $Pages.Count - 1) -and $done
}

function Show-Page([int]$i) {
    $script:Page = $i
    $p = $Pages[$i]
    $Title.Text = ('Step {0} of {1}: {2}' -f ($i + 1), $Pages.Count, $p.Title)
    $Body.Text = (@($p.Text) -join "`r`n")
    $Actions.SuspendLayout()
    $Actions.Controls.Clear()
    $keep = $Result.Text
    Set-Result '' 'info'
    if ($p.Build) { & $p.Build }
    if (-not $Result.Text -and $keep -and ($script:LastShown -eq $i)) { $Result.Text = $keep }
    $script:LastShown = $i
    $Actions.ResumeLayout()
    Update-Steps
    Update-Nav
}
$script:LastShown = -1

# ------------------------------------------------------------------------------------------------------------
# Tools / Undo
# ------------------------------------------------------------------------------------------------------------
$Menu = New-Object System.Windows.Forms.ContextMenuStrip
function Add-Menu([string]$text, [scriptblock]$action) {
    $it = $Menu.Items.Add($text)
    $it.Tag = $action
    $it.Add_Click({ param($s, $e) try { & $s.Tag } catch { Show-Error $_ } })
}
function Need-SignIn {
    if ($script:SignedIn -or $Demo) { return $true }
    Set-Result 'Sign in first (step 3: Connect).' 'warn'
    return $false
}
Add-Menu 'Check status (reads only)' {
    if (-not (Need-SignIn)) { return }
    Start-Engine -Action 'status' -OnDone {
        param($res)
        $script:Car = Read-CarStatus $res.Text
        $m = 'Original (not installed)'
        if ($script:Car.Swapped) { $m = 'Installed, bridge ' + $(if ($script:Car.DiskMode -eq 'active') { 'ON' } else { 'OFF' }) }
        elseif ($script:Car.Staged) { $m = 'Test files present, not installed' }
        if ($script:Car.TestLink) { $m += '; a memory-only test is running (a restart removes it)' }
        $k = 'ok'
        if ($script:Car.NewWatchdog) { $m += '; NEW iDrive reset reported - consider turning it off and reporting it'; $k = 'bad' }
        Set-Result ("Status: {0}" -f $m) $k
    }
}
Add-Menu 'Turn the bridge off (stays installed)' {
    if (-not (Need-SignIn)) { return }
    if (-not (Confirm-IDrive 'Turn the bridge off' @('Writes "off" to /fs/sda0/opt/aa-cp/mode. From the next CarPlay connection the original CarPlay program runs alone.', 'Turn it on again later with the Switch on step.'))) { return }
    Start-Engine -Action 'mode' -Mode 'off' -Confirmed -OnDone { param($res) if (Test-Result $res '^PASS$') { $script:Flags['OnOk'] = $false; $script:Flags['ActiveLogOk'] = $false; Set-Result "$Tick Bridge turned off. Reconnect CarPlay (or restart the iDrive) for it to take effect." 'ok' } else { Set-Result 'Could not turn it off - see the details.' 'bad' } }
}
Add-Menu 'Remove everything (back to original)' {
    if (-not (Need-SignIn)) { return }
    if (-not (Confirm-IDrive 'Remove everything' @('Removes any memory-only test link.', 'Puts your original CarPlay program back (mm-ipod.real -> mm-ipod) if it was installed.', 'Deletes the folder /fs/sda0/opt/aa-cp.', 'Restores iap2_Wifi.cfg from its .orig backup if one exists.', 'Then: restart the iDrive, enable SSH again, and use "Check files are original".'))) { return }
    Start-Engine -Action 'rollback' -Confirmed -OnDone {
        param($res)
        if (Test-Result $res '^PASS$') {
            foreach ($k in 'StageOk', 'StageChecked', 'DryOk', 'ActiveOk', 'SwapOk', 'SwapChecked', 'OnOk', 'ActiveLogOk', 'FinalOk', 'RestartOk', 'RestartSeen', 'DryStarted', 'ActStarted', 'PreflightOk') { $script:Flags[$k] = $false }
            Set-Result "$Tick Removed. Restart the iDrive, enable SSH again, then Tools / Undo > Check files are original." 'ok'
            Show-Page 3
        } else { Set-Result 'Removal was not complete - see the details. Do not restart repeatedly; see docs\TROUBLESHOOTING.md.' 'bad' }
    }
}
Add-Menu 'Check files are original (after removal)' {
    if (-not (Need-SignIn)) { return }
    Start-Engine -Action 'verify-stock' -OnDone { param($res) if (Test-Result $res '^PASS$') { Set-Result "$Tick Byte-for-byte original." 'ok' } else { Set-Result 'Not fully original - see the details and docs\TROUBLESHOOTING.md.' 'bad' } }
}
[void]$Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
Add-Menu 'Type the password in a window instead' {
    $script:UseConsole = $true
    Set-Result 'From now on a black window opens at each step and asks for the password there.' 'info'
}
Add-Menu 'Open my backups folder' { if (Test-Path -LiteralPath $BackupRoot) { Start-Process explorer.exe $BackupRoot } else { Set-Result 'No backups yet (they are made by "Check the car").' 'info' } }
Add-Menu 'Open the technical log of the last step' { if ($script:LogPath -and (Test-Path -LiteralPath $script:LogPath)) { Start-Process notepad.exe $script:LogPath } }

# ------------------------------------------------------------------------------------------------------------
# Wiring and start
# ------------------------------------------------------------------------------------------------------------
$BackBtn.Add_Click({ if ($script:Page -gt 0) { Show-Page ($script:Page - 1) } })
$NextBtn.Add_Click({ if ($script:Page -lt $Pages.Count - 1) { Show-Page ($script:Page + 1) } })
$ToolsBtn.Add_Click({ $Menu.Show($ToolsBtn, (New-Object System.Drawing.Point(0, $ToolsBtn.Height))) })
$Form.Add_FormClosing({
    param($s, $e)
    if ($script:Busy) {
        $a = [System.Windows.Forms.MessageBox]::Show($Form, 'A step is still running on the iDrive. Closing now could interrupt it. Wait until it finishes?', 'CarPlay HUD Wizard', 'YesNo', 'Warning')
        if ($a -eq 'Yes') { $e.Cancel = $true; return }
    }
    $SshTimer.Stop()
    if ($script:Pw) { $script:Pw.Dispose(); $script:Pw = $null }
})

function Invoke-SelfTest {
    $script:SelfErrors = New-Object System.Collections.ArrayList
    function Confirm-IDrive([string]$title, [string[]]$lines) { Write-Host "  confirm dialog: $title ($(@($lines).Count) lines)"; return $true }
    function Show-Error($err) { [void]$script:SelfErrors.Add([string]$err) }
    function Press([string]$like) {
        $b = @($Actions.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -like $like })
        if ($b.Count -ne 1) { [void]$script:SelfErrors.Add("page $($script:Page + 1): button '$like' found $($b.Count) times"); return }
        Write-Output "  press: $($b[0].Text)"
        & $b[0].Tag
    }
    function Tick-All { foreach ($c in @($Actions.Controls | Where-Object { $_ -is [System.Windows.Forms.CheckBox] })) { $c.Checked = $true } }
    $plan = @(
        @{ Steps = { Tick-All } },
        @{ Steps = { Tick-All } },
        @{ Steps = { Press 'Check connection'; Press 'Sign in*' } },
        @{ Steps = { Press 'Run the check*' } },
        @{ Steps = { Press 'Copy the test files'; Press 'CarPlay still works normally' } },
        @{ Steps = { Press 'Start test 1*'; Press 'YES*' } },
        @{ Steps = { Press 'Start test 2*'; Press 'YES*' } },
        @{ Steps = { Press 'Start Bavarian and wait for SSH'; Press 'YES - CarPlay reconnected*' } },
        @{ Steps = { Press 'Install permanently'; Press 'Everything works normally' } },
        @{ Steps = { Press 'Switch the bridge on'; Press 'YES*' } },
        @{ Steps = { Press 'Arrows came back*' } }
    )
    $fail = 0
    for ($i = 0; $i -lt $plan.Count; $i++) {
        Show-Page $i
        Write-Output ("Page {0}: {1}" -f ($i + 1), $Pages[$i].Title)
        & $plan[$i].Steps
        Write-Output ("  result: {0}" -f $Result.Text)
        if (-not $NextBtn.Enabled) { Write-Output '  FAIL: Next is not enabled'; $fail++ } else { Write-Output '  ok: Next enabled' }
    }
    Show-Page ($Pages.Count - 1)
    Write-Output ("Page {0}: {1}  (last page, Next disabled: {2})" -f $Pages.Count, $Pages[-1].Title, (-not $NextBtn.Enabled))
    foreach ($e in $script:SelfErrors) { Write-Output "  ERROR: $e"; $fail++ }
    $marks = @($Steps.Items | Where-Object { $_ -like "$Tick*" }).Count
    Write-Output ("Step list ticks: {0} of {1}" -f $marks, ($Pages.Count - 1))
    if ($marks -ne $Pages.Count - 1) { $fail++ }
    if ($fail -eq 0) { Write-Output 'SELFTEST PASS' } else { Write-Output "SELFTEST FAIL ($fail)" }
}

try {
    if (-not (Test-Path -LiteralPath $Engine)) { throw "cphud.ps1 not found next to the wizard ($Engine). Extract the whole download, then start Start-Wizard.cmd." }
    if ($SelfTest) { Invoke-SelfTest; return }
    Show-Page 0
    [void]$Form.ShowDialog()
} catch {
    Show-Error $_
} finally {
    $Timer.Stop()
    if ($script:Pw) { $script:Pw.Dispose() }
    $Form.Dispose()
}
