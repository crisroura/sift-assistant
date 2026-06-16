# Skill: case-analyze — Phase 2 Per-Asset Analysis

## Overview

Second phase of the investigation pipeline. For each asset, read every parsed artifact in
`export/<asset_id>/` — **never modify them** — cross-reference the case intelligence, and write one
evidence-backed analysis report per asset. Invoked standalone with `/case-analyze` (after parsing)
or as the second step of `/case-investigate`.

Analyze also **owns prioritization** (there is no separate triage phase): after the breadth-first
review it derives a working hypothesis from the case context and decides — in three tiers — which
**asset**, then which **source**, then which **artifact class** to examine first; order only, nothing
skipped (see *Establish the examination order*, below).

**Inputs:** `export/<asset_id>/` (from `/case-parse`), `./context/case_context.md`.
**Output:** `./analysis/{CASE_ID}-{ASSET_ID}-analysis-report.md`, one per asset.

**Export layout to read:** each asset has one subtree per Windows volume —
`export/<asset>/<vol>/<artifact>/` (e.g. `mnt-001-base-dc-cdrive`, `mnt-002-base-dc-disk`) — plus asset-level
memory output under `export/<asset>/memory*/`. Most assets have a single volume dir;
treat multiple volume dirs as separate volumes of the same host and attribute every finding to its volume.

Assets are independent — each gets its own report. Examine them in an explicit, ranked order
(Tier 1, below); they may still run in parallel, in which case the ranking just decides which starts
first. Drop the `&`/`wait` to run strictly serially.

```bash
CASE_ROOT="$(pwd)"; CASE_ID="{CASE_ID}"
# Phase marker — locks ./export read-only for the rest of the pipeline (see /case-parse, evidence_guard).
mkdir -p "$CASE_ROOT/analysis" "$CASE_ROOT/audit"; printf 'analyze\n' > "$CASE_ROOT/audit/.dfir_phase"

# TIER 1 — Asset order (prioritization, not scope). Consult the Assets Inventory in
# case_context.md (AssetID | Hostname | Role) plus the Case Notes / IOC block / Incident Window,
# and derive the ranked list (see "Establish the examination order", Tier 1). Examine first the
# assets named in the incident notes, matched by an IOC, or central to the hypothesis by role.
RANKED_ASSETS="{ASSET_ID_1} {ASSET_ID_2}"   # <- replace with the order you derived from the inventory

analyze_asset() {
  local ASSET="$1"
  local EXP="$CASE_ROOT/export/$ASSET"
  local OUT="$CASE_ROOT/analysis/${CASE_ID}-${ASSET}-analysis-report.md"
  # Breadth-first review of everything present, THEN establish the examination order
  # (see "Establish the examination order"): hypothesis -> Tier 2 source rank (from the Sources
  # Inventory) -> Tier 3 per-source artifact order (playbook). Record all three in "Examination
  # Approach". Deep-dive one source fully before the next, in the Tier 2 order.
  # Per-volume (disk) artifacts (volume dirs are named mnt-NNN-<imgbase>; memory is a separate
  # source handled below; plaso timeline is dropped):
  for VOLDIR in "$EXP"/*/; do
    VOLDIR="${VOLDIR%/}"
    [ -d "$VOLDIR" ] || continue
    case "$(basename "$VOLDIR")" in memory*|timeline*) continue ;; esac
    VOL="$(basename "$VOLDIR")"   # read $VOLDIR/<artifact>/... in playbook order; tag findings with $VOL
  done
  # Asset-level memory artifacts ($EXP/memory*/) — their own source; deep-dive in playbook order.
  # Cross-reference case_context.md, write $OUT (sections below).
  # Capture each citation with add_evidence and each finding with add_finding as you write, then
  # generate the Evidence Index and resolve the findings' source/locator from the registry:
  render_evidence_index "$ASSET"
  resolve_findings "$CASE_ROOT/analysis/${CASE_ID}-${ASSET}-findings.jsonl"
}
# Launch in Tier-1 ranked order so the highest-priority asset starts first.
for ASSET in $RANKED_ASSETS; do ( analyze_asset "$ASSET" ) & done
wait
```

---

## Role & Operating Rules

