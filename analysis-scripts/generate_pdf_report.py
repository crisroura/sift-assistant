#!/usr/bin/env python3
"""
DFIR Executive PDF Report Generator
Converts a finished Markdown report (the output of the `case-investigate` pipeline)
into a styled PDF via Markdown -> HTML -> WeasyPrint.

CLI (the supported interface):
    generate_pdf_report.py <input.md> <output.pdf> [--case-id ID] [--client NAME]
                           [--title T] [--subtitle S] [--prepared-by P] [--date D] [--force-final]

Draft-not-signed: if the report's sign-off block has an empty `author_of_record`, the PDF is stamped
with a DRAFT — UNVALIDATED watermark on every page (a human examiner must sign off for a final report).
`--force-final` overrides this and is for human use only — the autonomous pipeline must never pass it.

Library:
    from generate_pdf_report import generate_report
    generate_report(content_dict, output_path)   # content_dict["body_html"] = rendered HTML

This script contains NO baked-in report. The previous hardcoded sample lives,
non-executable, in ./samples/baseline-memory-sample.html for structure reference
only and can never be emitted as a deliverable.
"""

import argparse
import datetime
import re
import sys
from pathlib import Path

try:
    from weasyprint import HTML
except ImportError:
    raise SystemExit("weasyprint not installed. Run: pip3 install weasyprint")


# ── Brand / Style ─────────────────────────────────────────────────────────────

