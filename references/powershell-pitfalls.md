# PowerShell and Windows environment pitfalls

Traps encountered while diagnosing and repairing app relocation failures. Each entry gives the
symptom, the cause, and a copy-paste fix.

---

## 1. Non-ASCII `.ps1` without a BOM breaks under Windows PowerShell 5.1

**Symptom.** A script that looks syntactically perfect fails to parse:

```
Unexpected token '}' in expression or statement.
The string is missing the terminator: ".
Missing closing '}' in statement block or type definition.
```

The reported line numbers **do not match the real file**, which makes you suspect the syntax itself
and start rewriting working code.

**Cause.** Windows PowerShell 5.1 decodes a BOM-less `.ps1` using the system ANSI code page, not
UTF-8. Multi-byte UTF-8 sequences are misinterpreted, some byte pairs terminate string literals
early, and the parser's line accounting drifts away from the file's real line numbering.

**Why it bites agents specifically.** Most file-writing tools emit UTF-8 **without** a BOM by default.
If the script contains any non-ASCII character — a Chinese comment, a smart quote, an em dash, an
emoji — it will fail on 5.1 even though the bytes are valid UTF-8.

**Fix — re-encode as UTF-8 with BOM:**

```powershell
$f   = 'path\to\script.ps1'
$raw = Get-Content -LiteralPath $f -Encoding UTF8 -Raw
[System.IO.File]::WriteAllText($f, $raw, (New-Object System.Text.UTF8Encoding($true)))

# Confirm the BOM landed: expect EF BB BF
$b = [System.IO.File]::ReadAllBytes($f)[0..2]
'{0:X2} {1:X2} {2:X2}' -f $b[0], $b[1], $b[2]
```

**Then validate the syntax without executing it** — never "just run it and see":

```powershell
$errs = $null; $toks = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$toks, [ref]$errs)
if ($errs.Count) {
    $errs | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }
} else { 'syntax OK' }
```

**Best practice for published scripts: keep them ASCII-only.** Then encoding, code page and Git
checkout settings become irrelevant. Both scripts in this skill follow that rule.

**Detect the edition before you write anything:**

```powershell
$PSVersionTable.PSVersion      # 5.1.x  -> Windows PowerShell
$PSVersionTable.PSEdition      # Desktop -> 5.1 ; Core -> 6+
([System.Text.Encoding]::Default).WebName   # the ANSI code page in effect
```

Beware: a tool advertised as `pwsh` may actually execute `powershell.exe` (5.1). Verify rather than
assume — check `(Get-Process -Id $PID).Path`.

---

## 2. PowerShell 7-only syntax fails silently-looking on 5.1

Avoid in any script that must run on 5.1:

| Feature | 5.1 status |
|---|---|
| `??` null-coalescing, `??=` | Not supported |
| Ternary `$a ? $b : $c` | Not supported |
| `ForEach-Object -Parallel` | Not supported |
| `&&` / `\|\|` pipeline chain operators | Not supported |
| `-not` on `$null` array results | Behaves differently |

Substitutes:

```powershell
# instead of  $x = $a ?? 'default'
$x = if ($null -ne $a) { $a } else { 'default' }

# instead of  $r = $cond ? 'yes' : 'no'
$r = if ($cond) { 'yes' } else { 'no' }
```

---

## 3. Cmdlets that are commonly access-denied

Under constrained execution, restricted WMI access, or without elevation, these fail with
`PermissionDenied` / `Access is denied`:

| Blocked | Substitute |
|---|---|
| `Get-CimInstance Win32_Process` (process ancestry) | `Get-Process -Id $PID` then walk `.Parent` (PowerShell 5.1+ exposes it) |
| `Get-Volume` | `[System.IO.DriveInfo]::GetDrives()` |
| `Get-NetTCPConnection` | `netstat -ano \| Select-String ':<port>'` |
| Listing `C:\Program Files\WindowsApps` | `Get-AppxPackage` and read `InstallLocation` |

```powershell
# Process ancestry without WMI
$p = Get-Process -Id $PID
while ($p) {
    '{0} pid={1} {2}' -f $p.Name, $p.Id, $p.Path
    try { $p = $p.Parent } catch { break }
}
```

