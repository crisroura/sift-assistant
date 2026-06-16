---
name: dfir-scheduled-tasks
description: Parse and interpret Windows Scheduled Tasks (Vista+ Task XML). Use to find persistence and execution footholds — the command/arguments a task runs, the account it runs as, its triggers, and its registration date on a Windows asset.
---

# dfir-scheduled-tasks — Parse Scheduled Tasks (Task XML)

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

Scheduled Tasks are a primary persistence and execution mechanism. This skill parses the modern
on-disk form:

- **Task XML (Vista+)** — plain-XML definitions under `Windows\System32\Tasks\` (recursive; the
  folder tree mirrors the Task Scheduler hierarchy). Each names the command/arguments, triggers, the
  principal (account/SID it runs as), and author/registration dates. No binary decoder is needed.

A second, registry-side view of the same tasks lives in the SOFTWARE hive under
`...\CurrentVersion\Schedule\TaskCache\Tasks` (reach it via `/dfir-registry`, RegRipper `taskcache`)
— use it to corroborate the on-disk XML, not as a replacement.

> **Out of scope: legacy `.job` (Task Scheduler 1.0, XP/Server 2003).** Binary `.job` files under
> `Windows\Tasks\` are **not** parsed by this skill. They are absent on Vista+ assets. If a `.job`
> file is found on an asset (see the detection in Step 0), treat it as an **unparseable** artifact:
> log it in `./audit/artifact_failures.log` and surface it in the report's Gaps / Unknowns section.

**Task-XML normalization:** `xmllint --format` when present, else `python3` (`xml.dom.minidom`),
falling back to a raw copy only on malformed XML.

---

# ── PART 1 · PARSING (used by /case-parse) ──

## Case Path Convention

`<source-dir>` is the operator-created mount subdirectory under `./sources/<asset_id>/`, used
**verbatim** — copy the real directory name exactly as it appears (e.g. `mnt-001-base-dc-cdrive`),
never a partition number or other abbreviation. The export path mirrors that name one-to-one
(`export/<asset>/<source-dir>/<artifact>/`, the canonical layout owned by `/case-parse`).

| Input | Path |
|-------|------|
| Task XML tree | `./sources/<asset_id>/<source-dir>/Windows/System32/Tasks/` |

Output: `./export/<asset_id>/<source-dir>/scheduledtasks/`
Output filename: `<asset_id>-<source-dir>-<scope>-<tool>.<ext>`. All input comes from `./sources/`.

---

## Parsing Steps

### 0. Locate the task directories (case-insensitive) — run first
```bash
SRC="./sources/<asset_id>/<source-dir>"
TASKSXML="$(find "$SRC" -ipath '*/Windows/System32/Tasks' -type d 2>/dev/null | head -1)"
SOFTWARE="$(find "$SRC" -ipath '*/Windows/System32/config/SOFTWARE' -type f 2>/dev/null | head -1)"
echo "xml: ${TASKSXML:-none}   software: ${SOFTWARE:-none}"

# Legacy .job is out of scope (see Overview). Detect any so they aren't silently missed:
JOBS="$(find "$SRC" -ipath '*/Windows/Tasks/*.job' -type f 2>/dev/null)"
if [ -n "$JOBS" ]; then
  echo "WARNING: legacy .job file(s) present but not parsed by this skill — log as a gap:"
  echo "$JOBS"
  # Per failure handling: record as unparseable in ./audit/artifact_failures.log (single-line printf).
fi
```
`find -ipath` resolves any casing of these paths — see the case-insensitive convention in
`/case-parse`. Steps below use `$TASKSXML`/`$SOFTWARE`; re-resolve if you run a block standalone.

### 1. Normalize Task XML (Vista+, primary)
Pretty-print every task into one reviewable file, preserving its tree path:
```bash
mkdir -p "./export/<asset_id>/<source-dir>/scheduledtasks"
OUT="./export/<asset_id>/<source-dir>/scheduledtasks/<asset_id>-<source-dir>-scheduledtasks-xmllint.txt"
find "$TASKSXML" -type f 2>/dev/null | while read -r t; do
  printf '\n===== %s =====\n' "$t" >> "$OUT"
  # --encode UTF-8 forces UTF-8 output: real Task XML is UTF-16, and without this
  # xmllint preserves UTF-16, garbling the UTF-8 export file. minidom emits UTF-8 too.
  xmllint --format --encode UTF-8 "$t" >> "$OUT" 2>/dev/null \
    || python3 -c 'import sys,xml.dom.minidom as m; sys.stdout.write(m.parse(sys.argv[1]).toprettyxml(indent="  "))' "$t" >> "$OUT" 2>/dev/null \
    || printf '!! NOT WELL-FORMED XML — %s bytes — original preserved in sources at the path above — FLAG FOR ANALYSIS\n' \
         "$(wc -c < "$t")" >> "$OUT"   # don't inline raw bytes: a task file that isn't XML is an irregularity
