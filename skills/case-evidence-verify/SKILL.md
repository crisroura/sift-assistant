# Skill: case-evidence-verify — Evidence Citation Verification

## Overview

Verifies that every factual claim in DFIR reports is backed by a specific export file.
Used automatically as Phase 4.5 of the `case-investigate` pipeline, and usable standalone
with `/case-evidence-verify` for post-hoc re-verification.

---

## Citation Format

Every factual statement in an analysis report must end with an inline evidence tag:

```
PowerShell executed with encoded arguments at 2026-05-12T03:14:22Z [EV-dc01-00001].
The attacker account `DOMAIN\svc_backup` logged in from 10.0.1.15 [EV-dc01-00002].
```

Rules:
- Tag format: `[EV-<asset>-NNNNN]` — asset id (`[A-Za-z0-9_]+`) then five zero-padded digits.
  Matching regex: `\[EV-[A-Za-z0-9_]+-[0-9]{5}\]`
- Tags are **globally unique per case**. The asset prefix guarantees uniqueness across reports, so a
  tag can be referenced from correlation or the final report without naming its report.
- Each asset keeps its own counter incrementing from `00001` (parallel-safe — `/case-analyze` assigns
  via `add_evidence`, one writer per asset). Do not number tags by hand.
- Never cite a file that does not exist. `add_evidence` enforces this at capture; verification re-checks
  it. A citation must resolve to a real file under `export/<asset_id>/`, `sources/` (an already-readable
  artifact needing no parsing), or `analysis/tool-output/` (output captured during analysis) — never the
  narrative report itself
- If a needed artifact is absent, note it in the Gaps / Unknowns section instead

---

## Evidence registry and generated Index

The tag → file mapping lives in a per-asset **registry**, `analysis/{CASE_ID}-{ASSET_ID}-evidence.jsonl`,
written by `/case-analyze`'s `add_evidence` — one object per tag, the single source of truth:

```json
{"tag":"EV-dc01-00001","asset":"dc01","path":"export/dc01/mnt-001-base-dc-cdrive/evtx/dc01-mnt-001-base-dc-cdrive-evtx-evtxecmd.csv","locator":"Event ID 4688 @ 2026-05-12T03:14:22Z; row 4213","description":"powershell.exe with encoded args"}
```

The `locator` pins where in the file to look — a semantic descriptor plus, for parsed CSV/text output,
a `; row <N>` line pointer (omitted when not applicable). It flows unchanged into the findings ledger's
generated `evidence[]` (see below).

The `## Evidence Index` appendix at the tail of each analysis report is **generated** from that registry
by `render_evidence_index` — never hand-written:

```markdown
## Evidence Index

| ID | File | Description |
|----|------|-------------|
| EV-dc01-00001 | `export/dc01/mnt-001-base-dc-cdrive/evtx/dc01-mnt-001-base-dc-cdrive-evtx-evtxecmd.csv` | Event ID 4688 @ 2026-05-12T03:14:22Z — powershell.exe with encoded args |
| EV-dc01-00002 | `export/dc01/mnt-001-base-dc-cdrive/evtx/dc01-mnt-001-base-dc-cdrive-evtx-evtxecmd.csv` | Event ID 4624 logon type 3 — DOMAIN\svc_backup from 10.0.1.15 |
| EV-dc01-00003 | `export/dc01/mnt-001-base-dc-cdrive/mft/dc01-mnt-001-base-dc-cdrive-mft-mftecmd.csv` | $MFT entry for C:\Windows\Temp\stager.exe, created 2026-05-12T03:09:11Z |
```

Requirements (enforced against the registry, since the Index is a projection of it):
- `path` must be relative to the case root and point to a file that exists under `export/`, `sources/`,
  or `analysis/tool-output/`
- Every `[EV-<asset>-NNNNN]` tag cited in a report body must have a record in that asset's registry
- The Index never drifts from the body: it is regenerated from the registry during verification, so a
  "row with no citation" / "citation with no row" mismatch is structurally impossible

### Findings enrichment

Each typed finding (`*-findings.jsonl`) carries a generated `evidence` array that resolves the
finding's `EV-` tags to `{tag, path, locator}`. Phase 4.5 (re)builds it from the merged registries —
one map serves per-asset and correlation findings because `EV-<asset>-` tags are globally unique;
`FD-`/`CORL-` provenance entries are finding cross-references, not evidence, and are excluded. A
finding citing an `EV-` tag absent from every registry yields an `UNRESOLVED` entry and forces FAIL
(the findings-side mirror of the orphan-citation check).

---

## Phase 4.5 Verification (automated, part of case-investigate pipeline)

The `case-investigate` skill runs this automatically after writing the final report:

