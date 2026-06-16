---
name: dfir-amcache
description: Parse and interpret Amcache.hve. Use to recover SHA1 hashes, full paths, PE compile times and first-seen metadata for programs present on a Windows asset, enabling hash-based IOC matching and proof a binary existed even after deletion.
---

# dfir-amcache — Parse Amcache.hve (Application Compatibility)

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

`Amcache.hve` is a registry-format (regf) hive that inventories programs that were present on the
system — added largely by the Microsoft Compatibility Appraiser scheduled task. For each binary it
records the **SHA1 hash**, full path, file size, PE link/compile time, and a first-seen time. The
SHA1 makes it the one execution-adjacent artifact that supports direct **hash-based IOC matching**,
and entries persist after the binary is deleted.

Important nuance: a modern Amcache (`InventoryApplicationFile`) entry proves the file was **present**
and inventoried — it is strong presence/installation evidence but is **not, by itself, proof of
execution**. Corroborate execution with Prefetch, Shimcache, SRUM, or EVTX.

**Primary tool:** `$EZAMCACHEPARSER` (AmcacheParser). **Fallback:** `$REGRIPPER` (amcache plugin).

---

# ── PART 1 · PARSING (used by /case-parse) ──

## Case Path Convention

`<source-dir>` is the operator-created mount subdirectory under `./sources/<asset_id>/`, used
**verbatim** — copy the real directory name exactly as it appears (e.g. `mnt-001-base-dc-cdrive`),
never a partition number or other abbreviation. The export path mirrors that name one-to-one
(`export/<asset>/<source-dir>/<artifact>/`, the canonical layout owned by `/case-parse`).

| Input | Canonical path (Windows casing) |
|-------|------|
| Amcache.hve | `./sources/<asset_id>/<source-dir>/Windows/AppCompat/Programs/Amcache.hve` |

> **Resolve the path case-insensitively — never hardcode the casing.** Windows is
> case-insensitive, but a disk image mounted on Linux (ntfs-3g, and most loop/FUSE mounts) is
> **case-sensitive**, so the on-disk directory may be `appcompat`, `AppCompat`, or `APPCOMPAT`, and
> the volume root `Windows` or `windows`. Locate the hive with `find -ipath` (Step 0 below) and use
> the resolved variable; do not pass the literal table path to the parser. This applies to every
> artifact skill — the table shows the canonical Windows spelling for reference only.

Output: `./export/<asset_id>/<source-dir>/amcache/`
Output filename: `<asset_id>-<source-dir>-amcache-<tool>.<ext>` (tool token `amcacheparser` /
`regripper`). All input comes from `./sources/`; parsers never read `./export/`.

---

## Parsing Steps

### 0. Locate the hive (case-insensitive) — run this first
```bash
SRC="./sources/<asset_id>/<source-dir>"
AMCACHE="$(find "$SRC" -ipath '*/Windows/AppCompat/Programs/Amcache.hve' 2>/dev/null | head -1)"

if [ -z "$AMCACHE" ]; then
  echo "Amcache.hve not found under $SRC (checked any-case Windows/AppCompat/Programs/)"
  # Genuinely absent? Record the gap in ./audit/artifact_failures.log and move on.
  # Found at a non-standard path/case? Record the resolved path in ./audit/decisions.log.
else
  echo "Using hive: $AMCACHE"
fi
```
`-ipath` matches the whole path case-insensitively, so it resolves `appcompat`/`AppCompat` and
`windows`/`Windows` alike. The `.LOG1`/`.LOG2` transaction logs sit in the **same directory** as the
hive — AmcacheParser finds and replays them automatically once given `$AMCACHE`. If `find` returns
more than one hit (e.g. a VSS copy mounted under the same source-dir), prefer the live-volume path and
log the choice in `./audit/decisions.log`.

### 1. Parse Amcache.hve (primary)
```bash
# Requires $AMCACHE from Step 0.
$EZAMCACHEPARSER \
  -f "$AMCACHE" \
  --csv "./export/<asset_id>/<source-dir>/amcache/" \
  --csvf "<asset_id>-<source-dir>-amcache-amcacheparser.csv"
```
Expected output: several CSVs (one per Amcache table, see below) prefixed with the `--csvf` base
name. AmcacheParser auto-replays the `.LOG1`/`.LOG2` transaction logs in the same directory — collect
them alongside the hive. A non-empty `*_UnassociatedFileEntries.csv` confirms a good parse.

The replay runs on an **in-memory** copy and may print `Sequence numbers have been updated … New
Checksum`; it does **not** write back to the source hive (which is why the read-only mount guarantee
holds) — this is expected, not evidence tampering. Prove it with `sha256sum "$AMCACHE"` before and
after. A non-fatal `hbin`/`New Checksum`/`extra … non-zero data` warning alongside non-empty output is
a **PARTIAL** parse — usable but incomplete; handle it per the central `PARTIAL` rule in `/case-parse`
(completeness caveat to `audit/artifact_failures.log`; absence of an entry is not proof of absence).

