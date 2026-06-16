---
name: dfir-registry
description: Parse and interpret Windows registry hives (SYSTEM, SOFTWARE, SAM, SECURITY, NTUSER.DAT, UsrClass.dat). Use to recover persistence (ASEP), program-execution evidence (UserAssist/Shimcache), USB device history, network profiles, accounts, and system configuration on a Windows asset.
---

# dfir-registry — Parse Windows Registry Hives

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

The Windows registry stores system configuration, user activity, and persistence mechanisms across
machine hives (SYSTEM, SOFTWARE, SAM, SECURITY) and per-user hives (NTUSER.DAT, UsrClass.dat). Batch
parsing surfaces auto-start entries, executed programs, USB history, network profiles, and accounts
in one pass.

**Primary tool:** `$EZRECMD` (RECmd, Kroll batch). **Fallback:** `$REGRIPPER` (RegRipper plugins).

---

# ── PART 1 · PARSING (used by /case-parse) ──

## Case Path Convention

`<source-dir>` is the operator-created mount subdirectory under `./sources/<asset_id>/`, used
**verbatim** — copy the real directory name exactly as it appears (e.g. `mnt-001-base-dc-cdrive`),
never a partition number or other abbreviation. The export path mirrors that name one-to-one
(`export/<asset>/<source-dir>/<artifact>/`, the canonical layout owned by `/case-parse`).

| Hive | Path |
|------|------|
| SYSTEM | `./sources/<asset_id>/<source-dir>/Windows/System32/config/SYSTEM` |
| SOFTWARE | `./sources/<asset_id>/<source-dir>/Windows/System32/config/SOFTWARE` |
| SECURITY | `./sources/<asset_id>/<source-dir>/Windows/System32/config/SECURITY` |
| SAM | `./sources/<asset_id>/<source-dir>/Windows/System32/config/SAM` |
| NTUSER.DAT | `./sources/<asset_id>/<source-dir>/Users/<username>/NTUSER.DAT` |
| UsrClass.dat | `./sources/<asset_id>/<source-dir>/Users/<username>/AppData/Local/Microsoft/Windows/UsrClass.dat` |

Output: `./export/<asset_id>/<source-dir>/registry/`
Output filename: `<asset_id>-<source-dir>-<scope>-<tool>.<ext>`. All input comes from `./sources/`.

---

## Parsing Steps

### 0. Locate the hive directories (case-insensitive) — run first
```bash
SRC="./sources/<asset_id>/<source-dir>"
CONFIGDIR="$(find "$SRC" -ipath '*/Windows/System32/config' -type d 2>/dev/null | head -1)"
USERSDIR="$(find "$SRC" -ipath '*/Users' -type d 2>/dev/null | head -1)"
echo "config: ${CONFIGDIR:-NOT FOUND}    users: ${USERSDIR:-NOT FOUND}"
```
`find -ipath` resolves any casing of `Windows/System32/config/` and `Users/` — see the case-insensitive
convention in `/case-parse`. Steps below use `$CONFIGDIR`/`$USERSDIR` and resolve individual hive
filenames with `-iname` (the `SYSTEM`/`NTUSER.DAT` files may also differ in case). Re-resolve if you
run a block standalone.

### 0.5. Transaction-log casing check — stage machine hives if needed

On a case-sensitive Linux mount, transaction logs may land as `system.log1` rather than `SYSTEM.LOG1`.
RECmd appends the uppercase suffix to locate logs; a lowercase name is invisible to it, leaving the
hive "dirty" and producing 0 key-value pairs. Detect the mismatch here and stage to `./tmp/` with
canonical casing so Step 1 parses clean.

```bash
MACHINE_HIVEDIR="$CONFIGDIR"   # default: parse directly from source
_needs_stage=0
for _hive in SYSTEM SOFTWARE SAM SECURITY; do
  for _suf in .LOG1 .LOG2; do
    _actual="$(find "$CONFIGDIR" -maxdepth 1 -iname "${_hive}${_suf}" -type f 2>/dev/null | head -1)"
    [ -n "$_actual" ] && [ "$(basename "$_actual")" != "${_hive}${_suf}" ] && { _needs_stage=1; break 2; }
  done
done
if [ "$_needs_stage" -eq 1 ]; then
  _mstage="./tmp/registry-hives/machine"
  mkdir -p "$_mstage"
  for _hive in SYSTEM SOFTWARE SAM SECURITY; do
    _src="$(find "$CONFIGDIR" -maxdepth 1 -iname "$_hive" -type f 2>/dev/null | head -1)"
    [ -n "$_src" ] && cp "$_src" "$_mstage/$_hive"
    for _suf in .LOG1 .LOG2; do
      _log="$(find "$CONFIGDIR" -maxdepth 1 -iname "${_hive}${_suf}" -type f 2>/dev/null | head -1)"
      [ -n "$_log" ] && cp "$_log" "$_mstage/${_hive}${_suf}"
    done
  done
  MACHINE_HIVEDIR="$_mstage"
  printf '%s | dfir-registry | LOG casing mismatch — machine hives staged to %s\n' \
    "$(date -u +%FT%TZ)" "$_mstage" >> ./audit/decisions.log
fi
```

