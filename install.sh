#!/usr/bin/env bash
# sift-assistant install script
# Usage: curl -fsSL https://raw.githubusercontent.com/crisroura/sift-assistant/main/install.sh | bash
set -euo pipefail

REPO_URL="https://github.com/crisroura/sift-assistant.git"
CLAUDE_DIR="${HOME}/.claude"
TMPDIR_PREFIX="sift-assistant-install"

# ── helpers ──────────────────────────────────────────────────────────────────

info()  { printf '\033[1;34m[info]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[ ok ]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[warn]\033[0m  %s\n' "$*"; }
die()   { printf '\033[1;31m[fail]\033[0m  %s\n' "$*" >&2; exit 1; }

backup_if_exists() {
    local target="$1"
    if [[ -e "$target" ]]; then
        local bak
    bak="${target}.bak-$(date +%Y%m%d%H%M%S)"
        mv "$target" "$bak"
        warn "Backed up existing $(basename "$target") → $bak"
    fi
}

# ── preflight ────────────────────────────────────────────────────────────────

command -v curl >/dev/null 2>&1 || die "curl is required but not found. Install curl and retry."
command -v git  >/dev/null 2>&1 || die "git is required but not found. Install git and retry."

info "SIFT Assistant — DFIR SIFT Claude Code installer"
echo

# ── system packages (apt) ─────────────────────────────────────────────────────
# Forensic tools shipped with SIFT are assumed present; this only covers extra
# OS packages the skills depend on that bare SIFT may lack.
#   libxml2-utils → xmllint, the Task-XML normalizer used by dfir-scheduled-tasks
APT_PACKAGES=(libxml2-utils)

info "Checking required system packages: ${APT_PACKAGES[*]}"
missing_pkgs=()
for pkg in "${APT_PACKAGES[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        ok "  $pkg already installed."
    else
        missing_pkgs+=("$pkg")
    fi
done

if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
    if command -v apt-get >/dev/null 2>&1; then
        SUDO=""
        [[ "$(id -u)" -ne 0 ]] && SUDO="sudo"
        info "Installing missing packages: ${missing_pkgs[*]}"
        if $SUDO apt-get update -qq && $SUDO apt-get install -y "${missing_pkgs[@]}"; then
            ok "System packages installed."
        else
            warn "Could not install: ${missing_pkgs[*]}. Install manually:"
            warn "  sudo apt-get install -y ${missing_pkgs[*]}"
        fi
    else
        warn "apt-get not found. Install these packages manually: ${missing_pkgs[*]}"
        warn "  sudo apt install ${missing_pkgs[*]}"
    fi
fi
echo

# ── Claude Code ───────────────────────────────────────────────────────────────

if command -v claude >/dev/null 2>&1; then
    ok "Claude Code already installed: $(command -v claude)"
else
    info "Claude Code not found — running official installer…"
    CLAUDE_INSTALLER="$(mktemp -t claude-install.XXXXXX.sh)"
    curl -fsSL https://claude.ai/install.sh -o "$CLAUDE_INSTALLER"
    bash "$CLAUDE_INSTALLER"
    rm -f "$CLAUDE_INSTALLER"
    # Re-source shell profile in case the installer added claude to PATH
    for profile in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.zshrc"; do
        # shellcheck disable=SC1090
        [[ -f "$profile" ]] && source "$profile" 2>/dev/null || true
    done
    command -v claude >/dev/null 2>&1 || \
        warn "Claude Code installed but 'claude' not yet in PATH. Open a new shell after this script finishes."
    ok "Claude Code installed."
fi
echo

# ── locate repo files ─────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/global/CLAUDE.md" && -f "$SCRIPT_DIR/global/settings.json" ]]; then
    info "Running from local repo/archive — skipping clone."
    REPO_DIR="$SCRIPT_DIR"
    WORK_DIR=""
else
    WORK_DIR="$(mktemp -d -t "${TMPDIR_PREFIX}.XXXXXX")"
    trap 'rm -rf "$WORK_DIR"' EXIT
    info "Cloning sift-assistant into temp directory…"
    git clone --depth=1 --quiet "$REPO_URL" "$WORK_DIR/repo"
    REPO_DIR="$WORK_DIR/repo"
    ok "Clone complete."
