<#
    Cairns After Dark - the graphical launcher.

    A WinForms window over install.ps1. install.ps1 is the engine and is not
    modified by this file: nothing here downloads, hashes, moves, deletes or
    writes a shortcut. It starts install.ps1 and shows you what it is doing.

    Why a child process instead of dot-sourcing install.ps1 and calling its
    functions directly: install.ps1 downloads with a blocking call
    (Start-BitsTransfer, or WebClient.DownloadFile), and a WinForms window only
    repaints while its message loop is running. Called in-process, the window
    would freeze solid for the whole 181 MB fetch and there would be nothing to
    draw a progress bar from. Out of process the window stays live, which is
    the entire reason this file exists.

    The read-only half - Get-Manifest, Get-ManifestRepo,
    Test-ManifestMatchesFile, Get-RemoteManifest - *is* loaded in-process,
    below, because the status pane needs the pinned digest and the same hash
    comparison the installer uses, and duplicating either would be a second
    trust boundary.

    Why PowerShell and not Electron/Tauri/.NET: same argument as install.ps1.
    A window over a script that already ships must not add a runtime.

    Requires Windows PowerShell 5.1+ with WinForms, or PowerShell 7 on
    Windows. Started by CairnsAfterDark-GUI.bat, which passes -STA: WinForms
    needs a single-threaded apartment and PowerShell 7 defaults to MTA.

    The v0.1.1 layout ran on Windows once and surfaced three bugs (a VB6
    .Lines property that is not WinForms, a MessageBox type loaded after the
    handler that needed it, and a startup note claiming an install that did
    not exist). This dark layout is new code and has never been run anywhere.
    CAD_GUI_HEADLESS=1 exercises the wiring only - it exits before a single
    control is created, so the window itself is verified by nobody. See
    windows/README.md, "Runbook: the GUI", for what a human with a Windows
    box has to check.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# WinForms and Drawing are loaded FIRST, before anything that can fail.
