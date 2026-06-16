---
name: case-init
description: Create the directory scaffold for a new DFIR case. Run once from inside the case directory (cd /cases/CASE-ID then /case-init) or with explicit args (/case-init CLIENT="Acme Corp" ASSETS="dc01 rd01"). Creates analysis/, reports/, context/, tmp/, audit/, and per-asset sources/export/ dirs; stamps CASE_ID and CLIENT into CLAUDE.md and case_context.md; seeds the Sources Inventory. Re-run to add new assets (creates per-asset dirs and seeds Asset Inventory rows). To update the Sources Inventory after copying evidence, run /case-scan-sources.
---

# Skill: Case Init — Create Multi-Asset Case Directory Structure

## Overview

Creates the directory scaffold for a new DFIR case, stamps the case ID and client into the
`CLAUDE.md` / `context/case_context.md` templates, and seeds starter Sources Inventory rows
for each asset (a disk-image and a memory-image row, which the examiner edits once evidence is
copied in — one row per source). Does **not** create mount point directories (created by
`/tools-mount-e01` and `/tools-mount-ntfs` at mount time) or export subdirectories (created by
each parsing skill at run time).

On re-run, it also scans every `sources/<asset>/` directory and auto-adds any evidence files
not yet listed in the Sources Inventory — deduped by source path. Hostname is inferred from
the filename; the examiner fills in `{role}`. Existing rows are never modified.

---

## Inputs

> **How to pass inputs:** These are shell variables resolved during execution — they are **NOT**
> parameters to the `Skill` tool. Always call this skill as `Skill(skill="case-init")` or, when
> the user supplies values inline (e.g. `/case-init CLIENT="Acme Corp" ASSETS="dc01"`), as
> `Skill(skill="case-init", args="CLIENT='Acme Corp' ASSETS='dc01'")`. Passing any other keyword
> argument to the Skill tool will fail with "Invalid tool parameters".
>
> **Inputs:** Pass `CLIENT` and `ASSETS` inline (e.g. `/case-init CLIENT="Acme Corp" ASSETS="dc01 rd01"`)
> or omit them — the skill will ask interactively before proceeding. Never infer either value from
> conversation history or memory; always get them from the user.
>
> **If a Bash command is denied:** log the denial to `./audit/decisions.log`, stop, and report
> what was blocked. Do not retry silently.

| Variable | Resolved from | Example | Description |
|----------|--------------|---------|-------------|
| `CASE_ID` | Current folder name (primary) or `args` | `ACME-IR-2026-001` | Auto-derived from `basename "$PWD"` when inside `/cases/<id>`; taken from `args` otherwise. |
| `CLIENT` | `args`, then interactive prompt | `Acme Corp` | Client or organisation name. Ask the user if not in `args`. |
| `ASSETS` | `args`, then interactive prompt | `dc01 rd01 wkst01` | Space-separated asset IDs. Ask the user if not in `args`; leave blank to add later. |
| `CASE_BASE` | Hardcoded default | `/cases` | Root directory. Only used on the fallback path (see step 0). |

---

## Commands

### Interactive Prompt (when CLIENT or ASSETS not in args)

If either value was not passed inline, collect both in a single `AskUserQuestion` call
structured exactly as shown below before running any shell commands.

```json
{
  "questions": [
    {
      "question": "What is the client or organisation name for this case?",
      "header": "Client name",
      "multiSelect": false,
      "options": [
        { "label": "Acme Corp",   "description": "Example — type the real name in Other" },
        { "label": "Client Corp", "description": "Example — type the real name in Other" }
      ]
    },
    {
      "question": "Which asset IDs should be scaffolded? (space-separated, e.g. dc01 rd01)",
      "header": "Asset IDs",
      "multiSelect": false,
      "options": [
        { "label": "dc01",             "description": "Single domain controller" },
        { "label": "dc01 rd01",        "description": "DC + RDP/jump server" },
        { "label": "dc01 rd01 wkst01", "description": "DC + RDP + workstation" }
      ]
    }
  ]
}
```

