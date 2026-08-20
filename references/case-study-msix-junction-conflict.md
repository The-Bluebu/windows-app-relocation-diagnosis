# Case study: an MSIX app whose sending broke because the documents folder was a junction

A complete worked example of this skill's workflow, drawn from a real incident. All personal
identifiers, credentials, organisation names and project names have been removed.

Read this for the **method**, especially section 5 — the five hypotheses that looked right and were
all wrong. Reproducing those five wrong turns is the main time cost in this failure class.

---

## 1. Metadata

```yaml
os: Windows 11 (build 26100)
app_install_type: MSIX (Microsoft Store signed)
package_family: <Vendor>.<App>_<hash>
symptom: window opens normally, but sending a message fails
user_report: "I moved it to D: with the official Windows method and now I can't talk to it.
              Will moving it back help?"
root_cause: Documents\<App> was a junction; the app requires a real directory
trigger: Settings > Apps > Advanced options > Move
data_loss: none
time_to_diagnose: ~20 minutes of read-only investigation
```

## 2. What the user asked, and what was actually true

| User's belief | Reality |
|---|---|
| "The app is on D: now and that broke it" | The package was **already back on C:**, and the move-back had **succeeded** — two minutes before they asked |
| "Maybe moving it back will help" | Move-back was irrelevant; it had already happened and changed nothing |
| "The app is broken" | The app was healthy: 8 live processes, zero crash reports, telemetry session status `ok` |

**Lesson:** read the deployment event log before accepting the user's framing. Telling them "you
already moved it back, and that is not the fix" prevents another round of pointless moving.

## 3. Timeline reconstructed from evidence

Local time is UTC+8; log bodies are UTC and have been converted.

| Local time | Event | Evidence source |
|---|---|---|
| day −12 | User ran a self-written script to migrate app data to `D:\<X>Data`, creating **three junctions** | the migration script itself, found at the target drive root |
| day −11 | **The same failure occurred once already** — a session got auto-named after the truncated error text `projectless-thread-directory-must-be-a` | a stale entry still present in the app's `config.toml` |
| 16:39 / 16:50 | App auto-updated twice, both on the C: volume | deployment event log, id 400 |
| 20:46 | User opened a session to troubleshoot an unrelated "archive failed" problem | session rollout filename |
| 22:40:13 | A turn in that session **completed normally**; `turn_context.cwd = "C:\Users\<user>\Documents\<App>\<date>\<slug>"` | session rollout JSONL |
| 22:41:44 | Last write to the D-side package data (frozen after this) | file mtime |
| **22:42:00** | **Move to D: succeeded** | event 400: `MovePackageOperation ... target volume D:` |
| **22:43:42** | **Move back to C: succeeded** | event 400 target volume C:; event 472 queued the D-side folder for deletion |
| 22:43:43–45 | OS relaunched 8 fresh processes | `Get-Process` `StartTime` — proves they are not stale |
| 22:44:24 | Session resumed successfully, `latestTurnStatus=completed` | desktop log `maybe_resume_success` |
| **22:47:54 / 22:47:55 / 23:03:10** | **Three send attempts, three failures** | see section 4 |

Note the alignment: **three user clicks produced exactly three log entries.** That is what turns a
suspicious log line into established causation.

## 4. The decisive error

Found in `%LOCALAPPDATA%\Packages\<PFN>\LocalCache\Local\<App>\Logs\<yyyy>\<MM>\<dd>\<app>-desktop-*.log`:

```text
2026-08-20T14:47:54.747Z error [electron-message-handler] [Composer] submit failed
  cwd=D:\<X>Data\Documents<App>\<date>\<slug>
  errorMessage="Projectless thread directory must be a real directory"
  errorName=Error
```

`[Composer] submit failed` is literally "the message box failed to submit" — an exact match for the
user's symptom.

### Why "junction" and not "missing directory"

Four independent proofs:

1. The error text literally demands a **real directory**.
2. `Get-Item` on `~\Documents\<App>` returned `LinkType=Junction` with a D: target.
3. **The directory existed** — `Test-Path` was true on both the C: and D: forms. That eliminates
   "path not found" and leaves only "it is a link".
4. **Historical recurrence** — the same error had fired eleven days earlier, one day after the
   junctions were created (see timeline).

### Why the move triggered it

Before the move, the app used the `C:\Users\<user>\Documents\<App>\...` path form and worked. After
the move and restart, it used the resolved `D:\<X>Data\Documents<App>\...` form, and validation
rejected it. The move changed **which path form the app resolved**, not whether the data existed.

## 5. The five falsified hypotheses

Every one of these looked plausible. All were wrong. This is the most valuable section of the case.

