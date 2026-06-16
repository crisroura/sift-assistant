# SIFT Assistant

A Claude Code orchestration layer for Digital Forensics and Incident Response (DFIR) on
the SANS SIFT Ubuntu workstation. Provides global behavioral rules, 32 skills (30 granular
`dfir-*` tools plus `case-investigate` and `case-init`), a centralized tool-path file, multi-asset
case templates, and a phased investigation pipeline (parse → analyze → correlate → report).

> Based on [protocol-sift](https://github.com/teamdfir/protocol-sift) by Rob Lee and the
> SANS DFIR team. This repository extends the original with multi-asset, multi-volume case
> support, granular per-task skills split across a four-phase pipeline, artifact failure
> tracking, evidence-backed reporting, and a PreToolUse evidence-integrity guard.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| SANS SIFT Workstation | Ubuntu x86-64, standard SIFT tool set installed |
| Claude Code CLI | `npm install -g @anthropic-ai/claude-code` |
| Anthropic API key | Set after first `claude` run — **never copy** `~/.claude/.credentials.json` |
| Python 3 + WeasyPrint + markdown | `pip3 install weasyprint markdown` — required for PDF report generation |
| dotnet runtime v6 | Pre-installed on SIFT; EZ Tools at `/opt/zimmermantools/` |

---

## Installation

### Method 1 — curl one-liner (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/crisroura/sift-assistant/main/install.sh | bash
```

The script:
- Clones the repo into a temp directory (auto-cleaned on exit)
- Backs up existing `~/.claude/{CLAUDE.md,settings.json,settings.local.json,tools.env,evidence_guard.py,action_logger.py,SIFT_SERVER_DFIR_TOOLS.json}` before overwriting
- Installs global config (incl. `tools.env`, the `evidence_guard.py` PreToolUse hook, the `action_logger.py` PostToolUse hook, and the `SIFT_SERVER_DFIR_TOOLS.json` fallback tool router), all 32 skills, the case template, and the PDF script into `~/.claude/`
- Offers optional WeasyPrint installation (prompt skipped when stdin is piped)

To also install WeasyPrint interactively:
```bash
curl -fsSL https://raw.githubusercontent.com/crisroura/sift-assistant/main/install.sh -o /tmp/install.sh
bash /tmp/install.sh
```

### Method 2 — Clone the repo

```bash
git clone --depth=1 https://github.com/crisroura/sift-assistant.git
cd sift-assistant
bash install.sh
```

### Method 3 — Download ZIP

1. **Code → Download ZIP** on GitHub
2. Extract and run:
   ```bash
   unzip sift-assistant-main.zip && cd sift-assistant-main
   bash install.sh
   ```

---

## Repository Structure

```
sift-assistant/
├── README.md
├── install.sh
├── global/
│   ├── CLAUDE.md                      ← role, constraints, methodology, Skills reference
│   ├── settings.json                  ← permissions + PreToolUse evidence guard + audit Stop hook
│   ├── settings.local.json            ← machine-local sudo/apt overrides
│   ├── tools.env                      ← single source of truth for tool paths ($VOLATILITY3, $EZ*)
│   ├── evidence_guard.py              ← PreToolUse hook: blocks writes/deletes to evidence
│   ├── action_logger.py              ← PostToolUse hook: appends every action to audit/forensic_actions.jsonl
│   └── SIFT_SERVER_DFIR_TOOLS.json    ← fallback tool router: artifact→installed-tool catalog (parse phase)
├── skills/
│   ├── case-investigate/SKILL.md           ← thin pipeline orchestrator (chains the phase skills)
│   ├── dfir-triage/SKILL.md           ← Phase 0 (advisory): evidence triage & prioritization
│   ├── case-parse/SKILL.md            ← Phase 1: mount + run all parsers → export/
│   ├── case-analyze/SKILL.md          ← Phase 2: per-asset evidence-tagged analysis reports
│   ├── case-correlate/SKILL.md        ← Phase 3: cross-asset correlation report
│   ├── case-report/SKILL.md           ← Phase 4: final report + evidence verify + PDF
│   ├── case-evidence-verify/SKILL.md  ← Phase 4.5: citation verification
│   ├── case-init/SKILL.md             ← multi-asset case directory scaffold
│   ├── tools-preflight/SKILL.md        ← Phase-0 tool availability check (run before a case)
│   ├── tools-mount/                    ← mount orchestrator + gen_mount_commands.sh (EWF + raw; validate→identify→emit sudo mount→verify)
│   ├── tools-mount-e01/SKILL.md        ← ewfmount EWF/E01 images (low-level reference)
│   ├── tools-mount-ntfs/SKILL.md       ← loop-mount NTFS partitions (low-level reference)
│   ├── tools-mount-vss/SKILL.md        ← VSS access on Linux (vss_carver/vshadowmount)
│   ├── dfir-sleuthkit-file-recovery/  ← fls, icat, tsk_recover, mactime
│   ├── dfir-file-carving/             ← bulk_extractor, photorec, foremost
│   ├── dfir-mft/                      ← MFTECmd ($MFT + UsnJrnl)
│   ├── dfir-evtx/                     ← EvtxECmd + key Event ID reference
│   ├── dfir-registry/                 ← RECmd (Kroll batch) + RegRipper
│   ├── dfir-prefetch/                 ← pref.pl + prefetch.py (PECmd absent on SIFT)
│   ├── dfir-amcache/                  ← AmcacheParser
│   ├── dfir-recentfilecache/          ← RecentFileCacheParser (Win7 RecentFileCache.bcf)
│   ├── dfir-shimcache/                ← AppCompatCacheParser
│   ├── dfir-srum/                     ← SrumECmd
│   ├── dfir-scheduled-tasks/          ← xmllint (Task XML) + jobparser (legacy .job)
│   ├── dfir-lnk-jumplists/            ← LECmd + JLECmd
│   ├── dfir-shellbags/                ← SBECmd
│   ├── dfir-recyclebin/               ← RBCmd ($Recycle.Bin $I/$R)
│   ├── dfir-browser/                  ← SQLECmd (Chrome/Edge/Firefox) + WxTCmd
│   ├── dfir-strings/                  ← bstrings + strings
│   ├── dfir-plaso-timeline/           ← log2timeline.py, psort.py, image_export.py
│   ├── dfir-memory-volatility/        ← Volatility 3 (all plugins)
│   └── dfir-yara/                     ← YARA rules and IOC sweeps (python3-yara)
├── case-templates/
│   ├── CLAUDE.md                      ← reference-only per-case template
│   └── context/
│       └── case_context.md            ← case intel template (evidence, IOCs, timeline)
└── analysis-scripts/
    ├── generate_pdf_report.py         ← Markdown → HTML → WeasyPrint PDF generator (CLI)
    └── samples/
        └── baseline-memory-sample.html ← reference-only sample (never emitted as a deliverable)
```

---

## How It Works

### Global config (`~/.claude/CLAUDE.md`)

Sets Claude's role as DFIR Orchestrator with strict evidence integrity rules:
- **No hallucinations** — all conclusions grounded in raw tool output only
- **Evidence-backed claims** — every factual statement carries an inline `[EV-NNNNN]` citation to a real `export/` file (verified in Phase 4.5)
- **Evidence read-only** — never modifies `/cases/`, `/mnt/`, `/media/`; only forensic tools write to `./export/`
- **Output routing** — analysis and reports go to `./analysis/`, `./reports/`, `./context/`
- **Bounded self-correction** — verify each tool (exit code + non-empty output); on failure, retry once with the documented fallback, then log the gap
- **Autonomous** — no check-ins; assumptions and deviations logged to the report's Gaps section
- **UTC timestamps** — always, with explicit UTC flags passed to every tool that supports one


### Skills (`~/.claude/skills/dfir-*/SKILL.md`)

Each skill is self-contained: tool path, key flags, usage example, and analysis tips
for one specific DFIR task. Each artifact skill is organized into two bannered parts —
**Part 1 · Parsing** (used by `/case-parse` in Phase 1) and **Part 2 · Analysis** (used
by `/case-analyze` in Phase 2) — under a shared Preconditions + Overview preamble. Claude
reads the appropriate skill when it needs to use that tool. Skills are invoked by name
(e.g. `/dfir-evtx`) or referenced automatically by the `case-investigate` pipeline.

### Permissions (`~/.claude/settings.json`)

`Bash(*)` is allowed so Claude never pauses for permission mid-investigation; the **deny list is
the real boundary**. Write/Edit are scoped to `./analysis/*`, `./reports/*`, `./context/*` and
explicitly denied on `sources/**`, `./export/**`, and the operational `./audit/**` plane; parsed
evidence in `./export/` is written only by forensic tools (bash), never the Write/Edit tools, and the
`./audit/` control + audit records are written only by skills (bash) and the hooks.

Deny list blocks destructive commands (`rm -r*`, `shred`, `truncate`, `mkfs`, `wipefs`, `fdisk`,
`parted`, `sgdisk`, `dd`) and all network egress (`wget`, `curl`, `ssh`, `scp`, `rsync`, `nc`,
`ncat`, `netcat`, `telnet`, `ftp`, `WebFetch`).

Two hooks back this up:
- **PreToolUse** (`evidence_guard.py`) — blocks any Bash command that would write to or delete
  `sources/`, `/mnt`, `/media`, or `*.E01` (the semantic chain-of-custody backstop).
- **Stop** — appends session metadata (session id, cwd, transcript path) to
  `./audit/forensic_audit.log`.

---

## Case Directory Structure

Each case follows this layout, supporting any number of assets:

```
/cases/CLIENT-IR-YYYY-NNN/
  CLAUDE.md                          ← @context/case_context.md + @case-investigate skill
  context/
    case_context.md                  ← investigator-maintained: evidence inventory,
                                        network topology, accounts, IOCs, timeline, notes
  sources/
    <asset_id>/
      base-dc-cdrive.E01             ← disk image (read-only, never modified)
      <hostname>.img                 ← memory image (read-only, never modified)
      e01-base-dc-cdrive/            ← ewfmount FUSE point, named from the image (created at mount time)
      mnt-001-base-dc-cdrive/        ← filesystem volume mount, named mnt-NNN-<imgbase> (every NTFS/FAT/exFAT partition)
      mnt-001-vss-NNN-base-dc-cdrive/ ← VSS snapshot mount (created at mount time)
  export/                            ← parsed evidence ONLY (tool output; chmod 444, immutable)
    <asset_id>/
      mnt-001-base-dc-cdrive/        ← one subtree per Windows volume (mnt-001-<imgbase>, mnt-002-<imgbase>, ...)
        mft/ usnjrnl/ evtx/ registry/ prefetch/ amcache/ shimcache/
        srum/ lnk/ shellbags/ browser/ yara/
      memory/   timeline/            ← asset-level (Volatility / plaso), created once per asset
      ← per-volume subdirs created by case-parse at parse time
  analysis/
    {case_id}-{asset_id}-analysis-report.md   ← one per asset
    {case_id}-global-correlation-report.md
  reports/
    {case_id}-final-report.md
    {case_id}-final-report.pdf
  audit/                             ← operational/control plane (not evidence, not analysis output)
    .dfir_phase                      ← pipeline phase marker (gates ./export writes)
    artifact_failures.log            ← parse failures / unparseable artifacts
    forensic_actions.jsonl           ← per-action audit trail (PostToolUse hook)
    forensic_audit.log               ← per-session record (Stop hook)
    <asset_id>/
      parse_state.txt                ← per-volume, per-artifact status
      parse.log                      ← per-asset parse progress log
```

---

## Starting an Investigation

### 1. Create the case directory structure

Create the case directory, launch Claude from inside it, and invoke the case-init skill:

```bash
cd /cases
mkdir ACME-IR-2026-001        # the case directory name becomes the case_id
cd ACME-IR-2026-001
claude
# Prompt: /case-init
# case-init detects the current directory as the case root and confirms before scaffolding.
# Provide: client name, and asset IDs (e.g. dc01 rd01) — or leave assets blank to add later.
```

Or create it manually:

```bash
CASE="ACME-IR-2026-001"
ASSETS="dc01 rd01"

mkdir -p /cases/${CASE}/{analysis,reports,context,audit}
for A in $ASSETS; do
  mkdir -p /cases/${CASE}/sources/${A} /cases/${CASE}/export/${A} /cases/${CASE}/audit/${A}
done

cp ~/.claude/case-templates/CLAUDE.md         /cases/${CASE}/CLAUDE.md
cp ~/.claude/case-templates/context/case_context.md /cases/${CASE}/context/
```

### 2. Fill in case intelligence

Edit `/cases/${CASE}/context/case_context.md`:
- **Incident Window (UTC)** — the analytical anchor; activity outside it is presumed baseline unless tied to the incident
- **Sources Inventory** — one row per asset: hostname, role, disk image path, memory image path
- **Network Topology** — subnets and key hosts
- **Domain Accounts** — DA, service accounts, local admins
- **Known IOCs** — one indicator per line in the typed `ioc` block (`hash:`/`ip:`/`domain:`/…) so the pipeline greps them deterministically
- **Incident Timeline** — known events with timestamps (updated as analysis progresses)
- **Case Notes** — scope decisions, client constraints

### 3. Drop evidence and launch

```bash
# Copy or symlink evidence files into sources/<asset_id>/
cp /media/evidence/dc01.E01 /cases/${CASE}/sources/dc01/

# Launch Claude from the case root
cd /cases/${CASE} && claude

# Start the full pipeline
# Prompt: /case-investigate
```

### 4. Investigation pipeline

The `case-investigate` skill is a thin orchestrator that chains four phase skills (each also runnable
standalone for resume/debug):

| Phase | Skill | What happens |
|-------|-------|-------------|
| **1 — Parse** | `/case-parse` | Bootstraps from `case_context.md`, mounts each asset via `/tools-mount`, runs all parsers with bounded parallelism (`MAX_PARALLEL`), tracks status in `parse_state.txt` |
| **2 — Analyze** | `/case-analyze` | Reads `export/<asset_id>/`; writes one evidence-tagged analysis report per asset, anchored to the Incident Window and case IOC block; never modifies export files |
| **3 — Correlate** | `/case-correlate` | Cross-references all asset reports; writes the global correlation report |
| **4 — Report** | `/case-report` | Writes the final report, runs `/case-evidence-verify` (Phase 4.5), generates the PDF if WeasyPrint is available |

---

## File-by-File Reference

### global/CLAUDE.md → `~/.claude/CLAUDE.md`

Global system prompt. Sets the DFIR Orchestrator role, evidence integrity rules,
autonomous operation preference, and a one-liner pointing Claude to the `dfir-*` skills.

```bash
cp global/CLAUDE.md ~/.claude/CLAUDE.md
```

---

### global/settings.json → `~/.claude/settings.json`

Permission policy plus the PreToolUse evidence guard and the audit Stop hook.

Write/Edit allowed: `./analysis/*`, `./reports/*`, `./context/*` (and explicitly denied on
`sources/**`, `./export/**`, `./audit/**`). `./export/` is written only by forensic tools (bash),
never the Write/Edit tools; `./audit/` holds the phase marker, parse state/logs, and the hook-written
audit trail.

```bash
cp global/settings.json ~/.claude/settings.json
```

---

### global/settings.local.json → `~/.claude/settings.local.json`

Machine-local overrides (sudo apt, psort.py). Keep minimal.

```bash
cp global/settings.local.json ~/.claude/settings.local.json
```

---

### global/tools.env → `~/.claude/tools.env`

Single source of truth for tool paths (`$VOLATILITY3`, `$EZ*`, `$REGRIPPER`, fallbacks). Skills and
the pipeline `source` it; correct a wrong path here once, never in a skill. Verify with `/tools-preflight`.

```bash
cp global/tools.env ~/.claude/tools.env
```

---

### global/evidence_guard.py → `~/.claude/evidence_guard.py`

PreToolUse hook (Bash matcher). Reads the tool call on stdin and `exit 2` blocks any command that
would write to or delete evidence (`sources/`, `/mnt`, `/media`, `*.E01`); evidence reads are allowed.

```bash
cp global/evidence_guard.py ~/.claude/evidence_guard.py
```

---

### global/action_logger.py → `~/.claude/action_logger.py`

PostToolUse hook (Bash|Write|Edit matcher) referenced by `settings.json`. Appends every action to the
append-only `./audit/forensic_actions.jsonl` trail (ts, session, phase, tool, target, outcome).

```bash
cp global/action_logger.py ~/.claude/action_logger.py
```

---

### global/SIFT_SERVER_DFIR_TOOLS.json → `~/.claude/SIFT_SERVER_DFIR_TOOLS.json`

Read-only fallback tool router: a machine-readable catalog mapping each forensic artifact type to an
installed SIFT command. Consulted by `/case-parse` only as a third-tier fallback (a skill's primary
and documented fallback both failed) or for artifact types no `dfir-*` skill covers. `tools.env`
remains the single source of truth for skill-mapped tools; router tools are a sanctioned exception
invoked by their listed `command` path.

```bash
cp global/SIFT_SERVER_DFIR_TOOLS.json ~/.claude/SIFT_SERVER_DFIR_TOOLS.json
```

---

### skills/ → `~/.claude/skills/`

32 skills installed individually by the installer (30 `dfir-*` plus `case-investigate` and `case-init`).
Each is self-contained and reads tool paths from `~/.claude/tools.env`. Companion files (e.g.
`tools-mount/gen_mount_commands.sh`) are copied alongside their `SKILL.md`.

```bash
# Installer handles this. Manual copy example:
mkdir -p ~/.claude/skills/dfir-evtx
cp skills/dfir-evtx/SKILL.md ~/.claude/skills/dfir-evtx/SKILL.md
```

---

### case-templates/CLAUDE.md → `/cases/<CASE>/CLAUDE.md`

Reference-only template. Contains only the case metadata table and two `@` references:
- `@./context/case_context.md` — loads case-specific intel
- `@~/.claude/skills/case-investigate/SKILL.md` — loads the investigation pipeline

No commands, tool paths, or case-specific data belong in this file.

```bash
cp ~/.claude/case-templates/CLAUDE.md /cases/<CASE>/CLAUDE.md
# Edit only: Case ID, Client, Case Root
```

---

### case-templates/context/case_context.md → `/cases/<CASE>/context/case_context.md`

The investigator-maintained case intelligence file. Sections:
1. Incident Window (UTC) — the analytical anchor
2. Sources Inventory (asset table)
3. Network Topology
4. Domain Accounts
5. Known IOCs (typed, greppable `ioc` block)
6. Incident Timeline (UTC)
7. Case Notes

This is the only file that should contain case-specific facts, IOCs, and timeline entries.
Claude reads it at the start of every session and references it throughout analysis.

---

### analysis-scripts/generate_pdf_report.py

Markdown -> HTML -> WeasyPrint PDF generator (CLI: `generate_pdf_report.py <md> <pdf> --case-id ID --client NAME`).
Installed to `~/.claude/analysis-scripts/` by the installer. The `/case-report` phase calls it at the end of
Phase 4 if WeasyPrint and markdown are available. It contains no baked-in content; the old sample lives,
non-executable, in `analysis-scripts/samples/`. Plain markdown is auto-enriched into styled components
(severity badges, `[!TYPE]` alert callouts, numbered sections, dark code blocks); fonts are system-only
(no remote `@import`) so rendering works on an air-gapped host.

```bash
pip3 install weasyprint markdown          # add --break-system-packages on PEP 668 systems, or use a venv
# If WeasyPrint's native libs are missing:
sudo apt-get install -y python3-gi python3-gi-cairo gir1.2-gtk-3.0 libpango-1.0-0
```

---

## Manual Install (copy-paste)

```bash
#!/bin/bash
set -e

# Global config
mkdir -p ~/.claude
cp global/CLAUDE.md ~/.claude/CLAUDE.md
cp global/settings.json ~/.claude/settings.json
cp global/settings.local.json ~/.claude/settings.local.json
cp global/tools.env ~/.claude/tools.env
cp global/evidence_guard.py ~/.claude/evidence_guard.py   # PreToolUse hook referenced by settings.json
cp global/action_logger.py ~/.claude/action_logger.py     # PostToolUse hook referenced by settings.json
cp global/SIFT_SERVER_DFIR_TOOLS.json ~/.claude/SIFT_SERVER_DFIR_TOOLS.json  # parse-phase fallback tool router

# Skills
for skill in \
  tools-preflight tools-mount \
  tools-mount-e01 tools-mount-ntfs tools-mount-vss \
  dfir-sleuthkit-file-recovery dfir-file-carving \
  dfir-mft dfir-evtx dfir-registry dfir-prefetch \
  dfir-amcache dfir-recentfilecache dfir-shimcache dfir-srum \
  dfir-scheduled-tasks dfir-lnk-jumplists dfir-shellbags \
  dfir-recyclebin dfir-browser dfir-strings \
  dfir-plaso-timeline dfir-memory-volatility \
  dfir-yara case-evidence-verify \
  dfir-triage case-parse case-analyze case-correlate case-report \
  case-investigate case-init; do
  mkdir -p ~/.claude/skills/${skill}
  cp skills/${skill}/SKILL.md ~/.claude/skills/${skill}/SKILL.md
done

# Companion script shipped with tools-mount
cp skills/tools-mount/gen_mount_commands.sh ~/.claude/skills/tools-mount/gen_mount_commands.sh

# Case template and analysis scripts
mkdir -p ~/.claude/case-templates/context ~/.claude/analysis-scripts
cp case-templates/CLAUDE.md ~/.claude/case-templates/CLAUDE.md
cp case-templates/context/case_context.md ~/.claude/case-templates/context/case_context.md
cp analysis-scripts/generate_pdf_report.py ~/.claude/analysis-scripts/generate_pdf_report.py

pip3 install weasyprint markdown   # add --break-system-packages on PEP 668 systems, or use a venv

echo "Done."
```

---

## Chain of Custody

- Claude never writes to `sources/`, `/mnt/`, `/media/`, or any evidence directory
- Enforced in layers: read-only mounts (`ro`), `Write`/`Edit` scoped + denied on `sources/**`, the
  hardened Bash deny list, and the `evidence_guard.py` PreToolUse hook that blocks any command
  writing to or deleting evidence
- Mount points are created inside `sources/<asset_id>/` at mount time; evidence files are never modified
- All parsed output lands in `export/<asset_id>/<part>/` — written only by forensic tools, never modified afterward
- Analysis and report files are written to `analysis/` and `reports/` only
- The `Stop` hook appends session metadata (session id, cwd, transcript path) to `./audit/forensic_audit.log` after every session
- Image integrity should be verified before analysis: `ewfverify /cases/<CASE>/sources/<asset_id>/*.E01`

---

## What Is NOT Included

| Excluded | Reason |
|----------|--------|
| `~/.claude/.credentials.json` | Anthropic API key — never share |
| `~/.claude/history.jsonl` | Session command history — machine specific |
| `~/.claude/projects/` | Session memory — case specific |
| Evidence files (`*.E01`, `*.img`) | Read-only evidence — never copy or share |
| Case analysis output | Case specific — lives in `/cases/<CASE>/` |
