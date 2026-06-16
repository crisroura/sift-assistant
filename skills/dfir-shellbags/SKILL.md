---
name: dfir-shellbags
description: Parse and interpret Windows Shellbags from NTUSER.DAT and UsrClass.dat. Use to prove a user browsed a specific folder in Explorer — including network shares, USB drives, and archives — even after the folder or its contents were deleted, on a Windows asset.
---

# dfir-shellbags — Parse Shellbag Artifacts

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

Shellbags record folder-browsing history in the Windows Shell (Explorer). They reveal folders a user
opened — including network shares, removable drives, and zip archives — and the interaction times,
and they survive deletion of the folder or its contents. They are stored as shell-item lists in the
per-user `NTUSER.DAT` and `UsrClass.dat` hives.

**Primary tool:** `$EZSBECMD` (SBECmd). **Fallback:** `$REGRIPPER` (shellbags plugin).

---

# ── PART 1 · PARSING (used by /case-parse) ──

## Case Path Convention

`<source-dir>` is the operator-created mount subdirectory under `./sources/<asset_id>/`, used
**verbatim** — copy the real directory name exactly as it appears (e.g. `mnt-001-base-dc-cdrive`),
never a partition number or other abbreviation. The export path mirrors that name one-to-one
(`export/<asset>/<source-dir>/<artifact>/`, the canonical layout owned by `/case-parse`).

| Hive | Path |
|------|------|
| NTUSER.DAT | `./sources/<asset_id>/<source-dir>/Users/<user>/NTUSER.DAT` |
| UsrClass.dat | `./sources/<asset_id>/<source-dir>/Users/<user>/AppData/Local/Microsoft/Windows/UsrClass.dat` |

Output: `./export/<asset_id>/<source-dir>/shellbags/<username>/` — one subdirectory per user profile.
All input comes from `./sources/`.

---

## Parsing Steps

### 0. Locate the Users directory (case-insensitive) — run first
```bash
SRC="./sources/<asset_id>/<source-dir>"
USERSDIR="$(find "$SRC" -ipath '*/Users' -type d 2>/dev/null | head -1)"
[ -n "$USERSDIR" ] && echo "Using: $USERSDIR" || echo "Users/ not found under $SRC (any case)"
```
`find -ipath` resolves any casing of `Users/` — see the case-insensitive convention in `/case-parse`.
Steps below use `$USERSDIR`; re-resolve it if you run a block standalone. For the specific-user step,
substitute the actual profile directory under `$USERSDIR`.

### 1. Parse shellbags for all users (primary)
```bash
find "$USERSDIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | \
while IFS= read -r userdir; do
  username=$(basename "$userdir")
  outdir="./export/<asset_id>/<source-dir>/shellbags/$username"
  mkdir -p "$outdir"
  $EZSBECMD -d "$userdir" --csv "$outdir"
done
```
Each user gets its own subdirectory (`shellbags/<username>/`) so output files are never
ambiguously renamed. SBECmd handles both `NTUSER.DAT` and `UsrClass.dat` per profile and
reconstructs the folder tree from the shell-item slots.

### 2. Parse a specific user
```bash
username="<username>"
outdir="./export/<asset_id>/<source-dir>/shellbags/$username"
mkdir -p "$outdir"
$EZSBECMD \
  -d "$USERSDIR/$username/" \
  --csv "$outdir"
```

### 3. Dirty hive recovery (when SBECmd aborts with "hive is dirty" or "Value cannot be null")

SBECmd requires transaction log files (`NTUSER.DAT.LOG1`, `NTUSER.DAT.LOG2` or `UsrClass.dat.LOG1/LOG2`)
to be co-located with the hive when it contains uncommitted transactions. On a live or recently mounted
image the logs are often absent from the extracted directory — SBECmd aborts rather than produce corrupt
output. Fix: stage the hive and its logs together in `./tmp/` and re-run.

