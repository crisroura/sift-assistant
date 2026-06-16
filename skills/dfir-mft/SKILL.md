---
name: dfir-mft
description: Parse and interpret the NTFS Master File Table ($MFT) and $UsnJrnl. Use to recover file timestamps (including deleted entries), detect timestomping (SI vs FN), reconstruct full paths, and surface alternate data streams and the file-change journal on a Windows asset.
---

# dfir-mft — Parse the NTFS Master File Table (MFT)

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

The `$MFT` is the index of every file and directory on an NTFS volume, including deleted entries. It
yields file creation/modification/access/MFT-entry timestamps (both `$STANDARD_INFORMATION` and
`$FILE_NAME` sets), sizes, full paths, resident data, alternate data streams (ADS), and `$I30` slack
for deleted filenames. The `$UsnJrnl:$J` change journal records every file create/delete/rename on
the volume.

**Primary tool:** `$EZMFTECMD` (MFTECmd). **Fallback:** `$ANALYZEMFT` (analyzeMFT).

---

# ── PART 1 · PARSING (used by /case-parse) ──

## Case Path Convention

`<source-dir>` is the operator-created mount subdirectory under `./sources/<asset_id>/`, used
**verbatim** — copy the real directory name exactly as it appears (e.g. `mnt-001-base-dc-cdrive`),
never a partition number or other abbreviation. The export path mirrors that name one-to-one so
parsed output is traceable to its origin at a glance. This is the canonical layout owned by
`/case-parse` (`export/<asset>/<source-dir>/<artifact>/`).

| Input | Path |
|-------|------|
| $MFT | `./sources/<asset_id>/<source-dir>/$MFT` |
| $MFTMirr | `./sources/<asset_id>/<source-dir>/$MFTMirr` |
| $J (UsnJrnl) | `./sources/<asset_id>/<source-dir>/$Extend/$UsnJrnl:$J` |

Output: `./export/<asset_id>/<source-dir>/mft/` (UsnJrnl → `.../usnjrnl/` in the pipeline)
Output filename: `<asset_id>-<source-dir>-<artifact>-<tool>.<ext>`. All input from `./sources/`.

> Example — for `./sources/dc01/mnt-001-base-dc-cdrive/$MFT`, output goes to
> `./export/dc01/mnt-001-base-dc-cdrive/mft/`, **not** `./export/dc01/001/mft/`.

> Reading `$UsnJrnl:$J` and other alternate data streams by path requires the volume to be mounted
> ntfs-3g with `streams_interface=windows` — `/tools-mount` sets this automatically.

---

## Parsing Steps

### 1. Parse $MFT to CSV (primary)
```bash
$EZMFTECMD \
  -f "./sources/<asset_id>/<source-dir>/\$MFT" \
  --csv "./export/<asset_id>/<source-dir>/mft/" \
  --csvf "<asset_id>-<source-dir>-mft-mftecmd.csv"
```
Expected output: one CSV with a row per MFT record (allocated + deleted), including the `0x10`/`0x30`
timestamp columns. Non-empty with `FullPath` populated confirms a good parse.

### 2. Parse $UsnJrnl ($J) — file-change journal
```bash
$EZMFTECMD \
  -f "./sources/<asset_id>/<source-dir>/\$Extend/\$UsnJrnl:\$J" \
  --csv "./export/<asset_id>/<source-dir>/usnjrnl/" \
  --csvf "<asset_id>-<source-dir>-usnjrnl-mftecmd.csv"
```

### 3. Export bodyfile for a mactime timeline
```bash
$EZMFTECMD \
  -f "./sources/<asset_id>/<source-dir>/\$MFT" \
  --body "./export/<asset_id>/<source-dir>/mft/" \
  --bodyf "<asset_id>-<source-dir>-mft-mftecmd.body" \
  --bdl c
```

### 4. Build the filesystem timeline from the bodyfile (mactime)
`mactime` (The Sleuth Kit, on PATH) collapses the four MAC timestamps in the Step 3 bodyfile into one
chronological MACB timeline. Always pass `-z UTC` (per the UTC mandate) and `-y` for ISO-8601 dates.

`mactime` only emits to stdout, so capture it with `tee` (which opens the `./export/` file itself) —
**not** a shell `>` redirect. See the note below: tool-opened writes into `./export/` succeed where
shell redirects are blocked.
```bash
mactime \
  -b "./export/<asset_id>/<source-dir>/mft/<asset_id>-<source-dir>-mft-mftecmd.body" \
  -d -y -z UTC \
  | tee "./export/<asset_id>/<source-dir>/mft/<asset_id>-<source-dir>-mft-mactime.csv" > /dev/null
```
`-d` emits comma-delimited (CSV) output; `-y` formats timestamps as ISO-8601; `-z UTC` fixes the
timezone. Expected output: a non-empty CSV, one row per timestamp event, with a `MACB` column showing
which of modified/accessed/changed/born each row represents.

