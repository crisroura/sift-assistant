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
| **Multi-agent** | The orchestrator spawns per-asset subagents for Parse and Analyze; their prompts and returns are logged as agent-to-agent messages | `agent-messages.jsonl` |
| **Persistent-loop** | The agent iterates Parse → Analyze → Correlate → Report → Verify; each pass is traced | `phase-iterations.jsonl`, `phase-timeline.md` |
| **Finding → tool traceability** | Every typed finding resolved through its evidence tag to the producing tool execution | `finding-trace.json` |
| **Run totals** | Tool counts, token totals (overall + per phase), findings, trace coverage | `session-summary.json` |

## The agent architecture these logs describe

SIFT Assistant is a **single orchestrator that fans out to per-asset subagents across phase iterations** —
not a flat single agent, and not a swarm. The orchestrator runs the pipeline; during **Parse** it spawns
one subagent per asset to run that asset's parsers in an isolated context, and during **Analyze** it
spawns one subagent per asset to build that asset's report. Each subagent returns its result to the
orchestrator, which then correlates and reports. The extracted logs make each of those structures
explicit and time-ordered.

Phase attribution is exact, not inferred: each Claude Code transcript line carries an `attributionSkill`
field naming the active skill (`case-parse`, `case-analyze`, `case-correlate`, …), folded into pipeline
phases. Subagent tool calls inherit the phase of the orchestrator step that spawned them, so a parser run
inside a Parse subagent is correctly labeled `parse`.

## Featured run: CLIENT-IR-2026-008

The committed logs under [`logs/CLIENT-IR-2026-008/`](../logs/CLIENT-IR-2026-008/) were generated from a
real, continuous two-asset investigation (`dc01` domain controller, `rd01` RDS host) — the same run shown
in the demo video:

- **321 tool executions** across **5 agent contexts** — the orchestrator plus 4 subagents: *Parse dc01*,
  *Parse rd01*, *Analyze dc01*, *Analyze rd01*
- **33,973,667 tokens** total (54,672 input / 231,164 output / 32.3M cache-read / 1.41M cache-creation)
- **8 phase passes** — a clean Setup → Mount → Parse → Analyze → Correlate → Report → Verify sequence
- **22 typed findings** (12 high / 6 medium / 4 low confidence)
- **56 evidence items** in the registry, cited **70 times** across findings — **100% trace coverage**
  (every citation resolves to a producing tool execution)
- end-to-end wall-clock of **~78 minutes** (2026-06-15T23:41Z → 2026-06-16T00:59Z)

## Log file reference

### `tool-executions.jsonl` — the single-agent view

One JSON object per tool call, in execution order (`seq`), each stamped with the agent context, phase,
outcome, duration, and the token usage of the turn that issued it. Full command text is preserved; large
tool outputs are truncated to a head+tail snippet with a `bytes_total` marker (no redaction).

```json
{
  "ts": "2026-06-15T23:53:21.906Z",
  "agent": "subagent:Parse dc01 artifacts",
  "session": "…",
  "skill": "case-parse",
  "phase": "parse",
  "tool": "Bash",
  "tool_use_id": "toolu_…",
  "target": "… MFTECmd.dll -f \"$SRC/$MFT\" --csv \"export/dc01/…/mft/\" --csvf \"dc01-…-mft-mftecmd.csv\" …",
  "outcome": "ok",
  "duration_ms": 12586,
  "tokens": { "input": 2, "output": 1, "cache_read": 88751, "cache_creation": 2675 },
  "seq": 68
}
```

### `agent-messages.jsonl` — the multi-agent view

The orchestrator-to-subagent communication, time-ordered. A `spawn` message carries the full task prompt;
the matching `result` message carries the subagent's returned report plus its own tool-call counts and
token total. `Skill` invocations are logged as orchestrator-to-skill control messages, so the full
control flow is visible:

```
invoke  skill:case-investigate
invoke  skill:case-parse
spawn   main → subagent:Parse dc01 artifacts
spawn   main → subagent:Parse rd01 artifacts
result  subagent:Parse dc01 artifacts → main   (Bash×49, Read×12)
result  subagent:Parse rd01 artifacts → main   (Bash×82, Read×16, Write×1)
invoke  skill:case-analyze
spawn   main → subagent:Analyze rd01
spawn   main → subagent:Analyze dc01
result  subagent:Analyze rd01 → main           (Bash×47, Write×1)
result  subagent:Analyze dc01 → main           (Bash×47, Write×1)
invoke  skill:case-correlate
invoke  skill:case-report
invoke  skill:case-evidence-verify
```

