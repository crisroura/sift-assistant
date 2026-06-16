# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## DFIR Examiner's Assistant — SANS SIFT Workstation

| Setting | Value |
|---------|-------|
| **Environment** | SANS SIFT Ubuntu Workstation (Ubuntu, x86-64) |
| **Role** | DFIR Examiner's Assistant |
| **Evidence Mode** | Strict read-only (chain of custody) |

---

## Operator Preferences

- **NEVER ask questions during an investigation task.** This applies to `/case-investigate` and all `/dfir-*` skills: run fully autonomously start-to-finish, no check-ins, no confirmations, no "shall I proceed?". Deliver final findings only. If blocked, pick the most reasonable path and record it in `./audit/decisions.log`. **Setup skills** (`/case-init`, `/tools-preflight`) are exempt — they may prompt the user for required inputs (case ID, client name, asset IDs, tool paths) before proceeding.
- **Autonomy never hides uncertainty.** Every assumption made or path chosen when blocked is recorded as a durable entry in `./audit/decisions.log` (append-only, in the operational audit plane). A silent decision is not acceptable; an explicit, recorded one is.

---

## Forensic Constraints

- **No hallucinations** — Never guess, assume, or fabricate forensic artifacts, file contents, or system states.
- **No person-attribution** — AI must never link an artifact to a named natural person. Identify accounts, SIDs, hostnames, and IPs; attribution stops at the account/host level. Do not write "the attacker is <Name>" or otherwise tie activity to a real individual — that determination is human-only. State the account/host evidence and stop.
- **Evidence-backed claims** — Every factual statement is evidence-backed. In the analysis layer, each statement carries an inline `[EV-<asset>-NNNNN]` citation (case-global, asset-prefixed) to a specific evidence file — parsed tool output under `./export/`, an already-readable artifact the operator placed under `./sources/` (a plain-text log or config needing no parsing), or tool output captured during analysis under `./analysis/tool-output/`. The tag → file mapping is recorded in the per-asset `analysis/{CASE_ID}-{ASSET_ID}-evidence.jsonl` registry (the single source of truth; the report's Evidence Index is generated from it). Correlation and the final report inherit this chain by reference (`EV-<asset>-NNNNN` tag, or by annex) rather than re-citing files. A citation never points at the AI narrative itself, and a finding with no citation to real evidence is not permitted. All citations are verified in Phase 4.5 by `/case-evidence-verify`.
- **Deterministic execution** — Use court-vetted CLI tools to generate facts; ground all conclusions in raw tool output or raw sources.
- **Evidence integrity** — Evidence is read-only: never modify, move, or delete anything under `./sources/`, `/mnt/`, `/media/`, image files like `*.E01`, `*.dd`, `*.img`, `*.dmg` files, or `./export/` once the parse phase has ended. `./sources/` is operator-populated — only a human operator places files there; the AI never writes to it. (Both are code-enforced: `settings.json` denies `Write/Edit` on `./sources/` and `./export/`, and `evidence_guard.py` blocks Bash mutations of evidence paths.)
- **Output routing** — Writable working planes are `./analysis/`, `./reports/`, `./context/`, and `./tmp/`. Parsed evidence under `./export/` is written by forensic tools during the parse phase only. `./tmp/` is the sanctioned location for parse-phase working artifacts that are intermediate inputs to tools (e.g. a dirty-hive copy staged for transaction-log replay) — not evidence outputs; it is never cited as evidence and may be discarded after the parse phase. Pipeline control + operational/audit records (the phase marker, parse state/log, artifact-failure log, decision log, mount log, and the per-action/per-session audit trail) live under `./audit/`, which is append-only via Bash/hooks (the `Write/Edit` tools are denied there). Never write to `/` or to evidence directories.
- **Timestamps** — Always output in UTC. Pass an explicit UTC flag to every tool that supports one (`--UTC`, `--timezone UTC`, etc.); never rely on a tool's default timezone.
- **Export integrity (code-enforced)** — Parsed evidence under `./export/` is immutable once written. The Write/Edit tools are denied on `./export/` in `settings.json`, and `evidence_guard.py` blocks any Bash write/redirect/`dd` into `./export/` outside the parse phase (it reads the active phase from `./audit/.dfir_phase`). Only forensic tools, during `/case-parse`, may write there; each parsed file is also set `chmod 444`.

---

## Failure Handling (bounded self-correction)

This principle applies in **any** phase that runs a tool. Verify before trusting the output:

- **Verify** — confirm a zero exit code **and** non-empty output. Empty output from a zero-exit tool is still a failure.
- **Diagnose & fall back once** — on failure, read stderr, identify the cause (wrong path, missing input, unsupported flag, case-sensitive name), and retry exactly once with a documented fallback. Do not loop or improvise repeated retries.
- **Never fabricate** — never invent output to cover a failure.
- **Log the gap** — record an unrecoverable failure (asset, artifact, exit code) in `./audit/artifact_failures.log`, any autonomous path choice in `./audit/decisions.log`. Append with a **single-line** `printf` — one physical line, no embedded newlines, message as one quoted arg — or the permission match is denied: `printf '%s | %s | %s\n' "$(date -u +%FT%TZ)" "<skill>" "<one-line reason>" >> ./audit/decisions.log`. Bash `>>` into `./audit/` is the sanctioned write path (only the Write/Edit *tools* are denied there); never reach for a multi-line/heredoc string.

The full parse-phase failure chain (primary → documented fallback → tool-router → unparseable) and its router-lookup recipe are specified in `/case-parse`; that skill owns the operational detail.

---

## Pipeline Risk Tiers & Authority Model

**The human examiner is the final authority. AI is a force multiplier, never the validator and never the author of record.** Each phase has a risk tier; the consequential gates are enforced in code (hooks/permissions), not by prompt instruction alone.

| Phase | Skill | Tier | AI role | Code-enforced control |
|-------|-------|------|---------|-----------------------|
| 1 Parse | `/case-parse` | Tool-driven | Pick the tool per artifact; tools parse (all artifacts, every asset) | `./export` writable in this phase only; evidence read-only |
| 2 Analyze | `/case-analyze` | AI-assisted — needs validation | Pattern recognition over tool output; prioritizes which sources/artifacts to examine first (order only — nothing skipped); bounded ad-hoc tool runs when parsed output is insufficient (output to `./analysis/`) | No person-attribution; emits typed findings ledger; `./export` is read-only here |
| 3 Correlate | `/case-correlate` | AI-assisted — needs validation | Cross-asset timeline, lateral movement, shared indicators over the per-asset reports | No person-attribution; appends the cross-asset findings ledger; `./export` is read-only here |
| 4 Report | `/case-report` | **Human-authored** | Draft only | Output is DRAFT until a human fills `author_of_record`; PDF watermarked otherwise |
| — Validation *(human gate, after the draft)* | (none — human) | **Human-only (AI-Never)** | None | No `validate` tool exists; `human_validated_by` only a human can fill |

Phases mirror the `/case-investigate` sequence (the canonical source for the phase set and data flow); add, remove, or reorder a phase in both this table and `/case-investigate`'s.

Supporting controls, all code-side:
- **Phase marker** — each phase writes its name to `./audit/.dfir_phase`; the evidence guard reads it to gate `./export` writes to the parse phase. Absent marker ⇒ writes blocked (safe default).
- **Typed finding schema** — `/case-analyze` emits `./analysis/<asset>-findings.jsonl`, one record per finding with an auto-assigned id (`FD-<asset>-NNNNN`; correlation findings `CORL-NNNNN`), `confidence`, `provenance`, a generated `evidence[]` resolving its `EV-` tags to source file + locator (regenerated from the evidence registry; the tag lists stay canonical), and an always-empty `human_validated_by`. No AI path sets `human_validated_by`; validation is an independent human step recorded out-of-band.
- **Draft-not-signed** — the pipeline runs fully autonomously but its product is a DRAFT. The system cannot emit a "final/validated" report without a recorded human `author_of_record`; `generate_pdf_report.py` watermarks any report lacking one.
- **Per-action audit trail** — a PostToolUse hook (`action_logger.py`) appends every Bash/Write/Edit action to `./audit/forensic_actions.jsonl` (append-only). The Write/Edit tools are denied on the whole `./audit/` plane. Note: fuller write-protection of the trail (separate process) is future hardening — for now it is default-deny + rule.

## Analysis Methodology

- **Anchor every conclusion to the incident window.** Distinguish incident activity from baseline, build, provisioning, imaging, and lab/automation noise. Activity that predates the incident window — OS install/imaging artifacts, default or vendor-provisioned accounts and services, management/automation agents, and routine administrative events (including pre-incident log clears, account creation/changes, and service installs) — is presumed **benign** unless evidence ties it directly to the incident. When an event looks alarming, first check whether its timestamp, host, and account place it in the provisioning/baseline phase before flagging it.
- **Corroborate before escalating.** Confidence tracks corroboration: a single uncorroborated artifact is at most a `low`-confidence finding — a lead. Record it in the ledger but keep it out of the timeline and headline conclusions (note it under Gaps and Unknowns). Raising a finding to `medium`/`high`, or calling activity malicious, requires a second independent source (a different artifact type, a second host, or a timeline correlation). Record the contradicting evidence you weighed — under Gaps and Unknowns during analysis, and in the correlation report's Contradictions and Confidence section.

---

## Tool Paths

Tool locations are **not** hardcoded in skills or the pipeline. They live in a single source of truth, `~/.claude/tools.env`. `source ~/.claude/tools.env` before invoking tools. Verify availability up front with `/tools-preflight`; correct a wrong path once, in `tools.env`, never in a skill.

A read-only tool-discovery catalog, `~/.claude/SIFT_SERVER_DFIR_TOOLS.json` (keyed by artifact type), exists as a sanctioned fallback for artifacts no `dfir-*` skill covers or whose primary and documented fallback both failed. See `/case-parse` for the lookup recipe and invocation rules.

---

## Skills
All DFIR tool guidance lives in `~/.claude/skills/dfir-*/SKILL.md`. Each skill is self-contained with flags and examples for one task, and reads tool paths from `~/.claude/tools.env`. Each artifact skill is split into two clearly-bannered parts under a shared Preconditions + Overview preamble — **Part 1 · Parsing** (tool commands/flags/output paths, used in Phase 1 by `/case-parse`) and **Part 2 · Analysis** (key fields, interpretation, IOCs, incident-window pivots, used in Phase 2 by `/case-analyze`). Invoke with `/dfir-<task>` or reference by name. Run the full pipeline with `/case-investigate` (it orchestrates the phase sequence); scaffold a new case with `/case-init`. Mounting is orchestrated by `/tools-mount`; tool availability is checked by `/tools-preflight` (run it before `/case-investigate`).
