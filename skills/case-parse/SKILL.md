# Skill: case-parse — Phase 1 Artifact Parsing

## Overview

First phase of the investigation pipeline. Assumes volumes are already mounted by the operator.
Runs all forensic parsers on **each mounted Windows filesystem** (NTFS, FAT32, exFAT, …) found as
a subdirectory under `./sources/<asset>/`, writing parsed artifacts to the mirrored path
`export/<asset>/<source-dir>/<artifact>/`. Source evidence is never modified. Per-source-directory,
per-artifact status is tracked in `parse_state.txt` so re-runs resume intelligently. Invoked
standalone with `/case-parse` or as the first step of `/case-investigate`.

**Before starting:** `./context/case_context.md` must list every asset ID and the Incident Window.
Volumes must already be mounted under `./sources/<asset>/` before invoking this skill.

---

## Role & Operating Rules

**Role:** Forensic parsing orchestrator on the SANS SIFT Workstation. During the parse phase you
select and sequence the appropriate `dfir-*` skills, route their output to the correct export path,
and track per-source-directory state. Parser logic lives in the individual skills, not here.

**Rules:**

- MUST write parsed tool output only under `./export/`, and all run-records/control only under
  `./audit/`. MUST NOT write to `./analysis/`, `./reports/`, `sources/`, `/mnt/`, `/media/`, or
  any other location.
- MUST record only real tool output. MUST NOT fabricate or invent parsed content.
- MUST select parsers from the available `dfir-*` skills first — they are the primary, vetted
  source. The tool router (`~/.claude/SIFT_SERVER_DFIR_TOOLS.json`) is the **only** sanctioned
  source outside the skills, and only in the fallback tier (see Phase 1.5).
- MUST NOT perform Analysis, Correlation, or Reporting — those are `/case-analyze`,
  `/case-correlate`, `/case-report`.
- MUST set `chmod 444` on every successful parsed artifact output file under `./export/`.
- MUST classify terminal failures along the chain **primary skill → documented fallback → router**.
  Input rejected by all three is **unparseable**: logged in `audit/artifact_failures.log` and
  surfaced in the report's Gaps / Unknowns section. One router attempt only; never loop. Never
  fabricate output to cover a failure.
- MUST NOT treat a zero exit code as proof of success. Some tools (notably the EZ Tools — LECmd,
  JLECmd — which enumerate the whole `-d` tree up front) return **exit 0 even after a fatal
  enumeration/IO abort that wrote zero or a truncated file** (e.g. one unreadable inode on the mount
  → `System.IO.IOException: Input/output error`). `run_artifact` already flags a *missing* output as
  `EMPTY`; beyond that, the **owning skill's verify step** must confirm output completeness against an
  independent ground truth (e.g. a `find` count that walks past the bad inode) and scan the captured
  tool log for `Error … / IOException / Input/output error`. A truncated-but-non-empty file passing as
  `OK` is a silent failure — the skill's verify step is what catches it.
- MUST classify every parse into one of **three** outcomes, not two — `OK` / `PARTIAL` / `FAILED`.
  `PARTIAL` is the middle state: zero exit **and** non-empty output **but** the tool log carries a
  *non-fatal* integrity warning (e.g. `hbin header incorrect at 0x…`, a bad/recomputed `New Checksum`,
  or `extra … non-zero data` past a high offset in a registry hive or ESE DB). The output is **usable
  and kept as `OK`-grade evidence**, but late/high-offset entries may be missing, so it MUST NOT be
  treated as a complete extraction. Handling: record a **completeness caveat** — not a hard failure —
  to `audit/artifact_failures.log` (asset, artifact, the verbatim warning) using the sanctioned
  single-line append (`printf '%s | %s | %s\n' "$(date -u +%FT%TZ)" "<skill>" "<warning>" >>
  ./audit/artifact_failures.log`); surface it under the report's Gaps / Unknowns; and **do not read the
  absence of an entry as proof of absence**. This is the single source of truth for `PARTIAL`; owning
  skills reference it rather than restating the rule.
- Mounting is the operator's responsibility. Do not call `/tools-mount`.

**Supported flags:**

| Flag | Behaviour |
|------|-----------|
| *(none)* | Smart resume — skip source-dirs/artifacts with `OK` status; retry `FAILED`/`EMPTY` |
| `--reparse <artifact>` | Force re-run one artifact type across all source dirs and assets |
| `--force` | Delete all `parse_state.txt` files and re-parse everything |

`MAX_PARALLEL` (env, default 2) caps concurrent assets. Within each source directory, Group A
artifact skills run in parallel (up to 4); Group B runs sequentially.

