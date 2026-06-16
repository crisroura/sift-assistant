#!/usr/bin/env bash
# sift-assistant — gen_mount_commands.sh
#
# USER-LEVEL helper for the /tools-mount orchestrator. Run from the case root
# AS THE USER (never sudo) through Claude Code's Bash tool:
#
#     bash ~/.claude/skills/tools-mount/gen_mount_commands.sh
#
# It does every step that does NOT need sudo, autonomously: it finds every disk
# image of every asset (EWF .E01 and raw .dd/.img/.raw — ALL of them, an asset
# may have several), works out each disk's partition offsets and each partition's
# filesystem type WITHOUT a privileged mount (The Sleuth Kit reads the image
# directly: mmls for the partition table, fsstat for the filesystem type, fls to
# spot \Windows at a volume root), and creates the user-owned mount-point
# directories. Then it PRINTS the exact commands that DO need sudo, for the
# operator to run in a separate terminal.
#
# Every recognized filesystem partition is mounted — NTFS, FAT12/16/32 and exFAT
# (old Windows data volumes), not only the \Windows OS volume. The parse phase
# later analyzes only the volumes that actually hold Windows; the others are
# mounted for manual review.
#
# Mount-point names use a mnt-NNN counter prefix with the image stem trailing,
# all hyphen-separated (no underscores):
#   * EWF  base-dc-cdrive.E01  ->  ewfmount dir  e01-base-dc-cdrive
#                                  volume mount  mnt-001-base-dc-cdrive
#   * raw  base-dc-disk.dd (2 partitions)  ->  mnt-001-base-dc-disk, mnt-002-base-dc-disk
#
# The emitted sudo commands, each split ONE ARGUMENT PER LINE with a trailing ` \`:
#   * raw image  -> one cmd:   sudo mount \
#                                -t <fs> \
#                                -o ro,loop,offset=... \
#                                <img> \
#                                <mnt-NNN-imgbase>
#   * EWF image  -> two cmds:  sudo fusermount -u \      +    sudo mount (as above, on <ewf1>)
#                                <e01-imgbase> 2>/dev/null
#                              sudo ewfmount \
#                                -X allow_other \
#                                <img.E01> \
#                                <e01-imgbase/>
#
# Why split per argument: short physical lines do not soft-wrap in a normal terminal,
# so copying them out of chat injects no stray hard newline, and the explicit ` \`
# joins them back into one command. This is what makes the printed commands directly
# copy-pasteable regardless of terminal width (the earlier break was `-X` getting
# separated from `allow_other` when a long single line wrapped on paste).
#
# Why sudo ewfmount -X allow_other (not -X allow_root, and no /etc/fuse.conf
# edit): root's loop-mount must read the FUSE ewf1; running ewfmount AS ROOT lets
# it use allow_other with no fuse.conf change (that restriction binds only
# non-root users), and allow_other keeps ewf1 readable by the user too.
#
# Why the operator runs these (not Claude): sudo cannot prompt for a password
# through Claude Code's Bash tool or the `!` prefix (no PTY).
#
# Fallback if a paste still fails (e.g. the long `-o <options>` line wraps on a very
# narrow terminal): besides printing the per-argument lines, this helper writes the
# SAME commands to a runnable script ./mount-readonly.sh at the case root. The operator
# reviews it (`cat`) then runs `sudo bash ./mount-readonly.sh` — no paste at all.
# uid/gid are baked in at generation time so `sudo bash` still maps the mounts to this
# user. The script is plain reviewable text — nothing is hidden.
#
# All emitted mounts are read-only (`ro`), never touch the evidence, and are also
# appended to ./audit/mount.log for the record.
set -uo pipefail

CASE_ROOT="$(pwd)"
RUID="$(id -u)"
RGID="$(id -g)"
LOG_DIR="$CASE_ROOT/audit"
LOG="$LOG_DIR/mount.log"

NTFS_VBR="eb52904e544653"   # EB 52 90 'N' 'T' 'F' 'S' — NTFS volume boot record

[[ -d "$LOG_DIR" ]] || { echo "ERROR: no ./audit directory in $CASE_ROOT — run /case-init first." >&2; exit 1; }

# ── disk inspection (all sudo-free; operate on any disk path: ewf1 or raw file) ──

# imgbase <path> — the image filename minus its disk extension, sanitized to a
# safe directory stem (non [A-Za-z0-9._-] -> -). base-dc-cdrive.E01 -> base-dc-cdrive
imgbase() {
    local n; n="$(basename "$1")"; n="${n%.*}"
    echo "${n//[^A-Za-z0-9._-]/-}"
}