### `phase-iterations.jsonl` + `phase-timeline.md` — the persistent-loop view

One record per contiguous **phase pass**, giving the time window, tool counts by type, tokens spent, the
agent contexts involved, assets touched, and a sample of outputs written. For this run the passes are:

| # | Phase | Tools | Agents |
|---|-------|-------|--------|
| 1 | Setup | 8 | main |
| 2 | Mount | 2 | main |
| 3 | Orchestration | 9 | main |
| 4 | **Parse** | 177 | main, ↳Parse dc01, ↳Parse rd01 |
| 5 | **Analyze** | 105 | main, ↳Analyze dc01, ↳Analyze rd01 |
| 6 | Correlate | 12 | main |
| 7 | Report | 4 | main |
| 8 | Evidence Verify | 4 | main |

[`phase-timeline.md`](../logs/CLIENT-IR-2026-008/phase-timeline.md) renders the same data with a
pass-by-pass "what changed" narrative.

### `finding-trace.json` — the traceability artifact

The crown jewel for the hackathon requirement. For every typed finding (`FD-<asset>-NNNNN` per-asset,
`CORL-NNNNN` cross-asset), it resolves each `EV-` provenance tag through the evidence registry to the
evidence file and locator, then to the **producing tool execution(s)** — by `seq`, timestamp, phase,
tool, command, and token cost. A `coverage` block reports how many citations resolved; anything that
cannot be matched is listed explicitly rather than hidden (honest gaps, never fabricated).

## Worked example: trace a finding to its tool execution

This is the exact chain a judge follows for **finding `FD-dc01-00001`** (high confidence, *exfiltration*) —
the headline "evil" in this case:

> **Finding.** "`shieldbase\spsql` extracted the Active Directory database (NTDS.dit + SYSTEM/SECURITY
> hives) twice via `ntdsutil ifm` on 2018-09-05, preceded by `vssadmin` shadow-copy creation. Full domain
> credential database compromised."

1. **Finding → evidence tag.** `FD-dc01-00001`'s provenance cites `EV-dc01-00009`.
2. **Evidence tag → file + locator.** The evidence registry resolves `EV-dc01-00009` to
   `export/dc01/mnt-001-base-dc-cdrive/mft/dc01-mnt-001-base-dc-cdrive-mft-mftecmd.csv`, locator
   *"EntryNumber 132817; .\temp\Active Directory\ntds.dit + ntds.jfm + .\temp\registry\SYSTEM,SECURITY;
   Created 2018-09-05 12:16:54."*
3. **File → producing tool execution.** That CSV was written by **`seq` 68** — a `Bash` call run by the
   **`Parse dc01 artifacts` subagent** under skill `case-parse`, phase `parse`, at
   `2026-06-15T23:53:21.906Z` (`outcome: ok`, `duration_ms: 12586`):
   ```
   EZ="dotnet /opt/zimmermantools/MFTECmd.dll"
   SRC="./sources/dc01/mnt-001-base-dc-cdrive"
   OUT="export/dc01/mnt-001-base-dc-cdrive/mft"
   $EZ -f "$SRC/\$MFT" --csv "$OUT/" --csvf "dc01-mnt-001-base-dc-cdrive-mft-mftecmd.csv"
   ```
4. **Cross-check.** Look up `seq` 68 in `tool-executions.jsonl` for the full row, including the turn's
   token usage. The finding is now grounded in a specific, timestamped tool execution — run inside a named
   subagent — that any reviewer can re-run against the same evidence.

Note that this chain crosses an **agent boundary**: the finding was authored by the orchestrator from the
Analyze subagent's report, but the evidence behind it was produced by a *Parse* subagent's MFTECmd run.
`finding-trace.json` carries the resolved chain for all 22 findings; `EV-dc01-00009` is one of the 70
citations that resolve at 100% coverage.

## Regenerating the logs

The extractor is read-only and deterministic. After re-running a case, regenerate everything with:

```bash
# 1. Extract the structured logs from the case's transcripts + findings/evidence registries
python3 tooling/extract_agent_logs.py --case-id CLIENT-IR-2026-008
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
