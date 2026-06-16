# Skill: tools-mount-vss — Access Volume Shadow Copies (VSS) on Linux

> **Tool paths:** `source ~/.claude/tools.env` before running these commands. `vshadowmount` and
> `vshadowinfo` (libvshadow) are PATH-resolved tools verified by `/tools-preflight` — invoke them by name,
> never hardcode a path.

## Overview

Windows Volume Shadow Copies (VSS) contain historical snapshots of the filesystem — invaluable for
recovering deleted files and earlier states (cleared event logs, deleted persistence keys, staged data
that survives only in an older snapshot). On SIFT (Linux), VSCMount is not available (Windows-only); use
`vshadowmount` (libvshadow) instead.

**This skill owns the VSS logic.** `/tools-mount` auto-invokes it (Step 6) after the live volumes are
mounted and verified — no separate manual step is needed for the normal pipeline. The two entry points:

- **Automatic** — `/tools-mount` runs `gen_vss_commands.sh` for every mounted NTFS volume (below).
- **Manual** — the recipes here, for targeted single-snapshot access or for an image you mounted by hand.

**Work over the already-mounted volume, not the raw image.** A live `mnt-NNN-<imgbase>` mount is backed
by a loop device (`mount -o loop,offset=…`); reuse *that* device as the `vshadowmount` source. No fresh
`losetup` at an offset, no re-reading `ewf1`.

**Tools:**
- `vshadowmount`: expose a volume's shadow copies as `vss1…vssN` files (libvshadow, system PATH)
- `vshadowinfo`: list/inspect shadow copies (presence + count) without mounting (libvshadow, system PATH)

---

## Case Path Convention

| Path | Purpose |
|------|---------|
| `./sources/<asset_id>/mnt-<NNN>-<imgbase>/` | Live NTFS mount (current state) — its loop device is the VSS source |
| `./sources/<asset_id>/vss-<NNN>-<imgbase>/` | `vshadowmount` FUSE point for that volume — exposes `vss1…vssN` |
| `./sources/<asset_id>/mnt-<NNN>-vss-<MMM>-<imgbase>/` | Individual VSS snapshot, loop-mounted read-only (`MMM` = `vssN` index) |

`NNN` matches the live volume's partition number; `MMM` is the shadow-copy store index (`vss1` = oldest).

---

## Automatic path — `gen_vss_commands.sh` (invoked by `/tools-mount` Step 6)

```bash
bash ~/.claude/skills/tools-mount-vss/gen_vss_commands.sh
```

Run from the case root **as the user** (never sudo). It does the sudo-free work and emits the one sudo
script:

- Enumerates every mounted NTFS volume under `sources/*/` (`findmnt -n -o FSTYPE <mnt>` →
  `fuseblk`/`ntfs3`/`ntfs`), skipping snapshot mounts (`mnt-*-vss-*`), `e01-*` and `vss-*` dirs.
- Resolves each one's backing device with `findmnt -n -o SOURCE <mnt>` (must be `/dev/loop*`; a non-loop
  source is noted and skipped — never re-read the raw image).
- Creates the user-owned `vss-<NNN>-<imgbase>` FUSE point and writes `./mount-vss-readonly.sh`.
- Emits **one self-discovering block per volume** (the snapshot count isn't known until `vshadowmount`
  runs, and the loop device is root-owned so detection needs root): `sudo vshadowmount -X allow_other
  /dev/loopN vss-<NNN>-<imgbase>/`, then a `for snap in …/vss*` loop that loop-mounts each store read-only
  as `mnt-<NNN>-vss-<MMM>-<imgbase>`. A volume with no shadow copies is a clean no-op.

The operator **runs the script** (it is shell logic, not a flat command list), as for the live mounts —
sudo can't prompt through Claude Code (no PTY):

```bash
cat /cases/<CASE_ID>/mount-vss-readonly.sh        # review every command first
sudo bash /cases/<CASE_ID>/mount-vss-readonly.sh  # expose + mount all shadow copies (read-only)
```

Every mount is `ro`; the emitted commands are also appended to `./audit/mount.log`.

---

## Manual path — targeted access over the already-mounted volume

### Detect first (sudo-free is not possible on a root-owned loop device — this needs sudo)

The live volume's loop device is owned by root, so probe it with sudo:

```bash
ASSET="<asset_id>"
SRC="./sources/$ASSET"
MNT="$SRC/mnt-001-<imgbase>"

LOOP="$(findmnt -n -o SOURCE "$MNT")"   # e.g. /dev/loop5 — sudo-free
sudo vshadowinfo "$LOOP"                 # presence + "Number of stores:" count (no mount)
```

### Expose + mount a snapshot

```bash
# Reuse the live volume's loop device — no losetup, no offset (the loop already starts at the volume).
mkdir -p "$SRC/vss-001-<imgbase>"
sudo vshadowmount -X allow_other "$LOOP" "$SRC/vss-001-<imgbase>/"

ls "$SRC/vss-001-<imgbase>/"             # vss1  vss2  vss3 …  (vss1 = oldest)

# Mount one snapshot (a vssN is a whole volume — NO offset=).
mkdir -p "$SRC/mnt-001-vss-001-<imgbase>"
sudo mount -t ntfs-3g -o ro,loop,noatime,streams_interface=windows \
  "$SRC/vss-001-<imgbase>/vss1" "$SRC/mnt-001-vss-001-<imgbase>/"

ls "$SRC/mnt-001-vss-001-<imgbase>/Windows/"
```

> **Unmounted image?** If the volume isn't mounted (so there is no loop device to reuse), fall back to a
> fresh loop at the partition byte offset: `LOOP=$(sudo losetup -f --show -o <OFFSET_BYTES> "$SRC/e01-<imgbase>/ewf1")`
> (offset from `/tools-mount-ntfs`), then `sudo vshadowmount "$LOOP" …` as above; detach with
> `sudo losetup -d "$LOOP"` during teardown.

### Unmount (snapshot → FUSE point → release the loop)

```bash
sudo umount "$SRC/mnt-001-vss-001-<imgbase>/"
sudo umount "$SRC/vss-001-<imgbase>/" 2>/dev/null || sudo fusermount -u "$SRC/vss-001-<imgbase>/"
rmdir "$SRC/mnt-001-vss-001-<imgbase>/" "$SRC/vss-001-<imgbase>/"
# Only if you created a fresh losetup (unmounted-image fallback): sudo losetup -d "$LOOP"
```

The VSS snapshot mounts and the `vss-*` FUSE point must come down **before** the live volume is unmounted,
because `vshadowmount` holds the live volume's loop device open. `/tools-mount --unmount` (Step 8) already
tears down in this order.

---

## DFIR Value of VSS

| Artifact | Why check VSS |
|----------|--------------|
| Event logs | Attacker may have cleared live logs; VSS may retain older copies |
| Registry hives | Recover persistence keys deleted before capture |
| Prefetch files | Deleted executables may appear in earlier snapshots |
| MFT | Recover $MFT entries for deleted files |
| User files | Staged/exfiltrated data recovered from earlier snapshot |

---

## Notes

- VSS snapshots are indexed oldest-first in vshadowmount (`vss1` = oldest).
- A `vssN` store is a whole volume — loop-mount it with **no** `offset=` (unlike the live disk image).
- Not all Windows Server editions enable VSS by default — `vshadowinfo` reports zero stores when absent;
  this is a clean no-op, never a case-halting failure.
- VSS stores are only available if the image includes the full partition (not just exported files).
- Do not pass the loop device or a `vssN` file to Plaso — use the mounted filesystem path instead.
