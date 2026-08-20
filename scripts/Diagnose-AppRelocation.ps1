<#
.SYNOPSIS
    Read-only diagnostic collector for Windows applications that broke after being moved to
    another drive, or after their data was relocated with directory junctions.

.DESCRIPTION
    Runs the read-only steps of the windows-app-relocation-diagnosis skill and prints a single
    consolidated report:

      1. Environment facts (PowerShell edition, OS build)
      2. MSIX/Appx package state
      3. Package move history from the deployment event log
      4. Live processes and their start times
      5. Reparse points discovered in every likely region (scanned, not guessed)
      6. User migration scripts found on non-system drives
      7. Application log locations plus candidate signature errors

    This script performs no modification other than an optional transcript file. When a cmdlet is
    blocked by policy or requires elevation, the section reports that instead of aborting.

    Written ASCII-only and PowerShell 5.1 compatible on purpose: a non-ASCII .ps1 without a BOM is
    decoded with the ANSI code page under 5.1, producing parser errors whose line numbers do not
    match the file.

.PARAMETER AppNamePattern
    Regex matched against Appx package names, process names and event log messages.
    Example: 'codex', 'slack|discord'.

.PARAMETER PackageFamilyName
    Optional. Supply to skip auto-detection, or when the package is no longer registered.

.PARAMETER ExtraPaths
    Additional paths to test for reparse points, e.g. an app data directory outside the package.

.PARAMETER LogTailLines
    How many trailing lines of the newest log file to scan for signature errors. Default 400.

.PARAMETER SkipMigrationScan
    Skip the search for migrate*/move* scripts on non-system drives.

.PARAMETER OutFile
    Optional path. Writes the whole report to this file in addition to the console.

.EXAMPLE
    .\Diagnose-AppRelocation.ps1 -AppNamePattern 'codex'

.EXAMPLE
    .\Diagnose-AppRelocation.ps1 -AppNamePattern 'myapp' `
        -ExtraPaths "$env:USERPROFILE\Documents\MyApp" -OutFile .\diagnosis.txt

.NOTES
    Part of the windows-app-relocation-diagnosis skill. MIT licensed.
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AppNamePattern,

    [string]$PackageFamilyName,

    [string[]]$ExtraPaths = @(),

    [int]$LogTailLines = 400,

    [switch]$SkipMigrationScan,

    [string]$OutFile
)

$ErrorActionPreference = 'Continue'
$script:Lines = New-Object System.Collections.ArrayList

# Legacy per-user junctions created by Windows itself; never the cause of an app failure.
$script:OsLegacyLinks = @(
    'Application Data', 'Cookies', 'Local Settings', 'My Documents', 'NetHood',
    'PrintHood', 'Recent', 'SendTo', 'Start Menu', 'Templates', 'History',
    'Temporary Internet Files', 'My Music', 'My Pictures', 'My Videos'
)

function W {
    param([string]$Text = '')
    [void]$script:Lines.Add($Text)
    Write-Host $Text
}

function Section {
    param([string]$Title)
    W ''
    W ('=' * 78)
    W ("  $Title")
    W ('=' * 78)
}

function Note {
    param([string]$Text)
    W ("    $Text")
}

function Try-Step {
    param([string]$What, [scriptblock]$Body)
    try { & $Body }
    catch {
        Note "[unavailable] $What"
        Note "             reason: $($_.Exception.Message)"
    }
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f [int]$Bytes)
}

function Get-ReparseInfo {
    param([string]$Path)
    $i = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $i) { return $null }
    $isLink = [bool]($i.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    $target = ''
    if ($i.PSObject.Properties.Name -contains 'Target' -and $i.Target) {
        $target = ($i.Target -join ',')
    }
    $linkType = ''
    if ($i.PSObject.Properties.Name -contains 'LinkType' -and $i.LinkType) {
        $linkType = $i.LinkType
    }
    return [pscustomobject]@{
        Path     = $i.FullName
        IsLink   = $isLink
        LinkType = $linkType
        Target   = $target
    }
}

# ---------------------------------------------------------------------------
Section '0. REPORT HEADER'
Note ("generated      : " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
Note ("app pattern    : $AppNamePattern")
Note ("script         : Diagnose-AppRelocation.ps1 (read-only)")

# ---------------------------------------------------------------------------
Section '1. ENVIRONMENT'
Note ("PowerShell     : " + $PSVersionTable.PSVersion.ToString() + '  (edition: ' + $PSVersionTable.PSEdition + ')')
if ($PSVersionTable.PSVersion.Major -lt 6) {
    Note "               WARNING: Windows PowerShell 5.1 detected."
    Note "               Any .ps1 you author with non-ASCII text must be saved UTF-8 WITH BOM."
}
Try-Step 'OS build via registry' {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    Note ("OS             : {0} (build {1}.{2})" -f $cv.ProductName, $cv.CurrentBuild, $cv.UBR)
}
Note ("ANSI code page : " + ([System.Text.Encoding]::Default).WebName)
Try-Step 'fixed drive free space' {
    [System.IO.DriveInfo]::GetDrives() |
        Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
        ForEach-Object {
            Note ("drive {0,-4} free {1,12}  of {2,12}  ({3})" -f `
                $_.Name, (Format-Bytes $_.AvailableFreeSpace), (Format-Bytes $_.TotalSize), $_.DriveFormat)
        }
}

