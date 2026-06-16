---
name: dfir-plaso-timeline
description: Build and query a super-timeline from a disk image. Use to merge timestamps from filesystem, event logs, registry, browser, prefetch, LNK and more into one chronological CSV for incident-window analysis and cross-asset correlation.
---

# dfir-plaso-timeline — Generate a Super-Timeline with Plaso

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

Plaso extracts timestamps from hundreds of sources on a disk image — filesystem metadata, event logs,
registry, browser history, prefetch, LNK, jump lists, SRUM and more — and merges them into one
chronological super-timeline. Run it after per-artifact parsing for comprehensive timeline analysis.
Output is **asset-level** (the whole image), not per-partition.

**Tools (on PATH):** `log2timeline.py` (build `.plaso`), `psort.py` (sort/export), `pinfo.py`
(inspect), `psteal.py` (build+export in one), `image_export.py` (extract files by type).

---

# ── PART 1 · PARSING (used by /case-parse) ──

## Case Path Convention

`<source-dir>` is the operator-created mount subdirectory under `./sources/<asset_id>/`, used
**verbatim** — copy the real directory name exactly as it appears (e.g. `mnt-001-base-dc-cdrive`),
never a partition number or other abbreviation. The export path mirrors that name one-to-one
(`export/<asset>/<source-dir>/<artifact>/`, the canonical layout owned by `/case-parse`).

| Input | Path |
|-------|------|
| Raw disk (from ewfmount) | `./sources/<asset_id>/e01-<imgbase>/ewf1` |
| Mounted filesystem | `./sources/<asset_id>/<source-dir>/` |

Output: `./export/<asset_id>/timeline/` (asset-level).
Output filename: `<asset_id>-timeline-plaso.csv` / `<asset_id>.plaso`. Input from `./sources/`.

---

## Parsing Steps

### 1. Build the .plaso storage file from the disk image (primary)
```bash
mkdir -p "./export/<asset_id>/timeline"
log2timeline.py \
  --storage-file "./export/<asset_id>/timeline/<asset_id>.plaso" \
  --parsers win_gen \
  --vss-stores all \
  --timezone UTC \
  --hashers md5 \
  "./sources/<asset_id>/e01-<imgbase>/ewf1"
```
Expected output: a `.plaso` file (typically 10–20% of image size). Build can take 1–4 h per image —
run in the background for multiple assets. Omit `--vss-stores all` / use `--hashers none` to speed up.

### 2. (Faster) build from a mounted filesystem
```bash
log2timeline.py \
  --storage-file "./export/<asset_id>/timeline/<asset_id>.plaso" \
  --parsers win_gen --timezone UTC \
  "./sources/<asset_id>/<source-dir>/"
```

### 3. Export to CSV (l2tcsv)
```bash
psort.py -o l2tcsv \
  -w "./export/<asset_id>/timeline/<asset_id>-timeline-plaso.csv" \
  "./export/<asset_id>/timeline/<asset_id>.plaso"
```

### 4. Bound or filter the export (large images)
```bash
# Date slice around a pivot
psort.py -o l2tcsv -w "./export/<asset_id>/timeline/<asset_id>-filtered-plaso.csv" \
  --slice "2023-01-24T00:00:00" --slice_size 10 \
  "./export/<asset_id>/timeline/<asset_id>.plaso"

# Keyword filter
psort.py -o l2tcsv -w "./export/<asset_id>/timeline/<asset_id>-stun-plaso.csv" \
  "./export/<asset_id>/timeline/<asset_id>.plaso" "STUN.exe OR stun.exe"
```

### 5. Inspect / merge
```bash
pinfo.py "./export/<asset_id>/timeline/<asset_id>.plaso"            # metadata, parser counts
psort.py -o l2tcsv -w "./analysis/${CASE_ID}-merged-timeline.csv" \  # cross-asset merge
  "./export/dc01/timeline/dc01.plaso" "./export/rd01/timeline/rd01.plaso"
```

---

## Fallback Tool

If plaso fails on the full image, build from the mounted filesystem (step 2) or narrow `--parsers`
to the artifacts of interest. For pure filesystem MAC-time timing without plaso, use the TSK
`fls`+`mactime` bodyfile in `/dfir-sleuthkit-file-recovery`. Log unrecoverable failures in
`./audit/artifact_failures.log`.

---

## Parsing Notes

- `win_gen` is the version-agnostic parser preset the pipeline uses; confirm presets with
  `log2timeline.py --info`.
- `image_export.py --extensions pf` (or `--names "*.evtx"`) extracts files by type without a full
  timeline — handy to pull raw artifacts for the per-artifact skills.

---

# ── PART 2 · ANALYSIS (used by /case-analyze) ──

## Key Fields (l2tcsv columns)

| Column | Meaning |
|--------|---------|
| `date` / `time` / `timezone` | Event timestamp (force UTC at build time) |
| `MACB` | Which timestamp this row represents (modified/accessed/changed/born) |
| `source` / `sourcetype` | High-level + specific origin (e.g. `LOG`/`WinEVTX`, `REG`/`UserAssist`) |
| `type` | Timestamp semantics (e.g. "Creation Time", "Last Access") |
| `user` / `host` | Associated account / hostname when known |
| `short` / `desc` | Short and full human-readable event description |
| `filename` / `inode` | Source file and inode the event came from |

---

## Interpretation & Analysis

- **Anchor to the incident window:** slice the timeline to the window first; a dense super-timeline is
  unreadable whole. The `--slice`/keyword filters are the main triage levers.
- **`source`/`sourcetype` tells you the artifact:** pivot quickly by filtering to `WinEVTX`, `PE`
  (prefetch), `REG` (registry), `WEBHIST` (browser), `LNK`, `OLECF`, etc.
- **MACB clustering:** a burst of `..B` (born/creation) rows from `FILE` source in `\Temp\`/`\AppData\`
  during the window = dropper/staging activity; correlate with `PE`/`WinEVTX` rows at the same instant.
- **Cross-artifact corroboration is built in:** because plaso merges sources, a single minute can show
  the registry Run-key write, the prefetch first-run, and the 4688 process-create together — strong,
  self-corroborating evidence. Use the per-artifact `dfir-*` outputs to confirm specifics.
- **Timezone discipline:** always build with `--timezone UTC`; a wrong tz produces off-by-hours errors
  that break correlation across assets.

---

## Analysis Notes

- `l2tcsv` opens in TimelineExplorer (Windows VM) for GUI review.
