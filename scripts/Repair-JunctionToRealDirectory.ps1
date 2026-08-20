<#
.SYNOPSIS
    Convert a directory junction (or directory symlink) back into a real directory by moving its
    payload to the link location.

.DESCRIPTION
    Some applications validate that a working directory is a REAL directory and reject reparse
    points, producing errors such as "must be a real directory". This script removes the link and
    relocates the target's contents into the original path.

    Four preconditions are asserted in code, not left to the operator:

      1. No process matching -ProcessPattern is running.
      2. -LinkPath is genuinely a reparse point (otherwise: nothing to do, exit 0).
      3. No nested reparse points exist inside the payload, which robocopy would follow.
      4. Free space on the destination >= payload size + -HeadroomMB.

    Idempotent: re-running after a successful repair reports the desired state and exits 0.

    Safety notes deliberately encoded here:
      * The link is deleted with [System.IO.Directory]::Delete($path, $false) - NOT
        Remove-Item -Recurse, which would delete the real data at the target.
      * robocopy success is exit code < 8. A normal success returns 1, 2 or 3, so testing
        "-ne 0" would misreport success as failure.

    Written ASCII-only and PowerShell 5.1 compatible on purpose.

.PARAMETER LinkPath
    The junction to eliminate, e.g. "$env:USERPROFILE\Documents\MyApp".
    Its current target is read from the filesystem; do not pass the target yourself.

.PARAMETER ProcessPattern
    Regex of process names that must not be running, e.g. '^(myapp|MyApp)$'.
    Pass '' to skip the check (not recommended).

.PARAMETER HeadroomMB
    Extra free space required beyond the payload size. Default 500.

.PARAMETER KeepSource
    Do not delete the emptied source directory after a successful move.

.PARAMETER DryRun
    Print the plan and perform no modification.

.EXAMPLE
    .\Repair-JunctionToRealDirectory.ps1 -LinkPath "$env:USERPROFILE\Documents\MyApp" `
        -ProcessPattern '^(myapp|MyApp)$' -DryRun

.EXAMPLE
    .\Repair-JunctionToRealDirectory.ps1 -LinkPath "$env:USERPROFILE\Documents\MyApp" `
        -ProcessPattern '^(myapp|MyApp)$'

.NOTES
    Part of the windows-app-relocation-diagnosis skill. MIT licensed.
    Exit codes: 0 success or already-correct, 1 precondition failed, 2 operation failed.
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LinkPath,

    [string]$ProcessPattern = '',

    [int]$HeadroomMB = 500,

    [switch]$KeepSource,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor Green }
function Write-Warn2{ param([string]$m) Write-Host "    $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "    $m" -ForegroundColor Red }

function Format-MB { param([double]$b) return ('{0:N2} MB' -f ($b / 1MB)) }

Write-Host ''
Write-Host 'Repair-JunctionToRealDirectory' -ForegroundColor White
Write-Host '------------------------------' -ForegroundColor White
if ($DryRun) { Write-Warn2 'MODE: DryRun - nothing will be modified' }
Write-Host ''

# --- Precondition 1: target application not running -------------------------
Write-Step 'Precondition 1/4: target application is not running'
if ([string]::IsNullOrWhiteSpace($ProcessPattern)) {
    Write-Warn2 'skipped (-ProcessPattern empty). Make sure the app is closed yourself.'
}
else {
    $running = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $ProcessPattern })
    if ($running.Count -gt 0) {
        $names = ($running | ForEach-Object { "$($_.Name)(pid $($_.Id))" }) -join ', '
        Write-Err "Still running: $names"
        Write-Warn2 'Exit the application completely, including any tray icon, then retry.'
        exit 1
    }
    Write-Ok 'not running'
}

# --- Precondition 2: LinkPath really is a reparse point ---------------------
Write-Step 'Precondition 2/4: path is a reparse point'
if (-not (Test-Path -LiteralPath $LinkPath)) {
    Write-Err "Path does not exist: $LinkPath"
    exit 1
}
$linkItem = Get-Item -LiteralPath $LinkPath -Force
if (-not ($linkItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    Write-Ok "$LinkPath is already a real directory."
    Write-Ok 'Nothing to do - this is the desired end state. Exiting 0 (idempotent).'
    exit 0
}
$targetPath = ''
if ($linkItem.Target) { $targetPath = @($linkItem.Target)[0] }
if ([string]::IsNullOrWhiteSpace($targetPath)) {
    Write-Err 'Could not read the reparse point target. Inspect manually with: fsutil reparsepoint query'
    exit 1
}
# Normalise a possible \??\ prefix.
$targetPath = $targetPath -replace '^\\\\\?\?\\', ''
Write-Ok ("LinkType={0}" -f $linkItem.LinkType)
Write-Ok ("target  ={0}" -f $targetPath)
if (-not (Test-Path -LiteralPath $targetPath)) {
    Write-Err "Reparse target does not exist: $targetPath"
    exit 1
}

# --- Precondition 3: no nested reparse points inside the payload -----------
Write-Step 'Precondition 3/4: no nested reparse points inside the payload'
$nested = @(Get-ChildItem -LiteralPath $targetPath -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint })
if ($nested.Count -gt 0) {
    Write-Err "Found $($nested.Count) nested reparse point(s). robocopy would follow them."
    foreach ($n in ($nested | Select-Object -First 10)) {
        $t = ''
        if ($n.Target) { $t = ($n.Target -join ',') }
        Write-Warn2 ("  {0}  ->  {1}" -f $n.FullName, $t)
    }
    Write-Warn2 'Resolve these first (or move them aside), then retry.'
    exit 1
}
Write-Ok 'none found'