Take the user's selections (or their "Other" text) as `CLIENT` and `ASSETS` and proceed to
Step 0. Never infer either value from memory or conversation history.

### Step 0 — Locate / confirm the case root

The installer's recommended flow puts you **inside** the case directory before launching
Claude (`cd /cases` → `mkdir <caseID>` → `cd <caseID>` → `claude`). Detect that and scaffold
in place; otherwise fall back to creating the case under `$CASE_BASE`.

```bash
CASE_BASE="/cases"
PARENT="$(dirname "$PWD")"

if [[ "$PARENT" == "$CASE_BASE" && "$PWD" != "$CASE_BASE" ]]; then
  # Primary path: already inside a case directory (the install.sh flow).
  CASE_ROOT="$PWD"
  CASE_ID="$(basename "$PWD")"
  echo "Detected case directory: $CASE_ROOT  (CASE_ID=$CASE_ID)"
  # → CONFIRM with the user before proceeding: "Initialize this directory as the case root?"
  # → Do NOT mkdir the case root; it already exists.
  if [[ -f "$CASE_ROOT/context/case_context.md" ]]; then
    echo "Already initialized — this is a RE-RUN (see 'Re-running to add assets' below)."
  fi
else
  # Fallback path: run from /cases root or elsewhere — legacy behavior.
  CASE_ID="ACME-IR-2026-001"          # ← prompt the user for this
  CASE_ROOT="$CASE_BASE/$CASE_ID"
  mkdir -p "$CASE_ROOT"
fi
```

If `CLIENT` or `ASSETS` were not passed in `args`, ask the user for each value now before continuing.

```bash
CLIENT="Acme Corp"      # ← from args, or ask the user
ASSETS="dc01 rd01"      # ← from args, or ask the user (leave blank to add assets later)
```

### First-run scaffold

On a re-run (when `context/case_context.md` already exists) **skip steps 2-3** — do not
re-copy the templates or re-run the placeholder sed, or investigator-filled content is lost.
See "Re-running to add assets" below.

```bash
TEMPLATES="$HOME/.claude/case-templates"   # canonical templates installed by install.sh

# 1. Create the always-present directory structure
mkdir -p "$CASE_ROOT/analysis" "$CASE_ROOT/reports" "$CASE_ROOT/context" "$CASE_ROOT/audit" "$CASE_ROOT/tmp"

# 2. Copy the CANONICAL templates — never maintain a second copy of them in this skill
cp "$TEMPLATES/CLAUDE.md"               "$CASE_ROOT/CLAUDE.md"
cp "$TEMPLATES/context/case_context.md" "$CASE_ROOT/context/case_context.md"

# 3. Substitute case-level placeholders in both copied files
for f in "$CASE_ROOT/CLAUDE.md" "$CASE_ROOT/context/case_context.md"; do
  sed -i -e "s#{CASE_ID}#$CASE_ID#g" -e "s#{CLIENT_NAME}#$CLIENT#g" "$f"
done

# 4. Assets (OPTIONAL) — create per-asset dirs and seed starter inventory rows.
if [[ -n "$ASSETS" ]]; then
  for ASSET in $ASSETS; do
    mkdir -p "$CASE_ROOT/sources/$ASSET" "$CASE_ROOT/export/$ASSET" "$CASE_ROOT/audit/$ASSET"
  done
  # Seed Asset Inventory (one row per asset) and Sources Inventory (disk01/memory01 placeholders).
  # Replaces {asset_id} placeholder rows in each section with per-asset rows.
  python3 - "$CASE_ROOT/context/case_context.md" "$CASE_ID" $ASSETS <<'PY'
import sys, re
ctx, case_id, *assets = sys.argv[1:]

def asset_row(a):
    return f"| `{a}` | {{hostname}} | {{role}} |"

def source_rows(a):
    # 4 columns: SourceID | AssetID | Type | SourcePath (Type matches the template; case-parse
    # and case-analyze Tier-2 source ranking read it instead of guessing from the extension).
    return [
        f"| `{a}-disk01` | `{a}` | `disk` | `/cases/{case_id}/sources/{a}/{{hostname}}.E01` |",
        f"| `{a}-memory01` | `{a}` | `memory` | `/cases/{case_id}/sources/{a}/{{hostname}}.img` |",
    ]

# A placeholder row is any inventory row whose first cell starts with `{asset_id}` —
# this covers the Asset Inventory row (`{asset_id}`) AND the Sources Inventory rows
# (`{asset_id}-disk01` / `{asset_id}-memory01`), which a bare `startswith` on the
# closing backtick would miss. Seed once per section on the first placeholder seen,
# then drop every placeholder row in that section (Sources has two).
ph = re.compile(r'^\|\s*`\{asset_id\}')
lines = open(ctx).read().splitlines()
out, section, seeded = [], None, set()
for ln in lines:
    s = ln.strip()
    if   s == '## Asset Inventory':   section = 'asset'
    elif s == '## Sources Inventory': section = 'sources'
    elif s.startswith('## '):         section = None
    if section in ('asset', 'sources') and ph.match(ln):
        if section not in seeded:
            if section == 'asset': out.extend(asset_row(a) for a in assets)
            else:                  out.extend(r for a in assets for r in source_rows(a))
            seeded.add(section)
        continue  # drop placeholder row(s)
    out.append(ln)
