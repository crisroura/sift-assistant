---
name: dfir-sleuthkit-file-recovery
description: Recover and analyze files directly from a raw disk image without mounting. Use to list allocated and deleted files, extract files by inode, read inode metadata and filesystem info, and build MAC-time bodyfile timelines on a Windows asset.
---

# dfir-sleuthkit-file-recovery — File System Analysis with The Sleuth Kit

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

The Sleuth Kit (TSK) reads a disk image directly — no mount required — to browse the filesystem, list
allocated and deleted files, extract files by inode, read inode metadata, and generate MAC-time
bodyfiles. It works on the raw `ewf1` exposed by `/tools-mount-e01`, selecting a volume with a sector
offset (`-o`).

**Tools (all on PATH):** `fls`, `icat`, `istat`, `ils`, `ffind`, `fsstat`, `blkls`, `mactime`,
`tsk_recover`, `mmls`.

---

# ── PART 1 · PARSING (used by /case-parse) ──

## Case Path Convention

| Input | Path |
|-------|------|
| Raw disk (from ewfmount) | `./sources/<asset_id>/e01-<imgbase>/ewf1` |

Output: `./export/<asset_id>/<source-dir>/recovered/`, `.../recovered-unalloc/`, and `.../timeline/`.

`<source-dir>` mirrors the source the image came from, **verbatim**, per the canonical `/case-parse`
layout. TSK reads the raw `ewf1` directly (no mount), so it selects a volume by sector offset (`-o`);
set `<source-dir>` to the EWF container dir plus that offset — `<e01-imgbase>-p<OFFSET>`
(e.g. `e01-base-dc-cdrive-p2048`) — so each volume's output stays separate and traceable to origin.
All input comes from `./sources/`.

### Set the partition offset first
```bash
DISK="./sources/<asset_id>/e01-<imgbase>/ewf1"
mmls "$DISK"          # read the partition table; pick the NTFS volume's Start sector
OFFSET=2048           # sector offset of the target volume (not bytes)
PART="e01-<imgbase>-p$OFFSET"   # export second segment: source container + offset (traceable)
```

---

## Parsing Steps

### 1. List files (allocated + deleted)
```bash
fls -r -o "$OFFSET" "$DISK"                 # recursive listing
fls -r -o "$OFFSET" "$DISK" | grep "^[-d]/[-d] \*"   # deleted entries (marked with *)
ffind -o "$OFFSET" "$DISK" "Windows/System32/STUN.exe"   # find a file -> inode
```

### 2. Extract a file by inode
```bash
mkdir -p "./export/<asset_id>/$PART/recovered"
icat -o "$OFFSET" "$DISK" <inode> | tee "./export/<asset_id>/$PART/recovered/<filename>" > /dev/null
```

### 3. Inode metadata
```bash
istat -o "$OFFSET" "$DISK" <inode>          # timestamps, size, allocated blocks
fsstat -o "$OFFSET" "$DISK"                 # filesystem type, cluster size, $MFT location
```

### 4. Bulk recovery
```bash
mkdir -p "./export/<asset_id>/$PART/recovered"
tsk_recover -o "$OFFSET" -a "$DISK" "./export/<asset_id>/$PART/recovered/"        # allocated
tsk_recover -o "$OFFSET" -e "$DISK" "./export/<asset_id>/$PART/recovered-unalloc/" # + deleted
```

### 5. MAC-time bodyfile + timeline
```bash
mkdir -p "./export/<asset_id>/$PART/timeline"
fls -r -m / -o "$OFFSET" "$DISK" | tee "./export/<asset_id>/$PART/timeline/<asset_id>-$PART-fls.body" > /dev/null
mactime -b "./export/<asset_id>/$PART/timeline/<asset_id>-$PART-fls.body" -d \
  | tee "./export/<asset_id>/$PART/timeline/<asset_id>-$PART-mac-mactime.csv" > /dev/null
# Date-bounded:
mactime -b "./export/<asset_id>/$PART/timeline/<asset_id>-$PART-fls.body" -d 2023-01-20 2023-02-01 \
  | tee "./export/<asset_id>/$PART/timeline/<asset_id>-$PART-mac-filtered-mactime.csv" > /dev/null
```

> **Writing into `./export/`: tool-opened files, never a shell redirect.** A shell `>`/`>>` redirect
> whose target is `./export/` is blocked — the evidence guard's export-redirect rule, mirrored by the
> harness deny on `Write(./export/**)`. `icat`, `fls -m`, and `mactime` all emit to stdout, so capture
> them with `tee` (which opens the `./export/` file itself); `tsk_recover` already writes its output
> directory directly and needs no change. The only `>` above targets `/dev/null`, to mute the
> duplicated stdout. Do **not** reroute this output to `./analysis/` to dodge the block (see
> Preconditions) — recovered files and bodyfile/timeline are parsed evidence and belong under
> `./export/`.

---

## Fallback Tool

TSK is itself the low-level fallback when EZ artifact parsers cannot reach a file (e.g. a locked or
partially corrupt volume): extract the raw artifact by inode with `icat`, then parse the recovered
copy with the relevant `dfir-*` skill. For files with no inode (overwritten), use
`/dfir-file-carving`.

---

## Parsing Notes

- TSK reads evidence directly — no mount and no writes to the source.
- Sector size is almost always 512; confirm with `fsstat` for 4K-native drives.
- All output goes under `./export/` only — never give TSK write access to evidence.

---

# ── PART 2 · ANALYSIS (used by /case-analyze) ──

## Key Fields

| Output | Field | Meaning |
|--------|-------|---------|
| `fls` | type flags `r/r`, `d/d`, leading `*` | file vs dir; `*` = deleted |
| `fls` | inode (e.g. `64-128-1`) | MFT entry-sequence-attribute address for `icat`/`istat` |
| `istat` | Created / File Modified / MFT Modified / Accessed | the four NTFS `$SI` times for the inode |
| `mactime` | MACB column | which timestamp (m/a/c/b) the row represents at that instant |

---

## Interpretation & Analysis

- **Deleted-but-recoverable:** `fls` entries marked `*` still have inode metadata; `icat`/`tsk_recover`
  recover their content if the clusters were not reused. Prioritise IOC filenames among deleted rows.
- **Offset selects the volume:** every command needs the right `-o` offset; a wrong offset yields no
  filesystem. Use `mmls` to confirm and `fsstat` to validate the volume type.
- **Bodyfile timeline = ground truth for file activity:** the `fls -m` bodyfile feeds `mactime` to
  show creation/modification bursts; cluster these against the incident window to spot staging,
  dropper writes, and mass changes.
- **Fully overwritten files have no inode** — TSK cannot recover them; switch to `/dfir-file-carving`.
- **Mind the order:** `istat`/`mactime` report `$SI` times; cross-check against `$MFT` `$FN` times
  (`/dfir-mft`) when timestomping is suspected.
