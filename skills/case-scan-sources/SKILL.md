---
name: case-scan-sources
description: Scan sources/<asset>/ directories and upsert any new evidence files (disk images,
  memory images, mounted dirs) into the Sources Inventory and Asset Inventory in
  context/case_context.md. Run after copying evidence into sources/ to keep the inventory
  current. Deduplicates by source path — existing rows are never modified.
---

# Skill: case-scan-sources — Update Sources Inventory from evidence files

## Overview

Run `/case-scan-sources` from inside the case directory after copying evidence files into
`sources/<asset>/`. The skill:

- Scans every `sources/<asset>/` subdirectory for recognised evidence files (`.E01`, `.dd`,
  `.img`, `.vmem`, `.mem`, `.raw`, `.dmp`) and currently-mounted directories.
- Adds a new Sources Inventory row for each file not already listed (dedup key: source path).
- Adds a new Asset Inventory row for each `sources/<asset>/` directory whose asset ID is not
  yet in the Asset Inventory.
- Never modifies, removes, or rewrites existing rows.

This skill does **not** create directories or copy templates — that is `/case-init`'s job.
Run `/case-init` first if the case is not yet scaffolded, or to add a new asset (which also
creates the `sources/<asset>/`, `export/<asset>/`, and `audit/<asset>/` directories).

---

## Inputs

| Variable    | Resolved from | Description |
|-------------|--------------|-------------|
| `CASE_ROOT` | `$PWD`        | Auto-detected from current directory. Must be run from inside a `/cases/<CASE_ID>` directory. |

---

## Commands

### Step 1 — Locate case root

```bash
CASE_BASE="/cases"
if [[ "$(dirname "$PWD")" == "$CASE_BASE" && "$PWD" != "$CASE_BASE" ]]; then
  CASE_ROOT="$PWD"
else
  echo "ERROR: run /case-scan-sources from inside the case directory." >&2
  echo "  cd /cases/<CASE_ID>  then re-run /case-scan-sources" >&2
  exit 1
fi

CTX="$CASE_ROOT/context/case_context.md"
if [[ ! -f "$CTX" ]]; then
  echo "ERROR: $CTX not found — run /case-init first to scaffold the case." >&2
  exit 1
fi

echo "Scanning sources in: $CASE_ROOT"
```

### Step 2 — Scan sources/ and update inventories

```bash
# Scan all sources/<asset>/ dirs and upsert Sources Inventory rows for new files
# and currently-mounted directories. Also adds missing Asset Inventory rows for
# any new assets found. Dedup key: source path (last backtick-quoted column).
python3 - "$CTX" "$CASE_ROOT" <<'PY'
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

echo ""
echo "Sources Inventory updated: $CTX"
echo "Fill in any {hostname} and {role} placeholders in context/case_context.md."
echo ""
echo "Next: if evidence includes disk images (.E01, .dd, .img), run /tools-mount before /case-investigate."
```
