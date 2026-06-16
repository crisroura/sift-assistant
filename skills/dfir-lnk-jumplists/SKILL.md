---
name: dfir-lnk-jumplists
description: Parse and interpret Windows LNK shortcuts and Jump Lists. Use to prove a user opened a specific file or folder, recover the target's original path/timestamps/volume/host (even after deletion), and surface remote-share and removable-media access on a Windows asset.
---

# dfir-lnk-jumplists — Parse LNK Files and Jump Lists

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

LNK shortcut files and Jump Lists record recently accessed files, folders, and applications —
revealing attacker reconnaissance, staged files, and lateral-movement targets. They retain metadata
about the **target** (path, timestamps, volume serial, machine name) even after the target file is
deleted.

**Primary tools:** `$EZLECMD` (LNK) and `$EZJLECMD` (Jump Lists). **Fallback:** Keydet `lnk.pl` /
`jl.pl` (router).

---

# ── PART 1 · PARSING (used by /case-parse) ──

## Case Path Convention

`<source-dir>` is the operator-created mount subdirectory under `./sources/<asset_id>/`, used
**verbatim** — copy the real directory name exactly as it appears (e.g. `mnt-001-base-dc-cdrive`),
never a partition number or other abbreviation. The export path mirrors that name one-to-one
(`export/<asset>/<source-dir>/<artifact>/`, the canonical layout owned by `/case-parse`).

| Artifact | Path |
|----------|------|
| LNK (Recent) | `./sources/<asset_id>/<source-dir>/Users/<user>/AppData/Roaming/Microsoft/Windows/Recent/` |
| LNK (Desktop) | `./sources/<asset_id>/<source-dir>/Users/<user>/Desktop/` |
| Automatic Destinations | `.../Recent/AutomaticDestinations/` |
| Custom Destinations | `.../Recent/CustomDestinations/` |

Output: `./export/<asset_id>/<source-dir>/lnk/`
Output filename: `<asset_id>-<source-dir>-<scope>-<tool>.<ext>`. All input from `./sources/`.

---

## Parsing Steps

### 0. Locate the Users directory (case-insensitive) — run first
```bash
SRC="./sources/<asset_id>/<source-dir>"
USERSDIR="$(find "$SRC" -ipath '*/Users' -type d 2>/dev/null | head -1)"
[ -n "$USERSDIR" ] && echo "Using: $USERSDIR" || echo "Users/ not found under $SRC (any case)"
```
`find -ipath` resolves any casing of `Users/` — see the case-insensitive convention in `/case-parse`.
Steps below use `$USERSDIR`; re-resolve it if you run a block standalone. For the `<user>`-specific
deep-inspect step, substitute the actual profile path under `$USERSDIR`.

### 1. Parse all LNK files (all users, primary)
```bash
$EZLECMD \
  -d "$USERSDIR/" \
  --csv "./export/<asset_id>/<source-dir>/lnk/" \
  --csvf "<asset_id>-<source-dir>-lnk-lecmd.csv" \
  -q
```
Expected output: one CSV row per `.lnk` with `SourceFile`, `TargetFullPath`, target timestamps,
`DriveType`, `VolumeSerialNumber`, `MachineID`.

### 2. Parse all Jump Lists (AutomaticDestinations, all users)
```bash
$EZJLECMD \
  -d "$USERSDIR/" \
  --csv "./export/<asset_id>/<source-dir>/lnk/" \
  --csvf "<asset_id>-<source-dir>-jumplists-jlecmd.csv" \
  -q
```

### 3. Deep-inspect a single LNK or AppID jump list
```bash
$EZLECMD -f "$USERSDIR/<user>/Desktop/<shortcut>.lnk"
$EZJLECMD -f "$USERSDIR/<user>/AppData/Roaming/Microsoft/Windows/Recent/AutomaticDestinations/<AppID>.automaticDestinations-ms" \
  --csv "./export/<asset_id>/<source-dir>/lnk/" -q
```

### 4. Verify the run — a zero exit code is NOT sufficient
LECmd/JLECmd build their work list with **one up-front recursive enumeration** of the whole `-d`
tree, then **return exit 0 even when that enumeration throws** (e.g. a single unreadable inode on the
mount raises `System.IO.IOException: Input/output error` and aborts the run before any `.lnk` is
processed — zero or a truncated CSV, exit 0). So always verify against an independent ground truth:
```bash
CSV="./export/<asset_id>/<source-dir>/lnk/<asset_id>-<source-dir>-lnk-lecmd.csv"
LOG="/tmp/<asset_id>-lecmd.log"   # capture the run with: $EZLECMD ... > "$LOG" 2>&1
GROUND=$(find "$USERSDIR" -iname '*.lnk' 2>/dev/null | wc -l)          # find walks past EIO
ROWS=$([ -f "$CSV" ] && echo $(($(wc -l < "$CSV")-1)) || echo 0)
echo "ground-truth .lnk=$GROUND  csv rows=$ROWS"
if grep -qiE 'Error getting lnk files|System\.IO\.IOException|Input/output error' "$LOG" \
   || [ "$ROWS" -le 0 ]; then
  echo "RUN UNRELIABLE → use the resilient fallback below (do NOT trust exit 0)"
fi
```
Treat a logged enumeration/IO abort, a missing CSV, or a row count far below `$GROUND` as a **failure**
even on exit 0. `ROWS` may legitimately *exceed* `$GROUND` (LECmd follows the legacy `All Users` /
`Default User` junctions into ProgramData Start Menu shortcuts, and follows per-profile symlinks) — only
a count well *below* ground truth, or a logged abort, signals a problem.