open(ctx, "w").write("\n".join(out) + "\n")
PY
  echo "Seeded Asset Inventory and Sources Inventory for: $ASSETS"
  echo "  Fill in hostname/role in Asset Inventory; run /case-scan-sources after copying evidence to auto-populate source paths."
else
  echo "No assets provided — add them later by re-running /case-init, or"
  echo "  mkdir sources/<asset>/ export/<asset>/ audit/<asset>/ manually."
fi

echo "Case directory ready: $CASE_ROOT"
echo ""
echo "If you have not yet verified tool availability on this workstation, run /tools-preflight"
echo "before /case-investigate — it is a one-time check per workstation, not per case."
echo ""
echo "Next steps:"
echo "  1. Drop evidence into sources/<asset_id>/"
echo "  2. Run /case-scan-sources  (updates Sources Inventory with the files you just copied)"
echo "  3. Run /tools-preflight  (once per workstation)"
echo "  4. If evidence includes disk images (.E01, .dd, .img): run /tools-mount first"
echo "  5. Run /case-investigate"
```

### Re-running to add assets

If `context/case_context.md` already exists, **do not re-copy the templates and do not re-run
the placeholder sed** — that would clobber investigator-filled content.

```bash
# 1. Create directories for any newly specified assets
if [[ -n "$ASSETS" ]]; then
  for ASSET in $ASSETS; do
    mkdir -p "$CASE_ROOT/sources/$ASSET" "$CASE_ROOT/export/$ASSET" "$CASE_ROOT/audit/$ASSET"
  done
fi

# 2. Scan all sources/<asset>/ dirs and upsert Sources Inventory rows for new files
#    and currently-mounted directories. Also adds missing Asset Inventory rows for
#    any new assets found. Dedup key: source path (last backtick-quoted column).
python3 - "$CASE_ROOT/context/case_context.md" "$CASE_ROOT" <<'PY'
import sys, os, re
from collections import defaultdict

TYPE_SLUG = {
    '.e01': 'disk', '.dd': 'disk',
    '.vmem': 'memory', '.mem': 'memory', '.raw': 'memory', '.dmp': 'memory', '.img': 'memory',
}

ctx, case_root = sys.argv[1], sys.argv[2]
sources_root = os.path.join(case_root, "sources")
lines = open(ctx).read().splitlines()

def has_placeholder_path(ln):
    ticks = re.findall(r'`([^`]+)`', ln)
    return bool(ticks) and '{' in ticks[-1]