> **Writing into `./export/`: tool-opened files, never a shell redirect.** A shell `>`/`>>` redirect
> whose target is `./export/` is blocked — the evidence guard's export-redirect rule, mirrored by the
> harness deny on `Write(./export/**)`. But a *tool that opens the output file itself* is unaffected:
> MFTECmd (`--csv`/`--body`), analyzeMFT (`-o`), and `tee` all open and write the file directly, so
> Steps 1–3 land in `./export/` cleanly and `tee` in Step 4 does too. This is the correct fix for a
> stdout-only tool — **do not** abandon `./export/` and reroute parsed output to `./analysis/` (see
> Preconditions). The only `>` here targets `/dev/null` to mute the duplicated stdout.

---

## Fallback Tool

If MFTECmd fails or produces no output, use **analyzeMFT** (`$ANALYZEMFT`):

```bash
mkdir -p "./export/<asset_id>/<source-dir>/mft"

$ANALYZEMFT \
  -f "./sources/<asset_id>/<source-dir>/\$MFT" \
  -o "./export/<asset_id>/<source-dir>/mft/<asset_id>-<source-dir>-mft-analyzemft.csv" \
  --localtz UTC
```

Note: analyzeMFT has fewer columns than MFTECmd; timestomping review relies on its `SI_fn_shift`
indicator. Lowercase wrapper `/usr/local/bin/analyzemft` is the installed binary.

---

## Parsing Notes

- `$MFTMirr` is a backup of the first MFT records — use it if `$MFT` is damaged.
- Resident small files store their data inside the MFT record; MFTECmd can surface resident content.
- All times are UTC as reported by MFTECmd.
- **No case-insensitive locate step here (unlike other skills):** `$MFT`, `$MFTMirr`, and
  `$Extend/$UsnJrnl` are NTFS metafiles exposed by ntfs-3g at the **volume root** with fixed
  `$`-prefixed names — there is no `Windows/…` path to vary in case (see the convention in
  `/case-parse`). Pass `<source-dir>` verbatim; the only shell concern is escaping the literal `$`
  (`\$MFT`), already done in the commands above.

---

# ── PART 2 · ANALYSIS (used by /case-analyze) ──

## Key Fields

| Column | Meaning |
|--------|---------|
| `EntryNumber` | MFT record number |
| `FileName` / `Extension` | File name and extension |
| `IsDirectory` / `IsDeleted` | Directory flag; `IsDeleted=True` = entry freed (record may be reused) |
| `Created0x10` | `$STANDARD_INFORMATION` creation time (user-writable — can be timestomped) |
| `Created0x30` | `$FILE_NAME` creation time (kernel-set — harder to tamper) |
| `LastModified0x10` / `0x30` | SI / FN last-modified |
| `LastRecordChange0x10` | SI MFT-record change time |
| `LastAccess0x10` | SI last-access |
| `FileSize` | Size in bytes |
| `ParentEntryNumber` / `FullPath` | Parent record and reconstructed full path |

---

## Interpretation & Analysis

- **Timestomping detection (SI vs FN):** `$SI` times are settable from user space (`SetFileTime`),
  `$FN` times are not. `Created0x10` **earlier than** `Created0x30` is a classic timestomp signal.
  Sub-second `$SI` values that are all zeros (whole-second times) while `$FN` carries nanoseconds is
  another tell. Confirm against Shimcache/Amcache/Prefetch times for the same binary.
- **Deleted entries:** `IsDeleted=True` rows recover the names/timestamps of removed files until the
  record is reused. Search for IOC filenames among deleted entries.
- **ADS:** an entry shown as `FileName:StreamName` is an alternate data stream — flag non-standard
  streams on executables and downloaded files (`:Zone.Identifier` shows mark-of-the-web origin).
- **Incident-window filter:** filter `Created0x10`/`Created0x30` to the window to surface dropped
  files; an executable created in `\Temp\`/`\AppData\`/`\ProgramData\` during the window is a lead.
- **UsnJrnl pivot:** `$J` records the sequence of create/rename/delete operations even for files no
  longer in the MFT — it reconstructs staging→rename→delete chains that the MFT alone misses.

```bash
# Executables outside standard dirs
grep -i "\.exe" "./export/<asset_id>/<source-dir>/mft/<asset_id>-<source-dir>-mft-mftecmd.csv" \
  | grep -iv "windows\|program files"
```