**Role:** Senior forensic analyst operating the SANS SIFT Workstation, with deep Windows DFIR
expertise. During the analysis phase you reconstruct asset-level activity from parsed artifacts, map
techniques to MITRE ATT&CK, and state confidence, gaps, and limitations. You run the analysis phase only.

**Rules:**

- MUST NOT fabricate findings, evidence, ATT&CK mappings, or attributions; record only what parsed
  artifacts in `./export/` support.
- MUST write only under `./analysis/`. MUST NOT update `./context/case_context.md` (it is
  investigator-maintained), nor write to `sources/`, `./export/`, `./audit/`, or `./reports/` — those
  are other phases' planes. (`./export/` is locked read-only once parse ends; the evidence guard
  blocks any write to it outside the parse phase.)
- MAY run a court-vetted forensic tool ad-hoc when the parsed output is insufficient to resolve a
  question (e.g. examining a suspicious binary or carved file identified during analysis). Such runs
  are **bounded**: write output only under `./analysis/tool-output/` using the
  `<asset>-<artifact>-<tool>.ext` naming (so it stays distinguishable from the AI narrative and is
  citable), record the exact command run, and apply the same verify-output rule (zero exit AND
  non-empty) and no-fabrication rule as the parse phase. Resolve tool paths from `~/.claude/tools.env`;
  the tool-discovery catalog (`~/.claude/SIFT_SERVER_DFIR_TOOLS.json`) may be consulted for a tool no
  skill covers. Never write tool output into `./export/` here.
- MUST analyze each asset independently and emit one report per asset.
- MUST begin each run with a **breadth-first artifact review**: load every available parsed output and
  the per-volume `parse_state.txt` across all volumes before deep-diving any single artifact. Establish
  the full evidence landscape before focused analysis — never start deep analysis of one artifact first.
- MUST then **establish and follow an explicit three-tier examination order** (see *Establish the
  examination order*): derive a working hypothesis from the case context, then order **(Tier 1)
  assets** (from the Assets Inventory + context), **(Tier 2) each asset's sources** (enumerated from
  the Sources Inventory, then ranked by source-type × hypothesis), and **(Tier 3) each source's
  artifact deep-dive** (by the playbook). The order sets **priority, not scope** — every present
  artifact is still analyzed and every absent/failed one still recorded in Gaps. Record the hypothesis,
  all three tiers, and any assumption in the report's **Examination Approach** note.
- MUST reason through multi-artifact evidence before writing any finding or conclusion; never compress
  multi-artifact reasoning into a single bare statement.
- MUST treat `./context/case_context.md` as investigative framing — a search directive, not a finding
  source. MUST NOT carry its IOCs, TTPs, or attributions into the report as findings unless
  independently confirmed by a parsed artifact. When an artifact confirms an indicator or TTP that
  appears in the context, the finding is sourced from the artifact and labeled
  **"Corroborated by provided context"**.
- MUST list evidence gaps and unavailable/failed artifacts (in Gaps and Unknowns) rather than silently
  ignoring them.
- MUST assign confidence to every finding: a single uncorroborated artifact is at most `low`;
  corroboration by two independent artifacts raises confidence (see the typed findings ledger below).

---

## Ground every finding in the case context

Before writing, load the two analytical anchors from `./context/case_context.md`:

- **Incident Window** — the `Incident Window (UTC)` table. Per the methodology, activity outside
  this window is presumed baseline/benign unless evidence ties it directly to the incident. State
  the window explicitly at the top of each report and test every candidate finding against it.
