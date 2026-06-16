---
name: dfir-browser
description: Parse and interpret browser artifacts (Chrome/Edge/Firefox history, downloads, cookies). Primary tool is Hindsight (Chromium-based); SQLECmd for Firefox. Use to reveal attacker reconnaissance, C2 / phishing URLs, download staging, and credential theft on a Windows asset.
---

# dfir-browser — Parse Browser and SQLite Artifacts

## Preconditions — runs inside the parse phase

This is a **parse-phase** artifact parser: it writes parsed output under `./export/`, which the
evidence guard permits **only while the phase marker `./audit/.dfir_phase` reads `parse`**. Normal use
is under `/case-parse` (or `/case-investigate`), which has already armed the parse phase — so just parse.

**The phase marker is owned solely by `/case-parse`.** `/case-parse` arms `parse` at the start and
writes `parse-complete` only once the **entire** parse phase has finished (closing the phase and
re-locking `./export/`). This skill — and every other artifact parser — must **never** write, change,
or close `./audit/.dfir_phase`: not to unblock a write, not for any reason.

**Do not stop the investigation if an `./export/` write is blocked** (guard message `BLOCKED
(evidence integrity): … outside the parse phase`, or a permission denial on an `export/` write): the
parse phase just isn't armed. Run **`/case-parse`** — the marker's owner — to arm it, then re-run the
blocked step. Do **not** set the marker yourself, and **never** reroute parsed output to `./analysis/`
to dodge the block (`./analysis/` is for analysis-phase tool runs only) — parsed evidence belongs
under `./export/` and nowhere else.

---

## Overview

Browser artifacts (history, downloads, cookies, login data) reveal reconnaissance, C2/phishing
traffic, and staging activity.

**Tool chain (all browsers):** `$HINDSIGHT` (Hindsight) → fallback `$EZSQLECMD` (SQLECmd) → fallback `sqlite3`

---

# ── PART 1 · PARSING (used by /case-parse) ──

## Case Path Convention

`<source-dir>` is the operator-created mount subdirectory under `./sources/<asset_id>/`, used
**verbatim** — copy the real directory name exactly as it appears (e.g. `mnt-001-base-dc-cdrive`),
never a partition number or other abbreviation. The export path mirrors that name one-to-one
(`export/<asset>/<source-dir>/<artifact>/`, the canonical layout owned by `/case-parse`).

| Artifact | Path |
|----------|------|
| Chrome History/Downloads | `./sources/<asset_id>/<source-dir>/Users/<user>/AppData/Local/Google/Chrome/User Data/Default/` |
| Edge History | `.../AppData/Local/Microsoft/Edge/User Data/Default/` |
| Firefox History | `.../AppData/Roaming/Mozilla/Firefox/Profiles/<profile>/` |

Output: `./export/<asset_id>/<source-dir>/browser/`
Output filename: `<asset_id>-<source-dir>-<user>-<browser>-<tool>` (Hindsight appends `.csv`). Input from `./sources/`.

---

## Parsing Steps

### 0. Locate the Users directory (case-insensitive) — run first
```bash
SRC="./sources/<asset_id>/<source-dir>"
USERSDIR="$(find "$SRC" -ipath '*/Users' -type d 2>/dev/null | head -1)"
[ -n "$USERSDIR" ] && echo "Using: $USERSDIR" || echo "Users/ not found under $SRC (any case)"
```
`find -ipath` resolves any casing of `Users/`. Steps below use `$USERSDIR`; re-resolve it if you
run a block standalone.

### 1. Hindsight — all browser profiles (primary)

Run once per discovered profile directory. Finds Chrome, Edge, and Firefox profiles:

```bash
mkdir -p "./export/<asset_id>/<source-dir>/browser"

find "$USERSDIR" \
  \( -ipath "*/Chrome/User Data/Default" \
     -o -ipath "*/Chrome/User Data/Profile *" \
     -o -ipath "*/Edge/User Data/Default" \
     -o -ipath "*/Edge/User Data/Profile *" \
     -o -ipath "*/Firefox/Profiles/*" \) \
  -type d 2>/dev/null | \
while IFS= read -r profile; do
  label="$(echo "$profile" | sed 's|.*/Users/||; s|/AppData.*Data/||; s|/AppData.*Profiles/|-firefox-|; s| |_|g')"
  python3 $HINDSIGHT \
    -i "$profile" \
    -o "./export/<asset_id>/<source-dir>/browser/<asset_id>-<source-dir>-${label}-hindsight" \
    -f csv \
    --timezone UTC
  echo "exit=$? profile=$profile"
done
```

Expected output: one CSV per profile, covering URLs, downloads, cookies, autofill, and more.
Verify: exit 0 **and** at least one non-empty `.csv` file written to `./export/…/browser/`.

### 2. SQLECmd fallback — all browsers (if Hindsight failed or produced empty output)

