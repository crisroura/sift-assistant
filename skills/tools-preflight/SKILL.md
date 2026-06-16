# Skill: tools-preflight — Tool Availability Check (run this BEFORE a case)

## Overview

Verifies that every binary, DLL, and script the dfir-* skills may invoke actually resolves on this
host, and reports the gaps up front — so a multi-hour run never dies halfway because a tool is missing,
and so you know in advance which **fallbacks** you'll be relying on.

This is a **standalone, operator-run** check. Invoke it by hand, step by step, before starting a case:

```
/tools-preflight
```

It is intentionally **not** wired into `/case-investigate` — `case-investigate` stays a pure investigation +
report workflow. Run preflight yourself first, read the table, install or note anything missing, then
start the pipeline.

It **reports only** — it never aborts and never modifies anything. Output goes to stdout and to
`./analysis/preflight-tools.md` (when run from a case root).

---

## What it checks

Two groups, both sourced from the single source of truth `~/.claude/tools.env`:

1. **Path-bearing tools** — the `VOLATILITY3`, `EZ*`, `ANALYZEMFT`, `PREF`, `PREFETCHPY`,
   `REGRIPPER`, `YARA_PYTHON` variables. For each, the underlying file or command must resolve:
   - `dotnet /path/X.dll` → the `.dll` file must exist.
   - `python3 /path/x.py` → the `.py` file must exist (and `python3` on PATH).
   - `python3` (interpreter-only, no script path, e.g. `YARA_PYTHON`) → interpreter must be on PATH; module availability verified by the `YARA_MODULE` row.
   - bare command or absolute path (e.g. `yara`, `rip.pl`, `/usr/local/bin/pref.pl`) → `command -v` must find it.
2. **PATH-resolved tools** — TSK, plaso, libewf, and core utilities listed in
   `PREFLIGHT_PATH_TOOLS` (`ewfmount mmls fsstat fls icat … log2timeline.py psort.py mount …`).

---

## Run

```bash
source ~/.claude/tools.env

OUT="./analysis/preflight-tools.md"
mkdir -p ./analysis 2>/dev/null

# resolve_one "<var-value or bare cmd>" → prints "OK|<resolved>" or "MISSING|<what>"
resolve_one() {
  local spec="$1" interp path
  read -r interp path _ <<<"$spec"
  case "$interp" in
    dotnet)  [[ -f "$path" ]] && echo "OK|$path"               || echo "MISSING|$path" ;;
    python3) command -v python3 >/dev/null || { echo "MISSING|python3 (interpreter)"; return; }
             if [[ -z "$path" ]]; then
               echo "OK|$(command -v python3)"
             elif [[ -f "$path" ]]; then
               echo "OK|$path"
             else
               echo "MISSING|$path"
             fi ;;
    *)       local r; r="$(command -v "$interp" 2>/dev/null)" \
               && echo "OK|$r" || echo "MISSING|$interp (not on PATH)" ;;
  esac
}

GAPS=0
{
  printf '# Preflight — Tool Availability\n\n'
  printf 'Host: %s   Generated: %s UTC\n\n' "$(hostname)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '| Tool (var) | Status | Resolved |\n|------------|--------|----------|\n'

  for VAR in VOLATILITY3 \
             EZMFTECMD EZEVTXECMD EZRECMD EZAMCACHEPARSER EZAPPCOMPATCACHEPARSER \
             EZLECMD EZJLECMD EZSBECMD EZSQLECMD EZWXTCMD EZBSTRINGS \
             PREF PREFETCHPY ANALYZEMFT REGRIPPER YARA_PYTHON; do
    spec="${!VAR:-}"
    if [[ -z "$spec" ]]; then
      printf '| %s | MISSING | (unset in tools.env) |\n' "$VAR"; GAPS=$((GAPS+1)); continue
    fi
    res="$(resolve_one "$spec")"
    status="${res%%|*}"; where="${res#*|}"
    printf '| %s | %s | `%s` |\n' "$VAR" "$status" "$where"
    [[ "$status" == "MISSING" ]] && GAPS=$((GAPS+1))
  done

  # YARA module import check — verifies what dfir-yara actually needs
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import yara" 2>/dev/null; then
      ver="$(python3 -c 'import yara; print(yara.__version__)' 2>/dev/null || echo '?')"
      printf '| YARA_MODULE | OK | `yara-python %s` |\n' "$ver"
    else
      printf '| YARA_MODULE | MISSING | `python3 -c "import yara"` failed — install python3-yara |\n'
      GAPS=$((GAPS+1))
    fi
  fi

  # Support files (maps / batch / rules dirs)
  for VAR in EZEVTXECMD_MAPS EZRECMD_BATCH EZSQLECMD_MAPS REGRIPPER_PLUGINS YARA_RULES; do
    p="${!VAR:-}"
    if [[ -n "$p" && -e "$p" ]]; then printf '| %s | OK | `%s` |\n' "$VAR" "$p"
    else printf '| %s | MISSING | `%s` |\n' "$VAR" "${p:-unset}"; GAPS=$((GAPS+1)); fi
  done

  # PATH-resolved forensic tools
  for t in $PREFLIGHT_PATH_TOOLS; do
    r="$(command -v "$t" 2>/dev/null)" \
      && printf '| %s | OK | `%s` |\n' "$t" "$r" \
      || { printf '| %s | MISSING | (not on PATH) |\n' "$t"; GAPS=$((GAPS+1)); }
  done

  printf '\n**Gaps: %d**\n' "$GAPS"
} | tee "$OUT"

if [[ "$GAPS" -gt 0 ]]; then
  printf '\n\033[1;33m[WARN]\033[0m %d tool(s) missing. Fallbacks will be used where available; see %s\n' "$GAPS" "$OUT"
else
  printf '\n\033[1;32m[OK]\033[0m All tools resolved.\n'
fi
```

---

## Reading the result

- **OK** — the tool is present; the primary path for that artifact will run.
- **MISSING** for a primary tool that has a fallback (e.g. `EZMFTECMD` → `ANALYZEMFT`,
  `EZRECMD` → `REGRIPPER`) — the run still works via the fallback, but outputs
  will carry the fallback's tool token in their filename (e.g. `dc01-mft-analyzemft.csv`). Note it.
- **MISSING** for a tool with **no** fallback (e.g. `VOLATILITY3`, `log2timeline.py`, `ewfmount`) — that
  artifact will be skipped. Install the tool or accept the gap before running `/case-investigate`.

Preflight changes nothing on disk except writing the report. Fix gaps (install, or correct the path in
`~/.claude/tools.env`) and re-run until the table reflects the host.