- **IOCs** — the typed IOC block is greppable, so match deterministically rather than by eye:
  ```bash
  CTX="./context/case_context.md"
  # Pull each indicator type out of the ```ioc block
  awk '/^```ioc/{f=1;next}/^```/{f=0}f' "$CTX" | sed -n 's/^ip:[[:space:]]*//p'     # attacker IPs
  awk '/^```ioc/{f=1;next}/^```/{f=0}f' "$CTX" | sed -n 's/^hash:[[:space:]]*//p'   # file hashes
  awk '/^```ioc/{f=1;next}/^```/{f=0}f' "$CTX" | sed -n 's/^domain:[[:space:]]*//p' # domains
  awk '/^```ioc/{f=1;next}/^```/{f=0}f' "$CTX" | sed -n 's/^file:[[:space:]]*//p'   # files
  ```
  Then grep **all files** under `export/<asset>/` (every parsed output file is plain text —
  CSVs, TXT, JSON, etc.) for each indicator. Use `grep -rl` to locate matching files first,
  then `grep -n` to pin line numbers for the `add_evidence` locator. Cite every hit with
  its volume or artifact sub-dir (`memory*/`, volume dir name).

  ```bash
  # Grep all export files for one indicator (repeat per IOC type):
  grep -rl "$IOC" "$EXP" | while IFS= read -r f; do
      grep -n "$IOC" "$f" | head -5
  done
  ```

### Supplemental plain-text sources in `sources/`

Some artifacts in `./sources/` are never parsed by Phase 1 because they are already readable
plain text. After reviewing all parsed `export/` output, check whether any of the following
are present and relevant to the hypothesis or IOC hits:

- **SetupAPI logs** (`SetupAPI.log`, `SetupAPI.dev.log`) — driver/device install history;
  corroborates USB/device IOCs and the registry device enumeration from `dfir-registry`.
- **Windows Update logs** (`WindowsUpdate.log`, `%WINDIR%\Logs\CBS\CBS.log`) — patch history
  and build baseline.
- **WER crash logs** (`.wer` text files) — crashed processes including attacker tools.
- **Application / service logs** — IIS `u_ex*.log`, RDP `TSViewer*.log`, VPN logs, AV console
  exports, or any other operational log the operator placed in `sources/`.

**Decision rule:** Examine a specific `sources/` file only when (a) an IOC hit in `export/`
points to it, (b) the working hypothesis makes it a high-value lead (e.g., SetupAPI when USB
activity is in scope), or (c) the file was noted as interesting during the earlier
parsed-artifact deep-dive. Do not enumerate all of `sources/` blindly — scope to relevance.

Citation: plain-text files under `sources/` are valid evidence. Cite them with `add_evidence`
exactly as you would a parsed export file; the helper enforces that the path resolves to a
real file under the case root.

---

## Establish the examination order (prioritization)

Analyze owns prioritization — there is no separate triage phase. After the breadth-first review (load
every parsed output + each volume's `parse_state.txt`) and **before** deep-diving, set an explicit
**three-tier** examination order: Tier 1 ranks **assets**, Tier 2 ranks each asset's **sources**, Tier
3 ranks each source's **artifact classes**. This is **order only**: every asset, source, and parsed
artifact is still analyzed; absent or failed ones still go to **Gaps and Unknowns**. Record the order
and any assumption in the report's **Examination Approach** note (see Report sections).

**0. Derive a working hypothesis** from `case_context.md` (Case Notes / incident description, plus the
IOC block and Incident Window). Classify into one of: `ransomware | data_exfil | lateral_movement |
persistence_backdoor | credential_theft | unknown`. When the context is thin (e.g. "servers are
compromised", empty IOC block), use `unknown` + the role-based default below and **record the
assumption** (it carries into Gaps and Unknowns). The hypothesis drives all three tiers.

**Tier 1 — Rank the assets.** Read the **Assets Inventory** (`AssetID | Hostname | Role`) from
`case_context.md`. Order assets by incident relevance:
- **named in the Case Notes / incident description**, or **matched by an IOC** (a host, account, or
  file tied to that asset) → examine first;
- **role central to the hypothesis** breaks ties — e.g. a Domain Controller leads for
  `credential_theft`, an external-facing / Remote Desktop host leads for initial access and
  `lateral_movement`, a file server leads for `data_exfil` / `ransomware`;
- everything else follows.

Drive the `analyze_asset` loop from this ranked list (see the orchestrator block). Assets remain
independent and may run in parallel — the rank then sets which starts first and the review priority.
Record the asset order + a one-line basis. This is **order only**; every asset is still analyzed.

**Tier 2 — Rank each asset's sources.** Enumerate the asset's sources from the **Sources Inventory**
(`SourceID | AssetID | Type | SourcePath`) in `case_context.md` — that table is the authoritative list
of what was acquired for the asset (e.g. one `disk` source and one `memory` source). Map each row to
its parsed export subtree:
- `Type = memory` → the asset-level `export/<asset>/memory*/` dir(s);
- `Type = disk` / `mount` → the disk volume dir(s) `export/<asset>/mnt-NNN-<imgbase>/` produced from
  that image (a single disk image may yield more than one volume dir — all are that source's volumes).

If the Sources Inventory is absent or its `Type` column is blank, fall back to classifying export dirs
by name (`memory*` → memory, `timeline*` → dropped, else disk) and **record the assumption**.

Then order the sources by **source-type × hypothesis**: memory leads for `lateral_movement` /
`credential_theft` / fileless / active-C2 hypotheses (volatile state: live processes, network, injected
code, cached creds); disk leads for `persistence_backdoor`, `ransomware`, `data_exfil`, and historical
reconstruction. Default (`unknown`) on a server: disk first (durable, comprehensive), memory a close
second for live-state corroboration. Record the source order + a one-line basis. Every source present
is still analyzed.

**Tier 3 — Build each source's artifact examination list.** Within a source (in Tier-2 order),
enumerate every artifact class actually present and order it by the playbook below. These are the
subdirs under each volume dir and under `memory*/`:

```bash
# Per disk volume (one line per artifact class dir):
find "$EXP/$VOL" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
# Memory (if present):
find "$EXP"/memory* -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort
```

Then build the ordered examination list for each source: slot each artifact class found into the
playbook order below (role × source-type, then hypothesis modifiers), then **append any artifact
class present in the export but not named in the playbook at the end** of that source's list. Every
artifact class found in the export must appear exactly once in this list — nothing is silently dropped.

Write all three tiers into the report's **Examination Approach** note before starting any deep-dive.
The deep-dive then works the sources in Tier-2 order, and within each source executes its Tier-3 list
in order — triage and deep-dive sequence are one decision, made once, recorded once.

### Per-source artifact playbook (priority order for known artifact classes)

**Disk — Domain Controller**
`evtx` (auth/Kerberos 4624/4625/4672/4768/4769; account & group changes 4720/4722/4724/4728/4732; log
clear 1102) → `registry` (ASEP: Run/RunOnce/Services/Winlogon) + `shimcache` → `scheduledtasks` →
`mft`+`usnjrnl` (NTDS.dit access/copy, timestomp SI-vs-FN, incident-window file activity) →
`prefetch`+`amcache` → `shellbags`+`lnk`+`recyclebin` → `browser`+`srum`+`yara`.

**Disk — Remote Desktop / external-facing server**
`evtx` (RDP: 4624 type 10 + 4778/4779, TerminalServices 1149/21/22/25; brute force 4625; 1102) →
`prefetch`+`amcache` → `registry`+`shimcache` → `scheduledtasks` → `mft`+`usnjrnl` (tool drops,
staging) → `shellbags`+`lnk`+`recyclebin` → `browser`+`srum`+`yara`.

**Disk — generic server / workstation**
`evtx` (logons 4624/4625/4672; service install 7045; 1102) → `registry`+`shimcache` →
`prefetch`+`amcache` → `scheduledtasks` → `mft`+`usnjrnl` → `shellbags`+`lnk`+`recyclebin` →
`browser`+`srum`+`yara`.

**Memory — any host** (`export/<asset>/memory*/`, all via `/dfir-memory-volatility`)
`pstree`/`pslist`/`psscan` (rogue/hidden processes, parent-child anomalies) → `netstat`/`netscan`
(C2, lateral connections) → `cmdline` (full command lines, encoded PowerShell) → `malfind` (injected
code) → `svcscan` (malicious services) → `dlllist` (sideloaded DLLs) → `hashdump` (credential exposure).

### Hypothesis modifiers (pull these classes to the front)
- **ransomware** — disk: `mft`+`usnjrnl` (mass changes), `evtx` (VSS deletion, service install 7045),
  `prefetch` (vssadmin/wmic/cipher); memory: `malfind`, `cmdline`.
- **data_exfil** — disk: `srum` (bytes sent), `browser`, `mft`/`shellbags` (staged archives);
  memory: `netstat`.
- **lateral_movement** — disk: `evtx` (4624 type 3/10, 5140/5145, 4648, 4672), `scheduledtasks`,
  `registry` Services; memory: `netstat`.
- **persistence_backdoor** — disk: `registry` ASEP, `scheduledtasks`, services (`evtx` 7045);
  memory: `svcscan`, `malfind`.
- **credential_theft** — memory: `hashdump`, lsass-related; disk: `registry` SAM/SECURITY,
  `evtx` 4672/4769.

This playbook is Tier 3 — **applied independently within each source**, in the Tier-2 source order;
never interleave one source's artifacts with another's. Adapt to the asset's actual role and the
derived hypothesis, and **record any deviation as an assumption**. The playbook defines priority order
for known artifact classes; it does not define scope. Scope is everything in the export — including
artifact classes not listed here.

---

## Evidence tagging (required while writing every section)

Tags are case-global and asset-prefixed: `EV-<asset>-NNNNN` (five digits, zero-padded), e.g.
`[EV-dc01-00001]`. The asset prefix makes every tag unique across the whole case, so correlation and
the final report can reference a tag without naming the report. Each asset keeps its own counter, so
parallel `analyze_asset` runs never collide.

- Every factual statement derived from a tool output file ends with an inline citation:
  `PowerShell executed with encoded arguments at 2026-05-12T03:14:22Z [EV-dc01-00001].`
- **Do not number tags by hand and do not hand-write the Evidence Index.** Call `add_evidence` (helper
  below) at the moment you cite: it assigns the next `EV-<asset>-NNNNN`, records the tag → path → locator
  mapping in the asset's evidence registry, and echoes the tag for you to drop into the sentence. The
  `## Evidence Index` table is then generated from that registry by `render_evidence_index` — never typed.