```bash
CASE_ROOT="$(pwd)"
CASE_ID="{CASE_ID}"
VER_OUT="$CASE_ROOT/analysis/${CASE_ID}-evidence-verification.md"
EVRE='\[EV-[A-Za-z0-9_]+-[0-9]{5}\]'

# Tags cited in report bodies (strip the surrounding brackets)
grep -rhoE "$EVRE" \
  "$CASE_ROOT/analysis/" "$CASE_ROOT/reports/" 2>/dev/null \
  | tr -d '[]' | sort -u > /tmp/ev_cited.txt

# Source of truth: tags + paths defined in the per-asset evidence registries
python3 - "$CASE_ROOT"/analysis/*-evidence.jsonl > /tmp/ev_registry.tsv 2>/dev/null <<'PY'
import json, sys
for p in sys.argv[1:]:
    try:
        for ln in open(p, encoding="utf-8"):
            ln = ln.strip()
            if ln:
                r = json.loads(ln); print("%s\t%s" % (r["tag"], r["path"]))
    except Exception:
        pass
PY
cut -f1 /tmp/ev_registry.tsv | sort -u > /tmp/ev_defined.txt
cut -f2 /tmp/ev_registry.tsv | sort -u > /tmp/ev_files.txt

# Missing files: a registry path with no file on disk
while IFS= read -r fpath; do
    [ -n "$fpath" ] && { [[ -f "$CASE_ROOT/$fpath" ]] || printf 'MISSING: %s\n' "$fpath"; }
done < /tmp/ev_files.txt > /tmp/ev_missing.txt

# Orphan citations: cited in prose but absent from every registry
comm -23 /tmp/ev_cited.txt /tmp/ev_defined.txt > /tmp/ev_orphan_cited.txt

# Regenerate every asset's Evidence Index from its registry (idempotent projection).
# The Index can no longer drift from the registry, so there is no orphan-index-entry check.
for reg in "$CASE_ROOT"/analysis/${CASE_ID}-*-evidence.jsonl; do
    [ -f "$reg" ] || continue
    a="$(basename "$reg")"; a="${a#${CASE_ID}-}"; a="${a%-evidence.jsonl}"
    report="$CASE_ROOT/analysis/${CASE_ID}-${a}-analysis-report.md"
    [ -f "$report" ] || continue
    python3 - "$reg" "$report" <<'PY'
import json, re, sys
reg, report = sys.argv[1], sys.argv[2]
seen, rows = set(), []
for line in open(reg, encoding="utf-8"):
    line = line.strip()
    if not line: continue
    r = json.loads(line)
    if r["tag"] in seen: continue
    seen.add(r["tag"]); rows.append(r)
rows.sort(key=lambda r: r["tag"])
body = open(report, encoding="utf-8").read()
body = re.split(r'\n##\s+Evidence Index\s*\n', body)[0].rstrip() + "\n"
out = ["\n## Evidence Index\n", "| ID | File | Description |", "|----|------|-------------|"]
for r in rows:
    loc, desc = (r.get("locator") or "").strip(), (r.get("description") or "").strip()
    out.append("| %s | `%s` | %s |" % (r["tag"], r["path"], " — ".join(x for x in (loc, desc) if x)))
open(report, "w", encoding="utf-8").write(body + "\n".join(out) + "\n")
PY
done

# Resolve every findings ledger's "evidence" array from the registries (idempotent), and list any
# finding citing an EV- tag absent from every registry. EV tags are globally unique, so one merged
# map resolves per-asset and correlation findings alike. Non-EV provenance (FD-/CORL-) is excluded.
python3 - "$CASE_ROOT" > /tmp/ev_unresolved.txt <<'PY'
import json, glob, os, sys
root = sys.argv[1]
reg = {}
for p in glob.glob(os.path.join(root, "analysis", "*-evidence.jsonl")):
    for line in open(p, encoding="utf-8"):
        line = line.strip()
        if not line: continue
        r = json.loads(line)
        reg.setdefault(r["tag"], {"tag": r["tag"], "path": r.get("path"),
                                  "locator": r.get("locator", "")})
for led in glob.glob(os.path.join(root, "analysis", "*-findings.jsonl")):
    out = []
    for line in open(led, encoding="utf-8"):
        line = line.strip()
        if not line: continue
        f = json.loads(line)
        seen, ev = set(), []
        for t in list(f.get("provenance", [])) + list(f.get("supporting_artifact_ids", [])):
            if not t.startswith("EV-") or t in seen: continue
            seen.add(t)
            rec = reg.get(t, {"tag": t, "path": None, "locator": "UNRESOLVED"})
            ev.append(rec)
            if rec["path"] is None:
                sys.stdout.write("%s\t%s\t%s\n" % (os.path.basename(led), f.get("id", "?"), t))
        f["evidence"] = ev
        out.append(json.dumps(f, ensure_ascii=False))
    open(led, "w", encoding="utf-8").write("\n".join(out) + ("\n" if out else ""))
PY

# Determine verdict
VERDICT="PASS"
[[ -s /tmp/ev_missing.txt ]]      && VERDICT="FAIL"
[[ -s /tmp/ev_orphan_cited.txt ]] && VERDICT="FAIL"
[[ -s /tmp/ev_unresolved.txt ]]   && VERDICT="FAIL"

# Validation status — count findings in the typed ledgers still awaiting human validation.
# This does NOT affect the citation VERDICT: a DRAFT is expected to be unvalidated. It reports
# the human-validation gap so the report's Validation Status section can state it.
FINDINGS_TOTAL=0; FINDINGS_UNVALIDATED=0
if compgen -G "$CASE_ROOT/analysis/"*-findings.jsonl > /dev/null; then
    read -r FINDINGS_TOTAL FINDINGS_UNVALIDATED < <(python3 - "$CASE_ROOT"/analysis/*-findings.jsonl <<'PY'
import json, sys
total = unval = 0
for path in sys.argv[1:]:
    try:
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if not line:
                continue
            total += 1
            rec = json.loads(line)
            if not (rec.get("human_validated_by") or "").strip():
                unval += 1
    except Exception:
        pass
print(total, unval)
PY
)
fi

# Write verification report
{
printf '# Evidence Verification — %s\n\n' "$CASE_ID"
printf 'Generated: %s UTC\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '**Verdict: %s**\n\n' "$VERDICT"
printf '| Metric | Count |\n|--------|-------|\n'
printf '| Distinct tags cited | %d |\n' "$(wc -l < /tmp/ev_cited.txt)"
printf '| Registry tags defined | %d |\n' "$(wc -l < /tmp/ev_defined.txt)"
printf '| Missing export files | %d |\n' "$(wc -l < /tmp/ev_missing.txt)"
printf '| Orphan citations (no registry record) | %d |\n' "$(wc -l < /tmp/ev_orphan_cited.txt)"
printf '| Findings citing unresolved evidence | %d |\n' "$(wc -l < /tmp/ev_unresolved.txt)"
printf '| Typed findings (total) | %d |\n' "$FINDINGS_TOTAL"
printf '| Findings awaiting human validation | %d |\n' "$FINDINGS_UNVALIDATED"
[[ "$FINDINGS_UNVALIDATED" -gt 0 ]] && printf '\n> Validation gate: %d of %d findings have an empty `human_validated_by`. A human examiner must validate these independently; AI cannot.\n' "$FINDINGS_UNVALIDATED" "$FINDINGS_TOTAL"
[[ -s /tmp/ev_missing.txt ]] && {
    printf '\n## Missing Export Files\n\n'
    cat /tmp/ev_missing.txt
}
[[ -s /tmp/ev_orphan_cited.txt ]] && {
    printf '\n## Orphan Citations (cited in report text but not defined in any evidence registry)\n\n'
    cat /tmp/ev_orphan_cited.txt
}
[[ -s /tmp/ev_unresolved.txt ]] && {
    printf '\n## Findings Citing Unresolved Evidence (ledger\\tfinding-id\\tEV-tag)\n\n'
    cat /tmp/ev_unresolved.txt
}
} > "$VER_OUT"

if [[ "$VERDICT" == "FAIL" ]]; then
    printf '\n\033[1;33m[WARN]\033[0m Evidence verification FAILED.\n'
    printf '       See %s\n' "$VER_OUT"
fi

rm -f /tmp/ev_cited.txt /tmp/ev_registry.tsv /tmp/ev_defined.txt /tmp/ev_files.txt \
      /tmp/ev_missing.txt /tmp/ev_orphan_cited.txt /tmp/ev_unresolved.txt
```