# ---------------------------------------------------------------------------
Section '2. APPX / MSIX PACKAGE STATE'
$pkgs = @()
Try-Step 'Get-AppxPackage' {
    $script:pkgs = @(Get-AppxPackage -ErrorAction Stop |
        Where-Object { $_.Name -match $AppNamePattern -or $_.PackageFullName -match $AppNamePattern })
    if ($script:pkgs.Count -eq 0) {
        Note "no registered package matches the pattern (the app may be a plain Win32 install)"
    }
    foreach ($p in $script:pkgs) {
        W ''
        Note ("Name              : " + $p.Name)
        Note ("PackageFullName   : " + $p.PackageFullName)
        Note ("PackageFamilyName : " + $p.PackageFamilyName)
        Note ("InstallLocation   : " + $p.InstallLocation)
        Note ("Status            : " + $p.Status + "   IsPartiallyStaged: " + $p.IsPartiallyStaged)
        Note ("SignatureKind     : " + $p.SignatureKind + "   Version: " + $p.Version)
        if ($p.InstallLocation) {
            $drive = ($p.InstallLocation -split ':')[0] + ':'
            Note ("=> package currently lives on drive $drive")
        }
    }
}
if (-not $PackageFamilyName -and $pkgs.Count -gt 0) {
    $PackageFamilyName = $pkgs[0].PackageFamilyName
    Note ''
    Note "auto-detected PackageFamilyName: $PackageFamilyName"
}