---

## Output layout

Export mirrors the source directory name exactly — the relationship between parsed output and its
origin is unambiguous at a glance.

```
sources/<asset>/
  <source-dir>/              ← any operator-created subdir (mnt-NNN-<imgbase>, exported-keys/, …)

export/<asset>/
  <source-dir>/              ← same name as in sources/ — one-to-one mirror
    mft/  usnjrnl/  evtx/  registry/  scheduledtasks/  prefetch/
    amcache/  recentfilecache/  shimcache/  srum/
    lnk/  shellbags/  recyclebin/  browser/  yara/
  memory-<mem-filename>/     ← Volatility output; one directory per memory capture file

audit/
  .dfir_phase                ← case-global phase marker (gates ./export writes)
  artifact_failures.log      ← case-global; failed/unparseable artifacts
  decisions.log              ← case-global; autonomous path choices when blocked
  <asset>/
    parse_state.txt          ← per-asset state; one line per source-dir + artifact
    parse.log                ← per-asset human-readable progress log
```

`parse_state.txt` line format — `SOURCE_DIR|ARTIFACT|STATUS|ISO8601_UTC|FILE_COUNT|BYTES`:
```
mnt-001-base-dc-cdrive|mft|OK|2026-06-05T14:32:01Z|3|45233190
mnt-001-base-dc-cdrive|evtx|FAILED|2026-06-05T14:38:12Z|0|0
_asset|memory-dc01.img|OK|2026-06-05T14:50:00Z|8|10485760
```

---

## Orchestration helpers

These helpers encode output routing, state tracking, and WORM locking only. Parser selection and
tool invocation live in the `dfir-*` skills.

```bash
CASE_ROOT="$(pwd)"
source ~/.claude/tools.env

# run_artifact ASSET  SOURCE_DIR  ARTIFACT  CMD [ARGS...]
# SOURCE_DIR is "_asset" for memory captures (files in sources/<asset>/, not subdirs).
run_artifact() {
    local asset="$1" srcdir="$2" artifact="$3"; shift 3
    local outdir state ts n b
    [[ "$srcdir" == "_asset" ]] \
        && outdir="$CASE_ROOT/export/$asset/$artifact" \
        || outdir="$CASE_ROOT/export/$asset/$srcdir/$artifact"
    state="$CASE_ROOT/audit/$asset/parse_state.txt"
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mkdir -p "$outdir" "$CASE_ROOT/audit/$asset"
    find "$outdir" -type f -exec chmod u+w {} + 2>/dev/null    # re-parse safety
    sed -i "/^${srcdir}|${artifact}|/d" "$state" 2>/dev/null   # drop prior status line
    if "$@"; then
        n=$(find "$outdir/" -type f 2>/dev/null | wc -l)
        b=$(du -sb "$outdir/" 2>/dev/null | cut -f1 || echo 0)
        if [[ "$n" -eq 0 ]]; then
            printf '%s|%s|EMPTY|%s|0|0\n'      "$srcdir" "$artifact" "$ts" >> "$state"
            printf '[EMPTY]  %s/%s/%s\n'        "$asset"  "$srcdir"  "$artifact" \
                >> "$CASE_ROOT/audit/artifact_failures.log"
        else
            printf '%s|%s|OK|%s|%d|%d\n'       "$srcdir" "$artifact" "$ts" "$n" "$b" >> "$state"
            find "$outdir" -type f -exec chmod 444 {} + 2>/dev/null
        fi
    else
        printf '%s|%s|FAILED|%s|0|0\n'         "$srcdir" "$artifact" "$ts" >> "$state"
        printf '[FAILED] %s/%s/%s (exit %d)\n'  "$asset"  "$srcdir"  "$artifact" "$?" \
            >> "$CASE_ROOT/audit/artifact_failures.log"
    fi
}

# artifact_done ASSET SOURCE_DIR ARTIFACT — returns 0 if already OK (smart resume).
artifact_done() {
    grep -q "^${2}|${3}|OK|" "$CASE_ROOT/audit/${1}/parse_state.txt" 2>/dev/null
}
```

---

## Phase 0 — Bootstrap

1. Parse flags:
   - `--force`: `rm -f "$CASE_ROOT"/audit/*/parse_state.txt`
   - `--reparse <artifact>`: `sed -i "/|${artifact}|/d" "$CASE_ROOT"/audit/*/parse_state.txt`