# Stop-WithMessage below reports through a MessageBox, and a MessageBox needs
# this type. When the assembly load sat further down this file, every early
# failure - a missing install.ps1 being the common one - reached an error
# handler that could not itself report, hit a swallowed exception inside the
# handler, and exited with no window and no message.
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
} catch {
    Write-Host ("Cairns After Dark: WinForms is not available: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

# The engine. Byte for byte the same file the console entry point runs.
$InstallerPath = Join-Path $PSScriptRoot 'install.ps1'

function Stop-WithMessage ([string]$Message) {
    Write-Host ''
    Write-Host "Cairns After Dark: $Message" -ForegroundColor Red
    try {
        [void][System.Windows.Forms.MessageBox]::Show(
            $Message + "`r`n`r`nSee windows\README.md.", 'Cairns After Dark', 'OK', 'Error')
    } catch { }
    exit 1
}

# --------------------------------------------------------------------------
# Load install.ps1's functions without running any of them
# --------------------------------------------------------------------------
# Everything above install.ps1's "# Entry point" banner is configuration and
# function definitions; everything below it is the switch that does the work.
# Only the top half is evaluated, so importing this defines Invoke-Install and
# friends and calls none of them.
#
# install.ps1 locates its own manifest through $PSScriptRoot, which PowerShell
# leaves empty inside a scriptblock with no file behind it. The prologue puts it
# back, and has to go *after* the param() block, because a scriptblock cannot
# have a statement in front of one. The two files always ship in the same
# folder, so that folder is this one.
try {
    $EngineSource = Get-Content -LiteralPath $InstallerPath -Raw
    $EngineEntry  = $EngineSource.LastIndexOf('# Entry point')
    if ($EngineEntry -lt 0) {
        throw "install.ps1 has no '# Entry point' section, so this file cannot tell its functions from its entry point."
    }

    $EngineTokens = $null
    $EngineErrors = $null
    $EngineAst    = [System.Management.Automation.Language.Parser]::ParseInput(
                       $EngineSource, [ref]$EngineTokens, [ref]$EngineErrors)
    $EngineInsert = if ($EngineAst.ParamBlock) { $EngineAst.ParamBlock.Extent.EndOffset } else { 0 }
    $EngineHead   = $EngineSource.Substring(0, $EngineInsert) +
                    "`n`$PSScriptRoot = '$($PSScriptRoot.Replace("'", "''"))'" +
                    $EngineSource.Substring($EngineInsert, $EngineEntry - $EngineInsert)
    . ([scriptblock]::Create($EngineHead))
} catch {
    Stop-WithMessage ("Could not load install.ps1: " + $_.Exception.Message)
}

# --------------------------------------------------------------------------
# Headless self-check: the wiring above, with no window
# --------------------------------------------------------------------------
# CAD_GUI_HEADLESS=1 runs everything up to here and stops. It is how the
# launcher half of this file gets exercised on a machine with no Windows; the
# window below it has still never been run anywhere.
if ($env:CAD_GUI_HEADLESS -eq '1') {
    $Manifest = Get-Manifest
    $Repo     = Get-ManifestRepo $Manifest
    foreach ($fn in 'Get-Manifest', 'Get-ManifestRepo', 'Test-ManifestMatchesFile', 'Get-RemoteManifest') {
        if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
            Write-Host "SELFCHECK FAIL: install.ps1 did not define $fn"
            exit 1
        }
    }
    Write-Host "SELFCHECK manifest   $($Manifest.version) $($Manifest.tag) repo=$Repo"
    Write-Host "SELFCHECK digest     $([string]$Manifest.sha256)"
    Write-Host "SELFCHECK powershell $PowerShellExe"
    Write-Host "SELFCHECK installed  $(Test-ManifestMatchesFile -Manifest $Manifest -Path $GameExe)"
    Write-Host "SELFCHECK saves      $SaveDir"
    # Prove Install is wired to the real function: -WhatIf prints the plan and
    # stops before the download, the shortcuts and any file is written.
    $WhatIfOnly = $true
    Invoke-Install
    $WhatIfOnly = $false
    Write-Host 'SELFCHECK ok'
    exit 0
}

# --------------------------------------------------------------------------
# The window
# --------------------------------------------------------------------------
# WinForms and Drawing were loaded at the top of this file, ahead of the first
# thing that can fail. Visual styles still have to be switched on here, which
# is why this line is not simply folded into that load.
[System.Windows.Forms.Application]::EnableVisualStyles()

# The console is left minimised rather than hidden: the .bat starts this script
# with `start /min`, so the window a player would otherwise stare at is out of
# the way but still one click away if the launcher ever needs a word. Errors are
# reported in the log box and in a message box, because after the window is up
# the console is not looking at anything.

# Palette: night-city dark with one streetlight-amber accent. Every colour the
# window uses lives here - five values, not a theme engine.
$colBg      = [System.Drawing.Color]::FromArgb(13, 15, 19)
$colPanel   = [System.Drawing.Color]::FromArgb(27, 30, 37)
$colHover   = [System.Drawing.Color]::FromArgb(44, 48, 58)
$colText    = [System.Drawing.Color]::FromArgb(228, 231, 236)
$colMuted   = [System.Drawing.Color]::FromArgb(140, 147, 157)
$colAccent  = [System.Drawing.Color]::FromArgb(240, 166, 42)
$colLogBg   = [System.Drawing.Color]::FromArgb(9, 10, 13)
$colOnAmber = [System.Drawing.Color]::FromArgb(24, 18, 6)

$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Cairns After Dark'
$form.ClientSize      = New-Object System.Drawing.Size(560, 576)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false
$form.StartPosition   = 'CenterScreen'
$form.BackColor       = $colBg
$form.ForeColor       = $colText
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

# --------------------------------------------------------------------------
# Banner: a 560x150 bitmap drawn once - gradient sky, a building silhouette,
# a few lit windows, the amber line. Drawn rather than shipped because the
# bundle is two scripts and a manifest; there is no assets folder to put a
# picture in. A label set Transparent over a PictureBox-painted panel shows
# the bitmap through it - that is the whole trick.
# --------------------------------------------------------------------------
$banner = New-Object System.Windows.Forms.Panel
$banner.Location  = New-Object System.Drawing.Point(0, 0)
$banner.Size      = New-Object System.Drawing.Size(560, 150)
$banner.BackColor = [System.Drawing.Color]::FromArgb(16, 19, 26)

try {
    $bmp = New-Object System.Drawing.Bitmap(560, 150)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $rect = New-Object System.Drawing.Rectangle(0, 0, 560, 150)
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect,
        [System.Drawing.Color]::FromArgb(34, 42, 62),
        [System.Drawing.Color]::FromArgb(10, 11, 15),
        [System.Drawing.Drawing2D.LinearGradientMode]::BackwardDiagonal)
    $g.FillRectangle($grad, $rect)

    # The skyline: dark rectangles over the gradient, deterministic heights so
    # every player sees the same city. Lit windows only on some of them.
    $skyBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(7, 8, 11))
    $winBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(190, 240, 176, 70))
    $heights  = @(62, 88, 50, 104, 72, 58, 96, 44, 80, 66, 110, 54, 76, 92, 48, 70, 84, 60)
    $x = -10
    for ($i = 0; $i -lt $heights.Count; $i++) {
        $bw = 26 + (($i * 13) % 22)
        $bh = $heights[$i]
        $g.FillRectangle($skyBrush, $x, (150 - $bh), $bw, $bh)
        if ($i % 2 -eq 0) {
            for ($w = 0; $w -lt 3; $w++) {
                $wx = $x + 5 + (($i * 7 + $w * 9) % ($bw - 8))
                $wy = (150 - $bh) + 8 + (($i * 11 + $w * 17) % ($bh - 20))
                $g.FillRectangle($winBrush, $wx, $wy, 2, 3)
            }
        }
        $x += $bw + 5
    }
    $g.FillRectangle((New-Object System.Drawing.SolidBrush $colAccent), 0, 147, 560, 3)
    $banner.BackgroundImage = $bmp
    $g.Dispose(); $grad.Dispose(); $skyBrush.Dispose(); $winBrush.Dispose()
} catch {
    # The flat dark BackColor above is the whole fallback. A banner that
    # cannot paint must never be the reason the launcher does not open.
}

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text      = 'CAIRNS AFTER DARK'
$lblTitle.Font      = New-Object System.Drawing.Font('Segoe UI', 21, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $colText
$lblTitle.BackColor = [System.Drawing.Color]::Transparent
$lblTitle.Location  = New-Object System.Drawing.Point(22, 14)
$lblTitle.Size      = New-Object System.Drawing.Size(520, 40)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text      = 'UNDERGROUND STREET RACING - FAR NORTH QUEENSLAND'
$lblSub.Font      = New-Object System.Drawing.Font('Segoe UI', 8.25, [System.Drawing.FontStyle]::Bold)
$lblSub.ForeColor = $colAccent
$lblSub.BackColor = [System.Drawing.Color]::Transparent
$lblSub.Location  = New-Object System.Drawing.Point(24, 56)
$lblSub.Size      = New-Object System.Drawing.Size(520, 16)

# Four lines, filled in by Update-State: is it installed, which build is
# pinned, which digest, where the saves are. All of it is read out of the
# manifest and install.ps1's own functions - nothing is written down twice.
$lblState = New-Object System.Windows.Forms.Label
$lblState.Location  = New-Object System.Drawing.Point(24, 80)
$lblState.Size      = New-Object System.Drawing.Size(512, 62)
$lblState.Font      = New-Object System.Drawing.Font('Segoe UI', 8.25)
$lblState.ForeColor = $colMuted
$lblState.BackColor = [System.Drawing.Color]::Transparent
# A WinForms Label has no Lines property - that is VB6/ASP.NET. Multi-line text
# goes in Text, joined with newlines. Set-StrictMode turns the wrong one into a
# hard stop, which is how a never-executed script dies on its first line.
$lblState.Text      = 'Reading manifest...'
foreach ($c in $lblTitle, $lblSub, $lblState) { $banner.Controls.Add($c) }

# Status line, then the progress bar. The bar is two panels - a track and a
# fill whose width is the percentage - because the stock ProgressBar ignores
# ForeColor while visual styles are on, and turning them off un-themes every
# other control in the window.
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location  = New-Object System.Drawing.Point(24, 164)
$lblStatus.Size      = New-Object System.Drawing.Size(512, 18)
$lblStatus.ForeColor = $colMuted
$lblStatus.Text      = 'Ready.'

$barTrack = New-Object System.Windows.Forms.Panel
$barTrack.Location  = New-Object System.Drawing.Point(24, 188)
$barTrack.Size      = New-Object System.Drawing.Size(512, 6)
$barTrack.BackColor = $colPanel

$barFill = New-Object System.Windows.Forms.Panel
$barFill.Location  = New-Object System.Drawing.Point(0, 0)
$barFill.Size      = New-Object System.Drawing.Size(0, 6)
$barFill.BackColor = $colAccent
$barTrack.Controls.Add($barFill)

$log = New-Object System.Windows.Forms.TextBox
$log.Multiline   = $true
$log.ReadOnly    = $true
$log.ScrollBars  = 'Vertical'
$log.WordWrap    = $false
$log.Font        = New-Object System.Drawing.Font('Consolas', 8.25)
$log.BackColor   = $colLogBg
$log.ForeColor   = $colMuted
$log.BorderStyle = 'FixedSingle'
$log.Location    = New-Object System.Drawing.Point(24, 326)
$log.Size        = New-Object System.Drawing.Size(512, 212)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text      = 'Saves are kept in %APPDATA%\CairnsAfterDark, outside the install folder.'
$lblHint.Location  = New-Object System.Drawing.Point(24, 548)
$lblHint.Size      = New-Object System.Drawing.Size(512, 16)
$lblHint.ForeColor = $colMuted

$script:Buttons       = @()
$script:EngineProc    = $null
$script:Tails         = @()
$script:PartFiles     = @()
$script:Total         = 0
$script:RemoteNote    = 'Ready.'
$script:RemoteChecked = $false
# install.ps1 keeps its update-check failure reason in its OWN $script:
# RemoteFail - a dot-sourced [scriptblock]::Create does not bind $script: to
# this file's scope, so reading it unset here is a StrictMode hard stop, and
# inside a timer tick that surfaces as the WinForms unhandled-exception box.
# Declared here so the read is always safe; if the engine's copy never reaches
# this scope the fallback message below is shown instead of the detail.
$script:RemoteFail    = ''

function New-LauncherButton {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height = 34, [switch]$Primary)
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $Text
    $b.Location  = New-Object System.Drawing.Point($X, $Y)
    $b.Size      = New-Object System.Drawing.Size($Width, $Height)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    if ($Primary) {
        $b.BackColor = $colAccent
        $b.ForeColor = $colOnAmber
        $b.Font      = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
        $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(255, 184, 66)
    } else {
        $b.BackColor = $colPanel
        $b.ForeColor = $colText
        $b.FlatAppearance.MouseOverBackColor = $colHover
    }
    $script:Buttons += $b
    $form.Controls.Add($b)
    return $b
}