Under ConstrainedLanguage mode, `.NET` static calls (`[System.IO.File]::`, `[math]::`), `Add-Type`,
COM objects and reflection are unavailable. Prefer cmdlets and core types (`[string]`, `[datetime]`,
`[regex]`, `[guid]`) when the mode is uncertain.

---

## 4. `robocopy` exit codes: success is `< 8`, not `0`

**This is a data-loss trap.** `robocopy` uses a bit-flag exit code:

| Code | Meaning |
|---|---|
| 0 | No files copied, no failures — nothing to do |
| 1 | Files copied successfully |
| 2 | Extra files or directories detected |
| 3 | 1 + 2 |
| 4 | Mismatched files or directories |
| **8** | **Some files or directories could not be copied — real failure** |
| 16 | Fatal error, no copy performed |

A perfectly successful `/MOVE` normally returns **1**. Testing `-ne 0` therefore reports success as
failure, which may trigger a rollback that deletes correctly-moved data.

```powershell
robocopy $src $dst /E /COPY:DAT /DCOPY:DAT /MOVE /R:1 /W:1
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
```

Useful flags for scripted moves: `/NFL /NDL /NP` suppress per-file, per-directory and percentage
output, keeping the summary readable. `/XJ` excludes junctions if you must copy a tree that contains
them — though for a migration you should refuse to proceed instead (see next entry).

---

## 5. Deleting a junction: never use `Remove-Item -Recurse`

**This is a data-loss trap.** `Remove-Item -Recurse` follows the reparse point and deletes the real
data at the target.

```powershell
# WRONG - destroys the payload the junction points at
Remove-Item -LiteralPath $link -Recurse -Force

# CORRECT - removes the link only. $false means non-recursive.
[System.IO.Directory]::Delete($link, $false)
```

Alternatives when `.NET` static calls are unavailable:

```cmd
rmdir "C:\path\to\link"      :: cmd rmdir without /S removes only the link
```

Always confirm you are dealing with a reparse point first:

```powershell
$i = Get-Item -LiteralPath $link -Force
[bool]($i.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
$i.LinkType      # Junction | SymbolicLink | HardLink
$i.Target
```

---

## 6. Nested reparse points make `robocopy` recurse into foreign trees

Before any `/E /MOVE`, verify the payload contains no nested links:

```powershell
Get-ChildItem -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint }
```

A non-empty result means `robocopy` would copy *through* those links, potentially pulling in
unrelated data or looping. Refuse to proceed rather than adding `/XJ` blindly — `/XJ` silently drops
the links, which may itself be data loss if they were intentional.

---

## 7. Reading large JSON state files

`ConvertFrom-Json` on a large application state file frequently throws
`System.ArgumentException` because of **duplicate keys**, and on failure the raw content can flood
stderr and pollute your output.

```powershell
# Do not do this on a multi-hundred-KB app state file
$j = Get-Content $stateFile -Raw | ConvertFrom-Json

# Extract only what you need
Select-String -LiteralPath $stateFile -Pattern '"someKey":"[^"]*"' |
    ForEach-Object { $_.Matches.Value }
```

---

## 8. Log time zones

Application log bodies are usually UTC (ISO-8601 with `Z`). Timestamps embedded in log **filenames**
are frequently UTC as well, even when the surrounding date folders are local. Always convert before
aligning log entries with what the user did, or you will look for evidence in the wrong file.

```powershell
# Local time from a UTC log timestamp
[datetime]::Parse('2026-08-20T14:47:54.747Z').ToLocalTime()
```

---

## 9. Free space and byte formatting on restricted hosts

```powershell
# Works without WMI
$d = [System.IO.DriveInfo]::new('C:')
'{0:N2} GB free of {1:N2} GB' -f ($d.AvailableFreeSpace / 1GB), ($d.TotalSize / 1GB)

# Enumerate fixed drives only
[System.IO.DriveInfo]::GetDrives() |
    Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }
```

---

## 10. Windows creates its own per-user junctions — ignore them

A reparse point scan of `%USERPROFILE%` will surface legacy compatibility junctions that Windows
created and that are never the cause of an application failure:

```
Application Data, Cookies, Local Settings, My Documents, NetHood, PrintHood,
Recent, SendTo, Start Menu, Templates, History, Temporary Internet Files,
My Music, My Pictures, My Videos
```

Filter or flag them so real findings stand out. `Diagnose-AppRelocation.ps1` tags them
`[OS legacy, ignore]`.
