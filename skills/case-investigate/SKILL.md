# Skill: case-investigate — DFIR Pipeline Orchestrator

## Overview

Runs a complete multi-asset DFIR investigation by chaining the phase-skills in order. Each
phase is also runnable on its own (for resume, re-run, or debugging); `case-investigate` simply sequences
them and passes through flags. All output lands in the case directory; source evidence is never
modified.

**Before starting:** populate `./context/case_context.md` with every asset ID, evidence path, the
Incident Window, and known IOCs. Verify tools once with `/tools-preflight`.

| Phase | Skill | Reads | Writes |
|-------|-------|-------|--------|
| 1 — Parse | `/case-parse` | `sources/`, `context/` | `export/` (parsed evidence — all artifacts on every asset), `audit/` (parse_state, logs) |
| 2 — Analyze | `/case-analyze` | `export/`, `context/` | per-asset reports + findings ledgers (prioritizes which assets, sources, and artifacts to examine first) |
| 3 — Correlate | `/case-correlate` | per-asset reports | global correlation report + cross-asset ledger |
| 4 — Report | `/case-report` | correlation + asset reports | DRAFT final report (MD + PDF) + evidence/validation verification |

This is the data-flow view. Each phase's risk tier, AI role, and code-enforced control live in the authority-model table in `global/CLAUDE.md` (the canonical governance view). Add, remove, or reorder a phase in both tables.

Authority model (enforced by the controls below, not just this prompt): **the human examiner is the
final authority.** The pipeline runs autonomously but its product is a DRAFT — findings carry an empty
`human_validated_by` and the report an empty `author_of_record`; the PDF stays watermarked DRAFT —
UNVALIDATED until a human signs off. There is no AI "validate" step (AI Never). Each phase writes its
name to `./audit/.dfir_phase`, which the evidence guard uses to keep `./export` writable only during
parse. Every action is appended to `./audit/forensic_actions.jsonl` by the audit hook.

---

## Flags

| Flag | Behaviour |
|------|-----------|
| *(none)* | Run all phases (Parse → Analyze → Correlate → Report). Parsing resumes intelligently (skips `OK` artifacts). |
| `--analyze-only` | Skip Parse; run Analyze → Correlate → Report against existing `export/` data. |
| `--report-only` | Run the Report phase only (re-verify citations and regenerate the report/PDF). |
| `--reparse <artifact>` | Pass through to `/case-parse` (re-run one artifact type for all assets). |
| `--force` | Pass through to `/case-parse` (delete all `parse_state.txt` and re-parse everything). |

---

## Sequence

1. **Parse** — unless `--analyze-only` or `--report-only`: invoke **`/case-parse`** (forward
   `--force` / `--reparse <artifact>`). It mounts every asset via `/tools-mount`, runs all parsers
   with bounded parallelism, and tracks status in `parse_state.txt`. Parse is comprehensive — every
   artifact on every asset; prioritization is an analysis concern, not a parse-time filter. When it
   finishes, review the failure summary before continuing.
2. **Analyze** — unless `--report-only`: invoke **`/case-analyze`**. One evidence-tagged analysis
   report per asset (plus the typed findings ledger), anchored to the Incident Window and the case
   IOC block. Analyze derives a working hypothesis from the case context and prioritizes — in three
   tiers — which assets, then sources, then artifact classes to examine first (order only — every asset
   and parsed artifact is still reviewed).
3. **Correlate** — unless `--report-only`: invoke **`/case-correlate`**. Cross-asset timeline,
   lateral movement, shared indicators; appends cross-asset findings to the ledger.
4. **Report** — always: invoke **`/case-report`**. Writes the DRAFT final report, runs
   `/case-evidence-verify` (citation + validation-status check), and generates the PDF (watermarked
   DRAFT — UNVALIDATED until a human fills `author_of_record`) if WeasyPrint is present.

Run the phases strictly in order — each consumes the previous phase's output from the case
directory, and each sets `./audit/.dfir_phase` so the evidence guard gates `./export` writes to
the parse phase. If a phase surfaces a blocking problem (e.g. no asset mounted in Parse, or an evidence
verification `FAIL` in Report), surface it rather than pressing on silently.

---

## Notes

- The pipeline communicates only through the case directory, so any phase can be re-run
  independently without re-running the others.
- Tool paths come from `~/.claude/tools.env`; availability is checked by `/tools-preflight`.
- Never use Write/Edit on `export/` — only the forensic tools (in `/case-parse`) write there. This is
  code-enforced (settings.json deny + the phase-aware `evidence_guard.py`).
