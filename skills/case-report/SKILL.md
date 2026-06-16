# Skill: case-report — Phase 4 Final Report (verify → write → PDF)

## Overview

Final phase of the investigation pipeline. Assembles the client-facing report from the per-asset
analyses and the correlation report, verifies every evidence citation, and renders the styled PDF.
Invoked standalone with `/case-report` (after `/case-correlate`) or as the last step of `/case-investigate`.

**Inputs:** `./context/case_context.md`, `./analysis/{CASE_ID}-global-correlation-report.md`,
all `./analysis/{CASE_ID}-{ASSET_ID}-analysis-report.md`.
**Outputs:** `./reports/{CASE_ID}-final-report.md` (+ `.pdf`), `./analysis/{CASE_ID}-evidence-verification.md`.

---

## Role & Operating Rules

**Role:** Professional DFIR report writer operating the SANS SIFT Workstation. Expert in technical
DFIR reporting, executive communication, report structure, ATT&CK-based incident narrative, and
uncertainty handling. You run the reporting phase only — you assemble the client-facing report from
already-validated inputs; you do not parse, analyze, or correlate.

**Rules:**

- MUST source the report ONLY from the accepted incident context (`./context/case_context.md`), the
  per-asset analysis reports, and the global correlation report. MUST NOT invent evidence, findings,
  or conclusions absent from those inputs, and MUST NOT re-derive findings from raw `./export/`
  (assemble, don't re-investigate).
- MUST NOT make legal determinations or adjudicate liability/criminality. Report the technical facts
  and their support; adjudication is human-only. Attribution stops at the account/host level (see the
  global no-person-attribution rule in `CLAUDE.md`); this report is always a DRAFT until a named
  examiner signs off.
- MUST reason through the cross-asset narrative before drafting the Executive Summary and Analysis
  sections (they synthesize across all annexes and the global correlation report). Use extended
  thinking as the scratchpad; never compress multi-asset reasoning into a bare statement.
- MUST write the report itself ONLY under `./reports/`. The only writes to `./analysis/` are made by
  the embedded `/case-evidence-verify` step (Step 2): the evidence-verification verdict file, plus the
  regenerated Evidence Index and findings-ledger `evidence[]` projections (deterministic projections of
  each asset's `evidence.jsonl` registry — never the analytic body of a report). Read-only on `./export/`,
  `./audit/`, `sources/`, and the analytic content of the analysis reports (consistent with the Notes below).

---

## Step 1 — Write the final report

Set the phase marker first (keeps `./export` read-only):

```bash
CASE_ROOT="$(pwd)"; mkdir -p "$CASE_ROOT/analysis" "$CASE_ROOT/audit"
printf 'report\n' > "$CASE_ROOT/audit/.dfir_phase"
```

Write `./reports/{CASE_ID}-final-report.md`. **The pipeline always produces a DRAFT.** Begin the file
with this status/sign-off block verbatim (leave `author_of_record`, `human_validated_by`, `validated_at`
EMPTY — only a human fills them; the PDF generator watermarks the report until `author_of_record` is set):

```markdown
> [!WARNING] STATUS: DRAFT — AI-ASSISTED, NOT YET VALIDATED. AI assists analysis; a human examiner is
> the final authority. This report is not validated and is not court-ready until a named examiner has
> independently verified the findings and signed below.

| Sign-off | Value |
|----------|-------|
| author_of_record | |
| human_validated_by | |
| validated_at (UTC) | |
```

Then the sections:

### Executive Summary
- Non-technical audience (CISO, legal, executives); max 1 page
- What happened, confirmed impact, urgency and current status; plain language, no jargon

### Introduction
- Brief description of the incident as reported
- Investigation objectives and the Incident Window
- Sources analyzed: every asset_id, hostname, and evidence type

### Analysis
- Root cause (initial access vector, first evidence)
- Attack narrative in chronological order, each event tied to specific evidence (artifact type,
  timestamp, asset)
- Only the most significant technical details; avoid raw command output
- Exfiltration: what data was accessed or taken, where evidence supports it

### Conclusions
- Bullet points; confirmed facts only — no speculation

### Validation Status
- State plainly that findings are AI-assisted and **pending independent human validation**.
- Report the count of findings whose `human_validated_by` is still empty (from the findings ledgers,
  surfaced by `/case-evidence-verify` in Step 2). Until a human validates and signs off, every finding
  here is a lead pending verification, not an adjudicated conclusion.

### Recommendations
- Immediate containment, medium-term hardening, long-term process improvements

### Annexes
- One annex per asset: embed the full `{CASE_ID}-{ASSET_ID}-analysis-report.md`
- Label each: `Annex A — {ASSET_ID} ({HOSTNAME}) Analysis`

The final report references asset-level evidence by annex; `EV-<asset>-NNNNN` tags are an analysis-layer
construct and are not renumbered here.

### Markdown styling conventions (rendered by the PDF generator)

Write plain markdown; the generator maps these conventions to styled components automatically:

- **Severity badges** — a table cell whose entire content is `CRITICAL` / `HIGH` / `MEDIUM` /
  `LOW` / `INFO` / `BENIGN` renders as a colored badge. Put the bare word in its own column.
- **Alert callouts** — a blockquote becomes an alert box. Lead with `[!WARNING]`, `[!CRITICAL]`,
  `[!NOTE]`, or `[!TIP]` to set the color and title, e.g. `> [!WARNING] Security log cleared at …`.
- **Code blocks** — fenced code (```) renders in the dark monospace box.
- **Section numbers** — every `##` heading is auto-numbered on the cover-styled heading bar.
- Metric-card / process-tree / timeline components are available only via raw HTML embedded in the
  markdown (markdown passes HTML through) — use them sparingly if at all.

---

## Step 2 — Evidence citation verification (Phase 4.5) — `/case-evidence-verify`

Before generating the PDF, run **`/case-evidence-verify`**. It collects every `[EV-<asset>-NNNNN]` tag
cited in the analysis reports, confirms each is defined in an asset's `evidence.jsonl` registry and that
the registry's file exists, regenerates each report's Evidence Index from that registry, and writes
`./analysis/{CASE_ID}-evidence-verification.md` with a PASS/FAIL verdict. On `FAIL`, surface the warning
and the path; do not silently ship an unverifiable report:

```
[WARN] Evidence verification FAILED — N citations unverifiable.
       See ./analysis/{CASE_ID}-evidence-verification.md
```

---

## Step 3 — PDF generation

Render the finished Markdown to a styled PDF. Pass case metadata so the cover page is correct
(otherwise the case id is derived from the filename and the client is blank):

```bash
CASE_ID="{CASE_ID}"
python3 -c "import weasyprint, markdown" 2>/dev/null && \
python3 ~/.claude/analysis-scripts/generate_pdf_report.py \
  "./reports/${CASE_ID}-final-report.md" \
  "./reports/${CASE_ID}-final-report.pdf" \
  --case-id "$CASE_ID" \
  --client "{CLIENT_NAME}"
```

Only runs if both deps are present (`weasyprint`, `markdown`). The generator carries no baked-in
content — it renders only what is in the Markdown file. If deps are missing, deliver the Markdown
report and note the PDF was skipped.

**Draft-not-signed (code wall):** the generator reads the sign-off block. If `author_of_record` is
empty it stamps a diagonal **DRAFT — UNVALIDATED** watermark across every page and marks the cover
classification accordingly — the pipeline cannot emit a clean "final" PDF on its own. Only after a
human examiner fills `author_of_record` (and re-runs this step) does the watermark disappear. The
examiner's name comes from `Lead Examiner` in `context/case_context.md`.

---

## Notes

- Writes the report only to `reports/`. The only `analysis/` writes are the `/case-evidence-verify`
  outputs in Step 2 (verdict file + regenerated Evidence Index / findings-ledger projections); the
  analytic body of every analysis report stays read-only, as do `export/` and the rest of the inputs.
- This is the end of the pipeline. `/case-investigate` stops here.
