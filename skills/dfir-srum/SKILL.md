---
name: dfir-srum
description: Parse and interpret the System Resource Usage Monitor (SRUM) database. Use to attribute network bytes sent/received, CPU time, and energy use to a specific process and user over a ~30-60 day window on a Windows asset, including processes since deleted.
---

# dfir-srum — Parse System Resource Usage Monitor (SRUM)

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

SRUM (`SRUDB.dat`) records per-application network usage, CPU time, memory, and energy consumption in
rolling ~30-60 day history. It is the primary artifact for attributing **network activity to a
specific process** — even after the binary is deleted — making it central to data-exfiltration cases.

`SRUDB.dat` is an **ESE (Extensible Storage Engine)** database, not SQLite. On this SIFT host the
dedicated parsers (SrumECmd, srum-dump) are **absent**, so the SIFT-native ESE reader `esedbexport`
(libesedb) is used to dump the tables. Resolving application IDs and network profiles to names
requires the SOFTWARE hive; esedbexport gives the raw tables, so that mapping is done by hand here
(SrumECmd does it automatically — install it for friendlier output when available).

**Primary tool:** `$ESEDBEXPORT` (libesedb). **Preferred when installed:** SrumECmd (`$EZSRUMECMD`,
currently MISSING).

---

# ── PART 1 · PARSING (used by /case-parse) ──

## Case Path Convention

`<source-dir>` is the operator-created mount subdirectory under `./sources/<asset_id>/`, used
**verbatim** — copy the real directory name exactly as it appears (e.g. `mnt-001-base-dc-cdrive`),
never a partition number or other abbreviation. The export path mirrors that name one-to-one
(`export/<asset>/<source-dir>/<artifact>/`, the canonical layout owned by `/case-parse`).

| Input | Path |
|-------|------|
| SRUDB.dat | `./sources/<asset_id>/<source-dir>/Windows/System32/sru/SRUDB.dat` |
| SOFTWARE hive (for ID resolution) | `./sources/<asset_id>/<source-dir>/Windows/System32/config/SOFTWARE` |
| Transaction logs | `./sources/<asset_id>/<source-dir>/Windows/System32/sru/SRU*.log`, `SRUDB.jfm` |

Output: `./export/<asset_id>/<source-dir>/srum/`
Output filename: `<asset_id>-<source-dir>-srum-<tool>.<ext>`. All input from `./sources/`.

---

## Parsing Steps

### 0. Locate SRUDB.dat (case-insensitive) — run first
```bash
SRC="./sources/<asset_id>/<source-dir>"
SRUM="$(find "$SRC" -ipath '*/Windows/System32/sru/SRUDB.dat' -type f 2>/dev/null | head -1)"
[ -n "$SRUM" ] && echo "Using: $SRUM" || echo "sru/SRUDB.dat not found under $SRC (any case)"
```
`find -ipath` resolves any casing of `Windows/System32/sru/` — see the case-insensitive convention in
`/case-parse`. Steps below use `$SRUM`; re-resolve it if you run a block standalone. (The `SRU*.log`
and `SRUDB.jfm` logs sit in the same `sru/` directory — `dirname "$SRUM"` — collect them alongside.)

### 1. Dump the SRUM ESE tables (primary)
```bash
mkdir -p "./export/<asset_id>/<source-dir>/srum"

$ESEDBEXPORT -t "./export/<asset_id>/<source-dir>/srum/<asset_id>-<source-dir>-srum-esedbexport" \
  "$SRUM"
```
Expected output: a `<...>-srum-esedbexport.export/` directory containing one TSV per ESE table. Each
SRUM data table has a GUID name; the **SruDbIdMapTable** maps the numeric `AppId`/`UserId` columns to
application strings and SIDs.

### 2. Rename GUID tables to human-readable names
`esedbexport` names each SRUM extension table by its raw GUID. Rename them now (still in parse phase)
so downstream analysis steps use descriptive filenames.

```bash
EXPORT_DIR="./export/<asset_id>/<source-dir>/srum/<asset_id>-<source-dir>-srum-esedbexport.export"

declare -A SRUM_NAMES=(
  ["{973F5D5C-1D90-4944-BE8E-24B94231A174}"]="network_data_usage"
  ["{DD6636C4-8929-4683-974E-22C046A43763}"]="network_connectivity_usage"
  ["{D10CA2FE-6FCF-4F6D-848E-B2E99266FA86}"]="app_timeline_push_notifications"
  ["{D10CA2FE-6FCF-4F6D-848E-B2E99266FA89}"]="app_resource_usage"
  ["{FEE4E14F-02A9-4550-B5CE-5FA2DA202E37}"]="energy_usage"
  ["{FEE4E14F-02A9-4550-B5CE-5FA2DA202E37}LT"]="energy_usage_long_term"
  ["{5C8CF1C7-7257-4F13-B223-970EF5939312}"]="energy_estimation_vfu"
)
for guid in "${!SRUM_NAMES[@]}"; do
  # esedbexport writes each table to a file named exactly after the table (the GUID, no extension).
  # Match the full name, not a substring — energy_usage's GUID is a prefix of the …}LT variant, so a
  # substring match would collide. Skip tables not present in this DB.
  [ -e "$EXPORT_DIR/$guid" ] && mv "$EXPORT_DIR/$guid" "$EXPORT_DIR/${SRUM_NAMES[$guid]}.tsv"
done
ls "$EXPORT_DIR"
```

