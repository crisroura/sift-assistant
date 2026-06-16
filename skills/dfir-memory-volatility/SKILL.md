---
name: dfir-memory-volatility
description: Analyze a raw memory image for running and hidden processes, network connections, injected code, loaded DLLs, services, registry, and cached files. Use to reconstruct system state at capture time and detect in-memory or fileless malware on a Windows asset.
---

# dfir-memory-volatility — Memory Analysis with Volatility 3

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

Volatility 3 analyzes raw memory images to reveal running processes, network connections, injected
code, loaded DLLs, registry artifacts, and cached files — the system state at the moment of capture.
Analysis is read-only on the image. Memory is analyzed per-asset, so output is **asset-level** (no
per-partition split).

**Tool:** `$VOLATILITY3`. Do **not** use `/usr/local/bin/vol.py` — that is Volatility 2 (different
plugin API). The command blocks below alias it as `VOL="$VOLATILITY3"` for readability.

**Build-specific note:** the plugin names below are correct for Volatility 3 **2.28.1** (the SIFT
build). Plugin registration changes between builds — if a plugin errors `exit=2` (invalid choice),
list the runnable plugins for *this* build with `$VOLATILITY3 -f "$IMG" --help` and re-check the
name before treating it as a real failure.

---

# ── PART 1 · PARSING (used by /case-parse) ──

## Case Path Convention

| Input | Path |
|-------|------|
| Memory image | `./sources/<asset_id>/<hostname>.img` |
| VMware memory | `./sources/<asset_id>/<hostname>.vmem` |

Output: `./export/<asset_id>/memory/` (asset-level)
Output filename: `<asset_id>-<plugin>-volatility3.<ext>`. All input comes from `./sources/`.

Renderers: `-r pretty` (human), `-r csv` (parseable), `-r json`.

```bash
VOL="$VOLATILITY3"
IMG="./sources/<asset_id>/<hostname>.img"
OUT="./export/<asset_id>/memory"; ERR="$OUT/err"; mkdir -p "$OUT" "$ERR"
```

### Canonical invocation — stderr is never discarded

Every plugin runs as `… 2> "$ERR/<asset_id>-<plugin>.err" | tee "$OUT/…"`. **Never** use a blanket
`2>/dev/null`: Volatility writes real failures to stderr (e.g. a `netstat` `AttributeError`, an
invalid-choice `exit=2`) interleaved with `Progress:` / `Updating caches` noise — discarding stderr
hides the failure and a zero-exit empty file then masquerades as a clean negative.

**Verify each plugin after it runs** (per CLAUDE.md: *empty output from a zero-exit tool is still a
failure*):
```bash
# real errors only — strip the progress/cache noise:
grep -vE 'Progress:|Updating caches' "$ERR/<asset_id>-<plugin>.err"
# datarows present?  CSV: >1 line (header + data); pretty/txt: non-empty body
[ "$(wc -l < "$OUT/<asset_id>-<plugin>-volatility3.csv")" -gt 1 ] || echo "EMPTY/zero-row — investigate"
```
A zero-exit plugin with **0 rows but a clean `.err`** is almost always a dead-DTB empty (see the
Image-health gate and the layer taxonomy below) — corroborate before reporting it as a true negative.

---

## Parsing Steps

Three tiers: a one-step **Image-health gate** (Step 0) run first, then the **Core triage set**, then
the **Deep / on-demand** set. Run the Core set by default — seven fast, high-signal plugins that
answer "what was running, talking, and injected" and fully feed the Part 2 six-step triage. Run the
**Deep / on-demand** set only when the Core set flags something (a rogue/hidden process, an external
connection, a malfind hit) or the analyst asks: those plugins are the slow ones (`timeliner`,
`filescan`, `malfind --dump`) or are targeted at a specific PID/address you only have *after* triage.
Skipping them by default is the time saving — they are documented here, not dropped.

### Step 0 — Image-health gate (always run FIRST, before anything else)

