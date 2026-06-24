<#
  minerva-setup-windows.ps1 — Minerva (Sinai HPC) tooling for native Windows.

  *** UNTESTED DRAFT as of 2026-06-24. Mirrors the macOS/Linux installers'
      feature set, adapted to Windows (WinFsp + SSHFS-Win drive letters). It has
      NOT been run on a Windows machine or syntax-checked with PowerShell — treat
      it as a starting point and validate before relying on it. ***

  Mirrors the macOS/Linux installers where the platform allows:
    * settings saved to a JSON config and REUSED as defaults on re-run
    * an optional scratch "mount" (a second drive letter), remote derived as
      /sc/arion/scratch/<username>
    * minerva-mount / -clear / -status / -scratch, minerva-forget, minerva-uninstall
      written into your PowerShell profile (backed up first)

  Platform limits (see README.md): native Windows OpenSSH has no 8-hour
  ControlMaster window, sshpass-style password storage isn't used, and MFA
  handling through SSHFS-Win is the main open question. So there is no saved
  password here — each mount authenticates on its own.

  Usage:
    .\minerva-setup-windows.ps1                 # interactive (reuses saved values)
    .\minerva-setup-windows.ps1 -Defaults       # accept defaults (needs a username once)
    .\minerva-setup-windows.ps1 -WipeCredentials # remove saved settings
    .\minerva-setup-windows.ps1 -Uninstall      # remove profile block + config; dismount drives
#>
[CmdletBinding()]
param(
  [switch]$Defaults,
  [switch]$Uninstall,
  [switch]$WipeCredentials,
  [switch]$Purge,
  [switch]$Help
)

$ErrorActionPreference = 'Stop'
$Begin = '# >>> minerva-setup >>>'
$End   = '# <<< minerva-setup <<<'
$Stamp = Get-Date -Format 'yyyyMMddHHmmss'
$ConfigDir  = Join-Path $env:USERPROFILE '.config\minerva'
$ConfigPath = Join-Path $ConfigDir 'minerva.json'
$Host_       = 'minerva.hpc.mssm.edu'

function Write-Ok   { param($m) Write-Host "  [ok] $m"   -ForegroundColor Green }
function Write-Info { param($m) Write-Host "  $m" }
function Write-Warn { param($m) Write-Host "  ! $m"      -ForegroundColor Yellow }
function Die        { param($m) Write-Host "ERROR: $m"   -ForegroundColor Red; exit 1 }

# Ask "Prompt" "default" -> string. In -Defaults mode returns the default.
function Ask {
  param([string]$Prompt, [string]$Default = '')
  if ($Defaults) { return $Default }
  $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
  $r = Read-Host $label
  if ([string]::IsNullOrEmpty($r)) { return $Default } else { return $r }
}

# YesNo "Prompt [y/n]:" "Y"|"N" -> bool. Uniform [y/n] casing; the default decides Enter.
function YesNo {
  param([string]$Prompt, [string]$Default = 'Y')
  if ($Defaults) { return ($Default -match '^[Yy]$') }
  $r = Read-Host $Prompt
  if ([string]::IsNullOrEmpty($r)) { $r = $Default }
  return ($r -match '^[Yy]')
}

# Remove the marker-delimited block from a file (exact full-line match).
function Remove-Block {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return }
  $keep = @(); $skip = $false
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -eq $Begin) { $skip = $true; continue }
    if ($line -eq $End)   { $skip = $false; continue }
    if (-not $skip) { $keep += $line }
  }
  Set-Content -LiteralPath $Path -Value $keep
}

# Replace (or append) the managed block in a file.
function Write-Block {
  param([string]$Path, [string]$Content)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  if (Test-Path $Path) { Remove-Block -Path $Path }
  Add-Content -LiteralPath $Path -Value $Begin
  Add-Content -LiteralPath $Path -Value $Content
  Add-Content -LiteralPath $Path -Value $End
}

function Backup-Once {
  param([string]$Path)
  if (Test-Path $Path) {
    $b = "$Path.minerva-bak.$Stamp"
    if (-not (Test-Path $b)) { Copy-Item -LiteralPath $Path -Destination $b }
  }
}

function Load-PriorConfig {
  if (Test-Path $ConfigPath) {
    try { return Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json } catch { return $null }
  }
  return $null
}

if ($Help) {
  Get-Content -LiteralPath $PSCommandPath | Select-Object -First 30 | ForEach-Object { $_ -replace '^\s*#?\s?', '' }
  exit 0
}

$Profile_ = $PROFILE.CurrentUserAllHosts
$prior = Load-PriorConfig

