---
name: windows-app-relocation-diagnosis
description: Diagnose and repair Windows applications that break after being moved to another drive or after their data was relocated. Covers MSIX/Store app "Move" operations, junction and symlink data migrations, and known-folder redirection. Use when an app launches but a core action fails, when an error mentions "must be a real directory" or a path that cannot be found, when a feature broke right after a drive migration, or when a user asks whether moving an app back will fix it.
license: MIT
---

# Windows App Relocation Diagnosis

## Overview

A user moved an application or its data between drives, and now something is broken. The report is
usually vague: *"I moved it to D: and now it doesn't work."*

Three patterns recur in this failure class:

1. **The cause the user believes in is almost always wrong.** They often already moved the app back
   — successfully — before asking. The failure has nothing to do with which drive the package
   lives on.
2. **The real culprit is usually a junction, not a drive letter.** Many applications validate that
   a key directory is a *real* directory and reject reparse points outright. The defect is often
   planted months earlier by a migration script; the move operation merely *activates* it.
3. **The loudest, densest errors in the log are usually noise.** Distinguishing signal from noise
   requires a pre-failure baseline from the same log family.

**Core method:** enumerate reparse points on every relevant path, then find the exact error string
in the app's own logs, then exclude noise with a pre-failure baseline. **Do not attempt a repair
before you have the exact error string.**

## Workflow

### Step 0 — Pin down the symptom, but start read-only diagnosis in parallel

"It doesn't work" maps to at least four different repairs:

| Symptom | Direction |
|---|---|
| Will not launch / blank window | Package registration or runtime damage |
| Launches, action hangs with no response | Backend process or IPC |
| Prompts to sign in | Credentials or encryption context |
| **Visible error text in the UI** | Best case — locate it directly |

Ask the user which one it is, and run steps 1–6 while you wait. Never idle.

### Step 1 — Establish the package's real state

Do not infer package location from the filesystem; `WindowsApps` is unreadable without elevation.

```powershell
Get-AppxPackage | Where-Object { $_.Name -match '<pattern>' } |
  Format-List Name,PackageFullName,PackageFamilyName,InstallLocation,Status,IsPartiallyStaged,SignatureKind,Version
```

Check `Status` (expect `Ok`), `IsPartiallyStaged` (expect `False`), and the drive in `InstallLocation`.

### Step 2 — Reconstruct the move history

This decides whether a move-back is even needed.

```powershell
Get-WinEvent -LogName 'Microsoft-Windows-AppXDeploymentServer/Operational' -MaxEvents 800 |
  Where-Object { $_.Id -in 400,401,404,472 -and $_.Message -match '<pattern>' } |
  Sort-Object TimeCreated |
  Select-Object TimeCreated, Id, @{n='Msg';e={$_.Message -replace '\s+',' '}}
```

- Event **400** with `MovePackageOperation ... target volume X:` — one successful move
- Event **472** — the old package folder was moved into the `Deleted\` queue

**Frequent finding:** the user already moved it back and it succeeded. Say so explicitly, so they
stop re-moving it and causing fresh damage.

### Step 3 — Rule out the "stale process" hypothesis

```powershell
Get-Process | Where-Object { $_.Name -match '<pattern>' } |
  Select-Object Name, Id, StartTime, Path | Sort-Object StartTime
```

`StartTime` later than the move completion means these are fresh processes; the stale-handle theory
is dead. Also check Crashpad for reports and any sentry `session.json` for a non-`ok` status.
A healthy process set with zero crash reports plus a precise error message means a **logic
validation failure** — investigate paths and configuration, not corruption or reinstallation.

### Step 4 — Enumerate every reparse point (the decisive step)

```powershell
$pfn = '<PackageFamilyName>'
$paths = @(
  "$env:USERPROFILE\.<appdir>"
  "$env:USERPROFILE\Documents\<AppName>"
  "$env:LOCALAPPDATA\Packages\$pfn"
  "$env:LOCALAPPDATA\Packages\$pfn\LocalCache"
  "$env:LOCALAPPDATA\Packages\$pfn\LocalCache\Roaming"
  "$env:LOCALAPPDATA\Packages\$pfn\LocalCache\Roaming\<AppName>"
  "$env:LOCALAPPDATA\Packages\$pfn\LocalState"
  "$env:LOCALAPPDATA\Packages\$pfn\RoamingState"
)
foreach ($p in $paths) {
  $i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
  if ($i) { '{0,-90} Link={1} Target={2}' -f $p, $i.LinkType, ($i.Target -join ',') }
  else    { '{0,-90} <missing>' -f $p }
}
```

Also hunt for the user's own migration script — usually at the target drive root, e.g.
`D:\<X>Data\migrate-*.ps1`. **It tells you exactly which junctions exist**, and is the single
highest-value clue available.

Classify every junction you find:

| Location | Verdict |
|---|---|
| A redirect the app **officially supports** (a directory named by an `APPNAME_HOME`-style variable) | **Safe.** Leave it alone. |
| **Inside the package data directory** (`%LOCALAPPDATA%\Packages\<PFN>\...`) | **Cannot survive a move.** The move materializes it into a plain directory. Usually harmless — data gets copied out — but it leaves an orphaned duplicate behind. |
| A working directory the app **path-validates** (documents, project, or workspace root) | **High risk. Suspect this first.** |

> Any junction placed inside `%LOCALAPPDATA%\Packages\<PFN>` is destroyed by an MSIX move: Windows
> relocates that whole tree to `<drive>\WpSystem\<SID>\AppData\Local\Packages\` and back, copying
> *through* the junction on the way.

### Step 5 — Find the exact error

Prefer plain-text logs over binary or SQLite stores.

```powershell
Get-ChildItem "$env:LOCALAPPDATA\Packages\$pfn" -Recurse -Force -File -Include *.log,*.txt |
  Sort-Object LastWriteTime -Descending | Select-Object -First 15 FullName, Length, LastWriteTime