# ---------------------------------------------------------------------------
Section '3. PACKAGE MOVE HISTORY (deployment event log)'
Note 'Event 400 + MovePackageOperation = one successful move. Event 472 = old folder queued for delete.'
W ''
Try-Step 'AppXDeploymentServer/Operational' {
    $evts = @(Get-WinEvent -LogName 'Microsoft-Windows-AppXDeploymentServer/Operational' `
                -MaxEvents 1000 -ErrorAction Stop |
        Where-Object { $_.Id -in 400, 401, 404, 472 -and $_.Message -match $AppNamePattern } |
        Sort-Object TimeCreated)
    if ($evts.Count -eq 0) { Note 'no matching deployment events found'; return }
    foreach ($e in $evts) {
        $msg = ($e.Message -replace '\s+', ' ').Trim()
        if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '...' }
        Note ("{0:yyyy-MM-dd HH:mm:ss}  id={1,-4} {2}" -f $e.TimeCreated, $e.Id, $msg)
    }
    W ''
    $moves = @($evts | Where-Object { $_.Message -match 'MovePackageOperation' })
    Note ("=> $($moves.Count) move operation(s) recorded")
    if ($moves.Count -ge 2) {
        Note '=> IMPORTANT: more than one move. The user may have already moved the app back.'
        Note '   If the last move restored the original drive, a further move-back is NOT the fix.'
    }
}

# ---------------------------------------------------------------------------
Section '4. LIVE PROCESSES'
Note 'A start time LATER than the last move means these are fresh processes (no stale handles).'
W ''
Try-Step 'Get-Process' {
    $procs = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $AppNamePattern } | Sort-Object StartTime)
    if ($procs.Count -eq 0) { Note 'no matching process is running'; return }
    foreach ($pr in $procs) {
        $st = ''
        try { $st = $pr.StartTime.ToString('yyyy-MM-dd HH:mm:ss') } catch { $st = '<denied>' }
        $path = ''
        try { $path = $pr.Path } catch { $path = '<denied>' }
        Note ("{0,-16} pid={1,-8} start={2}  {3}" -f $pr.Name, $pr.Id, $st, $path)
    }
    Note ''
    Note ("=> $($procs.Count) process(es) alive")
}

# ---------------------------------------------------------------------------
Section '5. REPARSE POINTS (junctions / symlinks)'
Note 'This is the decisive step. Regions are SCANNED, not guessed.'

$regions = New-Object System.Collections.ArrayList
[void]$regions.Add([pscustomobject]@{ Path = $env:USERPROFILE;   Depth = 1 })
[void]$regions.Add([pscustomobject]@{ Path = (Join-Path $env:USERPROFILE 'Documents'); Depth = 1 })
[void]$regions.Add([pscustomobject]@{ Path = $env:APPDATA;       Depth = 1 })
[void]$regions.Add([pscustomobject]@{ Path = $env:LOCALAPPDATA;  Depth = 1 })
if ($PackageFamilyName) {
    $pkgRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'Packages') $PackageFamilyName
    [void]$regions.Add([pscustomobject]@{ Path = $pkgRoot; Depth = 4 })
}

$found = New-Object System.Collections.ArrayList
foreach ($r in $regions) {
    if (-not $r.Path -or -not (Test-Path -LiteralPath $r.Path)) { continue }
    W ''
    Note ("scanning: {0}   (depth {1})" -f $r.Path, $r.Depth)
    Try-Step ("scan of " + $r.Path) {
        $items = @(Get-ChildItem -LiteralPath $r.Path -Directory -Force -Recurse -Depth $r.Depth `
                    -ErrorAction SilentlyContinue |
            Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint })
        if ($items.Count -eq 0) { Note '  (none)'; return }
        foreach ($it in $items) {
            $tgt = ''
            if ($it.Target) { $tgt = ($it.Target -join ',') }
            $tag = ''
            $isOsLegacy = $false
            # OS legacy per-user junctions always carry Hidden + System. This attribute test is
            # locale-independent, unlike a name list (e.g. a localized "Start Menu").
            if (($it.Attributes -band [System.IO.FileAttributes]::Hidden) -and
                ($it.Attributes -band [System.IO.FileAttributes]::System)) { $isOsLegacy = $true }
            if ($script:OsLegacyLinks -contains $it.Name) { $isOsLegacy = $true }
            if ($isOsLegacy) { $tag = '  [OS legacy, ignore]' }
            else { [void]$found.Add($it) }
            Note ("  {0}" -f $it.FullName)
            Note ("      LinkType={0}  Target={1}{2}" -f $it.LinkType, $tgt, $tag)
        }
    }
}

foreach ($p in $ExtraPaths) {
    W ''
    Note ("explicit path: $p")
    $info = Get-ReparseInfo -Path $p
    if ($null -eq $info) { Note '  <missing>'; continue }
    if ($info.IsLink) {
        Note ("  REPARSE POINT  LinkType={0}  Target={1}" -f $info.LinkType, $info.Target)
        [void]$found.Add((Get-Item -LiteralPath $p -Force))
    }
    else { Note '  real directory (OK)' }
}