---

## Fallback Tool

### Tier 1 — resilient per-profile LECmd/JLECmd (preserves rich CSV)
A single unreadable inode anywhere under `Users/` aborts the whole-tree `-d Users/` pass. Retry **once**
per-profile against the canonical LNK-bearing directories: this isolates the blast radius to one
profile sub-branch, never descends into `AppData/Local/Packages/.../TempState` (where transient EIO
inodes typically live), and `find -maxdepth 1 -type d` skips the junction symlinks (no double-traversal).
Record the switch in `./audit/decisions.log` (see the append recipe at the end of this section).

**Each invocation writes a tool-native CSV with a profile-unique filename — no merge, no bash writes to
`./export/`.** Do **not** post-process in `export/` with `cat`/`>>`/`rm`/`chmod`/`mv`: the evidence
guard permits **only the parser tool itself** to write there, and only during the parse phase
(`evidence_guard.py` blocks bash redirects/`rm`/`chmod` on `export/` whenever the phase marker isn't
`parse`). A profile-unique `--csvf` per run is also what prevents the **overwrite trap**: `JLECmd`
appends `_AutomaticDestinations` / `_CustomDestinations` to the basename and `LECmd` uses it verbatim,
so reusing one basename across the loop silently overwrites every prior profile.

```bash
OUT="./export/<asset_id>/<source-dir>/lnk"; mkdir -p "$OUT"
PFX="<asset_id>-<source-dir>"

# --- LNK: one tool-native CSV per profile × scope (filenames are unique → no collision) ---
while IFS= read -r prof; do
  pn=$(basename "$prof")
  for sub in "Desktop" \
             "AppData/Roaming/Microsoft/Windows/Recent" \
             "AppData/Roaming/Microsoft/Windows/Start Menu"; do
    d="$prof/$sub"; [ -d "$d" ] || continue
    scope=$(printf '%s' "$sub" | tr '/ ' '__')
    $EZLECMD -d "$d" --csv "$OUT" --csvf "$PFX-lnk-$pn-$scope-lecmd.csv" -q
  done
done < <(find "$USERSDIR" -mindepth 1 -maxdepth 1 -type d)

# --- Jump Lists: one call per profile at Recent/ (JLECmd recurses into both *Destinations subdirs
#     and writes a _AutomaticDestinations.csv and _CustomDestinations.csv per profile) ---
while IFS= read -r prof; do
  pn=$(basename "$prof")
  d="$prof/AppData/Roaming/Microsoft/Windows/Recent"; [ -d "$d" ] || continue
  $EZJLECMD -d "$d" --csv "$OUT" --csvf "$PFX-jumplists-$pn-jlecmd.csv" -q
done < <(find "$USERSDIR" -mindepth 1 -maxdepth 1 -type d)

# verify by tallying rows across the per-profile CSVs (reads only — find walks past any EIO)
n=0; for f in "$OUT"/$PFX-lnk-*-lecmd.csv;        do [ -f "$f" ] && n=$((n+$(($(wc -l <"$f")-1)))); done
echo "LNK: $n rows across $(ls "$OUT"/$PFX-lnk-*-lecmd.csv 2>/dev/null | wc -l) per-profile CSVs"
j=0; for f in "$OUT"/$PFX-jumplists-*-jlecmd_*.csv; do [ -f "$f" ] && j=$((j+$(($(wc -l <"$f")-1)))); done
echo "JumpLists: $j rows across $(ls "$OUT"/$PFX-jumplists-*-jlecmd_*.csv 2>/dev/null | wc -l) CSVs"
```
Output is **one CSV per profile/scope** (e.g. `…-lnk-tdungan-Recent-lecmd.csv`), not a single merged
file. That is intentional and downstream-safe: `/case-parse`'s `run_artifact` counts files (any non-zero
count ⇒ `OK`) and `/case-analyze` globs the `lnk/` directory — no consumer hardcodes the merged name.
It also gives per-profile provenance for citations.

Tradeoff: the per-profile scan covers each user's own Start Menu (under `AppData\Roaming`) but **not**
the machine-wide ProgramData Start Menu reached via the `All Users` junction in the whole-tree pass —
an accepted, recorded loss of mostly installer/baseline shortcuts in exchange for getting the
user-activity LNKs that the aborted run would otherwise have dropped entirely.

Record the fallback decision with a **single-line** append (multi-line / heavily-quoted strings are
what get the permission match denied — keep the message to one physical line):
```bash
printf '%s | %s | %s\n' "$(date -u +%FT%TZ)" "dfir-lnk-jumplists" \
  "<asset_id> (<source-dir>): whole-tree LECmd/JLECmd aborted on EIO inode under a Packages/TempState path; switched to Tier-1 per-profile split-file scan; accepted loss: machine-wide ProgramData Start Menu via All Users junction" \
  >> ./audit/decisions.log
```