# One loud verb, four quiet ones - the way every launcher that is not a
# settings dialog does it. Play installs first when nothing is installed, so
# it is always the right button.
$btnPlay      = New-LauncherButton 'PLAY'    24  214 512 52 -Primary
$btnUpdate    = New-LauncherButton 'Update'  24  278 156
$btnInstall   = New-LauncherButton 'Repair'  188 278 96
$btnSaves     = New-LauncherButton 'Saves'   292 278 116
$btnUninstall = New-LauncherButton 'Uninstall' 416 278 120

foreach ($c in $banner, $lblStatus, $barTrack, $log, $lblHint) { $form.Controls.Add($c) }

# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

function Write-Log ([string]$Line) {
    $log.AppendText($Line + [System.Environment]::NewLine)
    $log.SelectionStart = $log.TextLength
    $log.ScrollToCaret()
}

function Show-Note ([string]$Text, [string]$Caption = 'Cairns After Dark') {
    $lblStatus.Text = $Text
    Write-Log ('== ' + $Text)
    [void][System.Windows.Forms.MessageBox]::Show(
        $Text, $Caption,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
}

function Ask-Yes ([string]$Text, [string]$Caption = 'Cairns After Dark') {
    return [System.Windows.Forms.MessageBox]::Show(
        $Text, $Caption,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning) -eq [System.Windows.Forms.DialogResult]::Yes
}

function New-TempPath ([string]$Suffix) {
    return (Join-Path ([System.IO.Path]::GetTempPath()) ('cad-gui-' + [System.IO.Path]::GetRandomFileName() + $Suffix))
}

function Set-EngineBusy ([string]$What) {
    foreach ($b in $script:Buttons) { $b.Enabled = $false }
    $barFill.Width = 0
    $lblStatus.Text = $What
    Write-Log ('== ' + $What)
    # Anything already sitting in TEMP is a leftover, not this run's download.
    $script:PartFiles = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) `
                             -Filter 'cad-*.part' -ErrorAction SilentlyContinue |
                         ForEach-Object { $_.FullName })
}

function Set-EngineIdle {
    foreach ($b in $script:Buttons) { $b.Enabled = $true }
}

# --------------------------------------------------------------------------
# Running install.ps1
# --------------------------------------------------------------------------
# The GUI's whole action surface. Each name is one of install.ps1's own
# [ValidateSet(...)] values on -Action, and install.ps1's switch at the bottom
# of that file turns each into exactly one function - Play is Invoke-Play,
# Install is Invoke-Install, Update is Invoke-Update, Uninstall is
# Invoke-Uninstall. There is no second implementation of any of them here to
# drift out of step, and Tools/verify_launcher.py checks that table both ways.
#
# -Visible is only ever used by Update, because install.ps1's update asks the
# player "Update now? [y/N]" with Read-Host, which needs a console somebody can
# answer. Every other action runs windowless with its output redirected, which
# is what keeps this window alive and the progress bar moving.
function Start-Engine {
    param([Parameter(Mandatory = $true)][string]$Action, [switch]$Visible)

    if ($null -ne $script:EngineProc) {
        Show-Note 'Wait for the current action to finish.'
        return
    }
    if (-not (Test-Path -LiteralPath $PowerShellExe)) {
        Show-Note "Cannot find PowerShell at $PowerShellExe."
        return
    }

    $script:Tails = @()
    $engineArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
                    '-File', ('"{0}"' -f $InstallerPath), '-Action', $Action)
    try {
        if ($Visible) {
            $proc = Start-Process -FilePath $PowerShellExe -ArgumentList $engineArgs -PassThru
        } else {
            $out = New-TempPath '.out'
            $err = New-TempPath '.err'
            $script:Tails = @(@{ Path = $out; Read = 0 }, @{ Path = $err; Read = 0 })
            $proc = Start-Process -FilePath $PowerShellExe -ArgumentList $engineArgs -PassThru `
                        -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError $err
        }
    } catch {
        Show-Note ('Could not start install.ps1: ' + $_.Exception.Message)
        return
    }

    # A Process from Start-Process -PassThru can come back without its handle
    # cached, and .HasExited then throws instead of answering once the engine is
    # gone - which would leave this window greyed out forever waiting for a
    # process it can no longer see. Touch the handle once, here.
    try { $null = $proc.Handle } catch { }

    $script:EngineProc = $proc
    Set-EngineBusy ('install.ps1 -Action ' + $Action + ' ...')
}

