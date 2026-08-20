# windows-app-relocation-diagnosis

An [Agent Skill](https://code.claude.com/docs/en/skills) for diagnosing and repairing Windows
applications that break after being moved to another drive — or after their data was relocated with
directory junctions.

[中文说明](README.zh-CN.md) · MIT licensed

---

## The problem this solves

A user moves an app to another drive to free up space on `C:`. The app stops working. They move it
back. It still does not work.

The reason is almost never the drive letter. It is usually a **directory junction** created months
earlier by a data-migration script. Many applications validate that a key working directory is a
*real* directory and reject reparse points outright — so the defect sits dormant until a move
operation changes which path form the app resolves, and suddenly a core action fails with something
like:

```
error [electron-message-handler] [Composer] submit failed
  cwd=D:\AppData\DocumentsApp\2026-08-20\some-thread
  errorMessage="Projectless thread directory must be a real directory"
```

Moving the package back cannot fix that. Removing the junction can.

## What the skill gives an agent

- A **7-step read-only diagnostic workflow** that establishes package state, reconstructs the move
  history from Windows deployment event logs, rules out stale processes, enumerates every relevant
  reparse point, and mines the application's own logs for the exact error string.
- A **noise-exclusion method** that reliably separates signal from the long-standing errors that
  dominate most application logs: compare against a pre-failure baseline from the same log family.
- **Two hardened scripts** — a read-only diagnostic collector and an idempotent junction-to-real-
  directory repair with four asserted preconditions.
- **Eleven documented pitfalls**, three of which cause a second round of data loss if you get them
  wrong.

## Installation

### Claude Code / agents that read a skills directory

```bash
git clone https://github.com/B-TQ/windows-app-relocation-diagnosis.git \
  ~/.claude/skills/windows-app-relocation-diagnosis
```

Common skill roots, depending on your harness:

| Harness | Path |
|---|---|
| Claude Code (personal) | `~/.claude/skills/<skill-name>/` |
| Claude Code (project) | `<repo>/.claude/skills/<skill-name>/` |
| Agent frameworks using the open format | `~/.agents/skills/<skill-name>/` |

The only hard requirement of the format is that the directory contains a `SKILL.md` whose YAML
frontmatter carries a `name` and a single-line `description`. Everything else — `scripts/`,
`references/` — is progressive disclosure the agent loads only when needed.

### Manual

Copy the directory into your skills root. No build step, no dependencies.

## Using the scripts directly

You do not need an agent to get value out of the scripts.

### Diagnose (read-only, safe to run anytime)

```powershell
# Everything matching "codex" in package name, process name and logs
.\scripts\Diagnose-AppRelocation.ps1 -AppNamePattern 'codex'

# Add your own suspect paths, and write a transcript to share
.\scripts\Diagnose-AppRelocation.ps1 -AppNamePattern 'myapp' `
    -ExtraPaths "$env:USERPROFILE\Documents\MyApp", "$env:USERPROFILE\.myapp" `
    -OutFile .\diagnosis.txt
```

The script performs no writes other than the optional transcript, and degrades gracefully when a
cmdlet is blocked by policy instead of failing outright.

### Repair (converts a junction back into a real directory)

```powershell
# Always preview first
.\scripts\Repair-JunctionToRealDirectory.ps1 `
    -LinkPath "$env:USERPROFILE\Documents\MyApp" `
    -ProcessPattern '^(myapp|MyApp)$' -DryRun

# Then execute
.\scripts\Repair-JunctionToRealDirectory.ps1 `
    -LinkPath "$env:USERPROFILE\Documents\MyApp" `
    -ProcessPattern '^(myapp|MyApp)$'
```

Behaviour:

- Refuses to run while any process matching `-ProcessPattern` is alive.
- Refuses if the path is not a reparse point — and exits `0`, because that is the desired end state
  (the script is idempotent and safe to re-run).
- Refuses if nested reparse points exist inside the payload, since `robocopy` would follow them.
- Refuses if free space is below payload size plus headroom.
- Deletes the link **non-recursively**, so the real data is never at risk.
- Verifies the result, then removes the emptied source directory.

## Design notes

**Scripts are ASCII-only by design.** Under Windows PowerShell 5.1, a `.ps1` containing non-ASCII
characters and no BOM is decoded with the ANSI code page, which produces parser errors whose line
numbers do not match the file. Keeping the scripts ASCII-only means they run correctly regardless of
the consumer's PowerShell edition, code page, or Git checkout settings. See
[`references/powershell-pitfalls.md`](references/powershell-pitfalls.md).

**Preconditions are asserted, not documented.** Every destructive step is gated in code. A wrong
`robocopy` exit-code test or a recursive junction delete is a data-loss event, so the scripts do not
rely on the operator remembering.

## Repository layout

```
.
├── SKILL.md                                     # the skill an agent loads
├── README.md / README.zh-CN.md
├── LICENSE
├── CHANGELOG.md
├── scripts/
│   ├── Diagnose-AppRelocation.ps1               # read-only collector
│   └── Repair-JunctionToRealDirectory.ps1       # idempotent repair
└── references/
    ├── case-study-msix-junction-conflict.md     # full worked case
    └── powershell-pitfalls.md                   # environment traps
```

## Scope

**Applies to:** Windows 10/11; MSIX/Store applications moved via Settings → Apps → Advanced options
→ Move; any application whose data was relocated with `mklink /J`, `New-Item -ItemType Junction`,
`robocopy /MOVE` plus a link, or a similar scheme; known-folder redirection questions.

**Does not apply to:** Linux/macOS symlink issues, container volume mounts, or MSI/EXE installers
relocated by editing registry paths (a different failure class with different evidence).

## Contributing

Additional real-world cases are the most valuable contribution — especially applications with a
different path-validation error string. Please include the exact error text, the reparse point
layout, and the log path where the error was found, with personal identifiers removed.

## License

MIT. See [LICENSE](LICENSE).
