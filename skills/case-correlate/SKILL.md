# Skill: case-correlate — Phase 3 Cross-Asset Correlation

## Overview

Third phase of the investigation pipeline. Reads every per-asset analysis report and builds a
single cross-asset picture of the incident. Invoked standalone with `/case-correlate` (after
`/case-analyze`) or as the third step of `/case-investigate`.

**Inputs:** all `./analysis/{CASE_ID}-{ASSET_ID}-analysis-report.md` files, `./context/case_context.md`.
**Output:** `./analysis/{CASE_ID}-global-correlation-report.md`.

---

## Method

Set the phase marker first (keeps `./export` read-only for this phase):

```bash
CASE_ROOT="$(pwd)"; CASE_ID="{CASE_ID}"
mkdir -p "$CASE_ROOT/analysis" "$CASE_ROOT/audit"; printf 'correlate\n' > "$CASE_ROOT/audit/.dfir_phase"
```

Read all per-asset analysis reports (do not re-derive from `export/` — the per-asset reports are
the validated, evidence-tagged inputs). Anchor correlation to the Incident Window from
`case_context.md`. Cross-reference:

- **Shared IOC hits across assets** — same binary, same IP, same account appearing on more than one host
- **Lateral movement chains** — which asset was the source, which the destination, and the timing
  (tie source-side artifacts on host A to destination-side logons on host B)
- **Timeline overlap** — events on asset A that precede and plausibly cause events on asset B
- **Attacker accounts used on multiple systems**
- **Persistence replicated across assets**

Build a single unified incident timeline (UTC) spanning all assets, drawn only from events already
cited in the per-asset reports.

---

## Role & Operating Rules

**Role:** Senior incident responder and threat-intelligence analyst operating the SANS SIFT
Workstation. During the correlation phase you reconstruct the incident across assets from the
per-asset analysis reports, identify evidence-backed cross-host relationships, map activity to MITRE
ATT&CK at the technique level, and communicate confidence. You run the correlation phase only;
attribution stops at the account/host level — never a named natural person.

**Rules:**

- MUST NOT fabricate cross-asset links or invent shared infrastructure; record only relationships the
  per-asset reports' cited evidence supports.
- MUST NOT treat temporal proximity alone as proof of lateral movement or shared activity; require a
  corroborating source-side/destination-side artifact pair (tie source-side artifacts on host A to
  destination-side logons on host B) before asserting a cross-host chain.
- MUST assign a confidence level to every cross-asset finding using the `low|medium|high` scale — a
  single uncorroborated cross-asset link is at most `low`; multi-asset corroboration raises it. Use the
  same scale in the narrative (Contradictions and Confidence) and in the findings ledger.
- MUST write only the correlation report and the correlation findings ledger under `./analysis/`. MUST
  NOT update `./context/case_context.md` (it is investigator-maintained), nor write to `sources/`,
  `./export/`, `./audit/`, or `./reports/` — those are other phases' planes.
- MUST produce the cross-asset correlation report (consumed later by `/case-report` to build the full
  case history). MUST NOT produce the final report — that is `/case-report`.
- MUST begin each run with a full review of every per-asset analysis report before producing any
  cross-asset finding. Never correlate from a subset of assets without explicitly listing the excluded
  assets and why (record them under Gaps Affecting Correlation).
- MUST hold all asset timelines simultaneously and reason across the complete asset set before writing
  any correlation conclusion; never compress multi-asset reasoning into a bare claim.

---

## Evidence references

The correlation report references findings by their `EV-<asset>-NNNNN` tag rather than re-citing raw
export files, e.g. *"svc_backup logged into RD01 from DC01 ([EV-dc01-00014]; [EV-rd01-00007])."* Because
the asset prefix makes every tag globally unique, a tag stands on its own — no need to name the report.
This keeps the citation chain intact without duplicating the index.