- **Never cite a file that does not exist.** This is now enforced at capture: `add_evidence` rejects a
  path with no file under the case root. A citation must resolve to a real file under `export/<asset_id>/`,
  an already-readable artifact under `sources/` (a plain-text log/config needing no parsing), or this
  phase's own tool output under `analysis/tool-output/`. Never cite the narrative report itself. If a
  needed artifact is absent or failed (`FAILED`/`EMPTY` in `parse_state.txt`), note it in Gaps / Unknowns
  instead.
- **Pin the location in the file.** The `locator` (3rd arg to `add_evidence`) is where a reviewer looks
  to confirm the citation. For parsed CSV/text output, include the **row/line** alongside the semantic
  descriptor: `"<descriptor> @ <ts>; row <N>"`. Cheap capture: when the hit is found via grep, use
  `grep -n` to get the line number; otherwise note the row you read. Best-effort — omit `row <N>` when it
  does not apply (memory images, registry hives, binary artifacts) and keep the semantic descriptor.

The registry, `./analysis/{CASE_ID}-{ASSET_ID}-evidence.jsonl`, is the single source of truth for the
tag → file mapping (one object per line):

```json
{"tag":"EV-dc01-00001","asset":"dc01","path":"export/dc01/mnt-001-base-dc-cdrive/evtx/dc01-mnt-001-base-dc-cdrive-evtx-evtxecmd.csv","locator":"Event ID 4688 @ 2026-05-12T03:14:22Z; row 4213","description":"powershell.exe with encoded args"}
```

