---
name: dfir-prefetch
description: Parse and interpret Windows Prefetch (.pf) execution artifacts. Use to prove a program executed, establish its last run time and run count, recover the binary's original run path (embedded in the .pf filename hash even after deletion), and list the modules/files it loaded on a Windows asset.
---

# dfir-prefetch — Parse Windows Prefetch Files

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

Prefetch files are **execution evidence**: each `.pf` shows that a program ran, when it last ran,
how many times, and which files/modules it loaded at start-up. The 8-character hash in the filename
encodes the executable's full run path, so the original location survives even after the binary is
deleted.

Absence of a `.pf` does **not** prove non-execution:
- Enabled on Windows **Workstation**; **disabled by default on Windows Server** (2008 only boot-prefetches).
- May be **disabled on SSD-backed systems** on some builds.
- Controlled by `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters\EnablePrefetcher` (0=off, 1=app, 2=boot, 3=both).

**Primary tool:** `$PREF` (pref.pl), driven **per-file** (`-f`). **Fallback:** `$PREFETCHPY`
(prefetch.py). Both emit UTC times.

> **Linux/SIFT caveat — do not use `pref.pl -d`.** pref.pl's directory mode hardcodes a Windows `\`
> path separator (it appends `\` to the directory, then `opendir` fails), so `-d` errors out on every
> Linux mount (`Could not open …/Prefetch\: No such file or directory`, exit 2). Its single-file mode
> (`-f`) works fine. The recipes below therefore loop `-f` over each `.pf` for the bulk parse, which
> also keeps pref.pl's resolved **EXE Path** column — the analysis phase greps it. prefetch.py natively
> accepts a directory but its CSV omits the resolved path, so it is the fallback, not the primary.

---

# ── PART 1 · PARSING (used by /case-parse) ──

## Case Path Convention

`<source-dir>` is the operator-created mount subdirectory under `./sources/<asset_id>/`, used
**verbatim** — copy the real directory name exactly as it appears (e.g. `mnt-001-base-dc-cdrive`),
never a partition number or other abbreviation. The export path mirrors that name one-to-one
(`export/<asset>/<source-dir>/<artifact>/`, the canonical layout owned by `/case-parse`).

| Input | Path |
|-------|------|
| Prefetch directory | `./sources/<asset_id>/<source-dir>/Windows/Prefetch/` |
| Single .pf file | `./sources/<asset_id>/<source-dir>/Windows/Prefetch/<NAME>-<HASH>.pf` |

Output: `./export/<asset_id>/<source-dir>/prefetch/`
Output filename: `<asset_id>-<source-dir>-prefetch-<tool>.<ext>` (tool token `pref` / `prefetchpy`).

All parser input comes from `./sources/` — whether a mounted disk image or an artifact directory the
investigator copied into `sources/`. Parsers never read from `./export/`.

---

## Parsing Steps

### 0. Locate Prefetch (case-insensitive) + presence check — run first
```bash
SRC="./sources/<asset_id>/<source-dir>"
PFDIR="$(find "$SRC" -ipath '*/Windows/Prefetch' -type d 2>/dev/null | head -1)"
[ -n "$PFDIR" ] \
  && echo "Prefetch present: $PFDIR" \
  || echo "Prefetch absent — likely Server, SSD, or disabled (check EnablePrefetcher)"
```
`find -ipath` resolves `prefetch`/`Prefetch` and `windows`/`Windows` alike — see the case-insensitive
convention in `/case-parse`. Steps below use `$PFDIR`; re-resolve it if you run a block standalone.

### 1. Parse all prefetch files to CSV (primary)
`pref.pl -d` is broken on Linux (see caveat above), so loop `-f` over each `.pf`. `-c` prints a header
per invocation, so keep it from the first file only:
```bash
mkdir -p "./export/<asset_id>/<source-dir>/prefetch"

first=1
for f in "$PFDIR"/*.pf; do
  if [ "$first" = 1 ]; then $PREF -f "$f" -c; first=0; else $PREF -f "$f" -c | tail -n +2; fi
done > "./export/<asset_id>/<source-dir>/prefetch/<asset_id>-<source-dir>-prefetch-pref.csv"
```
Expected output: a CSV with one row per `.pf` — columns **File, EXE Path, Last Run Time (UTC), Run
Count**. A non-empty file with those four columns and a single header row confirms a good parse. (`-c`
writes to stdout, so the loop is redirected to the export CSV.)

### 2. Deep-inspect a single .pf (paths + volume + alerts)
```bash
$PREF -f "$PFDIR/<NAME>-<HASH>.pf" -p -i -a \
  > "./export/<asset_id>/<source-dir>/prefetch/<asset_id>-<source-dir>-<NAME>-prefetch-pref.txt"
```
`-p` lists the module/file path strings, `-i` prints the volume information block (volume name,
serial, creation date), `-a` raises alerts on suspicious paths (recycle, globalroot, temp, system
volume information, appdata, application data).

### 3. Timeline (TLN) output for super-timeline ingestion
Same per-file loop (no `-d`). pref.pl's TLN uniquely emits Win8+ prior run times, one line each:
```bash
for f in "$PFDIR"/*.pf; do
  $PREF -f "$f" -t -s "<asset_id>"
done > "./export/<asset_id>/<source-dir>/prefetch/<asset_id>-<source-dir>-prefetch-pref.tln"
```
(Alternatively, let `/dfir-plaso-timeline` ingest Prefetch into the super-timeline directly.)

---

## Fallback Tool

If the pref.pl `-f` loop fails or produces no output (e.g. a newer/compressed format it does not
handle), use **prefetch.py** (`$PREFETCHPY`, windowsprefetch — parses format versions 17/23/26/30).
Unlike pref.pl it accepts the Prefetch **directory** directly:

```bash
mkdir -p "./export/<asset_id>/<source-dir>/prefetch"

# -f accepts a single .pf OR a directory of .pf files; -c emits CSV
$PREFETCHPY -c -f "$PFDIR" \
  > "./export/<asset_id>/<source-dir>/prefetch/<asset_id>-<source-dir>-prefetch-prefetchpy.csv"
```

prefetch.py's CSV columns are **Timestamp, Executable Name, MFT Seq Number, MFT Entry Number, Prefetch
Hash, Run Count** — note it carries the **Prefetch Hash but not the resolved EXE run path**, so the
suspicious-path grep in Part 2 will not match against this CSV. To recover the run path from
prefetch.py, run it per-file **without** `-c` (full text: executable name, run count, last execution,
volume information, directory strings, resources loaded). Call `$PREFETCHPY` directly as an executable
(its shebang invokes the venv Python at `/opt/windowsprefetch/bin/python`); do **not** prefix with
`python3` — the system Python cannot find the `windowsprefetch` module.

---

## Parsing Notes

- The CSV (`-c`) emits one last-run timestamp. Windows 8+ stores up to 8 run times (current + 7 prior)
  in the `.pf`; to recover the prior runs, use pref.pl's TLN output (Step 3, `-f -t`), which lists each
  run on its own line.
- `pref.pl -d` (directory mode) does not work on Linux/SIFT — it appends a Windows `\` to the path and
  `opendir` fails. Always drive pref.pl per-file with `-f` (Steps 1–3); use prefetch.py if you need a
  tool that takes the directory directly.
- Windows 10/11 store `.pf` in MAM-compressed form. Confirm the parser decompresses it — older
  parsers may not. If a Win10 `.pf` yields no output, decompress first or use a v30-aware parser, and
  record the gap in `./audit/artifact_failures.log`.

---

# ── PART 2 · ANALYSIS (used by /case-analyze) ──

## Key Fields

CSV (pref.pl `-f … -c` loop, Step 1):

| Column | Meaning |
|--------|---------|
| File path | Path to the `.pf` file (name `<EXE>-<HASH>.pf`; hash encodes the executable's full run path) |
| EXE path | Executable the prefetch was built for |
| Last run time | Most recent execution timestamp (UTC) |
| Run count | Total execution count (approximate — see caveat) |

Single-file (`-f … -p -i -a`):

| Field | Meaning |
|-------|---------|
| Module/file paths (`-p`) | Files and DLLs accessed during the program's start-up |
| Volume name / serial / created (`-i`) | Volume device path, serial number, and creation time the binary ran from |
| Alerts (`-a`) | Hits on suspicious path substrings (recycle, globalroot, temp, system volume information, appdata, application data) |

---

## Interpretation & Analysis

- **Execution proof + original path:** the filename hash encodes the binary's full run path. A `.pf`
  named `STUN.EXE-AB12CD34.pf` proves `stun.exe` ran from a specific path even if the EXE is gone. The
  same EXE name with **different hashes** = the binary ran from **multiple paths** (e.g. a copy in
  `\Temp\` and one in `\System32\`) — a strong masquerading/relocation indicator.
- **Timing:** the `.pf` filesystem creation time ≈ **first** run; the embedded last-run time = **last**
  run. Correlate both against the incident window.
- **Run count is approximate** — treat it as a floor, not an exact tally; do not hang a conclusion on
  its precise value alone.
- **Suspicious run locations:** the `-a` alert list flags `\Temp\`, recycle bin, `globalroot`, System
  Volume Information, AppData/Application Data. Also manually scrutinise `\Users\Public\`,
  `\ProgramData\`, `\Windows\Temp\`, and removable volumes.
- **Modules pivot (`-p`):** the loaded-file list surfaces side-loaded DLLs in non-standard paths and
  dropped data files — cross-reference against known-malicious DLLs.
- **Volume pivot (`-i`):** the volume serial ties execution to a specific volume — match against USB
  history (USBSTOR) or a mounted image's serial to place execution on removable media.
- **Cross-artifact corroboration:** confirm with Amcache (SHA1 + first-seen), Shimcache (presence),
  SRUM (per-process network/CPU), and EVTX 4688 / Sysmon 1 (command line).

```bash
# Flag suspicious run paths in the consolidated CSV
grep -iE "\\\\temp\\\\|\\\\public\\\\|\\\\programdata\\\\|recycle" \
  "./export/<asset_id>/<source-dir>/prefetch/<asset_id>-<source-dir>-prefetch-pref.csv"
```

---

## Analysis Notes

- Max stored entries: 128 on Windows XP, raised to 1024 on Windows 8+ (oldest evicted first).
- If the `Prefetch/` directory exists but is empty, it may have been cleared — check MFT/UsnJrnl for
  its deletion and correlate the time in EVTX.