### Tier 2 — Keydet lnk.pl / jl.pl (last resort, lossy text)
Only if even the targeted CSV scan fails. The Keydet **lnk.pl** / **jl.pl** parsers (router,
`/usr/local/bin/lnk.pl`, `/usr/local/bin/jl.pl`); liblnk `lnkinfo` (`apt install liblnk-utils`) is an
alternative per-file LNK parser:

```bash
mkdir -p "./export/<asset_id>/<source-dir>/lnk"

find "$USERSDIR" -iname "*.lnk" 2>/dev/null | \
while IFS= read -r lnk; do
  /usr/local/bin/lnk.pl "$lnk" \
    >> "./export/<asset_id>/<source-dir>/lnk/<asset_id>-<source-dir>-lnk-lnkpl.txt" 2>/dev/null
done
```

Note: lnk.pl/jl.pl emit text (TLN-style), not the structured CSV LECmd/JLECmd provide; extract target
paths and timestamps manually. The per-file `find … | while read` loop is inherently EIO-tolerant
(find skips the bad inode), so use it when even per-profile `-d` scans abort. The `>>` redirect into
`export/` is the one unavoidable bash write here (lnk.pl is stdout-only); it succeeds **only because
Tier 2 runs inside the parse phase** — the guard would block it in any later phase.

---

## Parsing Notes

- Timestamps are UTC as reported by LECmd/JLECmd.
- **LECmd/JLECmd exit 0 is not proof of success** — a single unreadable inode aborts the whole-tree
  enumeration yet still returns 0. Always run Step 4's verification; on a logged abort or a row count
  far below the `find` ground truth, switch to the Tier-1 resilient fallback.
- **`--csvf` filename behavior** — `LECmd` writes the `--csvf` basename verbatim (one file). `JLECmd`
  **appends** `_AutomaticDestinations` / `_CustomDestinations` to it (up to two files per run). Any
  per-profile / looped invocation must therefore give each run a **unique** `--csvf` basename, or later
  runs silently overwrite earlier ones.
- **Don't bash-merge or mutate `./export/`** — keep each file pure tool output. Never `cat`/`tail`/`mv`
  to merge, or `rm`/`chmod` to fix up, parsed evidence; emit unique tool-native filenames instead and
  let `/case-analyze` glob them. This keeps every artifact traceable to one tool invocation and respects
  the `chmod 444` WORM lock `/case-parse` applies. The **only** acceptable bash write is a direct `>`/`>>`
  redirect capturing a *stdout-only* tool's output (e.g. Tier-2 `lnk.pl`), and only during the parse
  phase — the evidence guard blocks all `export/` bash writes in any later phase regardless.

---

# ── PART 2 · ANALYSIS (used by /case-analyze) ──

## Key Fields (LNK)

| Column | Meaning |
|--------|---------|
| `SourceFile` | Path to the `.lnk` file |
| `SourceCreated` / `SourceModified` | LNK create/modify ≈ first/last access of the target |
| `TargetFullPath` | Reconstructed path to the target file |
| `TargetCreated` / `TargetModified` | Target file timestamps (embedded) |
| `TargetSize` | Target size in bytes |
| `DriveType` | Fixed / Removable / Network |
| `VolumeSerialNumber` | Serial of the volume the target was on |
| `MachineID` | NetBIOS name of the machine where the shortcut was created |
| `MACAddress` | MAC of the machine (when target accessed over network) |

---

## Interpretation & Analysis

- **Access proof + deleted-target recovery:** a LNK proves the user opened `TargetFullPath` and
  preserves its path/timestamps even after the target is deleted — cross-check `$MFT`/UsnJrnl to
  confirm and time the deletion.
- **Remote access / lateral movement:** `DriveType = Network` with a `MachineID`/path like
  `\\<host>\c$\...` reveals access to another host — a lateral-movement/recon signal.
- **Removable media:** `DriveType = Removable` + `VolumeSerialNumber` — pivot to USBSTOR and shellbags
  to place a specific device on the host.
- **Host attribution nuance:** `MachineID` is the machine where the shortcut was *created* (the source
  host), not necessarily the target host — read it accordingly.
- **Jump Lists add frequency/recency:** AutomaticDestinations track most-recently/frequently used
  items per application AppID — useful for what a user actually worked with during the window.

```bash
# glob the lnk/ dir — output may be one merged CSV (primary) or several per-profile CSVs (Tier-1
# fallback); -h drops per-file headers so the match works across both layouts
grep -hi ",Network," "./export/<asset_id>/<source-dir>/lnk/"<asset_id>-<source-dir>-lnk-*lecmd*.csv
```

---

## Analysis Notes

- LNK and Jump Lists exist on Windows 7+. Jump List AppIDs map to specific applications (EZ Tools ship
  a known-AppID list).
- GUI file-open dialogs create LNK entries; files opened purely via `cmd.exe`/scripts typically do not.