Helpers (define alongside `add_finding`, below). `add_evidence` captures a citation; `render_evidence_index`
projects the registry into the report's `## Evidence Index`:

```bash
# add_evidence ASSET PATH LOCATOR DESCRIPTION  ->  echoes the assigned tag (e.g. EV-dc01-00001)
# One writer per asset (assets run in parallel, each owns its own registry) -> no lock needed.
add_evidence() {
  # NB: do not name a local 'path' — under zsh that aliases $PATH. Use 'epath'.
  local asset="$1" epath="$2" locator="$3" desc="$4"
  local reg="$CASE_ROOT/analysis/${CASE_ID}-${asset}-evidence.jsonl"
  python3 - "$reg" "$asset" "$epath" "$locator" "$desc" "$CASE_ROOT" <<'PY'
import json, os, re, sys
reg, asset, path, locator, desc, root = sys.argv[1:7]
# Never cite a file that does not exist — enforced at capture, not just at verify.
if not os.path.isfile(os.path.join(root, path)):
    sys.stderr.write("EV-REJECT: no such evidence file: %s\n" % path); sys.exit(1)
mx = 0
if os.path.exists(reg):
    for line in open(reg, encoding="utf-8"):
        line = line.strip()
        if line:
            m = re.search(r'-(\d{5})$', json.loads(line)["tag"])
            if m: mx = max(mx, int(m.group(1)))
tag = "EV-%s-%05d" % (asset, mx + 1)
rec = {"tag": tag, "asset": asset, "path": path, "locator": locator, "description": desc}
with open(reg, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
print(tag)
PY
}

# render_evidence_index ASSET  -> (re)generates "## Evidence Index" at the tail of the asset report.
# Idempotent: strips any prior Index before re-rendering, so it is safe to re-run (e.g. in verify).
render_evidence_index() {
  local asset="$1"
  local reg="$CASE_ROOT/analysis/${CASE_ID}-${asset}-evidence.jsonl"
  local report="$CASE_ROOT/analysis/${CASE_ID}-${asset}-analysis-report.md"
  [ -f "$reg" ] && [ -f "$report" ] || return 0
  python3 - "$reg" "$report" <<'PY'
import json, re, sys
reg, report = sys.argv[1], sys.argv[2]
seen, rows = set(), []
for line in open(reg, encoding="utf-8"):
    line = line.strip()
    if not line: continue
    r = json.loads(line)
    if r["tag"] in seen: continue          # uniqueness guard at render
    seen.add(r["tag"]); rows.append(r)
rows.sort(key=lambda r: r["tag"])
body = open(report, encoding="utf-8").read()
body = re.split(r'\n##\s+Evidence Index\s*\n', body)[0].rstrip() + "\n"   # idempotent re-render
out = ["\n## Evidence Index\n", "| ID | File | Description |", "|----|------|-------------|"]
for r in rows:
    loc, desc = (r.get("locator") or "").strip(), (r.get("description") or "").strip()
    out.append("| %s | `%s` | %s |" % (r["tag"], r["path"], " — ".join(x for x in (loc, desc) if x)))
open(report, "w", encoding="utf-8").write(body + "\n".join(out) + "\n")
PY
}

Usage while writing a section:

```bash
EV=$(add_evidence dc01 "export/dc01/mnt-001-base-dc-cdrive/evtx/dc01-mnt-001-base-dc-cdrive-evtx-evtxecmd.csv" \
     "Event ID 4688 @ 2026-05-12T03:14:22Z; row 4213" "powershell.exe with encoded args")
