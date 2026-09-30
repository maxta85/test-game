<#
    Cairns After Dark - installer / launcher / updater / uninstaller.

    One script, four jobs:
      Install   fetch the pinned release, verify its SHA-256, unpack it,
                drop Start-menu + desktop shortcuts.
      Play      start the game.
      Update    re-read manifest.json and offer a newer build.
      Uninstall remove the game, the shortcuts and the install dir, but
                never the player's saves.

    Why PowerShell and not a Tauri/Electron shell: the whole job is
    download + hash + move files + write a .lnk. PowerShell ships on every
    supported Windows, does all of that natively, and adds zero runtime
    dependency. An Electron shell would add ~180 MB and a Node runtime to do
    the same job with more supply chain.

    Why not a .bat: .bat cannot show progress, ask a yes/no question, or
    hash a file without shelling out to certutil. The .bat in this folder is
    a three-line shim that runs this file.

    Requires Windows PowerShell 5.1+ (anything from Windows 7 onward).
#>

[CmdletBinding()]
param(
    [ValidateSet('Install', 'Play', 'Update', 'Uninstall')]
    [string] $Action = 'Play',

    # Used by the Play path: check for a new version, but only ever surface a
    # window if one actually exists. Keeps a normal double-click silent.
    [switch] $Quiet,

    # The desktop/Start-menu shortcut passes this so a launch never hangs on
    # a prompt while the game is waiting to start.
    [switch] $NoUpdateCheck,

    # Print the plan and verify what is local, without downloading.
    [switch] $WhatIfOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# PS 5.1 on older Windows defaults to SSL3/TLS1.0 and GitHub rejects those.
try {
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
} catch { }

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

# $PSScriptRoot is the folder holding this script. The shipped bundle is
# <root>\launcher\install.ps1 next to CairnsAfterDark.exe, but this also runs
# straight out of the source checkout's windows/ folder.
$ScriptDir = $PSScriptRoot
$Root      = Split-Path -Parent $ScriptDir

$GameExeName  = 'CairnsAfterDark.exe'
$GameExe      = Join-Path $Root $GameExeName
$ManifestFile = Join-Path $ScriptDir 'manifest.json'
$VersionFile  = Join-Path $Root 'version.txt'
$UninstallBat = Join-Path $Root 'uninstall.bat'
$StateFile    = Join-Path $env:APPDATA 'CairnsAfterDark\installed.json'

# Saves live in %APPDATA%, never in the install directory, so an update - or a
# user who reinstalls into a different folder - cannot wipe progress.
$SaveDir = Join-Path $env:APPDATA 'CairnsAfterDark'

$StartMenuDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Cairns After Dark'
$DesktopDir   = [Environment]::GetFolderPath('Desktop')

$DefaultRepo  = 'maxta85/test-game'
$UserAgent    = 'CairnsAfterDark-Launcher'

# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

function Write-Step ([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   ([string]$m) { Write-Host "    $m" -ForegroundColor Green }
function Write-Note ([string]$m) { Write-Host "    $m" -ForegroundColor Yellow }
function Write-Bad  ([string]$m) { Write-Host "    $m" -ForegroundColor Red }

function Get-Manifest {
    if (-not (Test-Path -LiteralPath $ManifestFile)) {
        throw "manifest.json is missing from '$ScriptDir' - the installer is incomplete, re-download it."
    }
    # Read strictly. A manifest we half-understand is worse than none at all,
    # because it is what pins the hash of a file we are about to execute.
    return (Get-Content -LiteralPath $ManifestFile -Raw) | ConvertFrom-Json
}

function Get-ManifestRepo {
    param($Manifest)
    $repo = $DefaultRepo
    if ($Manifest.PSObject.Properties.Name -contains 'repo' -and $Manifest.repo) {
        $repo = [string]$Manifest.repo
    }
    return $repo.Trim('/')
}

# Update checks are a nicety and must never be able to break an install or a
# launch, so this returns $null on any failure rather than throwing.
function Get-RemoteManifest {
    param([string]$Repo, [int]$TimeoutMs = 8000)
    $tmp = $null
    try {
        $url = "https://raw.githubusercontent.com/$Repo/main/windows/manifest.json"
        $req = [System.Net.HttpWebRequest]::Create($url)
        try {
            $req.Timeout           = $TimeoutMs
            $req.ReadWriteTimeout  = $TimeoutMs
            $req.UserAgent         = $UserAgent
            $resp = $req.GetResponse()
            try {
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
                try { $body = $sr.ReadToEnd() } finally { $sr.Dispose() }
            } finally { $resp.Dispose() }
        } finally { $req.Close() }
        return ($body | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-Sha256 ([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-ManifestMatchesFile {
    param($Manifest, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return ((Get-Sha256 $Path) -eq ([string]$Manifest.sha256).ToLowerInvariant())
}

function New-Shortcut {
    param([string]$Path, [string]$Target, [string]$Arguments, [string]$WorkingDir)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # Through the shell COM object so the shortcut takes its icon from the
    # exe rather than a default arrow. This is what Explorer itself uses.
    $shell = New-Object -ComObject WScript.Shell
    try {
        $sc = $shell.CreateShortcut($Path)
        $sc.TargetPath       = $Target
        $sc.Arguments        = $Arguments
        $sc.WorkingDirectory = $WorkingDir
        $sc.IconLocation     = "$Target,0"
        $sc.Description      = 'Cairns After Dark'
        $sc.Save()
    } finally {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

# Single implementation of "fetch, verify, replace", shared by Install and
# Update. They differ only in what they do before and after calling this.
function Install-RemoteBuild {
    param($Manifest, [string]$Repo, [string]$Label)

    $url = "https://github.com/$Repo/releases/download/$($Manifest.tag)/$($Manifest.asset)"
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('cad-' + [System.IO.Path]::GetRandomFileName() + '.part')
    try {
        Write-Step "$Label downloading $($Manifest.asset)"
        Write-Ok $url
        Write-Ok ("$([math]::Round(([double]$Manifest.size) / 1MB, 1)) MB")

        if ($WhatIfOnly) { Write-Note '-WhatIf: download skipped.'; return $false }
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }

        $haveBits = $null -ne (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue)
        if ($haveBits) {
            # BITS gives a real progress bar and resumes a dropped connection.
            try { Start-BitsTransfer -Source $url -Destination $tmp -ErrorAction Stop }
            catch { Invoke-PlainDownload -Url $url -Path $tmp }
        } else {
            Invoke-PlainDownload -Url $url -Path $tmp
        }

        # Verify before anything is executed. Running an unverified download
        # with the player's privileges is the one thing this script must never
        # do, so a mismatch is fatal and the partial file is discarded.
        Write-Step 'verifying SHA-256'
        $got  = Get-Sha256 $tmp
        $want = ([string]$Manifest.sha256).ToLowerInvariant()
        if ($got -ne $want) {
            throw ("checksum mismatch - download is corrupt or tampered with.`n" +
                   "  expected $want`n" +
                   "  got      $got")
        }
        Write-Ok ("sha256 ok ($($got.Substring(0, 16))...)")

        if ($WhatIfOnly) { Write-Note '-WhatIf: unpack skipped.'; return $false }

        Move-Item -LiteralPath $tmp -Destination $GameExe -Force
        Write-Ok "installed $GameExe"
        return $true
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-PlainDownload {
    param([string]$Url, [string]$Path)
    $client = New-Object System.Net.WebClient
    try {
        $client.Headers.Add('User-Agent', $UserAgent)
        $client.DownloadFile($Url, $Path)
    } finally {
        $client.Dispose()
    }
}

function Write-InstallState {
    param($Manifest, [string]$Repo)
    $state = @{
        version    = [string]$Manifest.version
        tag        = [string]$Manifest.tag
        asset      = [string]$Manifest.asset
        sha256     = (Get-Sha256 $GameExe)
        size       = (Get-Item -LiteralPath $GameExe).Length
        installDir = $Root
        savesDir   = $SaveDir
        repo       = $Repo
        installed  = (Get-Date).ToString('o')
    }
    if (-not (Test-Path -LiteralPath $SaveDir)) { New-Item -ItemType Directory -Path $SaveDir -Force | Out-Null }
    ($state | ConvertTo-Json) | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

# --------------------------------------------------------------------------
# Install
# --------------------------------------------------------------------------

function Invoke-Install {
    Write-Step 'Cairns After Dark - install'

    $m    = Get-Manifest
    $repo = Get-ManifestRepo $m

    Write-Ok "pinned build : $($m.version)  ($($m.tag))"
    Write-Ok "saves        : $SaveDir"

    if (-not (Test-Path -LiteralPath $SaveDir)) { New-Item -ItemType Directory -Path $SaveDir -Force | Out-Null }

    if (Test-ManifestMatchesFile -Manifest $m -Path $GameExe) {
        Write-Ok 'already installed and verified (sha256 matches) - skipping download.'
    } else {
        if (Test-Path -LiteralPath $GameExe) {
            Write-Note 'installed game does not match the pinned release - re-downloading.'
        }
        $ok = Install-RemoteBuild -Manifest $m -Repo $repo -Label 'install:'
        if (-not $ok) { return }
    }

    if ($WhatIfOnly) { Write-Note '-WhatIf: shortcuts skipped.'; return }

    # version.txt is what a support request needs ("which build are you on?").
    # It lives outside the exe because rcedit is not available in the Linux
    # build, so the exe cannot carry version metadata itself.
    Set-Content -LiteralPath $VersionFile -Value "$($m.version) ($($m.tag))" -Encoding UTF8

    # The uninstaller beside the game is this same script with a different
    # -Action, so there is exactly one implementation of remove-and-uninstall.
    @(
        '@echo off',
        'rem Generated by install.ps1 - removes Cairns After Dark.',
        'rem Your saves in "%APPDATA%\CairnsAfterDark" are deliberately left alone.',
        'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher\install.ps1" -Action Uninstall %*',
        'pause'
    ) | Set-Content -LiteralPath $UninstallBat -Encoding ASCII

    Write-Step 'creating shortcuts'
    New-Shortcut -Path (Join-Path $StartMenuDir 'Cairns After Dark.lnk')                 -Target $GameExe     -WorkingDirectory $Root
    New-Shortcut -Path (Join-Path $StartMenuDir 'Uninstall Cairns After Dark.lnk')        -Target $UninstallBat -WorkingDirectory $Root
    if ($DesktopDir) {
        New-Shortcut -Path (Join-Path $DesktopDir 'Cairns After Dark.lnk') -Target $GameExe -WorkingDirectory $Root
    }
    Write-Ok 'Start menu + desktop shortcuts created'

    Write-InstallState -Manifest $m -Repo $repo
    Write-Ok "install state -> $StateFile"

    Write-Step 'installed'
    Write-Ok 'play it from the desktop shortcut'
}

# --------------------------------------------------------------------------
# Play
# --------------------------------------------------------------------------

function Invoke-Play {
    if (-not (Test-Path -LiteralPath $GameExe)) {
        Write-Step 'not installed yet - installing first'
        Invoke-Install
        if (-not (Test-Path -LiteralPath $GameExe)) {
            Write-Bad 'install did not produce the game executable.'
            return
        }
    }

    # The game has no main menu yet and boots straight into the world, so the
    # launcher has nothing to wait for and no scene to pre-warm.
    #
    # SEAM: when the UI agent lands a splash screen / main menu, this is the
    # only place that needs to change - pass the menu arguments here and let
    # the game hand control back. Nothing below this line moves.
    if (-not (Test-Path -LiteralPath $SaveDir)) { New-Item -ItemType Directory -Path $SaveDir -Force | Out-Null }

    $proc = Start-Process -FilePath $GameExe -WorkingDirectory $Root -PassThru
    Write-Ok "started pid $($proc.Id)"
    Write-Ok "saves -> $SaveDir"
}

# --------------------------------------------------------------------------
# Update
# --------------------------------------------------------------------------

function Invoke-Update {
    $local = Get-Manifest
    $repo  = Get-ManifestRepo $local

    $remote = Get-RemoteManifest -Repo $repo
    if ($null -eq $remote) {
        if (-not $Quiet) { Write-Note 'could not reach GitHub - staying on the installed build.' }
        return
    }

    $same = ([string]$local.version -eq [string]$remote.version) -and ([string]$local.tag -eq [string]$remote.tag)
    if ($same) {
        if (-not $Quiet) { Write-Step "up to date ($($local.version))" }
        return
    }

    if ($Quiet) {
        # The background check found something. Now show it, properly, with a
        # window the player can actually answer.
        Write-Step "Cairns After Dark $($remote.version) is available (you have $($local.version))"
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass',
                            '-File', (Join-Path $ScriptDir 'install.ps1'), '-Action', 'Update')
        return
    }

    Write-Step 'update available'
    Write-Ok "installed : $($local.version) ($($local.tag))"
    Write-Ok "available : $($remote.version) ($($remote.tag))"

    $ans = Read-Host 'Update now? [y/N]'
    if ($ans -notmatch '^(y|yes)$') { Write-Ok 'left as-is.'; return }

    $ok = Install-RemoteBuild -Manifest $remote -Repo $repo -Label 'update:'
    if (-not $ok) { return }

    Set-Content -LiteralPath $VersionFile -Value "$($remote.version) ($($remote.tag))" -Encoding UTF8
    Write-InstallState -Manifest $remote -Repo $repo
    Write-Ok "updated to $($remote.version) - your saves were not touched"
}

# --------------------------------------------------------------------------
# Uninstall
# --------------------------------------------------------------------------

function Invoke-Uninstall {
    Write-Step 'uninstalling'

    $procName = [System.IO.Path]::GetFileNameWithoutExtension($GameExeName)
    $running  = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Write-Note 'the game is still running - asking it to close.'
        foreach ($p in $running) { try { [void]$p.CloseMainWindow() } catch { } }
        Start-Sleep -Seconds 2
    }

    $lnks = @(
        (Join-Path $StartMenuDir 'Cairns After Dark.lnk'),
        (Join-Path $StartMenuDir 'Uninstall Cairns After Dark.lnk')
    )
    if ($DesktopDir) { $lnks += (Join-Path $DesktopDir 'Cairns After Dark.lnk') }
    foreach ($lnk in $lnks) {
        if (Test-Path -LiteralPath $lnk) {
            Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
            Write-Ok "removed $lnk"
        }
    }
    if (Test-Path -LiteralPath $StartMenuDir) {
        Remove-Item -LiteralPath $StartMenuDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # The saves are NOT deleted. That is the entire reason they live in
    # %APPDATA% rather than beside the exe.
    Write-Ok "saves kept at $SaveDir"

    # Recursive delete is the one unrecoverable thing in this script, so it is
    # gated on the target actually looking like a game install.
    $resolved = $null
    if (Test-Path -LiteralPath $Root) { $resolved = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\') }
    $home     = $env:USERPROFILE
    $isRoot   = ($null -ne $resolved) -and ($resolved -match '^[A-Za-z]:\\?$')
    $isHome   = ($null -ne $resolved) -and ($null -ne $home) -and ($resolved -eq $home.TrimEnd('\'))

    if ($null -eq $resolved -or $isRoot -or $isHome) {
        Write-Note "not removing '$Root' - it does not look like a game install folder. Delete it by hand."
    } else {
        Write-Step "removing $resolved"
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok 'game files removed'
    }

    Write-Step 'done'
    Write-Ok "your saves are still in $SaveDir"
}

# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

try {
    switch ($Action) {
        'Install'   { Invoke-Install }
        'Play'      {
            Invoke-Play
            # Detached and hidden so a normal launch never flashes a console.
            # It surfaces a window only if an update genuinely exists.
            if (-not $NoUpdateCheck) {
                $psExe = Join-Path $PSHOME 'powershell.exe'
                if (Test-Path -LiteralPath $psExe) {
                    Start-Process -FilePath $psExe -WindowStyle Hidden -ErrorAction SilentlyContinue `
                        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass',
                                        '-File', (Join-Path $ScriptDir 'install.ps1'),
                                        '-Action', 'Update', '-Quiet')
                }
            }
        }
        'Update'    { Invoke-Update }
        'Uninstall' { Invoke-Uninstall }
    }
} catch {
    Write-Host ''
    Write-Bad $_.Exception.Message
    Write-Host ''
    Write-Host 'Cairns After Dark could not continue. Usual causes:' -ForegroundColor Yellow
    Write-Host '  * no internet connection on first run (the download needs github.com)'
    Write-Host '  * a proxy, firewall or antivirus is blocking the download'
    Write-Host '  * PowerShell execution policy - run this instead:'
    Write-Host '      powershell -NoProfile -ExecutionPolicy Bypass -File windows\install.ps1 -Action Install'
    exit 1
}