CSS_STYLE = """
/* System font stack only — no remote @import. The SIFT box is air-gapped (network egress is
   denied), so a Google Fonts @import would fail/stall at render time. Fall back to installed fonts. */

@page {
    size: A4;
    margin: 0;
    @bottom-right {
        content: "Page " counter(page) " of " counter(pages);
        font-family: 'Inter', sans-serif;
        font-size: 8pt;
        color: #9ca3af;
        margin-right: 2cm;
        margin-bottom: 0.6cm;
    }
    @bottom-left {
        content: "CONFIDENTIAL — DFIR INTERNAL USE ONLY";
        font-family: 'Inter', sans-serif;
        font-size: 8pt;
        color: #9ca3af;
        margin-left: 2cm;
        margin-bottom: 0.6cm;
    }
}

* { box-sizing: border-box; margin: 0; padding: 0; }

body {
    font-family: 'Inter', 'Helvetica Neue', Arial, sans-serif;
    font-size: 9.5pt;
    color: #1f2937;
    background: #ffffff;
    line-height: 1.55;
}

/* ── Cover / Header ── */
.cover {
    background: linear-gradient(135deg, #0f172a 0%, #1e3a5f 60%, #1d4ed8 100%);
    color: white;
    padding: 2.8cm 2.2cm 2cm 2.2cm;
    page-break-after: always;
    min-height: 100vh;
    display: flex;
    flex-direction: column;
    justify-content: space-between;
}

.cover-top { }

.org-tag {
    font-size: 8pt;
    font-weight: 600;
    letter-spacing: 0.18em;
    text-transform: uppercase;
    color: #93c5fd;
    margin-bottom: 0.5cm;
}

.report-type {
    font-size: 10pt;
    font-weight: 400;
    color: #bfdbfe;
    letter-spacing: 0.05em;
    text-transform: uppercase;
    margin-bottom: 0.3cm;
}

.cover h1 {
    font-size: 28pt;
    font-weight: 700;
    line-height: 1.15;
    color: #ffffff;
    margin-bottom: 0.4cm;
}

.cover-subtitle {
    font-size: 13pt;
    font-weight: 300;
    color: #bfdbfe;
    margin-bottom: 1cm;
}

.cover-divider {
    width: 60px;
    height: 4px;
    background: #3b82f6;
    border-radius: 2px;
    margin: 0.6cm 0 1cm 0;
}

.cover-meta {
    display: table;
    border-collapse: collapse;
    width: 100%;
    margin-top: 0.6cm;
}
.cover-meta-row { display: table-row; }
.cover-meta-label {
    display: table-cell;
    font-size: 8pt;
    font-weight: 600;
    color: #93c5fd;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    padding: 0.12cm 0.6cm 0.12cm 0;
    white-space: nowrap;
    width: 3cm;
}
.cover-meta-value {
    display: table-cell;
    font-size: 9pt;
    color: #e0f2fe;
    padding: 0.12cm 0;
}

.cover-bottom {
    border-top: 1px solid rgba(255,255,255,0.15);
    padding-top: 0.4cm;
    display: flex;
    justify-content: space-between;
    align-items: flex-end;
}
.cover-classification {
    font-size: 8pt;
    font-weight: 700;
    letter-spacing: 0.15em;
    color: #fbbf24;
    text-transform: uppercase;
}
.cover-date {
    font-size: 8pt;
    color: #93c5fd;
}

/* ── Page header stripe ── */
.page-header {
    background: #0f172a;
    color: white;
    padding: 0.35cm 2.2cm;
    display: flex;
    justify-content: space-between;
    align-items: center;
}
.page-header-title {
    font-size: 8.5pt;
    font-weight: 600;
    letter-spacing: 0.05em;
    color: #93c5fd;
}
.page-header-case {
    font-size: 8pt;
    color: #6b7280;
}

/* ── Content area ── */
.content {
    padding: 0.8cm 2.2cm 1.5cm 2.2cm;
}

/* ── Section headings ── */
h2 {
    font-size: 14pt;
    font-weight: 700;
    color: #0f172a;
    margin-top: 0.8cm;
    margin-bottom: 0.3cm;
    padding-bottom: 0.15cm;
    border-bottom: 2.5px solid #1d4ed8;
    display: flex;
    align-items: center;
    gap: 0.3cm;
}
h2 .section-num {
    background: #1d4ed8;
    color: white;
    font-size: 9pt;
    font-weight: 700;
    padding: 0.05cm 0.22cm;
    border-radius: 3px;
    min-width: 0.7cm;
    text-align: center;
}

h3 {
    font-size: 10.5pt;
    font-weight: 700;
    color: #1e3a5f;
    margin-top: 0.5cm;
    margin-bottom: 0.2cm;
}

p { margin-bottom: 0.25cm; }

/* ── Executive Summary box ── */
.exec-summary {
    background: #eff6ff;
    border-left: 4px solid #1d4ed8;
    border-radius: 0 6px 6px 0;
    padding: 0.4cm 0.6cm;
    margin: 0.3cm 0 0.5cm 0;
}
.exec-summary p { margin-bottom: 0.15cm; font-size: 9.5pt; }
.exec-summary p:last-child { margin-bottom: 0; }

/* ── Alert boxes ── */
.alert {
    border-radius: 5px;
    padding: 0.3cm 0.5cm;
    margin: 0.3cm 0;
    font-size: 9pt;
}
.alert-red    { background: #fef2f2; border-left: 4px solid #dc2626; }
.alert-orange { background: #fff7ed; border-left: 4px solid #f97316; }
.alert-green  { background: #f0fdf4; border-left: 4px solid #16a34a; }
.alert-blue   { background: #eff6ff; border-left: 4px solid #2563eb; }

.alert-title {
    font-weight: 700;
    font-size: 9pt;
    margin-bottom: 0.1cm;
}
.alert-red    .alert-title { color: #dc2626; }
.alert-orange .alert-title { color: #c2410c; }
.alert-green  .alert-title { color: #15803d; }
.alert-blue   .alert-title { color: #1d4ed8; }

/* ── Tables ── */
table {
    width: 100%;
    border-collapse: collapse;
    margin: 0.25cm 0 0.5cm 0;
    font-size: 8.8pt;
}
thead tr {
    background: #1e3a5f;
    color: white;
}
thead th {
    padding: 0.18cm 0.28cm;
    text-align: left;
    font-weight: 600;
    font-size: 8pt;
    letter-spacing: 0.04em;
    text-transform: uppercase;
}
tbody tr:nth-child(even) { background: #f8fafc; }
tbody tr:nth-child(odd)  { background: #ffffff; }
tbody td {
    padding: 0.15cm 0.28cm;
    border-bottom: 1px solid #e5e7eb;
    vertical-align: top;
}
tbody tr:hover { background: #eff6ff; }

/* ── Severity badges ── */
.badge {
    display: inline-block;
    padding: 0.04cm 0.2cm;
    border-radius: 3px;
    font-size: 7.5pt;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.05em;
}
.badge-critical { background: #7f1d1d; color: #fecaca; }
.badge-high     { background: #dc2626; color: #ffffff; }
.badge-medium   { background: #f97316; color: #ffffff; }
.badge-low      { background: #2563eb; color: #ffffff; }
.badge-info     { background: #6b7280; color: #ffffff; }
.badge-benign   { background: #16a34a; color: #ffffff; }

/* ── Code / mono ── */
code, .mono {
    font-family: 'Roboto Mono', 'Courier New', monospace;
    font-size: 8pt;
    background: #f1f5f9;
    padding: 0.02cm 0.1cm;
    border-radius: 3px;
    color: #0f172a;
}
.code-block {
    font-family: 'Roboto Mono', 'Courier New', monospace;
    font-size: 7.8pt;
    background: #0f172a;
    color: #e2e8f0;
    padding: 0.35cm 0.45cm;
    border-radius: 6px;
    margin: 0.2cm 0 0.4cm 0;
    white-space: pre-wrap;
    word-break: break-all;
    line-height: 1.6;
}
.code-block .hl  { color: #fbbf24; font-weight: 600; }
.code-block .red { color: #f87171; }
.code-block .grn { color: #86efac; }
.code-block .blu { color: #93c5fd; }

/* ── Process tree ── */
.proc-tree {
    font-family: 'Roboto Mono', 'Courier New', monospace;
    font-size: 8pt;
    background: #0f172a;
    color: #e2e8f0;
    padding: 0.35cm 0.45cm;
    border-radius: 6px;
    margin: 0.2cm 0 0.4cm 0;
    line-height: 1.8;
}
.proc-tree .suspicious { color: #f87171; font-weight: 600; }
.proc-tree .benign     { color: #86efac; }
.proc-tree .neutral    { color: #93c5fd; }

/* ── Metric cards ── */
.metric-row {
    display: flex;
    gap: 0.3cm;
    margin: 0.3cm 0;
}
.metric-card {
    flex: 1;
    background: #f8fafc;
    border: 1px solid #e2e8f0;
    border-top: 3px solid #1d4ed8;
    border-radius: 5px;
    padding: 0.3cm 0.4cm;
    text-align: center;
}
.metric-card.red-top  { border-top-color: #dc2626; }
.metric-card.orange-top { border-top-color: #f97316; }
.metric-card.green-top  { border-top-color: #16a34a; }
.metric-number {
    font-size: 20pt;
    font-weight: 700;
    color: #0f172a;
    line-height: 1.1;
}
.metric-label {
    font-size: 7.5pt;
    font-weight: 600;
    color: #6b7280;
    text-transform: uppercase;
    letter-spacing: 0.07em;
    margin-top: 0.05cm;
}

/* ── Timeline ── */
.timeline { margin: 0.3cm 0; }
.tl-entry {
    display: flex;
    gap: 0.4cm;
    margin-bottom: 0.2cm;
    align-items: flex-start;
}
.tl-dot {
    width: 10px;
    height: 10px;
    border-radius: 50%;
    background: #1d4ed8;
    margin-top: 0.1cm;
    flex-shrink: 0;
}
.tl-dot.red    { background: #dc2626; }
.tl-dot.orange { background: #f97316; }
.tl-dot.green  { background: #16a34a; }
.tl-time {
    font-family: 'Roboto Mono', monospace;
    font-size: 8pt;
    color: #4b5563;
    white-space: nowrap;
    flex-shrink: 0;
    width: 4.5cm;
}
.tl-text { font-size: 9pt; }

/* ── Footer note ── */
.footer-note {
    margin-top: 0.8cm;
    padding-top: 0.3cm;
    border-top: 1px solid #e5e7eb;
    font-size: 7.5pt;
    color: #9ca3af;
}

.page-break { page-break-before: always; }

/* ── Draft / unvalidated watermark (repeats on every page via position: fixed) ── */
.draft-watermark {
    position: fixed;
    top: 45%;
    left: 0;
    width: 100%;
    text-align: center;
    transform: rotate(-32deg);
    font-size: 60pt;
    font-weight: 800;
    letter-spacing: 0.1em;
    color: rgba(220, 38, 38, 0.16);
    text-transform: uppercase;
    z-index: 9999;
}
.draft-banner {
    background: #7f1d1d;
    color: #fecaca;
    text-align: center;
    font-size: 9pt;
    font-weight: 700;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    padding: 0.2cm;
}
"""


