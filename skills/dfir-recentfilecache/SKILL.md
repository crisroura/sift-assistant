---
name: dfir-recentfilecache
description: Parse and interpret Windows 7 RecentFileCache.bcf. Use to recover the full paths of executables that ran since the last AppCompat flush on a Windows 7 asset — a third execution-evidence source alongside Prefetch and Amcache.
---

# dfir-recentfilecache — Parse RecentFileCache.bcf

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

`RecentFileCache.bcf` is a **Windows 7 / Server 2008 R2** application-compatibility artifact that
records the full paths of executables run since the last AppCompat flush. A path in the file is
**execution evidence**: that binary ran. On Windows 8+ it was superseded by Amcache.hve, so the file
is **absent on Win8/10/11** — treat its absence as a clean skip, not a failure.

**Primary tool:** `$EZRECENTFILECACHE` (RecentFileCacheParser). No second parser exists.

---

# ── PART 1 · PARSING (used by /case-parse) ──

## Case Path Convention

`<source-dir>` is the operator-created mount subdirectory under `./sources/<asset_id>/`, used
**verbatim** — copy the real directory name exactly as it appears (e.g. `mnt-001-base-dc-cdrive`),
never a partition number or other abbreviation. The export path mirrors that name one-to-one
(`export/<asset>/<source-dir>/<artifact>/`, the canonical layout owned by `/case-parse`).

| Input | Path |
|-------|------|
| RecentFileCache.bcf | `./sources/<asset_id>/<source-dir>/Windows/AppCompat/Programs/RecentFileCache.bcf` |

Output: `./export/<asset_id>/<source-dir>/recentfilecache/`
Output filename: `<asset_id>-<source-dir>-recentfilecache-rfcparser.csv`. All input from `./sources/`.

---

## Parsing Steps

### 0. Locate the artifact (case-insensitive, Win7 only) — run first
```bash
SRC="./sources/<asset_id>/<source-dir>"
RFC="$(find "$SRC" -ipath '*/Windows/AppCompat/Programs/RecentFileCache.bcf' -type f 2>/dev/null | head -1)"
[ -n "$RFC" ] \
  && echo "RecentFileCache present (Win7): $RFC" \
  || echo "absent — Win8+ or never created; use Amcache instead"
```
`find -ipath` resolves any casing of `Windows/AppCompat/Programs/` — see the case-insensitive
convention in `/case-parse`. Steps below use `$RFC`; re-resolve it if you run a block standalone.

### 1. Parse to CSV (primary)
```bash
$EZRECENTFILECACHE \
  -f "$RFC" \
  --csv "./export/<asset_id>/<source-dir>/recentfilecache/" \
  --csvf "<asset_id>-<source-dir>-recentfilecache-rfcparser.csv"
```
Expected output: a CSV listing executable paths. The artifact carries **no per-entry timestamp**.

---

## Fallback Tool

There is no second independent parser for `.bcf`. If `$EZRECENTFILECACHE` fails, retry once via the
router entry "Windows RecentFileCache" (`/usr/local/bin/RecentFileCacheParser`); if that also fails,
the artifact is **unparseable** — log it in `./audit/artifact_failures.log` and surface it in the
report's Gaps / Unknowns section.

---

## Parsing Notes

- The lowercase wrapper `/usr/local/bin/recentfilecacheparser` is also installed on SIFT.

---

# ── PART 2 · ANALYSIS (used by /case-analyze) ──

## Key Fields

| Column | Meaning |
|--------|---------|
| `SourceFile` | The `RecentFileCache.bcf` parsed |
| `ExecutablePath` | Full path of an executable that ran since the last AppCompat flush |

There is no timestamp per entry — the artifact proves execution, not *when*.

---

## Interpretation & Analysis

- **Every path is an execution lead.** Flag those in `\Temp\`, `\AppData\`, `\Users\Public\`,
  `\Windows\Temp\`, `\ProgramData\`, or other non-standard locations.
- **No timestamps:** never place a RecentFileCache hit on the timeline by itself — bound its timing by
  correlating the path with Prefetch (`LastRun`), Amcache (first-seen), Shimcache, and `$MFT`/`$SI`
  timestamps for the same binary.
- **Win7 execution triad:** RecentFileCache + Prefetch + Amcache are the three Win7-era execution
  sources; corroborate a suspect binary across them before escalating.

---

## Analysis Notes

- Present only on Windows 7 / Server 2008 R2. On newer systems this skill records EMPTY/skips.