| Hypothesis | Why it looked right | What killed it |
|---|---|---|
| **Credentials lost** — the browser-engine cookie encryption context broke across the drive move | The credential file was absent on both drives | The config showed API-key authentication (`preferred_auth_method = "apikey"` plus an inline bearer token). This deployment **never had** a credential file. Its absence was normal. |
| **Vendor authentication failure is the cause** (`authentication required for remote plugin catalog`) | Appeared dozens of times in the log | **The identical errors appear in the same day's 08:51 log**, fourteen hours before the move. Long-standing noise. |
| **Network fault** (`net::ERR_CONNECTION_TIMED_OUT` against the vendor's endpoints) | Loud and dense | Same as above — present before the move. Also, this deployment called a third-party API; vendor endpoint reachability was irrelevant. |
| **Stale processes** holding handles into the relocated package | App running but not working — matches intuition | All `StartTime` values were 22:43:43–45, **later** than the 22:43:42 move completion. Fresh processes. |
| **The destroyed junction inside the package data directory is the cause** | It genuinely was destroyed by the move | Its data had been copied intact to the C: side and the app was actively reading and writing it (cookies, preferences updating live). The damage was **real but harmless**. |

### The generalisable technique

> **The loudest, densest error in a log is usually noise. To test whether an error is the cause, get
> a log from the same family recorded before the failure and compare.**

In this case a single pre-failure log eliminated three of the five hypotheses at once.

## 6. Causal chain

```
User asks the app to troubleshoot an unrelated problem
        |
        v
App suggests migrating data / the app itself to another drive
        |
        v
User invokes Settings > Apps > Move, relocating the MSIX package to D:
        |
        v
Something looks wrong; user moves it back to C: within two minutes (succeeds)
        |
        v
The move carried %LOCALAPPDATA%\Packages\<PFN> along, materializing the junction inside it
        |   (real damage, but harmless: data was copied out intact)
        v
After the restart the app resolves the session working directory to the D: real-path form
        |
        v
Validation: "projectless thread directory must be a real directory" -> path traverses a junction -> rejected
        |
        v
[Composer] submit failed. UI fine, processes healthy, no crash - only sending is dead.
```

**Trigger vs cause:**

- **Cause:** `Documents\<App>` had been a junction for twelve days.
- **Trigger:** the MSIX move changed the resolved path form, activating the dormant defect.
- Therefore **moving the package back cannot fix it** — the cause is not where the package lives.

## 7. The three junctions, and the verdict on each

| # | Location | Post-incident state | Verdict |
|---|---|---|---|
| 1 | `~\.<appdir>` | Intact, read/write working | **Safe.** A user environment variable (`<APP>_HOME`) also pointed there — an officially supported redirect. Left untouched. |
| 2 | `~\Documents\<App>` | Intact | **Harmful. The actual culprit.** Removed. |
| 3 | `%LOCALAPPDATA%\Packages\<PFN>\LocalCache\Roaming\<App>` | **Materialized into a plain directory by the move** | Broken but **harmless**. Data was copied to the C: side (~182 MB); the D: side became an orphaned snapshot (~167 MB) frozen at 22:41:44. Left as a cleanup item. |

## 8. The repair, and its verification

Junction #2 was eliminated: the payload was moved back to the original path, making it a real directory.

```
robocopy summary: Dirs  1021 (Copied 1020, Skipped 1 = the root itself)
                  Files 2000 (Copied 2000, FAILED 0)
                  Bytes 115.49 MB (FAILED 0)
                  Elapsed 3 seconds
```

| Verification | Result |
|---|---|
| `~\Documents\<App>` | Real directory (`LinkType` empty) |
| The exact path named in the error | Real directory |
| File count | 2000 = 2000; bytes identical |
| Source directory | Emptied and removed |
| Junction #1 and the `<APP>_HOME` variable | Untouched, as intended |
| System drive free space | Net increase in usage: 115 MB |

The user then reopened the app and repeated the exact failing action. That is the only acceptance
test that counts.

## 9. Rules delivered to the user

1. **Never use the Windows Settings "Move" feature on this app again.** A junction-based layout and
   that feature are mutually exclusive.
2. **Never place a junction inside the package data directory.** It cannot survive a move and may not
   survive a major update.
3. **To keep data off the system drive, use official mechanisms:** the app's own home environment
   variable, or Windows known-folder redirection (right-click Documents → Properties → Location →
   Move), which yields a **real** directory on the target drive.

## 10. Leftover cleanup items (unrelated to the failure)

| Path | Size | Nature |
|---|---|---|
| `<drive>\WindowsApps` | empty shell | Directory skeleton left by the move; needs elevation to remove |
| `<drive>\WpSystem\<SID>\AppData\Local\Packages` | empty shell | Same; needs elevation |
| `<drive>\<X>Data\<App>DataCodex`-style orphan | ~167 MB | The materialized junction's orphaned snapshot. The live copy is on the system drive and working. |

## 11. One paragraph for the next agent

> If a user reports "the app broke after I moved it to another drive": **first check
> `Get-Item <suspected working dir>` for `LinkType`.** If it is `Junction`, you have very likely
> found the cause — many apps require a real directory for their working paths. Moving the package
> back will not help; eliminating the junction will. Meanwhile, tell the user which alternative entry
> point still works so they can keep working today. Do not be misled by the pile of vendor
> authentication and network timeout errors in the log — one comparison against a pre-failure log
> proves they are long-standing noise.
