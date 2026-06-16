---
name: dfir-evtx
description: Parse and interpret Windows Event Logs (EVTX). Use to investigate authentication and logons, process execution, service and scheduled-task creation, PowerShell, RDP, log clearing, and Defender detections on a Windows asset.
---

# dfir-evtx — Parse Windows Event Logs

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

Windows Event Logs (EVTX) are the primary source for authentication, process execution, network,
PowerShell, service, and security events. Parsing to CSV with field maps makes them usable for
grepping and timeline analysis.

**Primary tool:** `$EZEVTXECMD` (EvtxECmd). **Fallback:** `$EVTXDUMP` (python-evtx `evtx_dump.py`).

---

# ── PART 1 · PARSING (used by /case-parse) ──

## Case Path Convention

`<source-dir>` is the operator-created mount subdirectory under `./sources/<asset_id>/`, used
**verbatim** — copy the real directory name exactly as it appears (e.g. `mnt-001-base-dc-cdrive`),
never a partition number or other abbreviation. The export path mirrors that name one-to-one
(`export/<asset>/<source-dir>/<artifact>/`, the canonical layout owned by `/case-parse`).

| Input | Path |
|-------|------|
| Event log directory | `./sources/<asset_id>/<source-dir>/Windows/System32/winevt/Logs/` |
| Single log | `.../winevt/Logs/<Log>.evtx` |

Output: `./export/<asset_id>/<source-dir>/evtx/`
Output filename: `<asset_id>-<source-dir>-<scope>-evtxecmd.csv`. All input comes from `./sources/`.

---

## Parsing Steps

### 0. Locate the event-log directory (case-insensitive) — run first
```bash
SRC="./sources/<asset_id>/<source-dir>"
EVTXDIR="$(find "$SRC" -ipath '*/Windows/System32/winevt/Logs' -type d 2>/dev/null | head -1)"
[ -n "$EVTXDIR" ] && echo "Using: $EVTXDIR" || echo "winevt/Logs not found under $SRC (any case)"
```
Resolves `windows`/`Windows` and any casing of the path — see the case-insensitive convention in
`/case-parse`. Steps below use `$EVTXDIR`; re-resolve it if you run a block standalone.

### 1. Parse all event logs (primary)
```bash
$EZEVTXECMD \
  -d "$EVTXDIR/" \
  --csv "./export/<asset_id>/<source-dir>/evtx/" \
  --csvf "<asset_id>-<source-dir>-evtx-evtxecmd.csv" \
  --maps $EZEVTXECMD_MAPS
```
Expected output: one consolidated CSV with normalized columns (`TimeCreated`, `EventId`, `Provider`,
`MapDescription`, `PayloadData*`). `--maps` is required for human-readable fields — always include it.

### 2. Parse a single log
```bash
$EZEVTXECMD \
  -f "$EVTXDIR/Security.evtx" \
  --csv "./export/<asset_id>/<source-dir>/evtx/" \
  --csvf "<asset_id>-<source-dir>-Security-evtxecmd.csv" \
  --maps $EZEVTXECMD_MAPS
```

---

## Fallback Tool

If EvtxECmd fails or produces no output, use **python-evtx** (`$EVTXDUMP`):

```bash
mkdir -p "./export/<asset_id>/<source-dir>/evtx"

# Reuse $EVTXDIR from Step 0 (re-resolve with find -ipath if running standalone).
for evtx in "$EVTXDIR/"*.evtx; do
  name=$(basename "${evtx%.evtx}")
  $EVTXDUMP "$evtx" \
    > "./export/<asset_id>/<source-dir>/evtx/<asset_id>-<source-dir>-${name}-evtxdump.xml" 2>/dev/null
done
```

Note: python-evtx emits raw XML without field normalization — grep `EventID` and `TimeCreated`
manually. The Keydet `evtxparse.pl` (`/usr/local/bin/evtxparse.pl`, TLN output) is a second installed
option per the router.

---

## Parsing Notes