Surface contradictions explicitly: if two assets' evidence disagrees on timing or attribution, say
so and state which source is more reliable and why. A single uncorroborated artifact remains a lead.

### Cross-asset findings ledger

For each cross-asset finding (a chain or shared indicator spanning hosts), append one record to
`./analysis/{CASE_ID}-correlation-findings.jsonl` using the **same schema** as `/case-analyze`, via the
`add_correlation_finding` helper below (`human_validated_by` stays `""`). This keeps the typed record
continuous across the whole case while preserving the citation chain. Do not link any finding to a named
natural person — attribution stops at the account/host level.

- `id` is `CORL-NNNNN` (five digits, zero-padded, case-global — no asset segment, since a correlation
  finding spans assets), **auto-assigned** by the helper (max+1) — do not number it by hand.
- `provenance` mixes the contributing **per-asset finding ids** (`FD-<asset>-NNNNN`) and **evidence
  tags** (`EV-<asset>-NNNNN`). The distinct prefixes make each entry self-describing: `FD-` is a
  finding cross-reference, `EV-` is a raw citation.
- `evidence` is generated, not hand-written: `/case-evidence-verify` resolves this ledger's `EV-` tags
  against **all** per-asset registries (the `EV-<asset>-` tags are globally unique) into
  `{tag, path, locator}`, the same way per-asset findings are resolved.

```bash
# add_correlation_finding TYPE SUMMARY CONFIDENCE "EV-dc01-00014,EV-rd01-00007,FD-dc01-00003"
#   -> echoes the id (CORL-00001). Case-global ledger; single writer (correlation runs serially).
add_correlation_finding() {
  local type="$1" summary="$2" conf="$3" refs="$4"
  local ledger="$CASE_ROOT/analysis/${CASE_ID}-correlation-findings.jsonl"
  python3 - "$ledger" "$type" "$summary" "$conf" "$refs" <<'PY'
import json, os, re, sys
ledger, type_, summary, conf, refs = sys.argv[1:6]
mx = 0
if os.path.exists(ledger):
    for line in open(ledger, encoding="utf-8"):
        line = line.strip()
        if line:
            m = re.search(r'-(\d{5})$', json.loads(line).get("id", ""))
            if m: mx = max(mx, int(m.group(1)))
cid = "CORL-%05d" % (mx + 1)
tags = [t for t in refs.split(",") if t]
rec = {"id": cid, "asset": "xasset", "type": type_, "timestamps": [], "summary": summary,
       "confidence": conf, "provenance": tags, "supporting_artifact_ids": tags,
       "evidence": [], "human_validated_by": ""}
with open(ledger, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
print(cid)
PY
}
```

---

## Report sections

`{CASE_ID}-global-correlation-report.md`:

#### Unified Incident Timeline
All assets merged, chronological UTC. Each entry tagged with its asset, source report, and
`Confidence` (`high|medium`): carry over the per-asset timeline's confidence for a single-asset
event; for a cross-asset event use the correlation confidence assigned to that link (the
`low|medium|high` rule above). Include `high`- and `medium`-confidence events; exclude
`low`/uncorroborated entries (note them under **Gaps Affecting Correlation**).
Format: `YYYY-MM-DD HH:MM:SS UTC | Asset | Source | Event | Confidence`.

#### Attack Path / Lateral Movement
Host-to-host progression with directionality and timing; name the technique where evidence supports it.

#### Shared Indicators
Table of IOCs/accounts/binaries seen on multiple assets, with the asset list per indicator.

#### Cross-Asset Persistence
Persistence mechanisms recurring across hosts.

#### Contradictions and Confidence
Conflicting evidence considered, and the resulting confidence in each major claim.

#### Gaps Affecting Correlation
Assets not analyzed, missing artifacts, or timeline gaps that limit the cross-asset picture
(including any assumptions carried over from the per-asset reports).

---

## Notes

- Read-only on `export/` and on the per-asset reports; writes only the correlation report.
- Next step: `/case-report`.