# --- Precondition 4: free space -------------------------------------------
Write-Step 'Precondition 4/4: destination free space'
$stat = Get-ChildItem -LiteralPath $targetPath -Recurse -Force -File -ErrorAction SilentlyContinue |
    Measure-Object -Property Length -Sum
$payloadBytes = 0
$fileCount = 0
if ($stat) {
    if ($stat.Sum) { $payloadBytes = [double]$stat.Sum }
    $fileCount = $stat.Count
}
$qualifier = Split-Path -Qualifier $LinkPath
$drive = [System.IO.DriveInfo]::new($qualifier)
$needBytes = $payloadBytes + ($HeadroomMB * 1MB)
Write-Ok ("payload : {0} file(s), {1}" -f $fileCount, (Format-MB $payloadBytes))
Write-Ok ("required: {0} (payload + {1} MB headroom)" -f (Format-MB $needBytes), $HeadroomMB)
Write-Ok ("free on {0}: {1}" -f $drive.Name, (Format-MB $drive.AvailableFreeSpace))
if ($drive.AvailableFreeSpace -lt $needBytes) {
    Write-Err 'Not enough free space on the destination.'
    exit 1
}
Write-Ok 'sufficient'

# --- Plan -----------------------------------------------------------------
Write-Host ''
Write-Step 'PLAN'
Write-Ok "1. delete the link (non-recursive): $LinkPath"
Write-Ok "2. robocopy /MOVE  $targetPath  ->  $LinkPath"
Write-Ok ("3. verify real directory + file count ({0}) + byte total" -f $fileCount)
if (-not $KeepSource) { Write-Ok "4. remove the emptied source: $targetPath" }
else { Write-Ok '4. keep the emptied source (-KeepSource)' }

if ($DryRun) {
    Write-Host ''
    Write-Warn2 'DryRun complete. Re-run without -DryRun to execute.'
    exit 0
}

# --- Execute --------------------------------------------------------------
Write-Host ''
Write-Step 'Executing'
try {
    # Delete the link only. $false = non-recursive. Never use Remove-Item -Recurse here.
    [System.IO.Directory]::Delete($LinkPath, $false)
    Write-Ok 'link removed (target data untouched)'
}
catch {
    Write-Err "Failed to remove the link: $($_.Exception.Message)"
    Write-Warn2 'The link is still present; no data was moved. Safe to retry.'
    exit 2
}

$rollbackNeeded = $true
try {
    New-Item -ItemType Directory -Path $LinkPath -Force | Out-Null
    $roboArgs = @($targetPath, $LinkPath, '/E', '/COPY:DAT', '/DCOPY:DAT', '/MOVE', '/R:1', '/W:1', '/NFL', '/NDL', '/NP')
    & robocopy @roboArgs | Out-Host
    $rc = $LASTEXITCODE
    # robocopy: exit code < 8 means success (1 = files copied, 2 = extras, 3 = 1+2, ...)
    if ($rc -ge 8) { throw "robocopy failed with exit code $rc" }
    Write-Ok ("robocopy completed (exit code $rc, success is < 8)")
    $rollbackNeeded = $false
}
catch {
    Write-Err $_.Exception.Message
    if ($rollbackNeeded) {
        Write-Warn2 'Payload may be split between source and destination. Do NOT delete either side.'
        Write-Warn2 "source     : $targetPath"
        Write-Warn2 "destination: $LinkPath"
        Write-Warn2 'Re-run robocopy manually with the same arguments to finish the move.'
    }
    exit 2
}

# --- Verify ---------------------------------------------------------------
Write-Host ''
Write-Step 'Verifying'
$after = Get-Item -LiteralPath $LinkPath -Force
if ($after.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    Write-Err "$LinkPath is still a reparse point. Repair did not take effect."
    exit 2
}
Write-Ok "$LinkPath is now a real directory"

$statAfter = Get-ChildItem -LiteralPath $LinkPath -Recurse -Force -File -ErrorAction SilentlyContinue |
    Measure-Object -Property Length -Sum
$afterCount = 0
$afterBytes = 0
if ($statAfter) {
    $afterCount = $statAfter.Count
    if ($statAfter.Sum) { $afterBytes = [double]$statAfter.Sum }
}
Write-Ok ("files: {0} (before {1})" -f $afterCount, $fileCount)
Write-Ok ("bytes: {0} (before {1})" -f (Format-MB $afterBytes), (Format-MB $payloadBytes))
if ($afterCount -ne $fileCount) {
    Write-Warn2 'File count differs. Inspect before deleting anything.'
}

if (Test-Path -LiteralPath $targetPath) {
    $left = @(Get-ChildItem -LiteralPath $targetPath -Recurse -Force -ErrorAction SilentlyContinue)
    if ($left.Count -eq 0) {
        if ($KeepSource) { Write-Ok "source is empty, kept as requested: $targetPath" }
        else {
            Remove-Item -LiteralPath $targetPath -Force -Recurse -ErrorAction SilentlyContinue
            Write-Ok "removed emptied source: $targetPath"
        }
    }
    else {
        Write-Warn2 ("source still holds {0} item(s); left in place for manual review: {1}" -f $left.Count, $targetPath)
    }
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan
Write-Warn2 'Reopen the application and repeat the exact action that failed before.'
Write-Warn2 'Do not use the Windows Settings "Move" feature on this app again if it relies on junctions.'
exit 0
