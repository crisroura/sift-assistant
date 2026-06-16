---
name: dfir-file-carving
description: Carve files and extract features from unallocated space or a raw disk image by file signature, without a filesystem. Use to recover deleted-and-overwritten files (no MFT entry) and to sweep an image or memory for embedded IOCs (emails, URLs, domains, PE headers) on a Windows asset.
---

# dfir-file-carving — Recover Files from Unallocated Space

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

Carving recovers file content from unallocated space or a raw image using file signatures (magic
bytes) — no filesystem needed. Use it when files were deleted **and overwritten** (no MFT/inode
entry remains, so `/dfir-mft` and `/dfir-sleuthkit-file-recovery` cannot help) or the filesystem is
damaged. A separate feature sweep extracts IOC strings (emails, URLs, PE headers) from the same bytes.

This operates on the whole disk image, so output is **asset-level** (no per-partition split).

**Carvers (router-confirmed):** `foremost`, `scalpel`. **Feature extraction:** `bulk_extractor`
(standard SIFT tool; confirm with `/tools-preflight`). **Broad-format recovery:** `photorec`.

---

# ── PART 1 · PARSING (used by /case-parse) ──

## Case Path Convention

| Input | Path |
|-------|------|
| Raw disk (from ewfmount) | `./sources/<asset_id>/e01-<imgbase>/ewf1` |

Output: `./export/<asset_id>/carving/` (asset-level). All input comes from `./sources/`; never give a
carver write access to evidence.

---

## Parsing Steps

### 1. Isolate unallocated space first (reduces noise)
```bash
DISK="./sources/<asset_id>/e01-<imgbase>/ewf1"
OFFSET=2048   # target volume start sector (from mmls)
mkdir -p "./export/<asset_id>/carving"
blkls -o "$OFFSET" "$DISK" > "./export/<asset_id>/carving/<asset_id>-unalloc.raw"
```

### 2. Signature carve with foremost (primary)
```bash
OUT="./export/<asset_id>/carving/foremost"; mkdir -p "$OUT"
foremost -t exe,pdf,zip,doc,docx,jpg,png -o "$OUT" \
  -i "./export/<asset_id>/carving/<asset_id>-unalloc.raw"
# foremost reads RAW images — use ewf1/unalloc.raw, never the .E01 container.
```

### 3. Alternative carver — scalpel
```bash
OUT="./export/<asset_id>/carving/scalpel"; mkdir -p "$OUT"
scalpel -o "$OUT" "./export/<asset_id>/carving/<asset_id>-unalloc.raw"
# scalpel is configured via /etc/scalpel/scalpel.conf — enable the needed file types there.
```

### 4. Feature / IOC sweep with bulk_extractor
```bash
OUT="./export/<asset_id>/carving/bulk"; mkdir -p "$OUT"
bulk_extractor -o "$OUT" -e email -e url -e domain -e base64 -e exe -j 4 "$DISK"
```

---

## Output Files

foremost/scalpel: recovered files grouped by type in `$OUT/<type>/`, plus an `audit.txt`/report.

bulk_extractor feature files in `$OUT/`:

| File | Contents |
|------|----------|
| `email.txt` | Email addresses |
| `url.txt` / `domain.txt` | URLs / domain names |
| `exe.txt` | Embedded PE headers (carved executables) |
| `base64.txt` | Base64-encoded blobs |
| `alerts.txt` | High-confidence IOC matches |

---

## Fallback Tool

If foremost yields nothing, try **scalpel** (different config/engine) and then **photorec**
(widest format coverage). For an IOC string sweep when whole-file carving is not the goal, use
**bulk_extractor**. If every carver returns nothing on a region known to hold data, record it in
`./audit/artifact_failures.log` and note it in Gaps / Unknowns.

---

## Parsing Notes

- foremost is faster but covers fewer types than photorec; `photorec` (broad-format, interactive)
  recovers the widest range — run it when foremost/scalpel miss a needed type.
- All output paths must be under `./export/`.

---

# ── PART 2 · ANALYSIS (used by /case-analyze) ──

## Interpretation & Analysis

- **Carving recovers content, not metadata** — no filename, path, or timestamp survives. A carved
  file is a lead; tie it to a name/time via `$MFT`/UsnJrnl, Prefetch, or its own internal metadata
  (PE header, document properties).
- **Carve unallocated first** (`blkls`) to avoid re-recovering live allocated files and to focus on
  deleted/overwritten content.
- **Feature sweep for fast IOC triage:** grep `email.txt`/`url.txt`/`domain.txt` against the case IOC
  block; `exe.txt` locates PE executables hiding in slack, swap, or carved blobs (also works on a
  memory image with `-e exe`).
- **Validate carved files** before trusting them — signature carving produces false positives and
  truncated files; open/parse a carved artifact to confirm it is intact.

---

## Analysis Notes

- bulk_extractor output is plain text; grep IOC strings directly.