# sector_size <disk> — bytes per sector from the mmls header (512 default).
sector_size() {
    local ss
    ss="$(mmls "$1" 2>/dev/null | sed -n 's/.*Units are in \([0-9][0-9]*\)-byte.*/\1/p' | head -1)"
    echo "${ss:-512}"
}

# partition_starts <disk> — one start sector per allocated partition row in mmls,
# for ANY filesystem (empty if there is no partition table). fs_type classifies each.
partition_starts() {
    mmls "$1" 2>/dev/null | awk '$2 ~ /^[0-9]+:[0-9]+$/ { print $3 }'
}

# fs_type <disk> <start_sector> — filesystem type string reported by fsstat
# ("NTFS", "FAT16", "FAT32", "exFAT", …); empty if fsstat finds no filesystem.
fs_type() {
    fsstat -o "$2" "$1" 2>/dev/null | sed -n 's/^File System Type: *//p' | head -1
}

# is_windows_volume <disk> <start_sector> — 0 if a \Windows dir sits at the volume root.
is_windows_volume() {
    fls -o "$2" "$1" 2>/dev/null | grep -qiE '[[:space:]]Windows$'
}

# validate_raw_disk <file> — 0 if the raw file is a mountable disk: a partition
# table, an NTFS VBR at offset 0, or any filesystem fsstat recognizes at offset 0.
validate_raw_disk() {
    mmls "$1" 2>/dev/null | grep -qE '^[0-9]{3}:[[:space:]]' && return 0
    [[ "$(head -c7 "$1" 2>/dev/null | xxd -p 2>/dev/null)" == "$NTFS_VBR" ]] && return 0
    [[ -n "$(fs_type "$1" 0)" ]]
}

# image_kind <file> — classify a candidate file by extension/content (no validation):
#   ewf | container | memory | tail | raw   (raw is provisional, validate_raw_disk confirms it)
image_kind() {
    local f="$1" name ext fb
    name="$(basename "$f")"
    if [[ "$name" == *.* ]]; then ext="${name##*.}"; ext="${ext,,}"; else ext=""; fi

    # split-segment tails (not the first segment) — handled via their first segment
    if { [[ "$ext" =~ ^e[0-9]{2}$ ]] && [[ "$ext" != e01 ]]; } \
    || { [[ "$ext" =~ ^ex[0-9]{2}$ ]] && [[ "$ext" != ex01 ]]; } \
    || { [[ "$ext" =~ ^s[0-9]{2}$ ]] && [[ "$ext" != s01 ]]; } \
    || { [[ "$ext" =~ ^[0-9]{3}$ ]] && [[ "$ext" != 001 && "$ext" != 000 ]]; }; then
        echo tail; return
    fi

    case "$ext" in
        vmem|mem|dmp|lime|core)            echo memory;    return ;;
        vmdk|vhd|vhdx|vdi|qcow|qcow2|vpc)  echo container; return ;;
    esac

    fb="$(file -b "$f" 2>/dev/null)"
    case "$fb" in
        *EWF*|*"Expert Witness"*)                       echo ewf;       return ;;
        *VMware*|*QCOW*|*"Virtual Disk"*|*VHD*|*VirtualBox*) echo container; return ;;
    esac

    case "$ext" in
        e01|ex01|s01|l01)            echo ewf; return ;;
        dd|raw|img|bin|000|001|"")   echo raw; return ;;   # provisional; validate_raw_disk confirms
    esac
    echo raw   # unknown extension — let validate_raw_disk decide
}

