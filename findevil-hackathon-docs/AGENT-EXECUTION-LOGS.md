# Agent Execution Logs

*Structured, judge-traceable logs of SIFT Assistant's full agent communication and tool-execution sequence — every finding linked back to the exact tool execution that produced it.*

## What these logs are

The Finddevil hackathon asks for **Agent Execution Logs**: structured logs showing the full agent
communication and tool-execution sequence, such that *"judges must be able to trace any finding back to
the specific tool execution that produced it."* It distinguishes three submission shapes — single-agent
(tool execution + timestamps + token usage), multi-agent (agent-to-agent messages), and persistent-loop
(iteration-over-iteration traces).

SIFT Assistant already records all of this. Every `/case-investigate` run is driven through Claude Code,
whose session transcripts capture every tool call, its result, per-turn token usage, every subagent it
spawns, and the skill active at each step. The pipeline also emits typed findings and an evidence
registry that map each finding to the evidence file behind it. The extractor
[`tooling/extract_agent_logs.py`](../tooling/extract_agent_logs.py) **joins these two sources** —
read-only — into submission-ready logs under `logs/<CASE_ID>/`. Nothing in the investigation pipeline
changes; the logs are derived after the fact from durable, tamper-evident records.

SIFT Assistant is a **hybrid** of all three shapes, so these logs cover all three:

| Hackathon dimension | What it means here | Log file |
|---|---|---|
| **Single-agent** | Every tool call with UTC timestamp, active skill/phase, outcome, duration, and token usage | `tool-executions.jsonl` |
| **Multi-agent** | The orchestrator spawns per-asset analysis subagents; their prompts and returns are logged as agent-to-agent messages | `agent-messages.jsonl` |
| **Persistent-loop** | The agent iterates Parse → Analyze → Correlate → Report, re-entering Parse once per artifact/asset; each pass is traced | `phase-iterations.jsonl`, `phase-timeline.md` |
| **Finding → tool traceability** | Every typed finding resolved through its evidence tag to the producing tool execution | `finding-trace.json` |
| **Run totals** | Tool counts, token totals (overall + per phase), findings, trace coverage | `session-summary.json` |

## The agent architecture these logs describe

SIFT Assistant is a **single orchestrator that fans out to subagents across phase iterations** — not a
flat single agent, and not a swarm. The orchestrator runs the four-phase pipeline; during Analyze it
spawns one general-purpose **subagent per asset** (each does its own tool sequence in an isolated
context and returns a report); Parse re-enters once per artifact/asset. The extracted logs make each of
those three structures explicit and time-ordered.

Phase attribution is exact, not inferred: each Claude Code transcript line carries an `attributionSkill`
field naming the active skill (`dfir-evtx`, `case-analyze`, `case-correlate`, …), which the extractor
folds into pipeline phases (`parse`, `analyze`, `correlate`, `report`, `verify`, plus `setup`/`mount`).

## Featured example: CLIENT-IR-2026-007

The committed logs under [`logs/CLIENT-IR-2026-007/`](../logs/CLIENT-IR-2026-007/) were generated from a
real two-asset run (`dc01` domain controller, `rd01` RDS host):

- **708 tool executions** across **3 agent contexts** (the orchestrator + 2 analysis subagents)
- **35,750,187 tokens** total (221,164 input / 585,943 output / 32.7M cache-read / 2.24M cache-creation)
- **33 phase passes**, **25 typed findings** (17 high / 5 medium / 3 low confidence)
- **46 evidence items** in the registry, cited **66 times** across findings — **100% trace coverage**
  (every citation resolves to a producing tool execution)

> The example case was assembled over several working sessions across three calendar days, so its
> wall-clock span is wide; a clean re-run is one continuous pipeline. The extractor is deterministic and
> idempotent — re-run it after your fresh case run to regenerate every file (see *Regenerating*).

## Log file reference

### `tool-executions.jsonl` — the single-agent view

One JSON object per tool call, in execution order (`seq`), each stamped with the agent context, phase,
outcome, duration, and the token usage of the turn that issued it. Full command text is preserved; large
tool outputs are truncated to a head+tail snippet with a `bytes_total` marker (no redaction).

```json
{
  "ts": "2026-06-14T22:04:12.141Z",
  "agent": "main",
  "session": "e3e77641-3abe-4fcb-a32b-2f7f0e5459be",
  "skill": "dfir-evtx",
  "phase": "parse",
  "tool": "Bash",
  "tool_use_id": "toolu_…",
  "target": "source ~/.claude/tools.env\n$EZEVTXECMD -d \"./sources/dc01/…/Logs/\" --csv \"./export/dc01/…/evtx/\" …",
  "outcome": "ok",
  "duration_ms": 52,
  "tokens": { "input": 2, "output": 323, "cache_read": 27999, "cache_creation": 820 },
  "seq": 261
}
```

### `agent-messages.jsonl` — the multi-agent view

The orchestrator-to-subagent communication, time-ordered. A `spawn` message carries the full task prompt;
the matching `result` message carries the subagent's returned report plus its own tool-call counts and
token total. `Skill` invocations are logged as orchestrator-to-skill control messages.