# Collect existing source paths and max SourceID sequence per (asset, slug)
existing_paths = set()
max_seq = defaultdict(int)
for ln in lines:
    ticks = re.findall(r'`([^`]+)`', ln)
    if not ticks or not ticks[-1].startswith('/'):
        continue
    existing_paths.add(ticks[-1])
    if len(ticks) >= 2 and not has_placeholder_path(ln):
        m = re.match(r'^(.+)-(disk|memory|mount)(\d{2})$', ticks[0])
        if m:
            max_seq[(m.group(1), m.group(2))] = max(max_seq[(m.group(1), m.group(2))], int(m.group(3)))

# Collect new evidence candidates
candidates = []  # (asset, fpath, slug)
if os.path.isdir(sources_root):
    for asset in sorted(os.listdir(sources_root)):
        src_dir = os.path.join(sources_root, asset)
        if not os.path.isdir(src_dir):
            continue
        for name in sorted(os.listdir(src_dir)):
            fpath = os.path.join(src_dir, name)
            if os.path.isfile(fpath):
                slug = TYPE_SLUG.get(os.path.splitext(name)[1].lower())
                if slug and fpath not in existing_paths:
                    candidates.append((asset, fpath, slug))
            elif os.path.isdir(fpath) and os.path.ismount(fpath) and fpath not in existing_paths:
                candidates.append((asset, fpath, 'mount'))

# Assign SourceIDs — always zero-padded two-digit to stay stable when a second image arrives
seq = defaultdict(int)
new_rows = []
for asset, fpath, slug in candidates:
    seq[(asset, slug)] += 1
    n = max_seq[(asset, slug)] + seq[(asset, slug)]
    source_id = f"{asset}-{slug}{n:02d}"
    # 4 columns incl. Type (= slug: disk|memory|mount) so Tier-2 source ranking is deterministic.
    new_rows.append(f"| `{source_id}` | `{asset}` | `{slug}` | `{fpath}` |")

# Locate Sources Inventory section
in_s, src_start, src_end, last_src_idx = False, -1, len(lines), -1
for i, ln in enumerate(lines):
    if ln.strip() == '## Sources Inventory':
        in_s = True; src_start = i
    elif in_s and re.match(r'^##\s', ln):
        src_end = i; in_s = False
    if in_s and ln.startswith('|'):
        last_src_idx = i

src_placeholder_count = sum(
    1 for i, ln in enumerate(lines)
    if src_start < i < src_end and ln.startswith('|') and has_placeholder_path(ln)
)

# Locate Asset Inventory section and existing asset IDs
in_a, ast_start, ast_end, last_ast_idx = False, -1, len(lines), -1
existing_assets = set()
for i, ln in enumerate(lines):
    if ln.strip() == '## Asset Inventory':
        in_a = True; ast_start = i
    elif in_a and re.match(r'^##\s', ln):
        ast_end = i; in_a = False
    if in_a and ln.startswith('| `') and not has_placeholder_path(ln):
        ticks = re.findall(r'`([^`]+)`', ln)
        if ticks: existing_assets.add(ticks[0])
    if in_a and ln.startswith('|'):
        last_ast_idx = i

new_asset_rows = [
    f"| `{asset}` | {{hostname}} | {{role}} |"
    for asset in (sorted(os.listdir(sources_root)) if os.path.isdir(sources_root) else [])
    if os.path.isdir(os.path.join(sources_root, asset)) and asset not in existing_assets
]

if not new_rows and not src_placeholder_count and not new_asset_rows:
    print("Inventories: nothing to update.")
    sys.exit(0)

# Build output: drop placeholder rows in both sections, insert real rows at section ends
out = []
for i, ln in enumerate(lines):
    drop = (
        (src_start < i < src_end and ln.startswith('|') and has_placeholder_path(ln)) or
        (new_asset_rows and ast_start < i < ast_end and ln.startswith('|') and has_placeholder_path(ln))
    )
    if not drop:
        out.append(ln)
    if last_src_idx >= 0 and i == last_src_idx:
        out.extend(new_rows)
    if last_ast_idx >= 0 and i == last_ast_idx:
        out.extend(new_asset_rows)