# ── per-asset → per-image discovery and command emission ─────────────────────
shopt -s nullglob
ASSET_DIRS=( "$CASE_ROOT"/sources/*/ )
if [[ ${#ASSET_DIRS[@]} -eq 0 ]]; then
    echo "ERROR: no sources/<asset>/ directories found. Copy evidence in first." >&2
    exit 1
fi

CMDS=()        # the sudo commands to print
NOTES=()       # diagnostics (skipped files, guidance)
ANY=0          # did we emit at least one mount?
declare -A SEEN_BASE   # per-asset imgbase -> count, to disambiguate shared stems

for ASSET_DIR in "${ASSET_DIRS[@]}"; do
    ASSET_DIR="${ASSET_DIR%/}"
    ASSET="$(basename "$ASSET_DIR")"
    SEEN_BASE=()

    # Collect this asset's distinct disk images (each as "type|path").
    IMAGES=()
    for f in "$ASSET_DIR"/*; do
        [[ -f "$f" ]] || continue
        kind="$(image_kind "$f")"
        case "$kind" in
            tail)      : ;;   # a segment of an image already represented by its first segment
            ewf)       IMAGES+=( "ewf|$f" ) ;;
            container) NOTES+=( "[$ASSET] container image $(basename "$f") — mount with qemu-nbd (see /tools-mount-ntfs), then re-run /tools-mount; skipped" ) ;;
            memory)    NOTES+=( "[$ASSET] memory image $(basename "$f") — analyze with /dfir-memory-volatility, not mounted; skipped" ) ;;
            raw)
                if validate_raw_disk "$f"; then
                    IMAGES+=( "raw|$f" )
                else
                    NOTES+=( "[$ASSET] $(basename "$f") has no partition table or recognizable filesystem — not a mountable disk; if it is a memory image use /dfir-memory-volatility; skipped" )
                fi ;;
        esac
    done

    if [[ ${#IMAGES[@]} -eq 0 ]]; then
        NOTES+=( "[$ASSET] no mountable disk image found — skipped" )
        continue
    fi

    for entry in "${IMAGES[@]}"; do
        TYPE="${entry%%|*}"
        IMG="${entry#*|}"
        IMG_NAME="$(basename "$IMG")"

        # Image-derived directory stem, disambiguated if two images share it.
        BASE_STEM="$(imgbase "$IMG")"
        if [[ -n "${SEEN_BASE[$BASE_STEM]:-}" ]]; then
            SEEN_BASE[$BASE_STEM]=$(( SEEN_BASE[$BASE_STEM] + 1 ))
            BASE_STEM="${BASE_STEM}-${SEEN_BASE[$BASE_STEM]}"
        else
            SEEN_BASE[$BASE_STEM]=1
        fi

        # Resolve the disk path used for discovery (DISC) and for the eventual mount (MDISK).
        EWF_DIR=""
        if [[ "$TYPE" == ewf ]]; then
            EWF_DIR="$ASSET_DIR/e01-$BASE_STEM"
            # Discovery is sudo-free: ensure a user ewfmount exists (created if missing), read ewf1.
            if [[ ! -e "$EWF_DIR/ewf1" ]]; then
                mkdir -p "$EWF_DIR"
                ewfmount "$IMG" "$EWF_DIR/" 2>>"$LOG" || true   # AS THE USER, never sudo
            fi
            DISC="$EWF_DIR/ewf1"
            MDISK="$EWF_DIR/ewf1"
            if [[ ! -e "$DISC" ]]; then
                NOTES+=( "[$ASSET] $IMG_NAME — ewfmount (as user) did not expose ewf1; cannot discover; skipped" )
                continue
            fi
        else
            DISC="$IMG"
            MDISK="$IMG"
        fi

        # Candidate partitions: every allocated partition, or the whole volume (@0) if no table.
        SS="$(sector_size "$DISC")"
        mapfile -t STARTS < <(partition_starts "$DISC")
        if [[ ${#STARTS[@]} -eq 0 ]]; then
            STARTS=( 0 )   # whole-volume image (no partition table)
        fi

        k=1                 # mounted-partition counter for THIS image -> mnt-NNN-<imgbase>
        img_prep_done=0
        for SEC in "${STARTS[@]}"; do
            # Filesystem type decides the mount driver (and whether to mount at all).
            FST="$(fs_type "$DISC" "$SEC")"
            FSL="${FST,,}"
            case "$FSL" in
                ntfs)                  mtype="ntfs-3g"; extra=",streams_interface=windows" ;;
                fat12|fat16|fat32|fat) mtype="vfat";    extra="" ;;
                exfat)                 mtype="exfat";   extra="" ;;
                "")
                    NOTES+=( "[$ASSET] $IMG_NAME @sector ${SEC} — fsstat found no filesystem (unallocated/unsupported); skipped" )
                    continue ;;
                *)
                    NOTES+=( "[$ASSET] $IMG_NAME @sector ${SEC} — filesystem '${FST}' not auto-mounted (ReFS/Linux/other); mount manually if needed; skipped" )
                    continue ;;
            esac

            if is_windows_volume "$DISC" "$SEC"; then
                role="${FST} — holds \\Windows"
            else
                role="${FST} data volume"
            fi

            # mmls prints zero-padded start sectors (e.g. 0000002048); force base-10 so
            # bash does not parse the leading zeros as octal (0000002048 -> octal error).
            OFF=$(( 10#$SEC * 10#$SS ))
            MNT="$ASSET_DIR/mnt-$(printf '%03d' "$k")-${BASE_STEM}"
            if mountpoint -q "$MNT"; then
                NOTES+=( "[$ASSET] $(basename "$MNT") already mounted — no command emitted" )
                ANY=1
                k=$(( k + 1 ))
                continue
            fi
            mkdir -p "$MNT"                                   # user-owned mount point (no root)

            # Each command is split ONE ARGUMENT PER LINE, joined with a trailing ` \`
            # (continuation lines indented two spaces). Short physical lines do not
            # soft-wrap in any reasonably-sized terminal, so copying them out of chat
            # introduces no stray hard newline, and the explicit ` \` makes bash join the
            # lines back into one command. `-X allow_other` is kept whole on its own line
            # (separating it was the original break). The only line that can still exceed a
            # very narrow terminal is the `-o <options>` token — for that edge, and as the
            # always-correct path, the same commands are also written to ./mount-readonly.sh.

            # EWF: emit the root ewfmount once per image, just before its first volume mount.
            if [[ "$TYPE" == ewf && "$img_prep_done" -eq 0 ]]; then
                CMDS+=( "# [$ASSET] EWF image $IMG_NAME — expose it as a raw disk for root (no /etc/fuse.conf change):" )
                CMDS+=( "sudo fusermount -u \\" )
                CMDS+=( "  '${EWF_DIR}' 2>/dev/null" )
                CMDS+=( "sudo ewfmount \\" )
                CMDS+=( "  -X allow_other \\" )
                CMDS+=( "  '${IMG}' \\" )
                CMDS+=( "  '${EWF_DIR}/'" )
                img_prep_done=1
            fi

            base="ro,loop,noatime,offset=${OFF},uid=${RUID},gid=${RGID},fmask=0133,dmask=0022"
            CMDS+=( "# [$ASSET] $IMG_NAME ${role} — sector ${SEC}, byte offset ${OFF} -> $(basename "$MNT")" )
            CMDS+=( "sudo mount \\" )
            CMDS+=( "  -t ${mtype} \\" )
            CMDS+=( "  -o ${base}${extra} \\" )
            CMDS+=( "  '${MDISK}' \\" )
            CMDS+=( "  '${MNT}'" )
            if [[ "$mtype" == ntfs-3g ]]; then
                CMDS+=( "#   if ntfs-3g errors: unmount, then run the kernel-driver version (remove the leading # on each line):" )
                CMDS+=( "# sudo mount \\" )
                CMDS+=( "#   -t ntfs3 \\" )
                CMDS+=( "#   -o ${base} \\" )
                CMDS+=( "#   '${MDISK}' \\" )
                CMDS+=( "#   '${MNT}'" )
            elif [[ "$mtype" == exfat ]]; then
                CMDS+=( "#   if mount reports 'unknown filesystem type exfat', install the driver:" )
                CMDS+=( "#   sudo apt-get install exfat-fuse exfatprogs   (then re-run the mount above)" )
            fi
            CMDS+=( "" )
            ANY=1
            k=$(( k + 1 ))
        done
    done
done

# Diagnostics first (what was skipped and why, plus guidance).
for n in "${NOTES[@]}"; do echo "$n"; done

if [[ "$ANY" -eq 0 ]]; then
    echo "ERROR: no mountable filesystem identified in any asset — nothing to mount." >&2
    exit 1
fi

# Record the emitted commands for the audit trail (user-level append to ./audit).
{
    printf '[%s] gen_mount_commands.sh emitted the following (uid=%s gid=%s):\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUID" "$RGID"
    for c in "${CMDS[@]}"; do printf '  %s\n' "$c"; done
} >> "$LOG"

# Write a COPY-SAFE runnable script. The mount lines are long; relaying them through
# chat and pasting them lets the renderer inject hard newlines at wrap points (e.g.
# splitting `-X` from its `allow_other` argument), which breaks the command. Running a
# generated script sidesteps copy-paste entirely. The script is plain text the operator
# reviews (cat it) before running — nothing is hidden; uid/gid are baked in at generation
# so `sudo bash` still maps the mount to this user. Case root is not an evidence path, so
# the evidence guard permits this write.
RUN="$CASE_ROOT/mount-readonly.sh"
{
    printf '#!/usr/bin/env bash\n'
    printf '# sift-assistant — generated READ-ONLY mount commands. REVIEW, then run:\n'
    printf '#     sudo bash %s\n' "$RUN"
    printf '# Generated %s (uid=%s gid=%s). Every mount is ro — nothing here touches the evidence.\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUID" "$RGID"
    printf '# NTFS volumes print a commented ntfs3 fallback below their mount — uncomment if ntfs-3g errors.\n\n'
    for c in "${CMDS[@]}"; do printf '%s\n' "$c"; done
} > "$RUN"
chmod +x "$RUN" 2>/dev/null || true

echo
echo "The mount commands are long and break if pasted from chat. Two ways to run them, in a SEPARATE terminal:"
echo
echo "  RECOMMENDED (copy-safe) — review then run the generated script:"
echo "      cat '$RUN'          # review every command first"
echo "      sudo bash '$RUN'    # all read-only mounts"
echo
echo "  OR paste the literal lines below (only if your terminal does not wrap them):"
echo
for c in "${CMDS[@]}"; do echo "$c"; done
echo
echo "After they succeed, return here — /tools-mount Step 5 verifies readability (no sudo needed)."