2. `source ~/.claude/tools.env`
3. Read `./context/case_context.md` — identify all `asset_id` values and their sources paths.
4. Read the actual directory tree: `find ./sources -maxdepth 3 | sort`. Reconcile with
   `case_context.md`: assets absent from `./sources/` are skipped and logged; extra dirs not in
   `case_context.md` are noted for the operator.
5. Set phase marker: `printf 'parse\n' > "$CASE_ROOT/audit/.dfir_phase"`. **This skill is the sole
   owner of `./audit/.dfir_phase`** — it arms `parse` here and closes it (`parse-complete`) only at
   the very end (after every asset is parsed). No artifact parser (`/dfir-mft`, `/dfir-evtx`, …) ever
   writes, changes, or closes the marker; if one is invoked standalone and its `./export/` write is
   blocked, the fix is to run `/case-parse` (here), not to touch the marker from the artifact skill.

---

## Phase 1 — Artifact Parsing

**Mounting is the operator's responsibility.** Do not call `/tools-mount`.

For each asset, discover source directories under `./sources/<asset>/`, excluding:
- `e01-*` — EWF FUSE containers (contain `ewf1`, not a mountable filesystem)
- `vss-*` — VSS FUSE containers (contain `vss1`/`vss2`/…, not a mountable filesystem)

All remaining directories are processed. Each artifact skill skips gracefully when its required
input files are absent — see the **Skip if** column in the tables below. No pre-probe is needed;
a directory with only exported registry hives, event logs, or other partial artifacts is valid.
Every **Skip if** presence check is **case-insensitive** (`find -ipath`, see the convention below):
a lowercase `windows/prefetch/` must not be treated as "absent".

### Case-insensitive path resolution (Linux mounts) — convention

Windows is case-insensitive, but a disk image mounted on Linux (ntfs-3g, and most loop/FUSE mounts)
is **case-sensitive**. A path the artifact skills spell in canonical Windows casing
(`Windows/System32/config/SYSTEM`) may sit on disk as `windows/system32/config/SYSTEM` or any other
mix, depending on how the image was created. Hardcoding the casing makes a present artifact look
**absent** — a silent miss, the worst failure mode.

**Rule for every artifact skill and every presence check:** never pass a hardcoded mixed-case path to
a parser. Resolve the real on-disk path first with `find -ipath`, which matches the whole path
case-insensitively (and `*` spans `/`), then use the resolved value:

```bash
SRC="./sources/<asset>/<source-dir>"
# single file (hive, db, .bcf):
HIVE="$(find "$SRC" -ipath '*/Windows/System32/config/SYSTEM' -type f 2>/dev/null | head -1)"
# directory (event logs, Prefetch, Tasks):
LOGS="$(find "$SRC" -ipath '*/Windows/System32/winevt/Logs' -type d 2>/dev/null | head -1)"
```

- **Absent** (empty result) → record the gap in `audit/artifact_failures.log`, mark EMPTY, move on.
- **Multiple hits** (e.g. a VSS copy mounted under the same source-dir) → prefer the live-volume path
  and record the choice in `audit/decisions.log`.

The artifact skills each carry a self-contained `find -ipath` locate step (so they also work
standalone); this section is the canonical statement of the rule.

### Per-source-directory artifacts

Run **Group A in parallel** (up to 4 concurrent per source dir) then **Group B sequentially**.
Guard each invocation with `artifact_done` for smart resume; wrap with `run_artifact` for output
routing, state tracking, and WORM locking.

**Group A — independent inputs, safe to parallelise:**

| Artifact | Skill | Skip if |
|---|---|---|
| MFT & UsnJrnl | `/dfir-mft` | — |
| Event logs | `/dfir-evtx` | — |
| Prefetch | `/dfir-prefetch` | `Windows/Prefetch/` absent |
| Amcache | `/dfir-amcache` | `Amcache.hve` absent |
| RecentFileCache | `/dfir-recentfilecache` | `.bcf` absent (Win 7 only) |
| LNK / Jump Lists | `/dfir-lnk-jumplists` | — |
| Recycle Bin | `/dfir-recyclebin` | `$Recycle.Bin/` absent |
| Browser  | `/dfir-browser` | — |
| Scheduled Tasks | `/dfir-scheduled-tasks` | `System32/Tasks/` and `Tasks/` both absent |

**Group B — share the SYSTEM hive, run sequentially:**

| Artifact | Skill | Skip if |
|---|---|---|
| Registry (machine + user hives) | `/dfir-registry` | — |
| Shimcache | `/dfir-shimcache` | — |
| SRUM | `/dfir-srum` | `sru/SRUDB.dat` absent |
| Shellbags | `/dfir-shellbags` | — |

Output for each artifact: `export/<asset>/<source-dir>/<artifact>/`.

