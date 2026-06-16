---
name: dfir-recyclebin
description: Parse and interpret the Windows Recycle Bin ($Recycle.Bin, $I/$R pairs and legacy INFO2). Use to prove which account deleted which named file at what time, and to recover the deleted content, on a Windows asset.
---

# dfir-recyclebin — Parse the Windows Recycle Bin ($I + $R)

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

The Recycle Bin records files a user deleted without bypassing it. On Vista+ each deletion produces a
pair under `$Recycle.Bin\<SID>\`:

- **`$I` file** — metadata: the original full path, original size, and deletion timestamp.
- **`$R` file** — the recovered content of the deleted file (same suffix as its `$I` partner).

This proves a specific account (the SID owning the subdirectory) deleted a named file at a known
time, and often lets the original content be recovered — high value for anti-forensics and
data-theft/staging cases.

**Primary tool:** `$EZRBCMD` (RBCmd). No second independent parser is shipped.

---

# ── PART 1 · PARSING (used by /case-parse) ──

## Case Path Convention

`<source-dir>` is the operator-created mount subdirectory under `./sources/<asset_id>/`, used
**verbatim** — copy the real directory name exactly as it appears (e.g. `mnt-001-base-dc-cdrive`),
never a partition number or other abbreviation. The export path mirrors that name one-to-one
(`export/<asset>/<source-dir>/<artifact>/`, the canonical layout owned by `/case-parse`).

| Input | Path |
|-------|------|
| Recycle Bin root | `./sources/<asset_id>/<source-dir>/$Recycle.Bin/` |
| Per-SID folder | `./sources/<asset_id>/<source-dir>/$Recycle.Bin/S-1-5-21-…/` |
| Single $I file | `./sources/<asset_id>/<source-dir>/$Recycle.Bin/S-1-5-21-…/$IXXXXXX.ext` |

Output: `./export/<asset_id>/<source-dir>/recyclebin/`
Output filename: `<asset_id>-<source-dir>-recyclebin-rbcmd.csv`. All input comes from `./sources/`.

Note: `$Recycle.Bin` begins with `$` and must be escaped in the shell so it is not read as a variable
(`"...\$Recycle.Bin"`).

---

## Parsing Steps

### 0. Locate the Recycle Bin root (case-insensitive) — run first
```bash
SRC="./sources/<asset_id>/<source-dir>"
# Single quotes keep $ literal; -ipath matches $Recycle.Bin / $RECYCLE.BIN at the volume root.
RBROOT="$(find "$SRC" -maxdepth 2 -ipath '*/$Recycle.Bin' -type d 2>/dev/null | head -1)"
[ -n "$RBROOT" ] && echo "Using: $RBROOT" || echo '$Recycle.Bin not found under '"$SRC"' (any case)'
```
`$Recycle.Bin` sits at the volume root and a Linux mount is case-sensitive — see the case-insensitive
convention in `/case-parse`. Steps below use `$RBROOT`; re-resolve it if you run a block standalone.

### 1. Parse the whole Recycle Bin to CSV (primary)
```bash
$EZRBCMD \
  -d "$RBROOT/" \
  --csv "./export/<asset_id>/<source-dir>/recyclebin/" \
  --csvf "<asset_id>-<source-dir>-recyclebin-rbcmd.csv" \
  -q
```
Expected output: a CSV with one row per `$I` record found. `RBCmd -d` recurses every per-SID
subdirectory automatically.

### 2. Parse a single $I metadata file (human-readable)
```bash
$EZRBCMD -f "$RBROOT/S-1-5-21-…/\$IXXXXXX.ext"
```

---

## Fallback Tool

If `$EZRBCMD` fails, retry once via the router entry "Windows Recycle Bin"
(`/usr/local/bin/RBCmd` or its lowercase wrapper, in `~/.claude/SIFT_SERVER_DFIR_TOOLS.json`). There
is no second independent parser shipped; if both fail, the artifact is **unparseable** — log it in
`./audit/artifact_failures.log` and surface it in Gaps / Unknowns. (The `$I` format is small and
fixed-layout, so a single record can be hand-decoded from a hexdump if ever required.)

---

## Parsing Notes

- Windows XP used a hidden `INFO2` index instead of `$I`/`$R` pairs; RBCmd parses INFO2 as well.
- An empty Recycle Bin root is normal — record EMPTY, do not treat it as a tool failure.

---

# ── PART 2 · ANALYSIS (used by /case-analyze) ──

## Key Fields

| Column | Meaning |
|--------|---------|
| `SourceName` | The `$I` file parsed |
| `FileName` | Original full path of the deleted file |
| `FileSize` | Original size in bytes |
| `DeletedOn` | Deletion timestamp (UTC) |

The owning **SID** is the name of the per-SID subdirectory the `$I` file lived in — map it to an
account via the SAM hive (see `/dfir-registry`).

---

## Interpretation & Analysis

- **Attribution:** the SID subdirectory ties the deletion to a specific account — record the SID, not
  a person.
- **Content recovery:** pair each `$I` with its `$R` (same suffix) to recover the file —
  `$IABC123.docx` ↔ `$RABC123.docx`.
- **Anti-forensics signal:** mass deletions clustered in time near the end of the incident window
  suggest cleanup; deletions from staging paths (`\Temp\`, `\Users\Public\`, `\AppData\`) are common
  in data theft.
- **Missing content:** an `$I` with no matching `$R` means the content was overwritten or purged —
  note it; the metadata still proves the file existed and was deleted.
- **Bypass check:** shift-delete and tool wipes never reach the bin — cross-check `$UsnJrnl` and
  `$MFT` (`/dfir-mft`) for deletions that bypassed the Recycle Bin.