# install.ps1 is a separate process, so its console output has to be tailed in.
# Tailing its redirected file is the whole trick: no threads, no cross-thread
# control access, and the window's own timer keeps it flowing.
function Read-EngineOutput {
    $esc = [string][char]27
    foreach ($tail in $script:Tails) {
        if (-not (Test-Path -LiteralPath $tail.Path)) { continue }
        $text = Get-Content -LiteralPath $tail.Path -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrEmpty($text) -or $text.Length -le $tail.Read) { continue }
        # Redirection normally strips the colours, but a host that supports VT
        # still emits them, and escape codes in a text box are unreadable.
        $chunk = $text.Substring($tail.Read) -replace ($esc + '\[[0-9;]*[A-Za-z]'), ''
        $tail.Read = $text.Length
        foreach ($line in ($chunk -split "`r?`n")) {
            if ($line.Trim().Length -gt 0) { Write-Log $line.TrimEnd() }
        }
    }
}

# The download in flight. install.ps1 streams the payload to %TEMP%\cad-*.part
# and only moves it into place once the digest matches, so the newest partial
# file is the download and its length is the real progress. This is a file-size
# poll, not a second download mechanism: nothing here touches the network.
#
# ponytail: BITS can buffer before it flushes, so the bar may sit at 0% and then
# jump. The upgrade path is Start-BitsTransfer -Asynchronous reading
# BitsJob.Progress, which means changing install.ps1 - out of scope here.
function Get-DownloadInFlight {
    $newest = $null
    $temp = [System.IO.Path]::GetTempPath()
    foreach ($f in @(Get-ChildItem -LiteralPath $temp -Filter 'cad-*.part' -ErrorAction SilentlyContinue)) {
        if ($script:PartFiles -contains $f.FullName) { continue }
        if ($null -eq $newest -or $f.LastWriteTimeUtc -gt $newest.LastWriteTimeUtc) { $newest = $f }
    }
    return $newest
}

