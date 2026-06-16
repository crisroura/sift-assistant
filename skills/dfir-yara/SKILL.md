---
name: dfir-yara
description: Scan files, directories, and memory images for malware patterns and IOCs using YARA rules. Use to sweep evidence for known malware families, suspicious code, and threat-intel indicators on a Windows asset.
---

# dfir-yara — Threat Hunting with YARA

## Preconditions — runs inside the parse phase

This is a **parse-phase** artifact parser: it writes parsed output under `./export/`, which the
evidence guard permits **only while the phase marker `./audit/.dfir_phase` reads `parse`**. Normal use
is under `/case-parse` (or `/case-investigate`), which has already armed the parse phase — so just parse.

**The phase marker is owned solely by `/case-parse`.** `/case-parse` arms `parse` at the start and
writes `parse-complete` only once the **entire** parse phase has finished (closing the phase and
re-locking `./export/`). This skill — and every other artifact parser — must **never** write, change,
or close `./audit/.dfir_phase`: not to unblock a write, not for any reason.

**Do not stop the investigation if an `./export/` write is blocked** (guard message `BLOCKED
(evidence integrity): … outside the parse phase`, or a permission denial on an `export/` write): the
parse phase just isn't armed. Run **`/case-parse`** — the marker's owner — to arm it, then re-run the
blocked step. Do **not** set the marker yourself, and **never** reroute parsed output to `./analysis/`
to dodge the block (`./analysis/` is for analysis-phase tool runs only) — parsed evidence belongs
under `./export/` and nowhere else.

---

## Overview

YARA matches files, directories, and memory images against pattern rules. Use it to sweep evidence
for known malware families, suspicious code constructs, and IOCs extracted from threat intelligence.

On this SIFT host the **`yara` CLI is absent**; the installed `python3-yara` module is the scan path,
driven through `$YARA_PYTHON` (python3). Supply a rules path per case via `$YARA_RULES` (no rules
ship on the host).

**Primary path:** `$YARA_PYTHON` + the `yara` module. **Rules:** `$YARA_RULES` (operator-supplied).

---

# ── PART 1 · PARSING (used by /case-parse) ──

## Case Path Convention

`<source-dir>` is the operator-created mount subdirectory under `./sources/<asset_id>/`, used
**verbatim** — copy the real directory name exactly as it appears (e.g. `mnt-001-base-dc-cdrive`),
never a partition number or other abbreviation. The export path mirrors that name one-to-one
(`export/<asset>/<source-dir>/<artifact>/`, the canonical layout owned by `/case-parse`).

| Scan target | Path |
|-------------|------|
| Mounted filesystem | `./sources/<asset_id>/<source-dir>/` |
| Memory image | `./sources/<asset_id>/<hostname>.img` |
| Carving / recovered output | `./export/<asset_id>/<source-dir>/carving/` |

Output: `./export/<asset_id>/<source-dir>/yara/` (filesystem scans) or
`./export/<asset_id>/yara/` (memory, asset-level).
Output filename: `<asset_id>-<source-dir>-yara-hits.txt`. Input from `./sources/` (or prior `./export/`).

---

## Parsing Steps

### 1. Recursively scan a mounted filesystem (primary)
```bash
RULES="$YARA_RULES/index.yar"     # an index .yar that includes the rule files
TARGET="./sources/<asset_id>/<source-dir>/"
OUT="./export/<asset_id>/<source-dir>/yara"; mkdir -p "$OUT"

$YARA_PYTHON - "$RULES" "$TARGET" \
  > "$OUT/<asset_id>-<source-dir>-yara-hits.txt" <<'PY'
import sys, os, yara
rules = yara.compile(filepath=sys.argv[1])
def scan(p):
    try:
        for m in rules.match(p, timeout=60):
            print(f"{m.rule}\t{p}\t{m.meta.get('description','')}")
    except Exception:
        pass
t = sys.argv[2]
if os.path.isfile(t):
    scan(t)
else:
    for root, _, files in os.walk(t):
        for fn in files:
            scan(os.path.join(root, fn))
PY
```
Expected output: one tab-separated line per hit (`rule  path  description`). Empty output = no
matches (record EMPTY, not failure). Reuse the same heredoc against a memory image or the carving dir
by changing `TARGET`.

### 2. Scan with a single custom IOC ruleset
Write case IOCs to a rule file, then point `RULES` at it:
```yara
rule IOC_STUN_exe {
    meta:
        description = "STUN.exe by path/mutex/url"
    strings:
        $path  = "C:\\Windows\\System32\\STUN.exe" ascii nocase
        $mutex = "STUNMutex_v1" ascii
        $url   = "http://172.15.1.20" ascii
    condition:
        any of them
}
```
Save to `./export/<asset_id>/<source-dir>/yara/<asset_id>-custom.yar` and use it as `RULES` above.

---

## Scanner Options (yara module)

| Concept | How |
|---------|-----|
| Recursive scan | walk the directory in python (shown above) |
| Per-file timeout | `rules.match(path, timeout=60)` — skip pathological files |
| Matched strings | `m.strings` (version-dependent API) — `m.meta` is the stable field for description |
| Compiled rules | `yara.compile(filepath=...)` once, reuse `rules` across files (fast) |
| Tag filter | compile rules with tags, then `[r for r in matches if 'tag' in r.tags]` |

---

## Fallback Tool

There is no second scanner installed (the `yara` CLI is MISSING; `python3-yara` is the only engine).
If `$YARA_PYTHON` cannot import `yara`, or no rules are available, the sweep cannot run — record it in
`./audit/artifact_failures.log` and surface it in Gaps / Unknowns. For a rules-free IOC sweep, fall
back to literal string hunting via `/dfir-strings` and `bulk_extractor` (`/dfir-file-carving`).

---

## Parsing Notes

- Put cheap conditions first in rules (`filesize`, `uint16(0)==0x5A4D` PE magic) to short-circuit costly
  string scans; guard with `filesize < 50MB` to avoid memory exhaustion on huge files.
- No rules ship on the host — `$YARA_RULES` must be populated per case (e.g. Neo23x0/signature-base,
  Elastic detection-rules, CISA MAR rules).

---

# ── PART 2 · ANALYSIS (used by /case-analyze) ──

## Interpretation & Analysis

- **A YARA hit is a lead, not a verdict.** Confirm each match: open the file, check it is the expected
  type, and corroborate with hash (Amcache SHA1), execution (Prefetch), or network (SRUM) evidence.
- **System directories produce false positives** — baseline-scan a clean image of the same build to
  identify FP-prone rules before trusting hits in `\Windows\`.
- **High-entropy, no-match files = packed/encrypted** — YARA sees raw bytes and cannot match inside
  packed content; pivot to `/dfir-strings` + entropy review and unpack first.
- **Memory scanning** matches patterns in any process's address space — strong for detecting injected
  or fileless code that never touched disk. Run YARA over the `.img` and correlate hits with
  `/dfir-memory-volatility` process/injection findings.
- **Record provenance:** note the rule name and source path for every hit so a human can validate it
  (`human_validated_by` stays empty — AI never self-validates).

---

## Analysis Notes

- YARA scans raw bytes only; it does not decrypt or deobfuscate.