fi
echo

# ── create ~/.claude if missing ───────────────────────────────────────────────

mkdir -p "$CLAUDE_DIR"

# ── global config files ───────────────────────────────────────────────────────

info "Installing global config files…"

for f in CLAUDE.md settings.json settings.local.json tools.env evidence_guard.py action_logger.py SIFT_SERVER_DFIR_TOOLS.json; do
    src="$REPO_DIR/global/$f"
    dst="$CLAUDE_DIR/$f"
    if [[ ! -f "$src" ]]; then
        warn "Source not found, skipping: global/$f"
        continue
    fi
    backup_if_exists "$dst"
    cp "$src" "$dst"
    ok "  global/$f → $dst"
done
echo

# ── skills ────────────────────────────────────────────────────────────────────

SKILLS=(
    tools-preflight
    tools-mount
    tools-mount-e01
    tools-mount-ntfs
    tools-mount-vss
    dfir-sleuthkit-file-recovery
    dfir-file-carving
    dfir-mft
    dfir-evtx
    dfir-registry
    dfir-prefetch
    dfir-amcache
    dfir-recentfilecache
    dfir-shimcache
    dfir-srum
    dfir-scheduled-tasks
    dfir-lnk-jumplists
    dfir-shellbags
    dfir-recyclebin
    dfir-browser
    dfir-strings
    dfir-plaso-timeline
    dfir-memory-volatility
    dfir-yara
    case-evidence-verify
    case-parse
    case-analyze
    case-correlate
    case-report
    case-investigate
    case-init
    case-scan-sources
)

info "Installing skills…"
for skill in "${SKILLS[@]}"; do
    src="$REPO_DIR/skills/$skill/SKILL.md"
    dst_dir="$CLAUDE_DIR/skills/$skill"
    if [[ ! -f "$src" ]]; then
        warn "  Skill not found, skipping: skills/$skill/SKILL.md"
        continue
    fi
    mkdir -p "$dst_dir"
    cp "$src" "$dst_dir/SKILL.md"
    ok "  skills/$skill/SKILL.md → $dst_dir/SKILL.md"
    # Copy any companion files shipped alongside the skill (e.g. gen_mount_commands.sh)
    while IFS= read -r companion; do
        [[ "$(basename "$companion")" == "SKILL.md" ]] && continue
        cp "$companion" "$dst_dir/"
        ok "  skills/$skill/$(basename "$companion") → $dst_dir/"
    done < <(find "$REPO_DIR/skills/$skill" -maxdepth 1 -type f ! -name SKILL.md)
done
echo

# ── analysis-scripts (kept in ~/.claude for reuse across cases) ───────────────

info "Installing analysis scripts…"
mkdir -p "$CLAUDE_DIR/analysis-scripts"
src="$REPO_DIR/analysis-scripts/generate_pdf_report.py"
if [[ -f "$src" ]]; then
    cp "$src" "$CLAUDE_DIR/analysis-scripts/generate_pdf_report.py"
    ok "  generate_pdf_report.py → $CLAUDE_DIR/analysis-scripts/"
else
    warn "  analysis-scripts/generate_pdf_report.py not found, skipping."
fi
# Reference samples (non-executable; never emitted as deliverables)
if [[ -d "$REPO_DIR/analysis-scripts/samples" ]]; then
    mkdir -p "$CLAUDE_DIR/analysis-scripts/samples"
    cp "$REPO_DIR/analysis-scripts/samples/"* "$CLAUDE_DIR/analysis-scripts/samples/" 2>/dev/null || true
    ok "  analysis-scripts/samples/ → $CLAUDE_DIR/analysis-scripts/samples/"
fi
echo

# ── case template (kept in ~/.claude for reuse) ───────────────────────────────

info "Installing case template…"
mkdir -p "$CLAUDE_DIR/case-templates/context"
src="$REPO_DIR/case-templates/CLAUDE.md"
if [[ -f "$src" ]]; then
    cp "$src" "$CLAUDE_DIR/case-templates/CLAUDE.md"
    ok "  case-templates/CLAUDE.md → $CLAUDE_DIR/case-templates/CLAUDE.md"