Expected names after rename:

| File | Content |
|------|---------|
| `network_data_usage.tsv` | Bytes sent/received per app per hour — primary exfil table |
| `network_connectivity_usage.tsv` | Network connection events |
| `app_resource_usage.tsv` | CPU cycles, memory per app |
| `app_timeline_push_notifications.tsv` | App timeline / push notification activity (Win10+) |
| `energy_usage.tsv` | Per-app energy consumption |
| `energy_usage_long_term.tsv` | Long-term energy rollup |
| `energy_estimation_vfu.tsv` | GPU / energy estimation provider |
| `SruDbIdMapTable` | AppId/UserId → application path / SID (required for resolution; not renamed) |

### 3. (Dirty database) replay transaction logs first
If esedbexport errors on a dirty/uncleanly-closed DB, ensure the `SRU*.log` and `SRUDB.jfm` from the
**same `sru/` folder** were collected alongside `SRUDB.dat` (libesedb uses them). On a Windows host the
equivalent repair is `esentutl /p`; on SIFT the practical fix is collecting those logs.

---

## Fallback Tool

If `$ESEDBEXPORT` is unavailable or fails (and SrumECmd/srum-dump remain MISSING), SRUM cannot be
parsed on this host: record it in `./audit/artifact_failures.log` and surface it in Gaps / Unknowns.
Confirm `esedbexport` (libesedb-utils) and, ideally, SrumECmd are installed via `/tools-preflight`
before relying on SRUM for a case.

---

## Parsing Notes

- SRUDB.dat is ESE, never SQLite — do not use SQLECmd on it.
- The database may be locked on a live system — use a VSS snapshot if needed.
- **Recovery/replay is non-destructive — keep it that way.** SrumECmd and libesedb recover a dirty
  (uncleanly-closed) DB by replaying the `SRU*.log`/`SRUDB.jfm` logs against an **in-memory** copy;
  this does **not** alter `SRUDB.dat` on disk (which is why the read-only mount guarantee holds). Do
  **not** run `esentutl /p` against the evidence copy — that repairs the file in place and mutates
  evidence; on SIFT the sanctioned path is collecting the logs and letting the parser replay them.
  Prove the source is untouched with `sha256sum "$SRUM"` before and after.
- **PARTIAL (succeeded-but-degraded) parse.** Output produced from a recovered-but-incomplete DB
  (recovery warnings, truncated tables, a high-offset read error) with non-empty content is a
  **PARTIAL** extraction, not a failure: keep it but treat it as incomplete. Handle per the central
  `PARTIAL` rule in `/case-parse` (completeness caveat to `audit/artifact_failures.log`; absence of a
  row is not proof of absence).
- esedbexport output is raw per-table TSV with numeric IDs; install SrumECmd for automatic
  app-name/SID/profile resolution and a far more readable CSV when the host allows it.

---

# ── PART 2 · ANALYSIS (used by /case-analyze) ──

## Key Fields (Network Data Usage table)

| Column | Meaning |
|--------|---------|
| `AppId` | Index into SruDbIdMapTable → application path/name |
| `UserId` | Index into SruDbIdMapTable → user SID |
| `TimeStamp` | Start of the measurement window (UTC) |
| `BytesSent` | Bytes sent by this app in this window |
| `BytesRecvd` | Bytes received |
| `InterfaceLuid` | Network interface identifier |
| `L2ProfileId` | Network profile (Wi-Fi SSID / Ethernet), resolved via SOFTWARE hive |

---

## Interpretation & Analysis

- **Exfiltration signal:** sort the Network Data Usage table by `BytesSent` descending — large outbound
  transfers from a non-browser process (especially one in `\Temp\`/`\AppData\`) are a prime
  exfiltration indicator. Each record covers roughly a one-hour window; aggregate per app for totals.
- **Process attribution after deletion:** SRUM retains rows for processes no longer on disk — evidence
  the binary ran and used the network even after cleanup. Resolve `AppId` via SruDbIdMapTable, then
  cross-reference the path with Prefetch/Amcache/MFT.
- **User attribution:** resolve `UserId` to a SID via SruDbIdMapTable and map it to an account in SAM
  (record SID/account, never a person).
- **Network context:** resolve `L2ProfileId` against the SOFTWARE hive `NetworkList` to name the
  SSID/profile in use during the transfer.
- **Time correlation:** align `TimeStamp` windows with EVTX logons (4624) and firewall/proxy logs to
  build the exfil timeline.

```bash
# Quick scan of the network-usage TSV for the largest senders (column indexes vary — inspect header first)
sort -t$'\t' -k<BytesSent_col> -rn \
  "./export/<asset_id>/<source-dir>/srum/"*.export/network_data_usage.tsv  2>/dev/null | head -30
```

---

## Analysis Notes

- SRUM retention is typically ~30 days (configurable in the registry); GPS/location data sits in
  separate tables (rarely useful for IR).
