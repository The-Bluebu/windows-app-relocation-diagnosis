# Changelog

All notable changes to this skill are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-08-20

Initial release, distilled from a real incident: an MSIX application whose message-sending broke
after the package was moved to another drive and back. The actual cause was a directory junction on
the documents folder that predated the move by twelve days.

### Added

- `SKILL.md` — 7-step read-only diagnostic workflow, repair procedure, 11 documented pitfalls,
  verification checklist, and reporting requirements.
- `scripts/Diagnose-AppRelocation.ps1` — read-only collector covering environment facts, Appx
  package state, deployment move history, live processes, reparse point scanning across four
  regions, migration-script discovery on non-system drives, log location discovery, and signature
  error scanning. Degrades gracefully when a cmdlet is blocked by policy.
- `scripts/Repair-JunctionToRealDirectory.ps1` — idempotent junction-to-real-directory repair with
  four asserted preconditions (app not running, path is a reparse point, no nested reparse points,
  sufficient free space), `-DryRun` support, non-recursive link deletion, correct robocopy exit-code
  handling, and independent post-repair verification.
- `references/case-study-msix-junction-conflict.md` — the full worked case including the five
  falsified hypotheses and the evidence that killed each one.
- `references/powershell-pitfalls.md` — the PowerShell 5.1 non-ASCII/BOM parser trap, constrained
  mode cmdlet substitutions, and robocopy exit-code semantics.

### Design decisions

- **Scripts are ASCII-only.** Under Windows PowerShell 5.1 a non-ASCII `.ps1` without a BOM is
  decoded with the ANSI code page, producing parser errors whose line numbers do not match the file.
  ASCII-only means the scripts run regardless of the consumer's PowerShell edition or code page.
- **Reparse points are scanned, not guessed.** Rather than shipping a hardcoded list of paths that
  only fits one application, the diagnostic scans four regions for reparse points and flags the
  known OS legacy per-user junctions so they can be ignored.
- **OS legacy junctions are detected by attributes, not by name.** Windows per-user compatibility
  junctions always carry `Hidden` + `System`. A name list alone misses localized folder names (a
  Chinese-locale Start Menu junction was reported as a genuine finding until this was fixed).
- **Browser-engine storage journals are excluded from log discovery.** Chromium and Electron embed
  binary LevelDB journals named `*.log` under `Local Storage`, `Session Storage`, `shared_proto_db`
  and similar directories. Without an exclusion filter, "the newest .log file" resolves to a binary
  journal instead of the application's diagnostic log.
- **Preconditions are asserted in code.** A recursive junction delete or a `-ne 0` robocopy check is
  a data-loss event; the scripts do not rely on the operator remembering.

### Validation

Both scripts were executed end to end on Windows 11 build 26200 under Windows PowerShell 5.1
(Desktop edition, GB2312 ANSI code page) against a live MSIX application, and verified for:

- 100% ASCII byte content
- Clean parse via `[System.Management.Automation.Language.Parser]::ParseFile`
- Correct behaviour when `Get-CimInstance`, `Get-Volume` and `Get-NetTCPConnection` are denied
- A real repair: 2000 files / 115.49 MB relocated with `robocopy` reporting 0 failures, followed by
  confirmation that the signature error disappeared from all subsequently written application logs