```json
{ "ts": "2026-06-15T22:15:54.772Z", "channel": "agent-to-agent", "kind": "spawn",
  "from": "main", "to": "subagent:Analyze rd01 asset", "subagent_type": "general-purpose",
  "prompt": { "bytes_total": 10696, "truncated": true, "text": "…" } }
{ "ts": "2026-06-15T22:35:…Z", "channel": "agent-to-agent", "kind": "result",
  "from": "subagent:Analyze rd01 asset", "to": "main",
  "subagent_tool_calls": { "Bash": 33, "Write": 1 }, "subagent_tokens_total": 2922513,
  "result": { "bytes_total": …, "text": "…" } }
```

### `phase-iterations.jsonl` + `phase-timeline.md` — the persistent-loop view

One record per contiguous **phase pass**. Because the agent re-enters Parse once per artifact/asset, the
iteration structure is visible: in the example, Parse appears as **multiple passes** before the pipeline
advances to Analyze. Each record gives the time window, tool counts by type, tokens spent, the agent
contexts involved, assets touched, and a sample of outputs written.
[`phase-timeline.md`](../logs/CLIENT-IR-2026-007/phase-timeline.md) renders the same data as a table plus
a pass-by-pass "what changed" narrative.

### `finding-trace.json` — the traceability artifact

The crown jewel for the hackathon requirement. For every typed finding (`FD-<asset>-NNNNN` per-asset,
`CORL-NNNNN` cross-asset), it resolves each `EV-` provenance tag through the evidence registry to the
evidence file and locator, then to the **producing tool execution(s)** — by `seq`, timestamp, phase,
tool, command, and token cost. A `coverage` block reports how many citations resolved; anything that
cannot be matched is listed explicitly rather than hidden (honest gaps, never fabricated).

## Worked example: trace a finding to its tool execution

This is the exact chain a judge follows for **finding `FD-dc01-00001`** (high confidence, *execution*):

> **Finding.** "Windows Defender detected PowerSploit (`Trojan:PowerShell/Powersploit.O`) in
> `C:\Users\spsql\n.ps1` on the DC on 2018-08-31; offensive PowerShell tooling staged under the spsql
> service-account profile."

1. **Finding → evidence tag.** `FD-dc01-00001`'s provenance cites `EV-dc01-00001`.
2. **Evidence tag → file + locator.** The evidence registry resolves `EV-dc01-00001` to
   `export/dc01/mnt-001-base-dc-cdrive/evtx/dc01-mnt-001-base-dc-cdrive-evtx-evtxecmd.csv`, locator
   *"EventId 1116/1117 Defender; Threat Trojan:PowerShell/Powersploit.O; file C:\Users\spsql\n.ps1; csv
   rows 2430698-2430701."*
3. **File → producing tool execution.** That CSV was written by **`seq` 261** — a `Bash` call under skill
   `dfir-evtx`, phase `parse`, at `2026-06-14T22:04:12.141Z`:
   ```
   source ~/.claude/tools.env
   $EZEVTXECMD \
     -d "./sources/dc01/mnt-001-base-dc-cdrive/Windows/System32/winevt/Logs/" \
     --csv "./export/dc01/mnt-001-base-dc-cdrive/evtx/" \
     --csvf "dc01-mnt-001-base-dc-cdrive-evtx-evtxecmd.csv" \
     --maps $EZEVTXECMD_MAPS …
   ```
4. **Cross-check.** Look up `seq` 261 in `tool-executions.jsonl` for the full row — outcome `ok`,
   `duration_ms` 52, and the token usage of that turn. The finding is now grounded in a specific,
   timestamped tool execution that any reviewer can re-run against the same evidence.

`finding-trace.json` carries this resolved chain for all 25 findings; `EV-dc01-00001` is one of the 66
citations that resolve at 100% coverage.

## Regenerating the logs

The extractor is read-only and deterministic. After re-running your case, regenerate everything with:

```bash
# 1. Extract the structured logs from the case's transcripts + findings/evidence registries
python3 tooling/extract_agent_logs.py --case-id <CASE_ID>
#   options: --case-dir /cases/<CASE_ID>  --projects-dir ~/.claude/projects  --out logs/<CASE_ID>

# 2. Re-render this document to HTML (house style, no dependencies)
python3 tooling/render_doc.py docs/AGENT-EXECUTION-LOGS.md docs/AGENT-EXECUTION-LOGS.html
```

It auto-discovers the Claude Code transcript directory (`~/.claude/projects/-cases-<CASE_ID>/`, including
per-subagent sidechains) and the case working dir (`/cases/<CASE_ID>/`). It writes only under
`logs/<CASE_ID>/` — never to `sources/`, `export/`, or any `audit/` plane.

## Provenance & honesty notes

- **Read-only and derivative.** The logs are extracted from Claude Code's own session transcripts and the
  case's typed findings/evidence registries. The extractor never mutates evidence, parsed output, or
  audit records; it adds no facts of its own.
- **No fabrication.** A finding whose evidence file cannot be matched to a tool execution is reported with
  an empty `produced_by` and a reason (e.g. operator-provided source, ad-hoc analysis output) in the
  `coverage.unresolved` list — never invented.
- **Token attribution.** Token usage is recorded per assistant **turn**; a turn issuing several tool calls
  attributes that turn's usage to each call, while `session-summary.json` counts each turn once for
  totals. Cache-read tokens dominate because the long forensic context is reused across turns.
- **No person-attribution.** The logs carry only account, SID, host, and IP identifiers inherited from the
  findings; linking activity to a named individual remains a human-only determination.

---

*Generated by `tooling/extract_agent_logs.py` + `tooling/render_doc.py`. Part of SIFT Assistant, an
enhancement of teamdfir's protocol-sift, submitted to the Finddevil hackathon.*
