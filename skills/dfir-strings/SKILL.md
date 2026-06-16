---
name: dfir-strings
description: Extract and triage embedded strings from binaries and disk/memory images. Use to surface C2 addresses, URLs, registry keys, file paths, mutexes, PowerShell, and Base64 blobs in malware and unknown executables on a Windows asset.
---

# dfir-strings — Extract Strings from Binaries and Images

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

String extraction surfaces embedded artifacts in malware and unknown executables: C2 addresses,
registry keys, file paths, encryption keys, mutexes, and ATT&CK-relevant indicators. Use the
structured EZ tool for analysis and the system tool for fast triage.

**Primary tool:** `$EZBSTRINGS` (bstrings, CSV). **Quick tool:** `strings` (system PATH, text).

---

# ── PART 1 · PARSING (used by /case-parse) ──

## Case Path Convention

`<source-dir>` is reused **verbatim** from the origin segment of the input — the operator-created
mount subdirectory under `./sources/<asset_id>/` (e.g. `mnt-001-base-dc-cdrive`) for a binary pulled
from a mounted volume, or the same second segment the recovery step already wrote under `./export/`.
Mirror it one-to-one per the canonical `/case-parse` layout; never substitute a bare partition number.

Inputs are suspect binaries from the mounted volume under `./sources/`, or files already recovered by
`/dfir-sleuthkit-file-recovery` / `/dfir-file-carving` under `./export/<asset_id>/<source-dir>/`.

Output: `./export/<asset_id>/<source-dir>/strings/`
Output filename: `<asset_id>-<source-dir>-<target>-strings-<tool>.<ext>`.

---

## Parsing Steps

### 1. Extract all strings to CSV (primary — bstrings)
```bash
mkdir -p "./export/<asset_id>/<source-dir>/strings"
$EZBSTRINGS \
  -f "./export/<asset_id>/<source-dir>/recovered/<malware>.exe" \
  --csv "./export/<asset_id>/<source-dir>/strings/" \
  --csvf "<asset_id>-<source-dir>-<malware>-strings-bstrings.csv"
```
Expected output: a CSV of ASCII + Unicode strings. bstrings extracts both encodings by default.

### 2. Targeted pattern search / whole-directory sweep
```bash
# Built-in regex search across a binary
$EZBSTRINGS -f "<file>" -s "http|ftp|cmd|powershell|base64" \
  --csv "./export/<asset_id>/<source-dir>/strings/"

# Whole directory of recovered files; -m raises the min length to cut noise (default 3)
$EZBSTRINGS -d "./export/<asset_id>/<source-dir>/recovered/" -m 6 \
  --csv "./export/<asset_id>/<source-dir>/strings/" \
  --csvf "<asset_id>-<source-dir>-strings-all-bstrings.csv"
```

### 3. Quick triage with system `strings`
```bash
OUT="./export/<asset_id>/<source-dir>/strings/<malware>-strings.txt"
strings "<file>" > "$OUT"            # ASCII
strings -e l "<file>" >> "$OUT"      # UTF-16LE (Unicode) — common in Windows malware
```

---

## Fallback Tool

If `$EZBSTRINGS` fails or is unavailable, use the system **strings** (always present) with `grep` for
IOC patterns (step 3 above). `strings` covers the same need with less structure; for encoded blobs the
SIFT CyberChef instance (router) can decode multi-layer encodings.

---

## Parsing Notes

- bstrings gives structured CSV for analysis; `strings` gives plain text for quick triage.
- Static string extraction is **read-only** — never execute an unknown binary on the SIFT workstation.
- For deleted/overwritten binaries with no file, run strings over carved output or the raw image
  region (`/dfir-file-carving`).

---

# ── PART 2 · ANALYSIS (used by /case-analyze) ──

## Key Fields / What to Look For

| Indicator | Pattern |
|-----------|---------|
| C2 domain / URL | `https?://`, Base64-encoded URLs |
| IP address | `\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}` |
| Registry persistence | `SOFTWARE\Microsoft\Windows\CurrentVersion\Run` |
| Drop paths | `%TEMP%`, `%APPDATA%`, `C:\Windows\Temp\` |
| PowerShell exec | `-EncodedCommand`, `-enc`, `IEX`, `Invoke-Expression` |
| Base64 blob | `[A-Za-z0-9+/=]{20,}` |
| Mutex / named pipe | unique mutex strings, `\\.\pipe\` |
| WMI subscription | `SELECT * FROM __InstanceCreationEvent` |

---

## Interpretation & Analysis

- **Strings are leads, not proof of behavior** — a URL in a binary shows capability/intent, not that
  it was contacted; corroborate with SRUM/browser/network evidence before asserting C2 traffic.
- **Extract both ASCII and UTF-16LE** — Windows malware stores much of its config as Unicode; an
  ASCII-only pass misses it.
- **Low string count + high entropy = packed/encrypted** — few readable strings means the payload is
  packed; unpack (or analyze in memory via `/dfir-memory-volatility`) and re-run, and confirm with a
  YARA entropy rule (`/dfir-yara`).
- **Decode Base64 inline** to reveal staged commands/URLs:
  ```bash
  grep -oE "[A-Za-z0-9+/]{30,}={0,2}" "./export/<asset_id>/<source-dir>/strings/<malware>-strings.txt" | \
    while read -r B64; do echo "$B64" | base64 -d 2>/dev/null | strings; done
  ```
- **Pivot every IOC** (URL, IP, mutex, path) back into the case IOC block and across artifacts
  (Prefetch/Amcache/SRUM/EVTX) before escalating.
