#!/usr/bin/env python3
"""sift-assistant — PreToolUse evidence-integrity guard.

Deployed to ~/.claude/evidence_guard.py and wired into settings.json as a PreToolUse hook for
the Bash tool. Claude Code passes the tool call as JSON on stdin; exit code 2 BLOCKS the call
(stderr is shown to the model), exit 0 allows it.

It blocks Bash commands that would MODIFY or DELETE forensic evidence — anything under
`sources/`, `/mnt/`, `/media/`, or a forensic disk image (`*.E01`/`.E0n`, `*.dd`, `*.img`,
`*.dmg`). Reads of evidence (fls, icat, cat, grep,
parsers …) are allowed; only mutating operations whose target is an evidence path are blocked.
This is the semantic backstop behind the read-only mounts and the settings.json deny list.

It also enforces PHASE-AWARE immutability of parsed evidence under `./export`: forensic parsers
may write there ONLY during the parse phase. The current phase is read from
`./audit/.dfir_phase` (written by each phase skill into the operational `./audit` plane, which is
never gated). Any write/redirect/dd into `./export` outside the parse phase is blocked. Absent or
unreadable marker ⇒ treated as not-parse ⇒ blocked (safe default). The Write/Edit *tools* are denied
on `./export` in settings.json regardless of phase.

Analysis must write to ./analysis or ./reports; parsed evidence under ./export is written by tools
during parse only and is immutable thereafter — never write to evidence (sources/, /mnt/, /media/).
"""
import json
import re
import sys

# Forensic disk-image extensions (case-insensitive): EnCase E01/E0n, raw .dd, .img, Apple .dmg.
IMG_EXT = r"\.(?i:e\d{2}|dd|img|dmg)\b"

# Evidence locations that are read-only (chain of custody) in EVERY phase.
EVIDENCE = re.compile(rf"(sources/|/mnt/|/media/|{IMG_EXT})")
# Parsed-evidence store: writable by tools during the parse phase only, immutable thereafter.
EXPORT = re.compile(r"(?:\./)?export/")

# Redirection (> or >>) whose target is an evidence path.
REDIR_EVIDENCE = re.compile(
    rf""">>?\s*['"]?(?:\./)?(?:sources/|/mnt/|/media/)|>>?\s*\S*{IMG_EXT}"""
)
# dd writing to evidence.
DD_OF_EVIDENCE = re.compile(rf"\bdd\b[^|;&]*\bof=\S*(?:sources/|/mnt/|/media/|{IMG_EXT})")
# Redirection / dd targeting the parsed-evidence store (gated on the parse phase below).
REDIR_EXPORT = re.compile(r""">>?\s*['"]?(?:\./)?export/""")
DD_OF_EXPORT = re.compile(r"\bdd\b[^|;&]*\bof=\S*(?:\./)?export/")
# Destructive verbs (checked per command segment, alongside a protected path).
DESTRUCTIVE = re.compile(r"\b(rm|shred|wipefs|mkfs\S*|truncate|chmod|chown)\b")


def current_phase() -> str:
    """Read the active pipeline phase from the on-disk marker; '' if absent/unreadable."""
    try:
        with open("./audit/.dfir_phase", encoding="utf-8") as f:
            return f.read().strip().lower()
    except Exception:
        return ""


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0  # unparseable input — don't block

    if data.get("tool_name") != "Bash":
        return 0
    cmd = (data.get("tool_input") or {}).get("command", "")
    if not cmd:
        return 0

    # Parsed evidence under ./export is writable by parser tools during the parse phase only.
    export_writes_allowed = current_phase() == "parse"

    reasons = []
    # Split into command segments so a read in one segment can't trip a verb in another.
    for seg in re.split(r";|\|\||&&|\||\n", cmd):
        if DESTRUCTIVE.search(seg) and EVIDENCE.search(seg):
            reasons.append("destructive command (rm/shred/mkfs/truncate/chmod/chown) on an evidence path")
        if REDIR_EVIDENCE.search(seg):
            reasons.append("redirecting output into an evidence path")
        if DD_OF_EVIDENCE.search(seg):
            reasons.append("dd writing to an evidence path")
        if not export_writes_allowed:
            if DESTRUCTIVE.search(seg) and EXPORT.search(seg):
                reasons.append("write/delete into ./export outside the parse phase")
            if REDIR_EXPORT.search(seg):
                reasons.append("redirecting output into ./export outside the parse phase")
            if DD_OF_EXPORT.search(seg):
                reasons.append("dd writing into ./export outside the parse phase")

    if reasons:
        uniq = "; ".join(sorted(set(reasons)))
        sys.stderr.write(
            "BLOCKED (evidence integrity): " + uniq + ".\n"
            "Evidence under sources/, /mnt/, /media/, and disk images (*.E01, *.dd, *.img, *.dmg) "
            "is read-only (chain of custody). "
            "Parsed evidence under ./export is written by tools during the parse phase only and is "
            "immutable thereafter. Write analysis/report output to ./analysis or ./reports instead.\n"
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