function Update-Progress {
    if ($script:Total -le 0) { return }
    $part = Get-DownloadInFlight
    if ($null -eq $part) { return }
    $pct = [int](100 * $part.Length / $script:Total)
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }
    $barFill.Width = [int]($barTrack.ClientSize.Width * $pct / 100)
    # The total is the size pinned in manifest.json. An update that ships a
    # different size saturates the bar early; install.ps1 verifies the digest
    # regardless, so this number is a progress hint and nothing more.
    $lblStatus.Text = ('downloading {0} of {1} MB ({2}%)' -f
                       [math]::Round($part.Length / 1MB, 1),
                       [math]::Round($script:Total / 1MB, 1),
                       $pct)
}

# --------------------------------------------------------------------------
# State
# --------------------------------------------------------------------------

# Everything shown about what is installed, and what the launcher would fetch,
# comes from the manifest and install.ps1's own functions.
function Update-State {
    try {
        $Manifest = Get-Manifest
    } catch {
        $lblState.Text = @('manifest.json could not be read:', $_.Exception.Message) -join [System.Environment]::NewLine
        return
    }
    $script:Total = [int64]$Manifest.size

    if (Test-ManifestMatchesFile -Manifest $Manifest -Path $GameExe) {
        $have = [string]$Manifest.version
        if (Test-Path -LiteralPath $VersionFile) {
            $have = ((Get-Content -LiteralPath $VersionFile -Raw) -replace '\s+', ' ').Trim()
        }
        $line = "Installed: $have  (sha256 verified)"
    } elseif (Test-Path -LiteralPath $GameExe) {
        $line = 'Installed, but NOT the pinned build. Press Install / Repair.'
    } else {
        $line = 'Not installed yet. Press Play or Install / Repair.'
    }
    $lblState.Text = @(
        $line,
        ('Pinned : {0} ({1})' -f $Manifest.version, $Manifest.tag),
        ('Digest : {0}...' -f ([string]$Manifest.sha256).Substring(0, 16)),
        ('Saves  : {0}' -f $SaveDir)
    ) -join [System.Environment]::NewLine
    if ($null -eq $script:EngineProc) { $lblStatus.Text = $script:RemoteNote }
}