open(ctx, 'w').write('\n'.join(out) + '\n')
parts = []
if src_placeholder_count: parts.append(f"removed {src_placeholder_count} source placeholder(s)")
if new_rows:              parts.append(f"added {len(new_rows)} source row(s)")
if new_asset_rows:        parts.append(f"added {len(new_asset_rows)} asset row(s)")
print(f"Inventories: {', '.join(parts)}.")
PY
```

---

## Templates

The case `CLAUDE.md` and `context/case_context.md` are **copied verbatim** from the canonical
templates in `~/.claude/case-templates/` by step 2 above — this skill does **not** carry its own
copy (a second copy would drift out of sync). The only customization is the placeholder
substitution (step 3) and the per-asset Sources Inventory seeding (step 4). To change what a
new case looks like, edit the files under `case-templates/`, never this skill.

Placeholder convention (used across all templates): `{CASE_ID}`, `{CLIENT_NAME}`, `{CASE_ROOT}`,
`{asset_id}`, `{hostname}`.

---

## Post-Init Checklist

After running case-init:

1. If you skipped assets at init, add them now — re-run `/case-init` from the case
   directory, or create `sources/<asset>/ export/<asset>/ audit/<asset>/` manually.
2. Copy evidence into `sources/<asset_id>/` — one entry per source (disk image, memory image,
   or a directory of logs); any number per asset.
3. Run `/case-scan-sources` after dropping evidence into `sources/<asset_id>/` — it auto-adds
   `.E01` / `.dd` / `.img` / `.vmem` / `.mem` / `.raw` / `.dmp` files not yet in the inventory
   (hostname inferred from filename; fill in `{role}` afterwards). Or edit the Sources Inventory
   in `context/case_context.md` manually — one row per source, one row per file.
4. Fill in the rest of `context/case_context.md`:
   - Examiner & Sign-off: `Lead Examiner` (becomes the report's author of record at sign-off)
   - Network Topology (if known)
   - Domain Accounts (from initial brief)
   - Known IOCs (from threat intel or initial triage)
5. Open the case directory in Claude Code — `CLAUDE.md` loads automatically.
6. If you have not yet run `/tools-preflight` on this workstation, do it now — it is a
   one-time tool-availability check, not per-case. Run it before `/case-investigate` so a missing
   tool is caught up front rather than mid-run.
7. If evidence includes disk images (`.E01`, `.dd`, `.img`): run `/tools-mount` to mount them
   before starting the pipeline — `/case-investigate` parses from mounted filesystems, not raw images.
8. Run `/case-investigate` to start the full parsing → analysis → report pipeline.

---

## Resulting Structure

```
/cases/{CASE_ID}/
  CLAUDE.md                    ← reference-only; loads case_context.md + case-investigate skill
  context/
    case_context.md            ← investigator-maintained intel
  sources/
    {asset_id}/                ← drop evidence files here (E01, img, vmem)
                               ← mount dirs created here by tools-mount-e01 / tools-mount-ntfs
  export/
    {asset_id}/                ← parsed evidence ONLY (tool output; subdirs created by each skill)
  analysis/                    ← per-asset reports + global correlation report
  reports/                     ← final report (MD + PDF)
  tmp/                         ← parse-phase working artifacts (dirty-hive copies, staged inputs)
                               ← never cited as evidence; safe to discard after parse phase
  audit/                       ← operational/control plane (NOT evidence, NOT analysis output)
    .dfir_phase                ← pipeline phase marker (gates ./export writes)
    artifact_failures.log      ← parse failures / unparseable artifacts
    decisions.log              ← autonomous AI decisions when blocked
    mount.log                  ← /tools-mount log: the sudo mount commands it emitted for the operator
    forensic_actions.jsonl     ← per-action audit trail (PostToolUse hook)
    forensic_audit.log         ← per-session record (Stop hook)
    {asset_id}/                ← per-asset parse_state.txt + parse.log
```