```bash
username="<username>"
HIVE_SRC="$USERSDIR/$username"

# Stage hive + transaction logs for NTUSER.DAT (casing-aware — logs may be lowercase on case-sensitive mounts)
stagedir="./tmp/shellbag-hives/$username/ntuser"
mkdir -p "$stagedir"
_ntuser="$(find "$HIVE_SRC" -maxdepth 1 -iname "NTUSER.DAT" -type f 2>/dev/null | head -1)"
[ -n "$_ntuser" ] && cp "$_ntuser" "$stagedir/NTUSER.DAT"
_nl1="$(find "$HIVE_SRC" -maxdepth 1 -iname "NTUSER.DAT.LOG1" -type f 2>/dev/null | head -1)"
[ -n "$_nl1" ] && cp "$_nl1" "$stagedir/NTUSER.DAT.LOG1"
_nl2="$(find "$HIVE_SRC" -maxdepth 1 -iname "NTUSER.DAT.LOG2" -type f 2>/dev/null | head -1)"
[ -n "$_nl2" ] && cp "$_nl2" "$stagedir/NTUSER.DAT.LOG2"

# Stage hive + transaction logs for UsrClass.dat (casing-aware)
usrdir="$(find "$HIVE_SRC" -ipath '*/AppData/Local/Microsoft/Windows' -type d 2>/dev/null | head -1)"
stagedir_uc="./tmp/shellbag-hives/$username/usrclass/Microsoft/Windows"
mkdir -p "$stagedir_uc"
_uc="$(find "$usrdir" -maxdepth 1 -iname "UsrClass.dat" -type f 2>/dev/null | head -1)"
[ -n "$_uc" ] && cp "$_uc" "$stagedir_uc/UsrClass.dat"
_ul1="$(find "$usrdir" -maxdepth 1 -iname "UsrClass.dat.LOG1" -type f 2>/dev/null | head -1)"
[ -n "$_ul1" ] && cp "$_ul1" "$stagedir_uc/UsrClass.dat.LOG1"
_ul2="$(find "$usrdir" -maxdepth 1 -iname "UsrClass.dat.LOG2" -type f 2>/dev/null | head -1)"
[ -n "$_ul2" ] && cp "$_ul2" "$stagedir_uc/UsrClass.dat.LOG2"

# Re-run SBECmd against the staged copies
outdir="./export/<asset_id>/<source-dir>/shellbags/$username"
mkdir -p "$outdir"
$EZSBECMD -d "./tmp/shellbag-hives/$username/" --csv "$outdir"
```

`./tmp/` is a parse-phase working plane — these copies are never cited as evidence. The parsed
CSV output in `./export/` is the evidence record. Log the fallback:
```bash
printf '%s | dfir-shellbags | dirty hive for %s — staged to ./tmp/shellbag-hives/%s/ for LOG replay\n' \
  "$(date -u +%FT%TZ)" "$username" "$username" >> ./audit/decisions.log
```

---

## Fallback Tool

If SBECmd fails or produces no output, use the **RegRipper shellbags plugin**:

```bash
find "$USERSDIR" -iname "UsrClass.dat" 2>/dev/null | \
while IFS= read -r hive; do
  username=$(echo "${hive#$USERSDIR/}" | cut -d/ -f1)
  outdir="./export/<asset_id>/<source-dir>/shellbags/$username"
  mkdir -p "$outdir"
  $REGRIPPER -r "$hive" -p shellbags \
    >> "$outdir/<asset_id>-<source-dir>-shellbags-regripper.txt" 2>/dev/null
done
```

Note: RegRipper output is plain text (folder paths with timestamps); it does not produce the
structured CSV that SBECmd provides. Check `$REGRIPPER_PLUGINS/shellbags.pl` exists first.

---

## Parsing Notes

- `UsrClass.dat` is the more comprehensive shellbag source on Windows 7+ (stores more extension
  blocks); always parse it alongside `NTUSER.DAT` — SBECmd does both.

---

# ── PART 2 · ANALYSIS (used by /case-analyze) ──

## Key Fields

| Column | Meaning |
|--------|---------|
| `AbsolutePath` | Full reconstructed folder path the user browsed |
| `FirstInteractedTime` | First time the folder was opened (from the shell-item) |
| `LastInteractedTime` | Last time the folder was opened |
| `SlotModifiedTime` | When the shellbag slot was last updated |
| `ExtensionBlockCount` | Count of extension blocks (richer items carry more) |
| `Source` | Which hive the entry came from (NTUSER vs UsrClass) |

---

## Interpretation & Analysis

- **Folder access proof:** an `AbsolutePath` proves *that user* opened *that folder* in Explorer —
  even if the folder no longer exists on disk. Record the path and interaction times.
- **Remote browsing / lateral movement:** paths starting with `\\`, `My Computer\UNC`, or `\Network\`
  reveal access to remote shares; browsing administrative shares (`C$`, `ADMIN$`) on another host is a
  lateral-movement/recon signal.
- **Removable media:** drive letters not matching `C:`, or `My Computer\<DRIVE>`, indicate USB/removable
  access — pivot to USBSTOR and LNK `VolumeSerialNumber`.
- **Archive access:** paths ending in `.zip`, `.rar`, `.7z` mean the user opened an archive in
  Explorer — relevant to staging/exfiltration.
- **Deleted folders:** the path in `AbsolutePath` may no longer exist — shellbags outlive the folder,
  so cross-check `$MFT`/UsnJrnl to confirm and time the deletion.
- **Timestamp care:** SBECmd reports UTC; confirm the system timezone (SYSTEM hive `TimeZoneInformation`)
  before placing interaction times on the timeline. Shellbags record **folder** browsing only — never
  file access.

```bash
# Remote share / UNC browsing (searches all per-user subdirectories)
grep -rliE "\\\\\\\\|unc|\\\\network\\\\" "./export/<asset_id>/<source-dir>/shellbags/" --include="*.csv"
```

---

## Analysis Notes

- Shellbags are created/updated by interactive Explorer use; programmatic file access (cmd/scripts)
  does not generate them.
