#!/usr/bin/env bash
# sift-assistant — gen_vss_commands.sh
#
# USER-LEVEL helper for /tools-mount-vss, auto-invoked by /tools-mount Step 6 AFTER
# the live volumes are mounted and verified. Run from the case root AS THE USER
# (never sudo) through Claude Code's Bash tool:
#
#     bash ~/.claude/skills/tools-mount-vss/gen_vss_commands.sh
#
# It works over the volumes that are ALREADY MOUNTED — not the raw image. Every
# live NTFS mount (sources/<asset>/mnt-NNN-<imgbase>) is backed by a loop device
# created by `mount -o loop,offset=…`; this helper finds that device with
# `findmnt -n -o SOURCE <mnt>` (sudo-free) and reuses it as the vshadowmount source.
# No fresh losetup, no re-reading ewf1 at an offset.
#
# Snapshot count is unknown until vshadowmount runs (and the loop device is
# root-owned, so detection needs root). So this helper does NOT pre-count: it emits
# ONE self-discovering sudo block per volume that the operator runs in a separate
# terminal — `sudo vshadowmount /dev/loopN` then a `for snap in <vssdir>/vss*` loop
# that mounts each shadow copy read-only. A volume with no VSS is a clean no-op.
#
# Naming, derived from the live mount `mnt-NNN-<imgbase>`:
#   * vshadowmount FUSE point  ->  vss-NNN-<imgbase>
#   * snapshot K loop-mount    ->  mnt-NNN-vss-KKK-<imgbase>   (KKK = vssK store index)
#
# Why the operator runs the sudo (not Claude): sudo cannot prompt for a password
# through Claude Code's Bash tool or the `!` prefix (no PTY). As with the live
# mounts, the same commands are written to a reviewable runnable script
# ./mount-vss-readonly.sh (cat it, then `sudo bash ./mount-vss-readonly.sh`).
#
# Every emitted mount is read-only (`ro`), and vshadowmount exposes the stores
# read-only. Nothing here touches the evidence. Commands are also appended to
# ./audit/mount.log for the record.
set -uo pipefail

CASE_ROOT="$(pwd)"
RUID="$(id -u)"
RGID="$(id -g)"
LOG_DIR="$CASE_ROOT/audit"
LOG="$LOG_DIR/mount.log"

[[ -d "$LOG_DIR" ]] || { echo "ERROR: no ./audit directory in $CASE_ROOT — run /case-init first." >&2; exit 1; }

if ! command -v vshadowmount >/dev/null 2>&1; then
    echo "ERROR: vshadowmount (libvshadow) not found on PATH — cannot mount VSS. Run /tools-preflight." >&2
    exit 1
fi

# loop_source <mountpoint> — the backing device of a mount (e.g. /dev/loop5), sudo-free.
loop_source() { findmnt -n -o SOURCE "$1" 2>/dev/null; }

# fs_type_of <mountpoint> — the mounted filesystem type as the kernel reports it.
fs_type_of() { findmnt -n -o FSTYPE "$1" 2>/dev/null; }