else
    warn "  case-templates/CLAUDE.md not found, skipping."
fi
src="$REPO_DIR/case-templates/context/case_context.md"
if [[ -f "$src" ]]; then
    cp "$src" "$CLAUDE_DIR/case-templates/context/case_context.md"
    ok "  case-templates/context/case_context.md → $CLAUDE_DIR/case-templates/context/"
else
    warn "  case-templates/context/case_context.md not found, skipping."
fi
echo

# ── optional: WeasyPrint ──────────────────────────────────────────────────────

if [[ -t 0 ]]; then
    # stdin is a terminal — we can prompt
    read -rp "Install PDF report dependencies now? (pip3 install weasyprint markdown) [y/N] " yn
else
    # piped install — skip interactive prompt, print manual instructions instead
    yn="n"
fi

if [[ "$yn" =~ ^[Yy]$ ]]; then
    if python3 -c "import weasyprint, markdown" 2>/dev/null; then
        ok "PDF dependencies already available (weasyprint + markdown importable)."
    else
        info "Installing WeasyPrint + markdown…"
        # python3-weasyprint is not in Ubuntu apt repos; use pip3.
        # --break-system-packages is required on PEP 668 systems (Python 3.12+).
        if pip3 install --break-system-packages weasyprint markdown; then
            ok "PDF dependencies installed."
        else
            warn "pip3 install failed. Install manually:"
            warn "  pip3 install --break-system-packages weasyprint markdown"
            warn "  # native libs if missing: sudo apt-get install -y python3-gi python3-gi-cairo gir1.2-gtk-3.0 libpango-1.0-0"
        fi
    fi
else
    info "Skipping PDF dependencies. Install them manually when needed:"
    echo "    pip3 install --break-system-packages weasyprint markdown"
    echo "    # native libs if missing:"
    echo "    sudo apt-get install -y python3-gi python3-gi-cairo gir1.2-gtk-3.0 libpango-1.0-0"
fi
echo

# ── done ─────────────────────────────────────────────────────────────────────

ok "Installation complete."
echo
echo "── Next steps ────────────────────────────────────────────────────────────"
echo
echo "  Start a new case:"
echo
echo "    cd /cases"
echo "    mkdir CLIENT-IR-2026-001      # your case ID"
echo "    cd CLIENT-IR-2026-001"
echo "    claude"
echo "    # Then run:"
echo "    /case-init CLIENT=\"Acme Corp\" ASSETS=\"dc01 rd01\""
echo "    #   CLIENT  — client or organisation name (required; use quotes if it contains spaces)"
echo "    #   ASSETS  — space-separated asset IDs for this case (optional; add more later)"
echo
echo "  Or create the structure manually:"
echo
echo "    CASE=CLIENT-IR-2026-001"
echo "    ASSETS=\"dc01 rd01\""
echo "    mkdir -p /cases/\${CASE}/{analysis,reports,context,audit}"
echo "    for A in \$ASSETS; do"
echo "      mkdir -p /cases/\${CASE}/sources/\${A} /cases/\${CASE}/export/\${A} /cases/\${CASE}/audit/\${A}"
echo "    done"
echo "    cp \${HOME}/.claude/case-templates/CLAUDE.md /cases/\${CASE}/CLAUDE.md"
echo "    cp \${HOME}/.claude/case-templates/context/case_context.md \\"
echo "       /cases/\${CASE}/context/case_context.md"
echo "    # Edit case_context.md — add evidence file paths, topology, IOCs"
echo "    cd /cases/\${CASE} && claude"
echo
echo "  Verify every tool resolves first (recommended):  /tools-preflight"
echo "  Drop evidence into sources/<asset_id>/"
echo "  Run /case-scan-sources to register new files in the Sources Inventory"
echo "  If evidence is disk images (.E01): mount them first with /tools-mount"
echo "  Then run /case-investigate"
echo
echo "  Evidence is protected: a PreToolUse hook (evidence_guard.py) blocks any command that"
echo "  would write to or delete sources/, /mnt, /media, or *.E01."
echo
echo "  Do NOT copy ~/.claude/.credentials.json — it contains your API key."
echo "──────────────────────────────────────────────────────────────────────────"