The two cheapest, most diagnostic plugins. **Run and read these before launching the Core batch** —
they tell you whether virtual-address translation works at all. Skipping this gate is how a full
13-plugin batch gets wasted on an image whose DTB is dead and every plugin returns empty-but-exit-0.

```bash
$VOL -f "$IMG" windows.info       2> "$ERR/<asset_id>-info.err"       | tee "$OUT/<asset_id>-info-volatility3.txt"
$VOL -f "$IMG" windows.statistics 2> "$ERR/<asset_id>-statistics.err" | tee "$OUT/<asset_id>-statistics-volatility3.txt"
```

**Two red lights — check both before proceeding:**
- `windows.info` → `KeNumberProcessors = 0`
- `windows.statistics` → `Valid pages (all) = 0` (e.g. 0 valid / 418,017 invalid)

A red gate means a **partial / corrupt / smeared acquisition**: virtual-address translation is dead,
so **only physical-layer plugins will work** (see the layer taxonomy below). Do **not** mistake the
resulting empties for a clean system or a rootkit. When the gate is red, run the **physical-layer
salvage set** instead of the full virtual-layer batch, and record the image condition in
Gaps/Unknowns. When the gate is green, proceed to the Core set.

### Plugin layer taxonomy — what survives a dead DTB

| Layer | Mechanism | Survives dead DTB? | Plugins |
|-------|-----------|--------------------|---------|
| **Physical** | pool-tag / KDBG scan over the raw address space | ✅ yes | `windows.info`, `windows.statistics`, `windows.psscan`, `windows.netscan`, `windows.modscan`, `windows.mutantscan`, `windows.callbacks`, `windows.filescan` |
| **Virtual** | needs page-table (DTB) address translation | ❌ no — return empty/exit-0 or throw | `windows.pslist`, `windows.pstree`, `windows.cmdline`, `windows.svcscan`, `windows.malfind`, `windows.netstat`, `windows.dlllist`, `windows.handles` |

**Fallback rule:** when virtual-layer plugins come back empty but the image isn't fully dead, fall
back to the scan-based equivalent — most importantly **`windows.netscan` for a failed
`windows.netstat`** (`netstat` throws `'NoneType' object has no attribute 'DllBase'` on a broken
image; `netscan` is the standard robust fallback). `modscan` / `mutantscan` / `callbacks` are
physical-layer salvage for module and notification-routine evidence when the virtual batch is dead.

### Core triage set — always run when the gate is green (fast)
```bash
$VOL -f "$IMG" -r pretty windows.pstree  2> "$ERR/<asset_id>-pstree.err"  | tee "$OUT/<asset_id>-pstree-volatility3.txt"
$VOL -f "$IMG" -r csv    windows.pslist  2> "$ERR/<asset_id>-pslist.err"  | tee "$OUT/<asset_id>-pslist-volatility3.csv"
$VOL -f "$IMG" -r csv    windows.psscan  2> "$ERR/<asset_id>-psscan.err"  | tee "$OUT/<asset_id>-psscan-volatility3.csv"
$VOL -f "$IMG" -r csv    windows.cmdline 2> "$ERR/<asset_id>-cmdline.err" | tee "$OUT/<asset_id>-cmdline-volatility3.csv"
$VOL -f "$IMG" -r csv    windows.netstat 2> "$ERR/<asset_id>-netstat.err" | tee "$OUT/<asset_id>-netstat-volatility3.csv"
$VOL -f "$IMG" -r csv    windows.malfind 2> "$ERR/<asset_id>-malfind.err" | tee "$OUT/<asset_id>-malfind-volatility3.csv"
```
These cover the six-step triage in Part 2: `pslist`⇄`psscan` diff (hidden procs), `pstree`
ancestry, `cmdline`, network, and injection. (`windows.info` already ran in Step 0.) Verify each
per the canonical-invocation block above; if `netstat` errored, fall back to `windows.netscan`.

