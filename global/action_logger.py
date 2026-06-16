#!/usr/bin/env python3
"""sift-assistant — PostToolUse per-action audit / provenance logger.

Deployed to ~/.claude/action_logger.py and wired into settings.json as a PostToolUse hook for
Bash, Write, and Edit. Claude Code passes the completed tool call as JSON on stdin. This hook
appends ONE JSON line per AI action to ./audit/forensic_actions.jsonl — an append-only
provenance trail of what the model did, distinct from the session-level Stop-hook record.

It is intentionally non-blocking: it always exits 0 so a logging hiccup never halts an action.
It logs ONLY fields the PostToolUse payload actually carries (session_id, tool_name, a compact
target summary, exit/error when present) plus the current pipeline phase from ./audit/.dfir_phase.
It does NOT invent a model id/version — session/model identity is recorded at session level by the
Stop hook. The Write/Edit tools are denied on this log in settings.json so the model cannot rewrite
the trail; appends here are hook-driven only.
"""
import datetime
import json
import os
import sys

LOG = "./audit/forensic_actions.jsonl"


def current_phase() -> str:
    try:
        with open("./audit/.dfir_phase", encoding="utf-8") as f:
            return f.read().strip().lower()
    except Exception:
        return ""


def target_summary(tool: str, tool_input: dict) -> str:
    """A compact, non-sensitive description of what the action touched."""
    if tool == "Bash":
        cmd = (tool_input.get("command") or "").replace("\n", " ").strip()
        return cmd[:300]
    if tool in ("Write", "Edit"):
        return (tool_input.get("file_path") or "")[:300]
    return ""


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0  # never block on a logging failure

    tool = data.get("tool_name", "")
    tool_input = data.get("tool_input") or {}
    response = data.get("tool_response")

    # Best-effort exit / error signal from the (tool-dependent) response payload.
    outcome = ""
    if isinstance(response, dict):
        if response.get("is_error") or response.get("error"):
            outcome = "error"
        elif "exit_code" in response:
            outcome = "exit=%s" % response.get("exit_code")

    rec = {
        "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "session": data.get("session_id", ""),
        "phase": current_phase(),
        "tool": tool,
        "target": target_summary(tool, tool_input),
        "outcome": outcome,
    }

    try:
        os.makedirs("./audit", exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception:
        return 0  # append-only best effort; never block the pipeline
    return 0


if __name__ == "__main__":
    sys.exit(main())