### 2. Suppress known-good entries (optional noise reduction)
```bash
# $EZAMCACHE_WHITELIST is MISSING on this host; omit -w unless a whitelist is provided.
$EZAMCACHEPARSER \
  -f "$AMCACHE" \
  -w "$EZAMCACHE_WHITELIST" \
  --csv "./export/<asset_id>/<source-dir>/amcache/" \
  --csvf "<asset_id>-<source-dir>-amcache-amcacheparser.csv"
```

---

## Output Files

| File suffix | Contents |
|-------------|----------|
| `*_UnassociatedFileEntries.csv` | Executables not tied to an installer — **most forensically relevant** |
| `*_AssociatedFileEntries.csv` | Files tied to an installer/MSI |
| `*_ProgramEntries.csv` | Installed programs |
| `*_DeviceContainers.csv` / `*_DevicePnps.csv` | Device + PnP history |
| `*_ShortCuts.csv` | Shortcut file entries |
| `*_DriveBinaries.csv` | Driver binary entries |

---

## Fallback Tool

If AmcacheParser fails or produces no output, use the **RegRipper amcache plugin** (a lowercase
`amcache.py` is also installed on SIFT per the router):

```bash
mkdir -p "./export/<asset_id>/<source-dir>/amcache"

# Reuse $AMCACHE from Step 0 (case-insensitively resolved); re-resolve here if running standalone:
#   AMCACHE="$(find "./sources/<asset_id>/<source-dir>" -ipath '*/Windows/AppCompat/Programs/Amcache.hve' 2>/dev/null | head -1)"
$REGRIPPER -r "$AMCACHE" -p amcache \
  > "./export/<asset_id>/<source-dir>/amcache/<asset_id>-<source-dir>-amcache-regripper.txt" 2>/dev/null
```

Note: RegRipper output is plain text and less structured than the AmcacheParser CSVs; SHA1 hashes are
still extracted. Check `$REGRIPPER_PLUGINS/amcache.pl` exists first.

---

# ── PART 2 · ANALYSIS (used by /case-analyze) ──

## Key Fields (UnassociatedFileEntries)

| Column | Meaning |
|--------|---------|
| `FullPath` | Path where the binary was inventoried |
| `SHA1` | SHA1 of the binary (use directly for hash IOC matching) |
| `FileSize` | Size in bytes |
| `FileDescription` / `CompanyName` | PE version-resource fields (compiled into the binary) |
| `FileVersion` / `ProductVersion` | Version strings |
| `LinkDate` | PE header compile/link timestamp (attacker-controllable; not a run time) |
| `Created` / `LastModified` | File `$SI` timestamps on disk |
| `Language` | Binary language code |

---

## Interpretation & Analysis

- **Hash IOC match (the headline use):** grep `SHA1` against known-bad hash lists — confirms a binary
  was present on the host even after it was deleted from disk.
- **Presence, not execution:** an entry means the inventory saw the file. Do not state it ran on
  Amcache alone — pair it with Prefetch (run count/time), Shimcache (encountered), or EVTX 4688.
- **Deleted-binary evidence:** a valid `SHA1`/`FullPath` with **no** matching `$MFT` entry means the
  file existed and was later removed.
- **Masquerading:** `FileDescription`/`CompanyName` that disagree with the binary name or path, or a
  Microsoft-looking name running from `\Temp\`/`\AppData\`/`\ProgramData\`, is suspicious.
- **`LinkDate` caveat:** it is the PE compile timestamp, trivially forged; never treat it as a run or
  install time. Use it only as a weak grouping/anomaly signal (e.g. a future-dated or epoch link time).
- **Cross-artifact:** Amcache (SHA1 + presence) + Shimcache (encountered) + Prefetch (executed) is the
  classic execution triad — agreement across them raises confidence substantially.

```bash
# Search for a specific SHA1
grep -i "<sha1_hash>" "./export/<asset_id>/<source-dir>/amcache/"*_UnassociatedFileEntries.csv

# Flag entries in suspicious paths
grep -iE "\\\\temp\\\\|\\\\public\\\\|\\\\appdata\\\\|\\\\programdata\\\\" \
  "./export/<asset_id>/<source-dir>/amcache/"*_UnassociatedFileEntries.csv
```

---

## Analysis Notes

- Present on Windows 7 SP1+ and Server 2008 R2+ (regf format). Table layout differs across Win7/8/10;
  AmcacheParser handles the version differences.
- The SHA1 reflects the binary as inventoried; if the file was later modified, the live file may no
  longer match the recorded hash.
- Amcache stores no run count or last-run time — use Prefetch or event logs for timing.