```

Electron apps commonly write to `...\LocalCache\Local\<App>\Logs\<yyyy>\<MM>\<dd>\`. Timestamps in
log *filenames* are typically **UTC** — convert before aligning them with what the user did.

High-value search patterns, chosen by what the user was doing:

```
submit failed | send failed          the send/submit action itself failed
error \[.*message-handler\]          main-process level errors
must be a real directory             path validation rejecting a reparse point (signature error)
os error 3 | cannot find the path     path resolution failure
turn_|task_started|stream            session or task lifecycle
```

**Align error timestamps with the number of user attempts.** Three send clicks producing exactly
three error entries establishes causation rather than coincidence.

### Step 6 — Exclude noise with a pre-failure baseline

Take a log from the *same* family recorded **before** the failure and run the same searches. **Any
error that already existed before the failure is not the cause.**

Typical noise, which can account for the overwhelming majority of log volume: account
authentication failures, telemetry endpoint timeouts, `no git remotes found`, plugin marketplace
duplicate-source warnings, and manifest validation warnings.

### Step 7 — Confirm the repair will not kill your own session

If you are running inside an agent service, verify the target app and your own service are
independent before restarting anything.

```powershell
netstat -ano | Select-String ':<port>'
Get-Process -Id <pid> | Select-Object Id,Name,StartTime,Path
```

Evidence of independence: the service process started long before the target app, and stayed alive
through the target app's restarts and updates.

## Repair

### Offer a zero-cost workaround first

Find an equivalent usage that does not trip the defect, so the user can work immediately. Example:
if only one code path validates the directory, another entry point whose root lives on a real path
keeps working — tell them to use that today, and schedule the real fix.

### Root fix — turn the junction back into a real directory

Use `scripts/Repair-JunctionToRealDirectory.ps1`, or apply the same preconditions manually. All
four are mandatory:

1. **Target app fully exited**, tray included. Assert it; refuse to run otherwise.
2. **No nested reparse points** inside the directory to be moved, or `robocopy` will follow them:
   ```powershell
   Get-ChildItem <target> -Recurse -Force |
     Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }
   ```
3. **Free space** on the destination at least the payload size plus headroom.
4. **Dry run first**, then execute.

The core operation:

```powershell
# Delete the link only. The $false second argument means "not recursive".
[System.IO.Directory]::Delete($LinkPath, $false)