`./tmp/` is a parse-phase working plane — staged copies are never cited as evidence.

---

### 1. Batch-parse machine hives (primary — Kroll batch)
```bash
$EZRECMD \
  -d "${MACHINE_HIVEDIR}/" \
  --bn $EZRECMD_BATCH \
  --csv "./export/<asset_id>/<source-dir>/registry/" \
  --csvf "<asset_id>-<source-dir>-registry-recmd.csv"
```
Expected output: a CSV covering 100+ artifact categories (Run keys, services, USBSTOR, etc.). Filter
later by the `HivePath`/`Category` columns. RECmd replays `.LOG1`/`.LOG2` automatically.

### 2. Parse each user's NTUSER.DAT
```bash
find "$USERSDIR" \
  -iname "NTUSER.DAT" -not -ipath "*/AppData/*" 2>/dev/null | while read -r HIVE; do
  USER=$(echo "$HIVE" | awk -F/ '{print $(NF-1)}')
  _hivedir="$(dirname "$HIVE")"
  HIVE_PATH="$HIVE"
  _needs_stage=0
  for _suf in .LOG1 .LOG2; do
    _actual="$(find "$_hivedir" -maxdepth 1 -iname "NTUSER.DAT${_suf}" -type f 2>/dev/null | head -1)"
    [ -n "$_actual" ] && [ "$(basename "$_actual")" != "NTUSER.DAT${_suf}" ] && { _needs_stage=1; break; }
  done
  if [ "$_needs_stage" -eq 1 ]; then
    _ustage="./tmp/registry-hives/$USER"
    mkdir -p "$_ustage"
    cp "$HIVE" "$_ustage/NTUSER.DAT"
    for _suf in .LOG1 .LOG2; do
      _log="$(find "$_hivedir" -maxdepth 1 -iname "NTUSER.DAT${_suf}" -type f 2>/dev/null | head -1)"
      [ -n "$_log" ] && cp "$_log" "$_ustage/NTUSER.DAT${_suf}"
    done
    HIVE_PATH="$_ustage/NTUSER.DAT"
    printf '%s | dfir-registry | LOG casing mismatch — %s NTUSER.DAT staged to %s\n' \
      "$(date -u +%FT%TZ)" "$USER" "$_ustage" >> ./audit/decisions.log
  fi
  $EZRECMD -f "$HIVE_PATH" --bn $EZRECMD_BATCH \
    --csv "./export/<asset_id>/<source-dir>/registry/" \
    --csvf "<asset_id>-<source-dir>-${USER}-ntuser-recmd.csv"
done
```

### 3. Single-hive targeted parse
```bash
SYSTEM="$(find "${MACHINE_HIVEDIR}" -maxdepth 1 -iname SYSTEM -type f 2>/dev/null | head -1)"
$EZRECMD \
  -f "$SYSTEM" \
  --bn $EZRECMD_BATCH \
  --csv "./export/<asset_id>/<source-dir>/registry/" \
  --csvf "<asset_id>-<source-dir>-system-recmd.csv"
```

---

## Fallback Tool

If RECmd fails or produces no output, use **RegRipper** (`$REGRIPPER`); a deeper option is libregf
`regfexport` (installed per the router) for raw key/value dumps.

```bash
mkdir -p "./export/<asset_id>/<source-dir>/registry"

# All plugins against each machine hive (resolve filename case-insensitively under $CONFIGDIR)
for hive in SYSTEM SOFTWARE SAM SECURITY; do
  H="$(find "$CONFIGDIR" -maxdepth 1 -iname "$hive" -type f 2>/dev/null | head -1)"
  [ -z "$H" ] && continue
  $REGRIPPER \
    -r "$H" \
    -p all \
    > "./export/<asset_id>/<source-dir>/registry/<asset_id>-<source-dir>-${hive}-regripper.txt" 2>/dev/null
done

# NTUSER.DAT per user
find "$USERSDIR" -iname "NTUSER.DAT" -not -ipath "*/AppData/*" 2>/dev/null | \
while IFS= read -r ntuser; do
  user=$(basename "$(dirname "$ntuser")")
  $REGRIPPER -r "$ntuser" -p all \
    > "./export/<asset_id>/<source-dir>/registry/<asset_id>-<source-dir>-${user}-ntuser-regripper.txt" 2>/dev/null
done
```