### Deep / on-demand — run only when triage warrants (slower / targeted)
```bash
# Service & autostart persistence
$VOL -f "$IMG" -r csv windows.svcscan 2> "$ERR/<asset_id>-svcscan.err" | tee "$OUT/<asset_id>-svcscan-volatility3.csv"
$VOL -f "$IMG" windows.registry.printkey \
  --key "SOFTWARE\Microsoft\Windows\CurrentVersion\Run" \
  2> "$ERR/<asset_id>-run-keys.err" | tee "$OUT/<asset_id>-run-keys-volatility3.txt"
# Network — robust physical-layer scan; the standard fallback when netstat fails
$VOL -f "$IMG" -r csv windows.netscan 2> "$ERR/<asset_id>-netscan.err" | tee "$OUT/<asset_id>-netscan-volatility3.csv"
# Credentials — NOTE: windows.hashdump is NOT a registered plugin on this build (2.28.1);
#   windows.registry.hashdump isn't either. Do not invoke it (fails exit=2). Alternatives:
#   on-disk SAM via /dfir-registry, or windows.cachedump (cached domain creds) below.
#   On a DC this is low-value anyway — credentials live in NTDS.DIT, not the SAM.
$VOL -f "$IMG" windows.cachedump 2> "$ERR/<asset_id>-cachedump.err" | tee "$OUT/<asset_id>-cachedump-volatility3.txt"
# Per-process deep dive — only for a PID the Core set flagged
$VOL -f "$IMG" windows.getsids 2> "$ERR/<asset_id>-sids.err" | tee "$OUT/<asset_id>-sids-volatility3.txt"
$VOL -f "$IMG" -r csv windows.dlllist --pid <PID> 2> "$ERR/<asset_id>-dlllist-<PID>.err" | tee "$OUT/<asset_id>-dlllist-<PID>-volatility3.csv"
$VOL -f "$IMG" windows.handles --pid <PID> 2> "$ERR/<asset_id>-handles-<PID>.err" | tee "$OUT/<asset_id>-handles-<PID>-volatility3.txt"
# Dump injected code for YARA/hash validation — only for a malfind hit
$VOL -f "$IMG" windows.malfind --dump --output-dir "$OUT/malfind-dumps/" 2> "$ERR/<asset_id>-malfind-dump.err"
# File objects (scans all of memory — slow) — only to recover a specific named file
$VOL -f "$IMG" windows.filescan 2> "$ERR/<asset_id>-filescan.err" | tee "$OUT/<asset_id>-filescan-volatility3.txt"
$VOL -f "$IMG" windows.dumpfiles --virtaddr <VIRT_ADDR> --output-dir "$OUT/dumpfiles/" 2> "$ERR/<asset_id>-dumpfiles.err"
# Full in-memory super-timeline (slow) — build only if needed for correlation.
#   NOTE: the plugin is timeliner.Timeliner — top-level/OS-agnostic, NO windows. prefix
#   (windows.timeliner fails exit=2 on this build).
$VOL -f "$IMG" -r csv timeliner.Timeliner 2> "$ERR/<asset_id>-timeline.err" | tee "$OUT/<asset_id>-timeline-volatility3.csv"
```

---

## Fallback Tool

Volatility 3 has no second framework installed here. Its common failure is missing symbols: it
auto-downloads ISF files on first use, but the DFIR policy denies network egress, so on an air-gapped
SIFT the download fails and plugins error. Remediate by pre-caching symbols for the target build:

```bash
$VOLATILITY3 -f "$IMG" windows.info     # note the exact build number
# Download the matching ISF from https://downloads.volatilityfoundation.org/volatility3/symbols/
# Place under: <volatility3>/volatility3/symbols/windows/
```

If symbols cannot be provided and no plugin runs, record it in `./audit/artifact_failures.log` and
surface it in Gaps / Unknowns.

---

## Parsing Notes