```bash
# Chrome / Edge — target the History database directly
find "$USERSDIR" \
  \( -ipath "*/Chrome/User Data/*/History" -o -ipath "*/Edge/User Data/*/History" \) \
  2>/dev/null | \
while IFS= read -r db; do
  label="$(echo "$db" | sed 's|.*/Users/||; s|/AppData.*User Data/|-|; s|/History||; s| |_|g')"
  $EZSQLECMD \
    -f "$db" \
    --csv "./export/<asset_id>/<source-dir>/browser/" \
    --csvf "<asset_id>-<source-dir>-${label}-sqlecmd.csv" \
    --maps $EZSQLECMD_MAPS
  echo "exit=$?"
done

# Firefox — scan the entire profile directory
find "$USERSDIR" -ipath "*/Firefox/Profiles/*" -type d 2>/dev/null | \
while IFS= read -r profile; do
  label="$(echo "$profile" | sed 's|.*/Users/||; s|/AppData.*Profiles/|-firefox-|; s| |_|g')"
  $EZSQLECMD \
    -d "$profile" \
    --csv "./export/<asset_id>/<source-dir>/browser/" \
    --csvf "<asset_id>-<source-dir>-${label}-sqlecmd.csv" \
    --maps $EZSQLECMD_MAPS
  echo "exit=$?"
done
```

---

## Last-Resort Fallback — sqlite3

If both primary and fallback fail for a browser, query directly:

```bash
mkdir -p "./export/<asset_id>/<source-dir>/browser"

# Chrome / Edge history
find "$USERSDIR" \
  -ipath "*/Chrome/User Data/*/History" -o -ipath "*/Edge/User Data/*/History" 2>/dev/null | \
while IFS= read -r db; do
  label=$(echo "$db" | tr '/[:blank:]' '__')
  sqlite3 "$db" \
    "SELECT datetime(last_visit_time/1000000-11644473600,'unixepoch','utc'), url, title
     FROM urls ORDER BY last_visit_time DESC LIMIT 10000;" \
    > "./export/<asset_id>/<source-dir>/browser/<asset_id>-<source-dir>-${label}-history-sqlite3.csv" 2>/dev/null
done

# Firefox history
find "$USERSDIR" -ipath "*/Firefox/Profiles/*/places.sqlite" 2>/dev/null | \
while IFS= read -r db; do
  label=$(echo "$db" | tr '/[:blank:]' '__')
  sqlite3 "$db" \
    "SELECT datetime(v.visit_date/1000000,'unixepoch','utc'), p.url, p.title
     FROM moz_historyvisits v JOIN moz_places p ON v.place_id=p.id
     ORDER BY v.visit_date DESC LIMIT 10000;" \
    > "./export/<asset_id>/<source-dir>/browser/<asset_id>-<source-dir>-${label}-history-sqlite3.csv" 2>/dev/null
done
```

---

## Parsing Notes

- If a database is locked (live copy open), use a VSS snapshot (`/tools-mount-vss`).
- Hindsight copies the SQLite files to a temp location internally before processing — this is safe
  on read-only mounts and does not touch source evidence.
- `--timezone UTC` ensures Hindsight outputs timestamps in UTC; without it, output uses system local time.
- SQLECmd maps handle timestamp conversion for known schemas; unknown schemas fall to `sqlite3`.
- `sqlite-carver` (router) can recover deleted rows from these databases when needed.

---

# ── PART 2 · ANALYSIS (used by /case-analyze) ──

## Key Fields

Hindsight outputs a single CSV per profile with a `type` column distinguishing artifact categories.

| Hindsight `type` | Key columns | Meaning |
|------------------|-------------|---------|
| `url` | `url`, `title`, `visit_time`, `visit_count`, `typed_count` | Visited URL; `typed_count > 0` means manually entered |
| `download` | `url`, `received_bytes`, `full_path`, `start_time`, `end_time` | Downloaded file path + source URL + size |
| `cookie` | `host`, `name`, `value`, `expires_utc` | Session/auth cookies |
| `autofill` | `name`, `value`, `date_created` | Form autofill entries — may contain usernames/PII |
| `login` | `origin_url`, `username_value`, `date_created` | Saved credentials (Login Data) |

SQLECmd fallback and sqlite3 last-resort produce standard CSV with raw field names (`last_visit_time`
FILETIME epoch for Chrome/Edge; `visit_date` Unix-µs for Firefox). Hindsight converts all timestamps
to UTC automatically via `--timezone UTC`.

---

## Interpretation & Analysis

- **C2 / beaconing:** repeated visits to the same IP-literal or odd domain at regular intervals;
  high `visit_count` on a non-browsing-looking URL. Grep `url` against the case IOC block.
- **Phishing delivery:** URLs to file-sharing sites, pastebin, URL shorteners, or newly registered
  domains immediately preceding a download or execution.
- **Download staging:** the `downloads` table ties a `target_path` to its source `tab_url` and time —
  pivot the dropped path to `$MFT`/Prefetch/Amcache.
- **Credential theft:** access to `Login Data` (saved passwords) is a theft signal — correlate with
  process execution and file reads in EVTX.
- **Timezone/epoch care:** Hindsight converts all timestamps to UTC when `--timezone UTC` is passed.
  SQLECmd maps convert automatically. In raw `sqlite3` you must convert manually: Chrome/Edge use
  FILETIME (µs since 1601-01-01); Firefox uses µs since 1970-01-01 — see fallback queries above.