---

## Parsing Notes

- **Transaction logs (`.LOG1`/`.LOG2`) and casing.** RECmd and RegRipper apply transaction logs
  automatically, replaying uncommitted changes in memory (messages like `Sequence numbers have been
  updated … New Checksum` are expected — not evidence tampering). On a case-sensitive Linux mount,
  logs may exist as `system.log1` rather than `SYSTEM.LOG1`; RECmd appends the uppercase suffix and
  silently skips the lowercase version, leaving the hive "dirty" and producing empty output. Step 0.5
  detects this and stages affected hives to `./tmp/` with canonical casing before parsing. To confirm
  the source was untouched after any parse, compare `sha256sum "$HIVE"` before and after.
- **PARTIAL (succeeded-but-degraded) parse.** A non-fatal warning (`hbin header incorrect at 0x…`, a
  recomputed `New Checksum`, `extra … non-zero data` at a high offset) with non-empty output is a
  **PARTIAL** extraction, not a failure: keep the output but treat it as incomplete. Handle per the
  central `PARTIAL` rule in `/case-parse` (completeness caveat to `audit/artifact_failures.log`;
  absence of a key/value is not proof of absence).
- NTUSER.DAT/UsrClass.dat may be locked on a live capture — pull from a VSS snapshot if needed
  (`/tools-mount-vss`).
- Prefer the RECmd Kroll batch for breadth; use targeted RegRipper plugins for depth on one key.

---

# ── PART 2 · ANALYSIS (used by /case-analyze) ──

## Key Registry Artifacts

### Persistence (ASEP — Auto-Start Extensibility Points)
| Key | Hive | Meaning |
|-----|------|---------|
| `...CurrentVersion\Run` / `RunOnce` | SOFTWARE / NTUSER | Startup execution (system + per-user) |
| `SYSTEM\CurrentControlSet\Services` | SYSTEM | Services and drivers (Start type, ImagePath) |
| `...Windows NT\CurrentVersion\Winlogon` | SOFTWARE / NTUSER | Userinit, Shell hijacks |

### Execution Evidence
| Key | Hive | Meaning |
|-----|------|---------|
| `...Session Manager\AppCompatCache` | SYSTEM | Shimcache (see `/dfir-shimcache`) |
| `...Explorer\UserAssist` | NTUSER | GUI program execution (ROT13 names, run count, last run) |
| `...Explorer\RecentDocs` | NTUSER | Recently opened files by extension |
| `...ComDlg32\OpenSavePidlMRU` | NTUSER | Open/Save dialog file history |

### System / Network / USB / User Activity
| Key | Hive | Meaning |
|-----|------|---------|
| `...Control\ComputerName\ComputerName` | SYSTEM | Hostname |
| `...Control\TimeZoneInformation` | SYSTEM | Timezone (apply to all local-time artifacts) |
| `...Windows NT\CurrentVersion` | SOFTWARE | OS version, install date |
| `...NetworkList\Profiles` | SOFTWARE | Network connection history (SSID, first/last connect) |
| `...Enum\USBSTOR` / `Enum\USB` | SYSTEM | USB storage / all USB devices ever connected |
| `...Explorer\RunMRU` / `TypedPaths` | NTUSER | Run dialog + Explorer address-bar history |

---

## Interpretation & Analysis

- **Persistence first:** triage Run/RunOnce, Services (Start=2 auto, suspicious ImagePath), and
  Winlogon Shell/Userinit for footholds. An ImagePath into `\Temp\`/`\ProgramData\`/`\AppData\` or a
  service whose name mimics a Windows service is a strong lead.
- **UserAssist = GUI execution:** value names are ROT13-encoded paths with a run count and last-run
  time — concrete per-user execution evidence; decode and correlate to the incident window.
- **TimeZoneInformation governs your timeline:** read it before interpreting any local-time artifact;
  convert everything to UTC.
- **USB attribution:** USBSTOR yields device serials and first/last-connect times — pivot to LNK
  `VolumeSerialNumber`, shellbags, and setupapi logs to place a specific device on the host.
- **Network profiles:** `NetworkList\Profiles` ties the host to SSIDs/domains with first/last connect
  — useful for placing the machine on a network during the window.
- **Account context:** SAM gives local accounts, RIDs, last-logon and creation; map every SID seen in
  other artifacts back to an account here (record SID/account, never a person).
- **Filter by `HivePath`** in the RECmd CSV to separate machine-hive from per-user findings.