shopt -s nullglob
ASSET_DIRS=( "$CASE_ROOT"/sources/*/ )
if [[ ${#ASSET_DIRS[@]} -eq 0 ]]; then
    echo "ERROR: no sources/<asset>/ directories found." >&2
    exit 1
fi

CMDS=()    # emitted operator script lines
NOTES=()   # diagnostics (skipped mounts, guidance)
ANY=0      # did we emit a VSS block for at least one volume?

for ASSET_DIR in "${ASSET_DIRS[@]}"; do
    ASSET_DIR="${ASSET_DIR%/}"
    ASSET="$(basename "$ASSET_DIR")"

    for MNT in "$ASSET_DIR"/mnt-*/; do
        MNT="${MNT%/}"
        [[ -d "$MNT" ]] || continue
        BN="$(basename "$MNT")"

        # Live volume dirs are mnt-NNN-<imgbase>; skip snapshot mounts (mnt-NNN-vss-*).
        [[ "$BN" =~ ^mnt-[0-9]{3}-vss- ]] && continue
        [[ "$BN" =~ ^mnt-([0-9]{3})-(.+)$ ]] || continue
        PNUM="${BASH_REMATCH[1]}"
        STEM="${BASH_REMATCH[2]}"

        mountpoint -q "$MNT" || continue   # only act on volumes that are actually mounted

        # VSS is NTFS-only. ntfs-3g shows as fuseblk, ntfs3 as ntfs3, older as ntfs.
        # vfat/exfat/etc. are skipped; a fuseblk that turns out non-NTFS fails gracefully below.
        FST="$(fs_type_of "$MNT")"
        case "$FST" in
            ntfs|ntfs3|fuseblk) : ;;
            *) NOTES+=( "[$ASSET] $BN — filesystem '${FST:-unknown}' is not NTFS; no VSS; skipped" ); continue ;;
        esac

        LOOP="$(loop_source "$MNT")"
        if [[ "$LOOP" != /dev/loop* ]]; then
            NOTES+=( "[$ASSET] $BN — backing device '${LOOP:-?}' is not a loop device; cannot reuse it for vshadowmount. For VSS here, mount the image with /tools-mount, or see /tools-mount-vss for the losetup path; skipped" )
            continue
        fi

        VSSDIR="$ASSET_DIR/vss-${PNUM}-${STEM}"
        if mountpoint -q "$VSSDIR"; then
            NOTES+=( "[$ASSET] $(basename "$VSSDIR") already exposed — block still emitted (snapshot mounts are guarded idempotently)" )
        fi
        mkdir -p "$VSSDIR"   # user-owned FUSE mount point

        # One self-discovering block per volume. vshadowmount runs as root with
        # -X allow_other (same rationale as `sudo ewfmount -X allow_other`: keeps the
        # vssN files readable, no /etc/fuse.conf change). vssN is a whole volume, so the
        # snapshot mounts carry NO offset=. uid/gid are baked in so the mounts map to this user.
        CMDS+=( "# [$ASSET] VSS for $BN via $LOOP — expose all shadow copies, mount each (ro)" )
        CMDS+=( "vss_ok=0" )
        CMDS+=( "if mountpoint -q '${VSSDIR}'; then echo '[$ASSET] $(basename "$VSSDIR") already exposed'; vss_ok=1;" )
        CMDS+=( "elif sudo vshadowmount -X allow_other '${LOOP}' '${VSSDIR}/'; then vss_ok=1;" )
        CMDS+=( "else echo '[$ASSET] $BN: no VSS stores (or vshadowmount failed) — skipped'; rmdir '${VSSDIR}' 2>/dev/null || true; fi" )
        CMDS+=( "if [ \"\$vss_ok\" = 1 ]; then" )
        CMDS+=( "  for snap in '${VSSDIR}'/vss*; do" )
        CMDS+=( "    [ -e \"\$snap\" ] || continue" )
        CMDS+=( "    idx=\"\$(basename \"\$snap\" | tr -dc '0-9')\"" )
        CMDS+=( "    mp='${ASSET_DIR}/mnt-${PNUM}-vss-'\"\$(printf '%03d' \"\$idx\")\"'-${STEM}'" )
        CMDS+=( "    mountpoint -q \"\$mp\" && continue" )
        CMDS+=( "    mkdir -p \"\$mp\"" )
        CMDS+=( "    sudo mount -t ntfs-3g -o ro,loop,noatime,uid=${RUID},gid=${RGID},fmask=0133,dmask=0022,streams_interface=windows \"\$snap\" \"\$mp\"" )
        CMDS+=( "  done" )
        CMDS+=( "fi" )
        CMDS+=( "" )
        ANY=1
    done
done

# Diagnostics first (what was skipped and why).
for n in "${NOTES[@]}"; do echo "$n"; done

if [[ "$ANY" -eq 0 ]]; then
    echo "No mounted NTFS volume to scan for VSS — nothing to do. (Run /tools-mount first; VSS is NTFS-only.)"
    exit 0
fi

# Record for the audit trail (user-level append to ./audit).
{
    printf '[%s] gen_vss_commands.sh emitted the following (uid=%s gid=%s):\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUID" "$RGID"
    for c in "${CMDS[@]}"; do printf '  %s\n' "$c"; done
} >> "$LOG"

# Write the copy-safe runnable script. VSS mounting is a logic block (the snapshot
# count is discovered at run time), so the operator runs the script rather than
# pasting — `sudo bash ./mount-vss-readonly.sh`. Plain reviewable text; uid/gid baked
# in. Case root is not an evidence path, so the evidence guard permits this write.
RUN="$CASE_ROOT/mount-vss-readonly.sh"
{
    printf '#!/usr/bin/env bash\n'
    printf '# sift-assistant — generated READ-ONLY VSS mount commands. REVIEW, then run:\n'
    printf '#     sudo bash %s\n' "$RUN"
    printf '# Generated %s (uid=%s gid=%s). Every mount is ro — nothing here touches the evidence.\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUID" "$RGID"
    printf '# Each block reuses the live volume loop device; vshadowmount exposes the shadow copies,\n'
    printf '# then every vssN store is loop-mounted read-only. A volume with no VSS is a no-op.\n\n'
    printf 'set -u\n\n'
    for c in "${CMDS[@]}"; do printf '%s\n' "$c"; done
} > "$RUN"
chmod +x "$RUN" 2>/dev/null || true

echo
echo "VSS mounting reuses each live volume's loop device. Run it in a SEPARATE terminal:"
echo
echo "      cat '$RUN'              # review every command first"
echo "      sudo bash '$RUN'        # expose + mount all shadow copies (read-only)"
echo
echo "After it succeeds, return here — /tools-mount Step 6 verifies the snapshot mounts (no sudo)."