New-Item -ItemType Directory -Path $LinkPath -Force | Out-Null
robocopy $TargetPath $LinkPath /E /COPY:DAT /DCOPY:DAT /MOVE /R:1 /W:1
if ($LASTEXITCODE -ge 8) { throw "robocopy failed (exit code $LASTEXITCODE)" }
```

**Preserve junctions the app officially supports.** They are unrelated to the failure; touching them
only adds risk.

### Give the user a durable alternative

To keep data off the system drive **without** junctions:

- The application's own home variable (`CODEX_HOME`, `XDG_*`, and similar)
- **Windows known-folder redirection**: right-click *Documents* → Properties → Location → Move.
  This yields a genuine directory on the target drive, not a reparse point, so path validation passes.

## Pitfalls

### Destructive mistakes (these cause a second round of data loss)

1. **Never remove a junction with `Remove-Item -Recurse`** — it deletes the real data at the target.
   Use `[System.IO.Directory]::Delete($path, $false)`.
2. **`robocopy` success is `< 8`, not `0`** — a normal success returns 1, 2, or 3. Testing `-ne 0`
   misreports success as failure and can trigger a wrong rollback.
3. **Never relocate a data directory while the app is running.** Open handles produce a
   half-migrated state.

### Diagnostic traps

4. **A missing credential file does not prove a broken login.** Read the config's auth-method field
   first; many deployments use an API key and legitimately have no such file.
5. **The densest error is not the cause.** Always run the pre-failure baseline comparison.
6. **Do not assume the move-back has not happened.** Read the deployment event log.
7. **"Launches" does not mean healthy, and "shows an error" does not mean crashed.**

### PowerShell environment traps

8. **Check the version before writing scripts:** `$PSVersionTable.PSVersion`. Under Windows
   PowerShell 5.1, a `.ps1` containing non-ASCII characters **must be saved as UTF-8 with BOM**;
   otherwise it is read as the ANSI code page, producing misleading parser errors such as
   "missing string terminator" or "unexpected token }" — **with line numbers that do not match the
   real file**, which makes you suspect the syntax itself. Fix and then validate:
   ```powershell
   $raw = Get-Content -LiteralPath $f -Encoding UTF8 -Raw
   [System.IO.File]::WriteAllText($f, $raw, (New-Object System.Text.UTF8Encoding($true)))

   $errs = $null; $toks = $null
   [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$toks, [ref]$errs)
   if ($errs.Count) { $errs | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" } }
   ```
   The safest habit for published scripts is to keep them **ASCII-only**, as the bundled scripts do.
   Also avoid PowerShell 7-only syntax (`??`, ternary `? :`, `ForEach-Object -Parallel`) on 5.1.
9. **These are commonly access-denied in constrained modes:** `Get-CimInstance Win32_Process`,
   `Get-Volume`, `Get-NetTCPConnection`. Substitute `Get-Process -Id $PID` with `.Parent` for
   process ancestry, `netstat -ano` for ports, and `[System.IO.DriveInfo]::new('C:')` for free space.
10. **Do not `ConvertFrom-Json` a large application state file wholesale.** Duplicate keys throw, and
    the dump floods your output. Extract fields with `Select-String` instead.
11. **Mind the log time zone.** Log bodies and filename timestamps are frequently UTC.

## Verification

Verify independently; do not trust the repair script's own success message.

```powershell
# 1. The key path is now a real directory (LinkType is empty)
Get-Item -LiteralPath $LinkPath -Force | Select-Object FullName, LinkType, Attributes

# 2. The exact path named in the original error is also a real directory
Get-Item -LiteralPath '<full cwd from the error>' -Force | Select-Object LinkType

# 3. File count and byte total match the pre-migration figures
Get-ChildItem $LinkPath -Recurse -Force -File | Measure-Object -Property Length -Sum

# 4. Junctions that had to survive were not touched
Get-Item -LiteralPath "$env:USERPROFILE\.<appdir>" -Force | Select-Object LinkType, Target

# 5. The source is empty or gone, with no half-migrated residue
Test-Path -LiteralPath $TargetPath
```

**Final acceptance belongs to the user, in the original failing scenario.** Have them reopen the app
and repeat the exact action that failed. If it still fails, read the newly written log and compare
the same error pattern's `cwd=` field against the expected path.

**Repair scripts must be idempotent:** when the target is already a real directory, report and
`exit 0`, so re-running is harmless.

## Reporting requirements

1. **Separate the trigger from the cause, and say so.** In this failure class the cause was often
   planted months earlier; the move merely activated it. Without this, users keep working the wrong
   angle — for instance, moving the app back and forth repeatedly.
2. **Correct your own earlier hypotheses out loud.** If you gave a wrong read before the exact error
   surfaced, state plainly what you got wrong and why it was falsified.
3. **Deliver a "do not do this again" rule**, e.g. *"stop using the Settings Move feature for this
   app; it is mutually exclusive with a junction-based layout."*
4. **List leftover cleanup items** — empty shells, orphaned duplicates — with sizes and conditions,
   while stating clearly that they are unrelated to the failure.

## Bundled resources

| Path | Purpose |
|---|---|
| `scripts/Diagnose-AppRelocation.ps1` | Read-only. Runs steps 1–5 and prints a consolidated report: package state, move history, processes, reparse points, log locations, candidate errors. |
| `scripts/Repair-JunctionToRealDirectory.ps1` | Converts a junction back into a real directory. Idempotent, `-DryRun` capable, with all four preconditions asserted. |
| `references/case-study-msix-junction-conflict.md` | A full worked case: an MSIX app whose "projectless" sessions broke because the documents directory was a junction. Includes the falsified hypotheses. |
| `references/powershell-pitfalls.md` | The PowerShell 5.1 encoding trap, constrained-mode substitutions, and robocopy exit-code semantics, with copy-paste fixes. |
