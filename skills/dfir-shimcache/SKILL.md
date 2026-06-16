---
name: dfir-shimcache
description: Parse and interpret Shimcache (AppCompatCache) from the Windows SYSTEM hive. Use to enumerate executables the OS encountered (presence — not proven execution), read each binary's on-disk last-modified time, and use cache ordering to bound when a file was seen on a Windows asset.
---

# dfir-shimcache — Parse Shimcache (AppCompatCache)

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

Shimcache (Application Compatibility Cache) records executables the OS **encountered** — for
application-compatibility shimming — whether or not they were executed. It lives in the SYSTEM
registry hive and stores each binary's path and its file **last-modified** timestamp on disk. It is
one of the few artifacts that retains the path of a binary that has since been deleted.

Critical nuance: Shimcache proves **presence**, not execution. On Vista/7/Server 2008/2012 a separate
process-execution flag (set by CSRSS) can distinguish the two; on Windows 8/8.1/10/11 that reliable
flag is absent, so an entry there means only that the OS saw the file.

**Primary tool:** `$EZAPPCOMPATCACHEPARSER` (AppCompatCacheParser). **Fallback:** `$REGRIPPER`
(appcompatcache plugin).

---

# ── PART 1 · PARSING (used by /case-parse) ──

## Case Path Convention

`<source-dir>` is the operator-created mount subdirectory under `./sources/<asset_id>/`, used
**verbatim** — copy the real directory name exactly as it appears (e.g. `mnt-001-base-dc-cdrive`),
never a partition number or other abbreviation. The export path mirrors that name one-to-one
(`export/<asset>/<source-dir>/<artifact>/`, the canonical layout owned by `/case-parse`).

| Input | Path |
|-------|------|
| SYSTEM hive | `./sources/<asset_id>/<source-dir>/Windows/System32/config/SYSTEM` |

Output: `./export/<asset_id>/<source-dir>/shimcache/`
Output filename: `<asset_id>-<source-dir>-shimcache-<tool>.<ext>` (tool token
`appcompatcacheparser` / `regripper`).

Registry key: `SYSTEM\CurrentControlSet\Control\Session Manager\AppCompatCache\AppCompatCache`
(Windows XP/2000 used `...\Session Manager\AppCompatibility`). All input comes from `./sources/` —
a mounted image or a hive the investigator copied into `sources/`; parsers never read `./export/`.

---

## Parsing Steps

### 0. Locate the SYSTEM hive (case-insensitive) — run first
```bash
SRC="./sources/<asset_id>/<source-dir>"
SYSTEM="$(find "$SRC" -ipath '*/Windows/System32/config/SYSTEM' -type f 2>/dev/null | head -1)"
[ -n "$SYSTEM" ] && echo "Using: $SYSTEM" || echo "SYSTEM hive not found under $SRC (any case)"
```
`find -ipath` resolves any casing of `Windows/System32/config/` — see the case-insensitive convention
in `/case-parse`. Steps below use `$SYSTEM`; re-resolve it if you run a block standalone.

### 1. Parse Shimcache, all ControlSets (primary)
```bash
$EZAPPCOMPATCACHEPARSER \
  -f "$SYSTEM" \
  --csv "./export/<asset_id>/<source-dir>/shimcache/" \
  --csvf "<asset_id>-<source-dir>-shimcache-appcompatcacheparser.csv"
```
Expected output: a CSV with rows ordered by `CacheEntryPosition` (0 = most recently seen), with
columns `ControlSet`, `Path`, `LastModifiedTimeUTC`, `Executed`. By default the tool extracts **all**
ControlSets — expect duplicate paths flagged in `Duplicate`.

### 2. Target a specific ControlSet (when CurrentControlSet matters)
```bash
# CurrentControlSet usually maps to ControlSet001 — confirm via SYSTEM\Select\Current
$EZAPPCOMPATCACHEPARSER \
  -f "$SYSTEM" \
  --cs 1 \
  --csv "./export/<asset_id>/<source-dir>/shimcache/" \
  --csvf "<asset_id>-<source-dir>-shimcache-appcompatcacheparser.csv"
```

### 3. Sort by last-modified time (triage view)
```bash
$EZAPPCOMPATCACHEPARSER \
  -f "$SYSTEM" \
  -t \
  --csv "./export/<asset_id>/<source-dir>/shimcache/" \
  --csvf "<asset_id>-<source-dir>-shimcache-sorted-appcompatcacheparser.csv"
```

---

## Fallback Tool

If AppCompatCacheParser fails or produces no output, use the **RegRipper appcompatcache plugin**:

```bash
mkdir -p "./export/<asset_id>/<source-dir>/shimcache"

$REGRIPPER \
  -r "$SYSTEM" \
  -p appcompatcache \
  > "./export/<asset_id>/<source-dir>/shimcache/<asset_id>-<source-dir>-shimcache-regripper.txt" 2>/dev/null
```

Note: RegRipper output is plain text and iterates all ControlSets automatically. It does not produce
the structured CSV (with `CacheEntryPosition`/`Executed`) that AppCompatCacheParser provides. Check
`$REGRIPPER_PLUGINS/appcompatcache.pl` exists first.

---

## Parsing Notes

- On Windows XP/2003 the key path and binary format differ — AppCompatCacheParser auto-detects.
- **Transaction-log replay is expected and non-destructive.** If the SYSTEM hive was captured dirty,
  AppCompatCacheParser replays `SYSTEM.LOG1`/`SYSTEM.LOG2` **in memory** to reach a consistent state and
  prints `Two transaction logs found … Replaying … Sequence numbers have been updated … New Checksum`.
  This does **not** write back to the source hive — the replay happens on an in-memory copy, which is
  exactly why the read-only mount guarantee holds. Keep the `.LOG1`/`.LOG2` files beside the hive so the
  replay can run. An examiner seeing "Sequence numbers updated / New Checksum" should not read it as
  evidence tampering.