done
```
Expected output: one text file concatenating every task definition, each headed by its source path.

### 2. Corroborate from the registry (cross-source)
```bash
$REGRIPPER \
  -r "$SOFTWARE" \
  -p taskcache \
  > "./export/<asset_id>/<source-dir>/scheduledtasks/<asset_id>-<source-dir>-taskcache-regripper.txt" 2>/dev/null
```

---

## Fallback Tool

Task XML normalization has its own built-in ladder (`xmllint` → `python3` → raw `cat`, see Step 1),
and the SOFTWARE-hive `taskcache` plugin (`/dfir-registry`) is the corroborating cross-source. There
is no further automated fallback — if the XML pass yields no output, the artifact is **unparseable**:
log it in `./audit/artifact_failures.log` and surface it in the report's Gaps / Unknowns section.
Legacy `.job` files are out of scope (see Overview) and, if present, are themselves logged as a gap.

---

## Parsing Notes

- Task XML files are plain XML, so the "parser" is a normalizer, not a decoder. The ladder is
  `xmllint --format` → `python3` (`xml.dom.minidom`) → a `FLAG FOR ANALYSIS` marker: `xmllint` is
  preferred when installed (`libxml2-utils`), but `python3` is guaranteed on SIFT, so a bare host
  still normalizes rather than failing for every file. A flagged entry therefore means the file was
  genuinely not well-formed XML, not that the normalizer tool was missing.
- When both normalizers reject a file, the skill does **not** inline its raw bytes (binary/null bytes
  would corrupt the UTF-8 concatenation and bury the anomaly). It writes a one-line marker citing the
  byte count; the pristine original stays in `./sources/` at the path in the `=====` header, where
  Phase 2 reads it directly or re-extracts via TSK `icat`. A non-XML file at a task path is itself an
  irregularity — see Part 2.
- The tool router has **no** scheduled-task entry, so the router fallback tier is a no-op here.

---

# ── PART 2 · ANALYSIS (used by /case-analyze) ──

## Key Fields

Pull these from each Task XML definition:

| XML path | Meaning |
|----------|---------|
| `Actions/Exec/Command` | The binary/script the task runs |
| `Actions/Exec/Arguments` | Command-line arguments (watch for encoded PowerShell, `-enc`) |
| `Principals/Principal/UserId` | Account/SID the task runs as (SYSTEM, a user SID) |
| `Principals/Principal/RunLevel` | `HighestAvailable` = elevated |
| `RegistrationInfo/Author` | Who/what registered the task |
| `RegistrationInfo/Date` | Task registration timestamp |
| `Triggers/*` | When it fires (logon, boot, time, event) |
| `Settings/Hidden` | `true` = hidden from the Task Scheduler GUI |

---

## Interpretation & Analysis

- **Command path is the strongest signal:** a `Command` pointing at `\Temp\`, `\AppData\`,
  `\Users\Public\`, `\ProgramData\`, or invoking `powershell -enc`, `rundll32`, `regsvr32`, `mshta`,
  or a script in an odd path is a high-confidence persistence lead.
- **Registration date in the incident window** is a key indicator; pre-incident registrations are
  presumed baseline unless tied to the incident. Compare `RegistrationInfo/Date` with the TaskCache
  `Date` value — a mismatch or a task in one source but not the other is suspicious.
- **Run-as account:** `Principals/Principal/UserId` = the SID the task executes under; record the
  SID/account (map via SAM), never a person. SYSTEM tasks triggering on boot/logon are common
  attacker footholds.
- **Hidden tasks:** `Settings/Hidden = true`, or a task present in TaskCache but with no XML file (or
  vice versa), indicates GUI-evasion — this is exactly why the registry cross-source matters.
- **Triggers:** logon/boot triggers = persistence; one-shot time triggers near the incident window
  may indicate staged execution.
- **Non-XML file at a task path (parse-phase `FLAG FOR ANALYSIS` marker):** a file under
  `System32\Tasks\` that isn't well-formed XML is an objective irregularity — task definitions are
  XML. Binary/PE content (e.g. PE headers, DLL imports, RPC NDR stubs) at a legitimate-looking task
  path is a Phase-2 lead, not a conclusion. Corroborate before escalating: re-extract the bytes with
  TSK `icat` to rule out mount/extraction corruption, compare against the TaskCache registry entry
  (present in one source but not the other?), and check the `$SI`/`$FN` MFT times for the file. Treat
  as `low` confidence until a second source agrees.