W ''
Note '--- verdict guide ---'
Note 'A junction is SAFE when the app officially supports that redirect (an APPNAME_HOME variable).'
Note 'A junction INSIDE %LOCALAPPDATA%\Packages\<PFN> cannot survive an MSIX move; usually harmless.'
Note 'A junction on a working directory the app path-validates is HIGH RISK. Suspect it first.'
W ''
$nonLegacy = @($found | Sort-Object FullName -Unique)
Note ("=> $($nonLegacy.Count) non-OS reparse point(s) require a verdict:")
foreach ($f in $nonLegacy) {
    $tgt = ''
    if ($f.Target) { $tgt = ($f.Target -join ',') }
    Note ("   $($f.FullName)  ->  $tgt")
}

# Relevant home-style environment variables
W ''
Note '--- *_HOME / XDG environment variables (officially supported redirects) ---'
$envHits = @(Get-ChildItem env: | Where-Object { $_.Name -match '_HOME$|^XDG_' })
if ($envHits.Count -eq 0) { Note '  (none set)' }
foreach ($e in $envHits) { Note ("  {0} = {1}" -f $e.Name, $e.Value) }

# ---------------------------------------------------------------------------
Section '6. USER MIGRATION SCRIPTS ON NON-SYSTEM DRIVES'
if ($SkipMigrationScan) { Note 'skipped by -SkipMigrationScan' }
else {
    Note 'A past migration script is the highest-value clue: it lists every junction created.'
    W ''
    Try-Step 'migration script scan' {
        $sys = $env:SystemDrive
        $drives = @([System.IO.DriveInfo]::GetDrives() |
            Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady -and $_.Name.TrimEnd('\') -ne $sys })
        if ($drives.Count -eq 0) { Note 'no non-system fixed drive found'; return }
        $any = $false
        foreach ($d in $drives) {
            $hits = @(Get-ChildItem -LiteralPath $d.RootDirectory.FullName -Recurse -Depth 2 -File `
                        -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Extension -in '.ps1', '.cmd', '.bat' -and
                    $_.Name -match 'migrat|move|relocat|junction|symlink'
                })
            foreach ($h in $hits) {
                $any = $true
                Note ("{0}   ({1}, modified {2:yyyy-MM-dd})" -f $h.FullName, (Format-Bytes $h.Length), $h.LastWriteTime)
            }
        }
        if (-not $any) { Note 'none found' }
        else { Note ''; Note '=> READ these scripts. They reveal the junction layout directly.' }
    }
}

# ---------------------------------------------------------------------------
Section '7. APPLICATION LOGS AND SIGNATURE ERRORS'
$signaturePatterns = @(
    'must be a real directory',
    'submit failed',
    'send failed',
    'os error 3',
    'cannot find the path',
    'The system cannot find the path',
    'Access is denied',
    'EPERM',
    'ENOENT'
)

$logRoots = New-Object System.Collections.ArrayList
if ($PackageFamilyName) {
    [void]$logRoots.Add((Join-Path (Join-Path $env:LOCALAPPDATA 'Packages') $PackageFamilyName))
}
foreach ($p in $ExtraPaths) { if (Test-Path -LiteralPath $p) { [void]$logRoots.Add($p) } }

$newest = @()
foreach ($root in $logRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    W ''
    Note ("searching logs under: $root")
    Try-Step ("log discovery in $root") {
        # Chromium/Electron embed LevelDB journals named *.log inside their storage directories.
        # Those are binary and never the application's diagnostic log; exclude them or the
        # signature scan will pick a binary file as "the newest log".
        $excludePattern = '\\(Local Storage|Session Storage|Sync Data|shared_proto_db|leveldb|' +
                          'IndexedDB|Partitions|Cache|Code Cache|GPUCache|Crashpad|Service Worker|' +
                          'Extension State|Extension Rules|Extension Scripts|blob_storage|' +
                          'Site Characteristics Database|DawnGraphiteCache|DawnWebGPUCache|' +
                          'GrShaderCache|ShaderCache|WebStorage|Nurturing)\\'
        $all = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Extension -in '.log', '.txt' -and $_.Length -gt 0 -and
                $_.FullName -notmatch $excludePattern
            })
        # Prefer paths that look like a real application log directory.
        $preferred = @($all | Where-Object {
            $_.FullName -match '\\Logs?\\' -or $_.Name -match 'desktop|main|renderer|error|debug'
        })
        if ($preferred.Count -gt 0) {
            Note ('  (using {0} application log file(s); browser-engine storage journals excluded)' -f $preferred.Count)
            $all = $preferred
        }
        $logs = @($all | Sort-Object LastWriteTime -Descending | Select-Object -First 15)
        if ($logs.Count -eq 0) { Note '  no plain-text log files found'; return }
        foreach ($l in $logs) {
            Note ("  {0,-12} {1:yyyy-MM-dd HH:mm:ss}  {2}" -f (Format-Bytes $l.Length), $l.LastWriteTime, $l.FullName)
        }
        $script:newest = $logs
    }
}

if ($newest.Count -gt 0) {
    W ''
    Note ("--- signature error scan: newest log, last $LogTailLines lines ---")
    $target = $newest[0]
    Note ("file: " + $target.FullName)
    W ''
    Try-Step 'signature scan' {
        $tail = Get-Content -LiteralPath $target.FullName -Tail $LogTailLines -ErrorAction Stop
        $hitCount = 0
        $seen = @{}
        foreach ($line in $tail) {
            foreach ($pat in $signaturePatterns) {
                if ($line -like "*$pat*") {
                    $key = $pat
                    if (-not $seen.ContainsKey($key)) {
                        $seen[$key] = 0
                        W ''
                        Note ("PATTERN HIT: '$pat'")
                    }
                    $seen[$key] = $seen[$key] + 1
                    if ($seen[$key] -le 3) {
                        $short = ($line -replace '\s+', ' ').Trim()
                        if ($short.Length -gt 300) { $short = $short.Substring(0, 300) + '...' }
                        Note ("  $short")
                    }
                    $hitCount++
                    break
                }
            }
        }
        W ''
        if ($hitCount -eq 0) {
            Note 'no signature pattern matched. Widen the search: grep the whole log for "error".'
        }
        else {
            foreach ($k in $seen.Keys) { Note ("  total '{0}' : {1}" -f $k, $seen[$k]) }
        }
    }
}

# ---------------------------------------------------------------------------
Section '8. NEXT ACTIONS'
Note '1. NOISE BASELINE - mandatory before believing any error above:'
Note '   pick a log from the SAME family recorded BEFORE the failure and rerun the same search.'
Note '   Any error that already existed before the failure is NOT the cause.'
Note ''
Note '2. Align error timestamps with the number of user attempts (3 clicks -> 3 entries).'
Note ''
Note '3. If a high-risk junction was listed in section 5, repair it with:'
Note '   .\Repair-JunctionToRealDirectory.ps1 -LinkPath "<path>" -ProcessPattern "<regex>" -DryRun'
Note ''
Note '4. Remember: log filename timestamps are usually UTC. Convert before aligning.'
W ''

if ($OutFile) {
    try {
        $dir = Split-Path -Parent $OutFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        # UTF-8 with BOM so the transcript opens correctly in any Windows editor.
        [System.IO.File]::WriteAllLines(
            $OutFile,
            [string[]]$script:Lines,
            (New-Object System.Text.UTF8Encoding($true)))
        Write-Host ''
        Write-Host "Report written to: $OutFile" -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to write report: $($_.Exception.Message)" -ForegroundColor Red
    }
}