# install.ps1's own remote check, used read-only to tell the player where they
# stand. The decision to *apply* an update is still Invoke-Update's; this only
# decides what the status line says.
function Update-RemoteNote {
    try {
        $Manifest = Get-Manifest
        $lblStatus.Text = 'Checking for updates...'
        [System.Windows.Forms.Application]::DoEvents()
        $remote = Get-RemoteManifest -Repo (Get-ManifestRepo $Manifest)
        if ($null -eq $remote) {
            # install.ps1's own words for what went wrong. "Could not reach
            # GitHub" is what a private repo looks like, and a player reading
            # that has no way to tell the two apart. The fallback is for the one
            # case that reaches no catch block at all.
            $script:RemoteNote = $script:RemoteFail
            if (-not $script:RemoteNote) {
                if (Test-ManifestMatchesFile -Manifest $Manifest -Path $GameExe) {
                    $script:RemoteNote = 'Could not reach GitHub - staying on the installed build.'
                } else {
                    $script:RemoteNote = 'Could not reach GitHub - cannot check for updates.'
                }
            }
        } else {
            switch (Get-UpdateVerdict -Local $Manifest -Remote $remote) {
                'current' { $script:RemoteNote = 'Up to date.' }
                'ahead'   { $script:RemoteNote = "Installed $($Manifest.version) is newer than main ($($remote.version))." }
                default   { $script:RemoteNote = "Version $($remote.version) is available." }
            }
        }
    } catch {
        # This runs from a timer tick, where an unhandled error would take the
        # window down rather than say anything useful.
        $script:RemoteNote = 'Could not check for updates: ' + $_.Exception.Message
    }
    if ($null -eq $script:EngineProc) { $lblStatus.Text = $script:RemoteNote }
}