# ----------------------------- forget / uninstall -----------------------------
if ($WipeCredentials) {
  Write-Host "Forget saved Minerva settings" -ForegroundColor Cyan
  Write-Warn "Windows stores no password (mounts authenticate on their own); this removes the saved JSON config."
  if (-not (YesNo "Remove saved settings? [y/n]:" "N")) { Die "Aborted." }
  if (Test-Path $ConfigPath) { Remove-Item -LiteralPath $ConfigPath -Force }
  Write-Ok "Removed saved settings ($ConfigPath)."
  exit 0
}

if ($Uninstall) {
  Write-Host "Uninstall Minerva tooling (Windows)" -ForegroundColor Cyan
  if (-not (YesNo "Remove the PowerShell profile block and saved config, and dismount drives? [y/n]:" "N")) { Die "Aborted." }
  # best-effort dismount of configured drives
  if ($prior) {
    foreach ($d in @($prior.Drive, $prior.ScratchDrive)) {
      if ($d) { cmd /c "net use $d /delete /y" 2>$null | Out-Null }
    }
  }
  Backup-Once $Profile_
  Remove-Block -Path $Profile_
  if (Test-Path $ConfigDir) { Remove-Item -LiteralPath $ConfigDir -Recurse -Force }
  Write-Ok "Removed profile block and config (profile backed up to *.minerva-bak.$Stamp)."
  if ($Purge) {
    if (YesNo "Also uninstall WinFsp + SSHFS-Win via winget? [y/n]:" "N") {
      winget uninstall -e --id SSHFS-Win.SSHFS-Win 2>$null
      winget uninstall -e --id WinFsp.WinFsp 2>$null
      Write-Ok "Removed WinFsp + SSHFS-Win (where present)."
    } else { Write-Info "Kept WinFsp + SSHFS-Win." }
  }
  Write-Info "Open a new PowerShell window for the change to take effect."
  exit 0
}

# ----------------------------------- install ----------------------------------
Write-Host "Minerva setup (Windows)" -ForegroundColor Cyan
if ($prior -and $prior.User) { Write-Ok "Found a previous setup for '$($prior.User)' — its values are the defaults below." }
Write-Host ""

# dependencies (informational — winget install needs the user to run it)
if (-not (Get-Command sshfs-win -ErrorAction SilentlyContinue) -and -not (Test-Path 'C:\Program Files\SSHFS-Win')) {
  Write-Warn "SSHFS-Win not detected. Install WinFsp + SSHFS-Win first:"
  Write-Info  "winget install -e --id WinFsp.WinFsp; winget install -e --id SSHFS-Win.SSHFS-Win"
}

$U = if ($prior) { [string]$prior.User } else { '' }
if ($U) {
  $MUSER = Ask "Sinai HPC username" $U
} elseif ($Defaults) {
  Die "No saved username to default to — run once interactively first."
} else {
  $MUSER = Read-Host "Sinai HPC username (e.g. smithj01)"
}
if (-not $MUSER) { Die "Username is required." }

$DriveDef   = if ($prior -and $prior.Drive) { [string]$prior.Drive } else { 'Z:' }
$RemoteDef  = if ($prior) { [string]$prior.RemotePath } else { '' }
$MDRIVE  = Ask "Drive letter for your primary mount (e.g. Z:)" $DriveDef
$MREMOTE = Ask "Remote path on Minerva (blank = home, e.g. /sc/arion/projects/<lab>/users/<you>)" $RemoteDef

# scratch (a second drive letter); remote derived from username
$ScratchDriveDef = if ($prior -and $prior.ScratchDrive) { [string]$prior.ScratchDrive } else { 'Y:' }
$priorHasScratch = ($prior -and $prior.ScratchDrive)
$scratchDefault  = if ((Test-Path $ConfigPath) -and -not $priorHasScratch) { 'N' } else { 'Y' }
$SDRIVE = ''; $SREMOTE = ''
Write-Host ""
Write-Host "Scratch mount (optional) — Minerva scratch is always /sc/arion/scratch/<username>." -ForegroundColor Cyan
if (YesNo "Also set up a scratch drive? [y/n]:" $scratchDefault) {
  $SDRIVE  = Ask "Drive letter for scratch (e.g. Y:)" $ScratchDriveDef
  $SREMOTE = "/sc/arion/scratch/$MUSER"
  Write-Info "scratch remote -> $SREMOTE"
}

Write-Host ""
Write-Host "About to apply:" -ForegroundColor Cyan
Write-Info "username:      $MUSER"
Write-Info "primary drive: $MDRIVE   (remote: $(if ($MREMOTE) { $MREMOTE } else { '<your Minerva home>' }))"
Write-Info "scratch drive: $(if ($SDRIVE) { "$SDRIVE   (remote: $SREMOTE)" } else { '<none>' })"
Write-Info "files touched: $ConfigPath ; PowerShell profile ($Profile_, backed up first)"
if (-not $Defaults) { if (-not (YesNo "Proceed? [y/n]:" "Y")) { Die "Aborted." } }