### Per asset-level artifacts

**Memory** (`/dfir-memory-volatility`) — use `_asset` as `SOURCE_DIR` in `run_artifact`:

Memory captures are identified via a three-layer check applied to every file directly under
`./sources/<asset>/` (not subdirectories):

1. **`case_context.md` Sources Inventory (authoritative)** — if the file's row has `Type = memory`,
   treat it as a memory capture. No further check needed.
2. **`file` magic-byte check (confirmation for untyped rows)** — if `Type` is blank or the file
   is not listed, run `file <path>` and match known signatures:
   - Contains `crash dump`, `hibernation`, `VMware`, `LiME`, or `ELF` → memory ✓
   - Returns `data` (no recognizable magic) → include with a warning; Volatility will fail fast
     on a non-memory file and `run_artifact` will record `FAILED` cleanly
3. **Not in Sources Inventory and `file` is inconclusive** → log as undeclared in `parse.log`,
   skip. Operator must add the file to the Sources Inventory with the correct `Type`.

Each confirmed memory file gets its own output directory:
- Artifact key: `memory-<filename>` (e.g., `memory-dc01.img`)
- Output: `export/<asset>/memory-<filename>/`
- parse_state.txt key: `_asset|memory-<filename>`

---

## Phase 1.5 — Unmapped & exhausted-fallback artifacts (tool router)

When a `dfir-*` skill's primary AND documented fallback both fail/empty, **or** when the evidence
holds an artifact type no skill covers (email, archive, document, …), consult the tool router once.

**Router catalog:** `~/.claude/SIFT_SERVER_DFIR_TOOLS.json` — read-only, keyed by `artifact_family`.

```bash
router_tool() {
  local q="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg q "$q" '
      .entries[] | select(
          (.artifact_family | ascii_downcase) == ($q | ascii_downcase)
          or ((.artifact + " " + (.artifact_aliases | join(" "))) | ascii_downcase | contains($q | ascii_downcase))
        ) | [.tool, .command, .analyst_use] | @tsv' \
      "$HOME/.claude/SIFT_SERVER_DFIR_TOOLS.json"
  else
    python3 - "$HOME/.claude/SIFT_SERVER_DFIR_TOOLS.json" "$q" <<'PY'
import json, sys
router, q = sys.argv[1], sys.argv[2].lower()
for e in json.load(open(router))["entries"]:
    hay = (e["artifact"] + " " + " ".join(e.get("artifact_aliases", []))).lower()
    if e["artifact_family"].lower() == q or q in hay:
        print("\t".join([e["tool"], e["command"], e["analyst_use"]]))
PY
  fi
}
```

Invoke the resolved command through `run_artifact` so output routing, state tracking, and WORM
locking are applied identically to skill-sourced artifacts. Filename convention:
`<asset>-<srcdir>-<artifact>-<rtool>.ext`. If the router returns no match, or the router tool also
fails/empties, log as **unparseable** in `audit/artifact_failures.log` and stop.

---

## Phase 2 handoff

```bash
# Failure summary
if [[ -f "$CASE_ROOT/audit/artifact_failures.log" ]]; then
    printf '\n[WARN] %d artifact(s) failed or produced no output:\n' \
        "$(wc -l < "$CASE_ROOT/audit/artifact_failures.log")"
    cat "$CASE_ROOT/audit/artifact_failures.log"
    printf '\nFull log: ./audit/artifact_failures.log\n'
fi

# Lock export back to read-only; anything after parse must not write parsed evidence.
# Only /case-parse closes the phase, and only here — once every asset has been parsed.
printf 'parse-complete\n' > "$CASE_ROOT/audit/.dfir_phase"
printf '\nAll assets parsed. Next: /case-analyze\n'
```

---

## Notes

- This skill only orchestrates parsing. Mounting is an operator step done before invocation.
  Analysis, correlation, and reporting are separate skills (`/case-analyze`, `/case-correlate`,
  `/case-report`), chained by `/case-investigate`.
- Export path mirrors the source dir name exactly — `export/<asset>/<source-dir>/` — so parsed
  output is trivially traceable to its origin without consulting any index.
- Never use Write/Edit on `export/` — the Write/Edit tools are denied there, and `evidence_guard.py`
  only permits Bash writes into `./export` while `.dfir_phase` reads `parse`.
- Re-running is safe: `OK` artifacts are skipped; `FAILED`/`EMPTY` are retried. A `dfir-*` skill
  whose primary and fallback both fail/empty is escalated to the tool router (Phase 1.5). If that
  also fails, the artifact is logged as unparseable.