# --------------------------------------------------------------------------
# The timer: tail the output, move the bar, notice when the engine is done
# --------------------------------------------------------------------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 200
$timer.Add_Tick({
    # Once, on the first tick after the window is up: Get-RemoteManifest can
    # take its full 8s timeout and there is no reason to stare at an empty box
    # while it does. Everything after that is the engine's own progress.
    if (-not $script:RemoteChecked) {
        $script:RemoteChecked = $true
        # Update-RemoteNote catches its own failures, but a throw out of a tick
        # handler becomes the WinForms unhandled-exception dialog, which is the
        # ugliest possible answer to "the update check failed". Belt on top of
        # the braces.
        try { Update-RemoteNote } catch { $lblStatus.Text = 'Could not check for updates.' }
        return
    }
    if ($null -eq $script:EngineProc) { return }

    try {
        Read-EngineOutput
        Update-Progress
        if (-not $script:EngineProc.HasExited) { return }
    } catch {
        # An exception here would leave every button greyed out with no way back
        # to them, so whatever went wrong gets reported and the window is
        # released. The engine may still be running; the next click restarts it.
        $script:EngineProc = $null
        $script:Tails = @()
        Set-EngineIdle
        Show-Note ('Lost track of install.ps1: ' + $_.Exception.Message)
        return
    }

    $code = $script:EngineProc.ExitCode
    $script:EngineProc = $null
    $script:Tails = @()
    Set-EngineIdle
    if ($code -eq 0) {
        Write-Log '== install.ps1 finished.'
        $lblStatus.Text = 'Done.'
    } else {
        # install.ps1 exits 1 and prints its own diagnosis; keep the number so a
        # bug report says something useful.
        Write-Log ('== install.ps1 exited with code ' + $code)
        $lblStatus.Text = "install.ps1 exited with code $code - see the log."
    }
    Update-State
})
$timer.Start()

# --------------------------------------------------------------------------
# The buttons
# --------------------------------------------------------------------------

# Nothing to confirm and nothing to choose: the plain launch, exactly what a
# double-click on the console .bat does.
$btnPlay.Add_Click({ Start-Engine 'Play' })

$btnInstall.Add_Click({ Start-Engine 'Install' })

$btnUpdate.Add_Click({
    if ($null -ne $script:EngineProc) { return }
    try {
        $Manifest = Get-Manifest
        $remote = Get-RemoteManifest -Repo (Get-ManifestRepo $Manifest)
    } catch {
        Show-Note ('Could not check for updates: ' + $_.Exception.Message)
        return
    }
    if ($null -eq $remote) {
        $why = $script:RemoteFail
        if (-not $why) { $why = 'GitHub did not return a manifest.' }
        Show-Note ($why + "`r`n`r`n" +
                   'A 404 from GitHub usually means the release repo is private. A public release' +
                   "`r`n" + 'needs no sign-in; a private one needs GITHUB_TOKEN set for this launcher.')
    } else {
        switch (Get-UpdateVerdict -Local $Manifest -Remote $remote) {
            'current' { Show-Note "You are up to date ($($Manifest.version))." }
            'ahead'   { Show-Note "Your build ($($Manifest.version)) is newer than main ($($remote.version)). Nothing to do." }
            default {
                $ans = Ask-Yes ("Cairns After Dark $($remote.version) is available.`r`n`r`n" +
                                "install.ps1 will open a window of its own to download and verify it,`r`n" +
                                "and will ask you to confirm before it changes anything. Continue?")
                if ($ans) { Start-Engine 'Update' -Visible }
            }
        }
    }
})

# The one destructive action. The confirmation is the GUI's job; the recursive
# delete and the "does this look like a game install folder" guard belong to
# install.ps1 and stay there. All this does is make the player say yes.
$btnUninstall.Add_Click({
    if ($null -ne $script:EngineProc) { return }
    $ans = Ask-Yes ("Remove Cairns After Dark?`r`n`r`n" +
                    "The game and its shortcuts are deleted.`r`n" +
                    "Your saves in`r`n$SaveDir`r`n" +
                    "are kept.", 'Uninstall Cairns After Dark')
    if ($ans) { Start-Engine 'Uninstall' }
})

# Saves live outside the install folder on purpose, which is exactly why a
# player cannot find them. This is the button that gives them back.
$btnSaves.Add_Click({
    if (-not (Test-Path -LiteralPath $SaveDir)) {
        New-Item -ItemType Directory -Path $SaveDir -Force | Out-Null
    }
    Invoke-Item -LiteralPath $SaveDir
})

# Closing the window mid-download would kill the engine halfway through a file
# it is about to move into place.
$form.Add_FormClosing({
    param($sender, $e)
    if ($null -ne $script:EngineProc) {
        $e.Cancel = $true
        [void][System.Windows.Forms.MessageBox]::Show(
            'Wait for the current action to finish before closing.',
            'Cairns After Dark',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information)
    }
})

# --------------------------------------------------------------------------
# Go
# --------------------------------------------------------------------------
Update-State
$form.ShowDialog()