- **Verify the source is unchanged** (reassurance the replay touched nothing on disk): hash the hive
  before and after the parse and compare — on a read-only mount the write is impossible by construction;
  the hash makes that provable.
  ```bash
  # Before the parse (Step 0 already resolved $SYSTEM):
  sha256sum "$SYSTEM"
  # … run AppCompatCacheParser …
  sha256sum "$SYSTEM"   # identical digest ⇒ source hive untouched by the replay
  ```
- **PARTIAL (succeeded-but-degraded) extraction.** A non-fatal warning — `hbin header incorrect at
  0x…`, a recomputed `New Checksum`, or `extra … non-zero data` near the end of the hive — alongside
  non-empty output is a **PARTIAL** parse, **not** a failure: the returned entries are usable, but
  late/high-offset entries may be missing. Handle it per the central `PARTIAL` rule in `/case-parse`
  (record a completeness caveat to `audit/artifact_failures.log`; keep the output; do not read a
  missing path as proof the binary was never present).

---

# ── PART 2 · ANALYSIS (used by /case-analyze) ──

## Key Fields

| Column | Meaning |
|--------|---------|
| `ControlSet` | Registry ControlSet the entry came from (e.g. 1 = ControlSet001) |
| `CacheEntryPosition` | LRU position; **0 = most recently inserted** (top of the queue) |
| `Path` | Full path of the executable as the OS saw it |
| `LastModifiedTimeUTC` | The file's `$STANDARD_INFORMATION` **last-modified** time on disk — **NOT** when it ran and **NOT** when it entered the cache |
| `Executed` | Process-execution flag. Meaningful on Vista/7/2008/2012 (`True`=executed, `False`=encountered via directory browsing). On Win8+/10 typically empty/`n/a` — do not infer execution from it there |
| `Duplicate` | Entry also appears in another ControlSet |

---

## Interpretation & Analysis

- **Presence vs execution:** an entry means the OS *encountered* the path. On Vista/7/2008/2012, an
  `Executed = True` entry was actually run (flag set by CSRSS); `Executed = False` can mean the file
  was only in a directory the user browsed (the Application Experience service records non-executed
  files too). On Windows 8/8.1/10/11 there is no reliable execution flag — treat every entry as
  *presence only* and corroborate execution from Prefetch/Amcache/EVTX.
- **Timestamp meaning:** `LastModifiedTimeUTC` is the binary's on-disk `$SI` modified time, which an
  attacker can timestomp and which has no relation to when the file was seen or run. Compare it with
  the MFT `$SI`/`$FN` times to detect timestomping. Notable exception: PsExec rewrites its own
  modified time on launch, so for `PSEXESVC.exe` this timestamp *is* a reliable run indicator.
- **Ordering bounds timing:** entries form an LRU queue, most-recent at position 0. Adjacent entries
  are temporally proximate, so a known-bad binary's neighbours bracket roughly *when* it was seen —
  useful when the binary itself carries a timestomped time.
- **Deleted-binary recovery:** Shimcache retains the path of binaries removed from disk. A path in
  Shimcache with **no** matching MFT entry indicates the file existed and was later deleted.
- **Suspicious paths:** flag `\Temp\`, `\Users\Public\`, `\AppData\`, `\ProgramData\`, `\PerfLogs\`,
  recycle-bin, and removable-drive paths.
- **UNC / admin-share execution (lateral movement):** flag any **UNC** path the OS encountered —
  `\\<host>\c$\`, `\\<host>\ADMIN$\`, or any `\\<host>\<share>\`. A binary referenced over an admin
  share is a classic remote-execution / lateral-movement footprint (PsExec, `wmiexec`, `sc \\host`,
  scheduled-task push), and Shimcache records the exact UNC path the OS saw — even for a binary that
  never touched local disk. These will not be caught by the local-directory filters above (a UNC
  binary can sit outside `\Temp\`), so triage them explicitly.
- **Volatility / preservation:** the in-memory cache is flushed to the registry on clean
  **shutdown/reboot**; a hard crash can lose the most recent entries, and old entries roll off when
  capacity is reached. Absence is not proof. A binary present in **both** Shimcache and Amcache is far
  stronger execution evidence than Shimcache alone.

```bash
# Flag executables in suspicious directories
grep -iE "\\\\temp\\\\|\\\\public\\\\|\\\\appdata\\\\|\\\\programdata\\\\|\\\\perflogs\\\\" \
  "./export/<asset_id>/<source-dir>/shimcache/<asset_id>-<source-dir>-shimcache-appcompatcacheparser.csv"

# Flag UNC / admin-share execution (lateral movement) — any \\host\share\, with \c$\ / \ADMIN$\ / \IPC$\
# called out explicitly. Catches remote binaries the local-directory filter above would miss.
grep -iE "\\\\\\\\|\\\\(c|admin|ipc)\\\$\\\\" \
  "./export/<asset_id>/<source-dir>/shimcache/<asset_id>-<source-dir>-shimcache-appcompatcacheparser.csv"

# Entries flagged as actually executed (Vista/7/2008/2012 hosts)
grep -i ",True," "./export/<asset_id>/<source-dir>/shimcache/<asset_id>-<source-dir>-shimcache-appcompatcacheparser.csv"
```

---

## Analysis Notes

- Maximum entries vary by OS (roughly 96 on XP, up to 1024 on later versions); oldest evicted first.
- Shimcache is a strong *lead* artifact but weak *proof*; always corroborate with file-system
  artifacts, registry, event logs, and network evidence before concluding execution.