# then write the sentence ending in [$EV]  ->  ...encoded args [EV-dc01-00001].
```

---

## Typed findings ledger (emit alongside the markdown report)

The markdown report is the narrative; the **findings ledger is the typed record** the reviewer audits.
For each material finding in the report, append one JSON line to
`./analysis/{CASE_ID}-{ASSET_ID}-findings.jsonl`. Schema (one object per line):

```json
{"id":"FD-dc01-00001","asset":"dc01","type":"execution|persistence|lateral_movement|exfiltration|logon|ioc_hit|other","timestamps":["2026-05-12T03:14:22Z"],"summary":"powershell.exe ran with encoded args","confidence":"low|medium|high","provenance":["EV-dc01-00001"],"supporting_artifact_ids":["EV-dc01-00001","EV-dc01-00003"],"evidence":[],"human_validated_by":""}
```

Rules:
- `id` is `FD-<asset>-NNNNN` (five digits, zero-padded), **auto-assigned** by `add_finding` (max+1 per
  asset ledger) — do not number it by hand, exactly as `add_evidence` assigns `EV-` tags.
  `provenance`/`supporting_artifact_ids` reuse the same `EV-<asset>-NNNNN` tags as the markdown (and as
  the evidence registry) — the ledger never invents evidence the report doesn't cite. Every tag here
  must exist in the asset's `evidence.jsonl`.
- `evidence` is a **generated** array — `resolve_findings` fills it by joining the finding's `EV-` tags
  against the registry into `{tag, path, locator}`. Never hand-write it; it is regenerated each run, so
  the tag lists above stay the single canonical reference. Emit it as `[]`; it is populated for you.
- `confidence` is the analyst-model's qualitative call (a single uncorroborated artifact is at most `low`;
  reserve `high` for corroborated, multi-source findings — see the global "corroborate before escalating").
- **`human_validated_by` is ALWAYS emitted as `""`.** No AI step may set it; validation is an independent
  human action recorded out-of-band. This is the Validation-phase (AI Never) gate, realized as data.

Helpers for deterministic writes. `add_finding` appends one finding (auto-assigning its `FD-` id);
`resolve_findings` populates each finding's `evidence` array from the evidence registry.

```bash
# add_finding ASSET TYPE SUMMARY CONFIDENCE "EV-dc01-00001,EV-dc01-00003"  -> echoes the id (FD-dc01-00001)
# One writer per asset (assets run in parallel, each owns its own ledger) -> no lock needed.
add_finding() {
  local asset="$1" type="$2" summary="$3" conf="$4" ev="$5"
  local ledger="$CASE_ROOT/analysis/${CASE_ID}-${asset}-findings.jsonl"
  python3 - "$ledger" "$asset" "$type" "$summary" "$conf" "$ev" <<'PY'
import json, os, re, sys
ledger, asset, type_, summary, conf, ev = sys.argv[1:7]
mx = 0
if os.path.exists(ledger):
    for line in open(ledger, encoding="utf-8"):
        line = line.strip()
        if line:
            m = re.search(r'-(\d{5})$', json.loads(line).get("id", ""))
            if m: mx = max(mx, int(m.group(1)))
fid = "FD-%s-%05d" % (asset, mx + 1)
tags = [t for t in ev.split(",") if t]
rec = {"id": fid, "asset": asset, "type": type_, "timestamps": [], "summary": summary,
       "confidence": conf, "provenance": tags, "supporting_artifact_ids": tags,
       "evidence": [], "human_validated_by": ""}
with open(ledger, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
print(fid)
PY
}

# resolve_findings FINDINGS_FILE  -> (re)fills each finding's "evidence" array from the registry.
# Joins the finding's EV- tags (provenance ∪ supporting_artifact_ids) to {tag,path,locator}. Idempotent.
# Loads every analysis/*-evidence.jsonl into one map — EV tags are globally unique, so this also
# resolves correlation findings whose tags span assets. Non-EV provenance entries (FD-/CORL-) are
# finding cross-references, not evidence, and are excluded. An EV tag with no registry record becomes
# {path:null, locator:"UNRESOLVED"} so the gap stays visible.
resolve_findings() {
  local ledger="$1"
  [ -f "$ledger" ] || return 0
  python3 - "$ledger" "$CASE_ROOT"/analysis/*-evidence.jsonl <<'PY'
import json, glob, os, sys
ledger = sys.argv[1]
reg = {}
for p in sys.argv[2:]:
    if not os.path.isfile(p): continue
    for line in open(p, encoding="utf-8"):
        line = line.strip()
        if not line: continue
        r = json.loads(line)
        reg.setdefault(r["tag"], {"tag": r["tag"], "path": r.get("path"),
                                  "locator": r.get("locator", "")})
out = []
for line in open(ledger, encoding="utf-8"):
    line = line.strip()
    if not line: continue
    f = json.loads(line)
    seen, ev = set(), []
    for t in list(f.get("provenance", [])) + list(f.get("supporting_artifact_ids", [])):
        if not t.startswith("EV-") or t in seen: continue
        seen.add(t)
        ev.append(reg.get(t, {"tag": t, "path": None, "locator": "UNRESOLVED"}))
    f["evidence"] = ev
    out.append(json.dumps(f, ensure_ascii=False))
open(ledger, "w", encoding="utf-8").write("\n".join(out) + ("\n" if out else ""))
PY
}
```

---

## Report sections

Each `{CASE_ID}-{ASSET_ID}-analysis-report.md` must contain:

#### Examination Approach
The three-tier prioritization used (analyst framing, not a finding — carries no `[EV-]` citation):
- **Working hypothesis** — the class derived from the case context (`ransomware | data_exfil |
  lateral_movement | persistence_backdoor | credential_theft | unknown`), and whether it was inferred
  from explicit context or defaulted (state the assumption when `unknown`).
- **Tier 1 — Asset rank** — this asset's position in the case-wide asset order and the one-line basis
  (named in incident notes / IOC match / role × hypothesis). The asset tier is case-level; restating it
  per report keeps each report self-contained.
- **Tier 2 — Source order** — the asset's sources (from the Sources Inventory: disk volume[s] +
  `memory*/`) in the order examined, with the one-line basis (source-type × hypothesis).
- **Tier 3 — Per-source artifact order** — the deep-dive order of artifact classes within each source
  (from the playbook).
Order only — every asset, source, and present artifact was still reviewed; absent/failed ones appear in
**Gaps and Unknowns**.

#### Asset Summary
System characterization from parsed artifacts:
- OS version, build number, install date (SOFTWARE hive)
- Hostname (SYSTEM hive `ComputerName`)
- Timezone (SYSTEM hive)
- User accounts: username, SID, creation date, last login, last logoff
- Last system shutdown (Event ID 6006 / SYSTEM hive)

#### Timeline of Relevant Events
Chronological (UTC), evidence-confirmed events only. No speculation. Include `high`- and
`medium`-confidence events; exclude `low`/uncorroborated entries (record those in **Gaps and
Unknowns**, not here). Format: `YYYY-MM-DD HH:MM:SS UTC | Source | Event | Confidence`. Tag each
row's `Confidence` (`high|medium`) on the same scale as the findings ledger — a row's tier matches
its ledger finding where one exists. Mark which events fall inside the Incident Window.

#### Evidence of Execution
- Prefetch (binary, run count, last run, volume serial)
- Amcache (first seen, SHA1)
- Shimcache (last modified, executed flag)
- Process evidence from memory (Volatility pstree, cmdline)

#### Persistence Mechanisms
- Registry ASEP keys (Run, RunOnce, Services, Scheduled Tasks — RECmd output)
- Scheduled task XML (MFT or filesystem)
- Suspicious services (svcscan, registry Services key)

#### Lateral Movement
- Net use / SMB (Event IDs 5140, 5145)
- RDP logons (4624 type 10, 4778)
- PsExec / WMI / DCOM artifacts
- Admin share access

#### Data Exfiltration
- Large outbound connections (SRUM network data)
- Staged archive files (MFT, shellbags)
- Cloud sync / FTP client artifacts

#### Logon Activity
- Logon/logoff events (4624, 4625, 4634, 4647, 4648, 4672), grouped by account and logon type
- Flag privileged logons and unusual times

#### IOC Hits
Cross-reference every indicator from the case context IOC block (greps above):
- File name / hash matches (MFT, Amcache, prefetch, filesystem)
- IP / domain hits (SRUM network, event logs)
- Service / registry key matches

Each hit is sourced from the artifact that produced it (cite its `[EV-<asset>-NNNNN]` tag). Because the
indicator also appears in the case context, tag the hit **"Corroborated by provided context"** — the
context confirms relevance but is never the source of the finding.

#### ATT&CK Mapping
Map evidence-backed findings to MITRE ATT&CK techniques — **technique-level only, never
person-attribution**. Include a technique only when a cited artifact supports it; do not import TTPs
from `case_context.md` unless an artifact confirms them (tag such rows "Corroborated by provided
context"). One row per mapped finding:

`| Tactic | Technique (ID — Name) | Finding / Behaviour | Evidence |`

Reuse the same `[EV-<asset>-NNNNN]` tags as the report body; a finding with no supporting artifact does not
appear here.

#### Gaps and Unknowns
- Event log gaps (missing ranges or cleared logs — Event ID 1102/104)
- Prefetch absent (document reason)
- Artifacts not present or unreadable (file, reason, implication)
- Artifacts that failed parsing (check `audit/<asset_id>/parse_state.txt` and `audit/artifact_failures.log`)
- **Every assumption or path chosen autonomously** — durably recorded in `./audit/decisions.log` (per
  the global Operator Preferences); surface the material ones here for the human reader

#### Evidence Index
Appendix table — **generated, not hand-written.** `render_evidence_index "$ASSET"` (called at the end
of `analyze_asset`) projects the asset's `evidence.jsonl` registry into this table. See
`/case-evidence-verify` for the format and the registry schema.

---

## Notes

- Read-only on `export/`. This skill writes only to `analysis/` — never to `context/case_context.md`
  (investigator-maintained), `sources/`, `audit/`, or `reports/`.
- One report per asset; the counter resets to `00001` per report.
- **No person-attribution.** Identify accounts, SIDs, hosts, and IPs — never link an artifact to a named
  natural person (e.g. do not write "the attacker is <Name>"). Attribution stops at the account/host level.
- Emit the typed findings ledger (above) in addition to the markdown; `human_validated_by` stays empty.
- Next step: `/case-correlate`.