---

## Standalone Verification

To run verification independently at any time:

```bash
EVRE='\[EV-[A-Za-z0-9_]+-[0-9]{5}\]'
# Quick citation count per tag
grep -rhoE "$EVRE" ./analysis/ ./reports/ | sort | uniq -c | sort -rn

# List all files defined in the evidence registries
python3 -c 'import json,glob,sys
[print(json.loads(l)["path"]) for f in glob.glob("./analysis/*-evidence.jsonl") for l in open(f) if l.strip()]' | sort -u

# Check each registry file exists
python3 -c 'import json,glob
[print(json.loads(l)["path"]) for f in glob.glob("./analysis/*-evidence.jsonl") for l in open(f) if l.strip()]' \
  | sort -u | while IFS= read -r f; do [ -f "./$f" ] || printf 'MISSING: %s\n' "$f"; done

# Show orphan citations (cited in prose but not defined in any registry)
grep -rhoE "$EVRE" ./analysis/ ./reports/ | tr -d '[]' | sort -u > /tmp/cited.txt
python3 -c 'import json,glob
[print(json.loads(l)["tag"]) for f in glob.glob("./analysis/*-evidence.jsonl") for l in open(f) if l.strip()]' \
  | sort -u > /tmp/defined.txt
comm -23 /tmp/cited.txt /tmp/defined.txt
```

---

## Notes

- Tags are globally unique per case via the asset prefix: `EV-dc01-00001` and `EV-rd01-00001` are
  distinct, and a tag identifies its asset without naming the report.
- The Evidence Index is a generated projection of the per-asset `evidence.jsonl` registry, never
  hand-written. Verification re-renders it, so body/Index drift cannot occur.
- The final report (`{CASE_ID}-final-report.md`) references asset-level evidence
  by asset report annex rather than direct EV- tags; EV- tags are an analysis-layer
  construct.
- If an artifact failed parsing (`FAILED`/`EMPTY` in `audit/<asset>/parse_state.txt`, or logged in
  `audit/artifact_failures.log`), note the gap in the Gaps / Unknowns section — do not fabricate an
  EV- tag for a non-existent file.