def build_html(data: dict) -> str:
    case_id    = data.get("case_id", "SRL-001")
    client     = data.get("client", "Stark Research Labs")
    prepared   = data.get("prepared_by", "DFIR Consulting Team")
    date_str   = data.get("date", datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"))
    title      = data.get("title", "DFIR Analysis Report")
    subtitle   = data.get("subtitle", "")
    body_html  = data.get("body_html", "")
    draft      = data.get("draft", False)

    # Draft-not-signed: with no human author_of_record, stamp the report DRAFT — UNVALIDATED on every
    # page and flag the cover. The pipeline cannot emit a clean "final" PDF without a human signing off.
    watermark_html = '<div class="draft-watermark">DRAFT — UNVALIDATED</div>' if draft else ""
    draft_banner = (
        '<div class="draft-banner">DRAFT — AI-ASSISTED, NOT YET VALIDATED BY A HUMAN EXAMINER</div>'
        if draft else ""
    )
    classification = (
        "DRAFT — UNVALIDATED, NOT FOR DISTRIBUTION" if draft
        else "CONFIDENTIAL — RESTRICTED DISTRIBUTION"
    )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<style>{CSS_STYLE}</style>
</head>
<body>
{watermark_html}

<!-- ══ COVER PAGE ══ -->
<div class="cover">
  <div class="cover-top">
    <div class="org-tag">Digital Forensics &amp; Incident Response</div>
    <div class="report-type">Confidential Forensic Analysis</div>
    <h1>{title}</h1>
    <div class="cover-subtitle">{subtitle}</div>
    <div class="cover-divider"></div>
    <div class="cover-meta">
      <div class="cover-meta-row">
        <div class="cover-meta-label">Client</div>
        <div class="cover-meta-value">{client}</div>
      </div>
      <div class="cover-meta-row">
        <div class="cover-meta-label">Case ID</div>
        <div class="cover-meta-value">{case_id}</div>
      </div>
      <div class="cover-meta-row">
        <div class="cover-meta-label">Prepared By</div>
        <div class="cover-meta-value">{prepared}</div>
      </div>
      <div class="cover-meta-row">
        <div class="cover-meta-label">Report Date</div>
        <div class="cover-meta-value">{date_str} UTC</div>
      </div>
      <div class="cover-meta-row">
        <div class="cover-meta-label">Classification</div>
        <div class="cover-meta-value" style="color:#fbbf24;font-weight:600;">{classification}</div>
      </div>
    </div>
  </div>
  <div class="cover-bottom">
    <div class="cover-classification">&#9632; Confidential</div>
    <div class="cover-date">Report generated {date_str}</div>
  </div>
</div>

<!-- ══ BODY PAGES ══ -->
{draft_banner}
<div class="page-header">
  <div class="page-header-title">{title}</div>
  <div class="page-header-case">Case: {case_id} | {client}</div>
</div>
<div class="content">
{body_html}
<div class="footer-note">
  This report was produced as part of an active digital forensics investigation.
  All findings are based on evidence present at the time of analysis.
  Evidence integrity maintained per chain-of-custody protocol — source images not modified.
</div>
</div>

</body>
</html>"""


def generate_report(data: dict, output_path: str) -> str:
    html = build_html(data)
    HTML(string=html).write_pdf(
        output_path,
        presentational_hints=True,
    )
    return output_path


# ── Markdown → HTML ──────────────────────────────────────────

# Maps used by _enrich_html to wire plain-markdown output to the styled component kit.
_SEVERITY_BADGE = {
    "CRITICAL": "critical", "HIGH": "high", "MEDIUM": "medium", "LOW": "low",
    "INFO": "info", "INFORMATIONAL": "info", "BENIGN": "benign",
}
_ALERT_KIND = {
    "WARNING": "orange", "CAUTION": "red", "CRITICAL": "red", "DANGER": "red",
    "NOTE": "blue", "INFO": "blue", "TIP": "green", "OK": "green", "SUCCESS": "green",
}


def _enrich_html(html: str) -> str:
    """Map conventions in plain-markdown HTML onto the styled component classes.

    - h2 headings get a sequential section-number badge
    - table cells that are exactly a severity word become colored badges
    - blockquotes become alert boxes; a leading `[!TYPE]` marker picks the color/title
    - fenced code blocks get the dark code-block style
    None of these require the report to contain raw HTML; authors may still embed raw HTML
    (e.g. metric-card / proc-tree / timeline components) and markdown passes it through.
    """
    # 1. Numbered section headings.
    n = [0]
    def _num_h2(m):
        n[0] += 1
        return f'<h2><span class="section-num">{n[0]}</span>{m.group(1)}</h2>'
    html = re.sub(r"<h2>(.*?)</h2>", _num_h2, html, flags=re.S)

    # 2. Severity badges — only when a cell is exactly a known severity word.
    def _badge(m):
        word = m.group(1)
        cls = _SEVERITY_BADGE.get(word.upper())
        return f'<td><span class="badge badge-{cls}">{word}</span></td>' if cls else m.group(0)
    html = re.sub(
        r"<td>\s*(CRITICAL|HIGH|MEDIUM|LOW|INFORMATIONAL|INFO|BENIGN)\s*</td>",
        _badge, html, flags=re.I,
    )

    # 3. Blockquotes → alert boxes (optional leading [!TYPE] marker).
    def _alert(m):
        inner = m.group(1)
        cls, title = "blue", None
        mm = re.search(r"\[!(\w+)\]", inner)
        if mm:
            key = mm.group(1).upper()
            cls = _ALERT_KIND.get(key, "blue")
            title = key.title()
            inner = inner.replace(mm.group(0), "", 1)
        title_html = f'<div class="alert-title">{title}</div>' if title else ""
        return f'<div class="alert alert-{cls}">{title_html}{inner}</div>'
    html = re.sub(r"<blockquote>(.*?)</blockquote>", _alert, html, flags=re.S)

    # 4. Dark style for fenced code blocks.
    html = html.replace("<pre>", '<pre class="code-block">')
    return html


def md_to_html(md_text: str) -> str:
    """Render a Markdown report body to HTML, then enrich it with the component styles.

    Uses the `markdown` library (tables, fenced code, sane lists). Imported
    lazily so that importing generate_report for direct HTML input does not
    require the markdown package.
    """
    try:
        import markdown
    except ImportError:
        raise SystemExit("python 'markdown' not installed. Run: pip3 install markdown")
    rendered = markdown.markdown(
        md_text,
        extensions=["tables", "fenced_code", "sane_lists", "toc"],
    )
    return _enrich_html(rendered)


def _derive_title(md_text: str, fallback: str) -> str:
    """First level-1 heading ('# ...') becomes the report title."""
    for line in md_text.splitlines():
        m = re.match(r"^#\s+(.*\S)\s*$", line)
        if m:
            return m.group(1)
    return fallback


def _signoff_author(md_text: str) -> str:
    """Return the author_of_record value from the report's sign-off block ('' if absent/empty).

    Matches the markdown table row `| author_of_record | <value> |`. An empty value means the report
    has not been signed off by a human, so it must render with the DRAFT — UNVALIDATED watermark.
    """
    m = re.search(r"^\|\s*author_of_record\s*\|\s*(.*?)\s*\|", md_text, flags=re.M | re.I)
    return m.group(1).strip() if m else ""


def _derive_case_id(md_path: Path) -> str:
    """Best-effort case id from '<CASE>-final-report.md' style filenames."""
    stem = md_path.stem
    for suffix in ("-final-report", "-report"):
        if stem.endswith(suffix):
            return stem[: -len(suffix)]
    return stem


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Render a finished Markdown DFIR report to a styled PDF.",
    )
    parser.add_argument("input_md", help="Path to the finished Markdown report")
    parser.add_argument("output_pdf", help="Path to write the PDF")
    parser.add_argument("--case-id", dest="case_id", default=None)
    parser.add_argument("--client", default="")
    parser.add_argument("--title", default=None)
    parser.add_argument("--subtitle", default="")
    parser.add_argument("--prepared-by", dest="prepared_by", default="DFIR Consulting Team")
    parser.add_argument("--date", default=None)
    parser.add_argument(
        "--force-final", dest="force_final", action="store_true",
        help="Suppress the DRAFT watermark even when author_of_record is empty. For human use only — "
             "the autonomous pipeline must never pass this; a final report requires a human author.",
    )
    args = parser.parse_args(argv)

    md_path = Path(args.input_md)
    if not md_path.is_file():
        parser.error(f"input markdown not found: {md_path}")

    md_text = md_path.read_text(encoding="utf-8")
    body_html = md_to_html(md_text)

    # Draft-not-signed: no human author_of_record ⇒ watermark, unless a human explicitly forces final.
    author = _signoff_author(md_text)
    draft = (not author) and (not args.force_final)
    if draft:
        print("NOTE: author_of_record is empty — rendering DRAFT — UNVALIDATED. "
              "A human examiner must sign off (fill author_of_record) for a final report.")

    data = {
        "case_id": args.case_id or _derive_case_id(md_path),
        "client": args.client,
        # If signed off, the named human author of record is the one prepared-by.
        "prepared_by": author or args.prepared_by,
        "date": args.date or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
        "title": args.title or _derive_title(md_text, "DFIR Analysis Report"),
        "subtitle": args.subtitle,
        "body_html": body_html,
        "draft": draft,
    }

    out = generate_report(data, args.output_pdf)
    print(f"PDF written: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