# ---- write JSON config ----
if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null }
$cfg = [ordered]@{
  User          = $MUSER
  Host          = $Host_
  Drive         = $MDRIVE
  RemotePath    = $MREMOTE
  ScratchDrive  = $SDRIVE
  ScratchRemote = $SREMOTE
}
($cfg | ConvertTo-Json) | Set-Content -LiteralPath $ConfigPath
Write-Ok "wrote $ConfigPath"

# ---- profile block (literal here-string; functions read the JSON at runtime) ----
$block = @'
# Minerva (Sinai HPC) — managed by minerva-setup-windows.ps1. Settings: ~/.config/minerva/minerva.json
function Get-MinervaConfig {
  $p = Join-Path $env:USERPROFILE '.config\minerva\minerva.json'
  if (Test-Path $p) { return Get-Content -LiteralPath $p -Raw | ConvertFrom-Json }
  return $null
}
function _Minerva-Unc {
  param($cfg, [string]$remote)
  $u = "\\sshfs\$($cfg.User)@$($cfg.Host)"
  if ($remote) { $u += ($remote -replace '/', '\') }
  return $u
}
function minerva-mount {
  $c = Get-MinervaConfig; if (-not $c) { Write-Host 'No Minerva config — run minerva-setup-windows.ps1.'; return }
  cmd /c "net use $($c.Drive) `"$(_Minerva-Unc $c $c.RemotePath)`""
  if ($c.ScratchDrive) { cmd /c "net use $($c.ScratchDrive) `"$(_Minerva-Unc $c $c.ScratchRemote)`"" }
}
function minerva-scratch {
  $c = Get-MinervaConfig; if (-not ($c -and $c.ScratchDrive)) { Write-Host 'No scratch drive configured — re-run setup.'; return }
  cmd /c "net use $($c.ScratchDrive) `"$(_Minerva-Unc $c $c.ScratchRemote)`""
}
function minerva-clear {
  $c = Get-MinervaConfig; if (-not $c) { return }
  cmd /c "net use $($c.Drive) /delete /y" 2>$null
  if ($c.ScratchDrive) { cmd /c "net use $($c.ScratchDrive) /delete /y" 2>$null }
}
function minerva-status { cmd /c 'net use' }
function minerva-forget {
  $p = Join-Path $env:USERPROFILE '.config\minerva\minerva.json'
  if (Test-Path $p) { Remove-Item -LiteralPath $p -Force; Write-Host 'Removed saved Minerva settings.' }
  else { Write-Host 'No saved settings.' }
}
function minerva-uninstall {
  $c = Get-MinervaConfig
  if ($c) { foreach ($d in @($c.Drive, $c.ScratchDrive)) { if ($d) { cmd /c "net use $d /delete /y" 2>$null | Out-Null } } }
  $prof = $PROFILE.CurrentUserAllHosts
  $stamp = Get-Date -Format 'yyyyMMddHHmmss'
  if (Test-Path $prof) { Copy-Item -LiteralPath $prof -Destination "$prof.minerva-bak.$stamp" }
  $cfgdir = Join-Path $env:USERPROFILE '.config\minerva'
  if (Test-Path $cfgdir) { Remove-Item -LiteralPath $cfgdir -Recurse -Force }
  if (Test-Path $prof) {
    $b = '# >>> minerva-setup >>>'; $e = '# <<< minerva-setup <<<'; $keep = @(); $skip = $false
    foreach ($line in Get-Content -LiteralPath $prof) {
      if ($line -eq $b) { $skip = $true; continue }
      if ($line -eq $e) { $skip = $false; continue }
      if (-not $skip) { $keep += $line }
    }
    Set-Content -LiteralPath $prof -Value $keep
  }
  Write-Host "Uninstalled. Profile backup: $prof.minerva-bak.$stamp. Open a new PowerShell window."
}
'@

Backup-Once $Profile_
Write-Block -Path $Profile_ -Content $block
Write-Ok "updated PowerShell profile ($Profile_)"

Write-Host ""
Write-Host "Done. Next steps:" -ForegroundColor Cyan
Write-Info "1. Open a new PowerShell window  (or: . `$PROFILE)"
Write-Info "2. minerva-mount   (maps your drive(s); type your password, approve MFA)"
Write-Info "3. minerva-status  •  minerva-clear to unmount"
Write-Info "Forget settings: minerva-forget   •   Remove everything: .\minerva-setup-windows.ps1 -Uninstall [-Purge]"
Write-Warn "Reminder: no 8-hour passwordless window on native Windows; each mount authenticates on its own."