- Memory captured during high I/O may be missing pages — normal; note any plugin that errors on it.
- MemProcFS is not installed on this SIFT instance; Volatility 3 handles VMware `.vmem` natively.
- **Idempotency (standalone vs `/case-parse`):** run standalone, outputs are **not** `chmod 444`,
  and a failed plugin leaves an empty file behind — re-runs are expected to **overwrite**, not
  append, so a clean re-run after fixing the cause is safe. (Under `/case-parse` the export is
  locked `444` once the phase closes; that's the pipeline's job, not this skill's.)
- **Cache priming / runtime:** on first use against an image, every plugin re-emits
  `Updating caches for N files` while it builds the symbol/page caches — this is the dominant
  per-plugin overhead in a batch, not a stall. Those are exactly the lines the canonical-invocation
  `grep -vE 'Progress:|Updating caches'` filters out; don't mistake them for an error or hang.

---

# ── PART 2 · ANALYSIS (used by /case-analyze) ──

## Key Fields / Anomaly Indicators

| Indicator | Red flag |
|-----------|----------|
| Wrong path | `svchost.exe` not in `C:\Windows\System32\` |
| Wrong parent | `lsass.exe` spawned by anything other than `wininit.exe` |
| Unusual name | typosquats (`svch0st`, `lsasss`, `explore`) |
| High privilege | a SYSTEM-SID process that should not be |
| RWX VAD | private executable memory with no mapped file (malfind) |
| Orphaned / spoofed PPID | no matching parent, or implausible parent |
| Shell from doc app | Office/browser spawning `cmd.exe`/`powershell.exe` |

---

## Interpretation & Analysis

Six-step triage:
1. **Rogue process ID** — diff `psscan` vs `pslist`; a *handful* of processes in psscan-but-not-pslist
   = unlinked/hidden (rootkit/DKOM). **Magnitude caveat:** a total or near-total `pslist` shortfall
   (`pslist≈0` while `psscan≫0`, e.g. 0 vs 125) is a **dead list-walk / unreadable image**, not 125
   unlinked processes — corroborate with the Step 0 `windows.statistics` gate before ever calling it
   DKOM. Wholesale divergence is a data-quality signal; a small delta is the rootkit signal.
   2. **Parent-child validation** — verify expected ancestry in `pstree`
   (`services.exe`→`svchost.exe`, `wininit.exe`→`lsass.exe`). 3. **Command-line inspection** —
   `cmdline` exposes encoded PowerShell, LOLBin abuse, odd arguments. 4. **Network** — `netstat`
   ESTABLISHED connections from non-browser processes to external IPs; pivot the IP to SRUM/browser.
   5. **Code injection** — `malfind` RWX regions; dump and confirm PE magic or YARA-scan the dumps
   (`/dfir-yara`). 6. **Dumped-artifact validation** — hash `malfind`/`dumpfiles` output against IOC
   lists, and cross-reference each suspect process path with Prefetch/Amcache/MFT on disk.

- **In-memory beats disk for fileless malware:** injected/reflective-loaded code never touches disk —
  memory is the only place it shows. Treat a malfind RWX hit in a normally-benign process (e.g.
  `explorer.exe`) as high priority.
- **Corroborate across the disk artifacts:** a process in memory + its Prefetch + its Amcache SHA1 +
  its SRUM network bytes is a complete, self-corroborating execution+exfil story.

---

## Analysis Notes

- `psscan` finds terminated/hidden processes via pool tags (physical layer); `pslist` only lists
  active EPROCESS entries via list-walking (virtual layer) — always run both and diff, but read the
  diff through the magnitude caveat in step 1: `pslist≈0` vs a large `psscan` is a broken image, not
  a rootkit.
- **Credentials / hashdump:** `windows.hashdump` is unavailable on this build (2.28.1). Use the
  on-disk SAM via `/dfir-registry`, or `windows.cachedump` for cached domain creds. On a **domain
  controller** this is moot — DC credentials live in **NTDS.DIT**, not the local SAM, so a memory
  hashdump is low-value there regardless.
