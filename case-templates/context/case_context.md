# Case Context: {CASE_ID} — {CLIENT_NAME}

> Investigator-maintained. Update as new intelligence is confirmed. All timestamps UTC.

---

## Examiner & Sign-off

> The human examiner is the final authority. AI assists; it never validates a conclusion or authors
> the final report. Fill `Lead Examiner` before sign-off — `/case-report` uses it as the
> `author_of_record`, and the PDF stays watermarked DRAFT — UNVALIDATED until it is set.

| Field | Value |
|-------|-------|
| Client | {CLIENT_NAME} |
| Lead Examiner (author of record) | |
| Validated (UTC) | |


---

## Incident Timeline (UTC)

| Timestamp (UTC) | Event | Source |
|-----------------|-------|--------|
| {date} | Incident declared | |
| | | |

---

## Case Notes

> Free-form notes about the case — scope decisions, client constraints, investigator observations.
> Not for tool or environment notes.

---

## Incident Window (UTC)

> The analytical anchor for the whole case. Per the Analysis Methodology, activity outside this
> window is presumed baseline/benign unless evidence ties it directly to the incident.

| Field | Timestamp (UTC) | Notes |
|-------|-----------------|-------|
| Incident declared | {YYYY-MM-DD} | Known anchor — set at case open |
| Look-back start | {YYYY-MM-DD} | Working estimate; refine during analysis |

---

## Asset Inventory

| AssetID | Hostname | Role |
|---------|----------|------|
| `{asset_id}` | {hostname} | {role} |

> One row per asset. Fill in hostname and role once evidence is received.

---

## Sources Inventory

| SourceID | AssetID | Type | SourcePath |
|----------|---------|------|------------|
| `{asset_id}-disk01` | `{asset_id}` | `disk` | `/cases/{CASE_ID}/sources/{asset_id}/{hostname}.E01` |
| `{asset_id}-memory01` | `{asset_id}` | `memory` | `/cases/{CASE_ID}/sources/{asset_id}/{hostname}.img` |

> One row per source file or mount point. `case-init` auto-populates on re-run.
> `Type` values: `disk` (EWF/raw disk image) or `memory` (RAM capture). Fill in for every row —
> case-parse uses this to identify memory captures without guessing from file extensions.

---

## Network Topology

| Network | Subnet | Key Hosts |
|---------|--------|-----------|
| {segment} | {cidr} | {hosts} |

**External attacker IP(s):** {ip}

---

## Domain Accounts

| Account | Role | Notes |
|---------|------|-------|
| | Domain Admin | |
| | Service Account | |
| | Local Admin | |

---

## Known IOCs

> One indicator per line inside the block below, each prefixed with its type. The `case-investigate`
> pipeline greps this block directly during Phase 2 IOC cross-reference (e.g. `grep '^ip:'`).
> Keep the prefixes exact, one value per line, no surrounding prose. Delete the example lines.

```ioc
hash:   {md5|sha1|sha256}
ip:     {attacker ip}
domain: {c2 domain or hostname}
file:   {full path or filename}
svc:    {service name}
reg:    {registry key}
task:   {scheduled task name}
```

### IOC Notes (free-form context)

> Optional narrative on the indicators above — provenance, threat-intel source, confidence.