- `--maps` translates raw XML into named fields — always include it.
- If `Logs/` is missing, check VSS snapshots (`/tools-mount-vss`) for backup copies.

---

# ── PART 2 · ANALYSIS (used by /case-analyze) ──

## Key Event IDs by Category

### Authentication
| ID | Log | Meaning |
|----|-----|---------|
| 4624 | Security | Successful logon (type 2=interactive, 3=network, 10=RDP) |
| 4625 | Security | Failed logon |
| 4634 / 4647 | Security | Logoff |
| 4648 | Security | Logon with explicit credentials (runas / pass-the-hash) |
| 4672 | Security | Special privileges assigned (admin logon) |
| 4768 / 4769 / 4771 | Security | Kerberos TGT / service ticket / pre-auth failure |
| 4776 | Security | NTLM credential validation |

### Process Execution
| ID | Log | Meaning |
|----|-----|---------|
| 4688 | Security | Process creation (needs audit policy; CommandLine if enabled) |
| 1 | Sysmon | Process create (CommandLine, ParentImage, Hashes) |

### PowerShell
| ID | Log | Meaning |
|----|-----|---------|
| 4103 | PS/Operational | Module/script-block logging |
| 4104 | PS/Operational | Script block (full text) — decode Base64/`-enc` |
| 400 / 600 / 800 | PowerShell | Engine/provider lifecycle / pipeline execution |

### Remote Access / Services / Scheduled Tasks
| ID | Log | Meaning |
|----|-----|---------|
| 4778 / 4779 | Security | RDP reconnect / disconnect |
| 21 / 24 / 25 | RDPClient/TerminalServices | RDP session connect/disconnect/reconnect |
| 7045 / 7036 / 7040 | System | New service installed / state change / start-type change |
| 4698 / 4702 | Security | Scheduled task created / updated |
| 106 / 200 / 201 | TaskScheduler/Operational | Task registered / launched / completed |

### Object Access / Defender / Log Tampering / WMI
| ID | Log | Meaning |
|----|-----|---------|
| 5140 / 5145 | Security | Network share / file-share object accessed |
| 4663 / 4660 | Security | Object access attempt / object deleted |
| 1116 / 1117 | Defender/Operational | Malware detected / action taken |
| 1102 / 104 | Security / System | Security log cleared / System log cleared |
| 5857–5861 | WMI-Activity | WMI query / permanent subscription activity |

---

## Interpretation & Analysis

- **Logon type is everything in 4624:** type 3 (network) + 4672 from an unusual account = remote admin
  use; type 10 = RDP; a burst of 4625 then a 4624 = successful brute force. Pivot the `IpAddress`/
  `WorkstationName` fields to other hosts.
- **4648 (explicit credentials)** often marks lateral movement / pass-the-hash — correlate the source
  and target accounts.
- **4104 script blocks** carry the actual PowerShell — decode `-enc`/Base64 payloads; this is frequently
  the clearest evidence of attacker tooling (only present if script-block logging was enabled).
- **7045 new service** + an ImagePath in `\Temp\`/`\ProgramData\` is a classic persistence/lateral
  pattern (PsExec, malicious service). Corroborate with the registry Services key.
- **Log clearing (1102/104):** record the exact time; a clear inside the incident window is itself an
  IOC. Note pre-incident clears are presumed baseline unless tied to the activity.
- **Anchor to the window + corroborate:** a single event is a lead; pair EVTX with Prefetch/Amcache
  (execution), SRUM (network), and the registry before escalating.

```bash
EVTX="./export/<asset_id>/<source-dir>/evtx/<asset_id>-<source-dir>-evtx-evtxecmd.csv"
grep ",4625," "$EVTX"            # failed logons
grep -E ",1102,|,104," "$EVTX"   # cleared logs
grep ",7045," "$EVTX"            # new services
grep ",4648," "$EVTX"            # explicit-credential logons
```

---

## Analysis Notes

- 4688 CommandLine and 4104 script blocks only exist if the corresponding audit/logging policy was
  enabled — absence is not proof of inactivity.
