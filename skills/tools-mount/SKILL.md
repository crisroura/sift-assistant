# Skill: tools-mount — Mount Orchestrator (authenticate once → validate → mount all → guarantee readable)

## Overview

Single entry point for making every disk image in a case readable. Replaces the mount block that was
inlined in `case-investigate` and the manual two-step dance of `/tools-mount-e01` + `/tools-mount-ntfs`.

Handles **every disk image of every asset** — EWF (`.E01`/`.Ex01`) and raw (`.dd`/`.img`/`.raw`), and an
asset may have several. One clean abstraction:

> **validate sources → detect each image's type (EWF vs raw) → enumerate every filesystem volume and
> detect its type (as the user, no mount) → print the exact sudo commands for the operator to run →
> guarantee the current user can read every mount → verify by actually reading → auto-mount the VSS
> shadow copies of every NTFS volume (delegated to `/tools-mount-vss`).**

Mount-point names use a `mnt-NNN` counter prefix with the **image-derived** stem trailing, all
hyphen-separated: an EWF `base-dc-cdrive.E01` ewfmounts under `e01-base-dc-cdrive` and its volume
mounts as `mnt-001-base-dc-cdrive`; a raw `base-dc-disk.dd` with two partitions mounts as
`mnt-001-base-dc-disk`, `mnt-002-base-dc-disk`. **Every** recognized filesystem
partition is mounted — NTFS, FAT12/16/32 and exFAT — not only the `\Windows` OS volume; the parse phase
later analyzes just the Windows volumes, the rest are mounted for manual review.

**Run everything that does not need sudo autonomously, as the user** — including reading each partition's
filesystem type with The Sleuth Kit (`mmls`/`fsstat`, no mount, no root) and spotting which volume holds
`\Windows` (`fls`), and creating the mount-point dirs. **Only the genuinely-privileged commands go to the
operator's terminal** — because sudo cannot prompt for a password through Claude Code's Bash tool or the
`!` prefix (neither allocates a PTY). They are delivered two ways: written verbatim into a reviewable
runnable script (`./mount-readonly.sh` — every option visible, the operator `cat`s it before running, so
nothing is hidden) and also printed as commands the operator can paste:

- **raw image** → `sudo mount` with `-t <fs>`, `-o ro,loop,offset=…`, the image and the mount point
- **EWF image** → `sudo ewfmount -X allow_other '<image>.E01' 'e01-<imgbase>/'` then `sudo mount … '<ewf1>'`

Each printed command is **split one argument per line, joined with a trailing ` \`** (e.g. `sudo mount \`
/ `  -t ntfs-3g \` / `  -o … \` / `  '<disk>' \` / `  '<mnt>'`). Short physical lines don't soft-wrap, so
copying them out of chat injects no stray hard newline and the explicit ` \` rejoins them into one
command — pasteable at any terminal width. `-X allow_other` is kept whole on one line (splitting it was
the original break). The **guaranteed** path, if even a per-argument line is too long for a very narrow
terminal (the `-o <options>` token), is `sudo bash ./mount-readonly.sh` — the same commands, no paste.
When you relay the printed commands, put them verbatim inside a fenced code block.

The low-level skills `/tools-mount-e01` (ewfmount detail) and `/tools-mount-ntfs` (offset/loop detail)
remain as references this orchestrator cites; use them when you need to debug a single step.

**Volume Shadow Copies (VSS).** Once the live volumes are mounted and verified (Step 5), the orchestrator
automatically delegates to `/tools-mount-vss` (Step 6) to expose and loop-mount every shadow copy of each
NTFS volume — **no separate manual invocation**. That skill works over the *already-mounted* volume,
reusing its loop device for `vshadowmount` (it never re-reads the raw image). VSS is best-effort
enrichment: a volume with no shadow copies is a no-op and **never halts** the case.

> **Step 6 is unconditional — never short-circuit before it.** Every `/tools-mount` run (except
> `--unmount`) ends at Step 6, *including a rerun where the live volumes were already mounted and Step 4
> emitted no sudo commands.* "All disk images already mounted, no sudo needed" describes the **live**
> volumes only — it says nothing about VSS, which still has to be checked. Do **not** stop at Step 5 or
> declare the case "ready for `/case-parse`" until Step 6 has run and the status summary reports VSS state
> (snapshots mounted, or "no shadow copies found") for every NTFS volume.

**Flags:** `/tools-mount` (mount all) · `/tools-mount --unmount` (clean teardown).

**Source tool paths first:**
```bash
source ~/.claude/tools.env
```

---

## Guardrails (non-negotiable)

- **Read-only always.** Every mount uses `ro`. Never drop it.
- **Do what you can without sudo; hand only sudo to the operator.** Validation, all `mmls`/`fls`/`fsstat`
  discovery, ewfmount-for-discovery (as the user), and `mkdir` of the `mnt-NNN-<imgbase>` volume dirs are run
  autonomously. The only commands the operator runs in a separate terminal are the sudo lines — raw: one
  `sudo mount`; EWF: `sudo ewfmount -X allow_other` then `sudo mount`.
- **No `/etc/fuse.conf` edits.** For EWF, root must read the FUSE `ewf1`; the way that needs no fuse.conf
  change is to run ewfmount **as root**: `sudo ewfmount -X allow_other` (when root mounts, `allow_other`
  is permitted with no fuse.conf change, and it keeps `ewf1` readable by the user too). This is the
  **standard** EWF prep, not a fallback. Never plain `sudo ewfmount` (no `-X`) — that leaves `ewf1`
  root-only. Raw images need no ewfmount at all — they loop-mount directly.
- **Never write to evidence.** Nothing modifies the image. The skill writes nothing privileged: it
  ewfmounts EWF images **as the user** for discovery, creates the user-owned mount-point dirs under
  `sources/<asset_id>/`, writes the reviewable `./mount-readonly.sh` at the case root (not an evidence
  path), and appends the emitted commands to `./audit/mount.log`. The actual mounting is the operator's
  `sudo` step.
- **Never write to `/mnt` or `/media`.**

---

## Case Path Convention

| Path | Purpose |
|------|---------|
| `./sources/<asset_id>/<image>.E01` | EWF evidence (read-only, never modified) |
| `./sources/<asset_id>/<image>.dd` | Raw-image evidence — loop-mounted directly, no ewfmount |
| `./sources/<asset_id>/e01-<imgbase>/ewf1` | EWF only: raw disk from ewfmount — **one per EWF image**, named from the image (`base-dc-cdrive.E01` → `e01-base-dc-cdrive`) |
| `./sources/<asset_id>/mnt-<NNN>-<imgbase>/` … | Each filesystem volume mount point (loop, read-only), named with a per-image partition number then the image stem (`mnt-001-base-dc-cdrive`, `mnt-002-base-dc-disk`); **always numbered**, every recognized FS (NTFS/FAT/exFAT) |
| `./sources/<asset_id>/vss-<NNN>-<imgbase>/` | `vshadowmount` FUSE point for the NTFS volume `mnt-<NNN>-<imgbase>` — exposes its shadow copies as `vss1…vssN` (Step 6) |
| `./sources/<asset_id>/mnt-<NNN>-vss-<MMM>-<imgbase>/` | Each VSS snapshot, loop-mounted read-only (`MMM` = the `vssN` store index) |
| `./mount-readonly.sh` | Generated runnable script of every read-only sudo mount command — the copy-safe way for the operator to run them (`sudo bash ./mount-readonly.sh`); reviewable plain text, regenerated each run |
| `./mount-vss-readonly.sh` | Generated runnable script of the VSS mount commands (Step 6) — `sudo bash ./mount-vss-readonly.sh`; reviewable plain text, regenerated each run |
| `~/.claude/skills/tools-mount/gen_mount_commands.sh` | Shipped helper (runs **as the user**; detects image type, identifies Windows volumes, writes `mount-readonly.sh` and prints the sudo commands) |
| `~/.claude/skills/tools-mount-vss/gen_vss_commands.sh` | Shipped helper (runs **as the user**; reuses each live NTFS volume's loop device, writes `mount-vss-readonly.sh`) |
| `./audit/mount.log` | Audit log — the emitted commands (live mounts **and** VSS) are appended here when the helpers run |

---

## Step 1 — Validate sources (readable, > 0 bytes, is a disk image)

For every asset in `context/case_context.md`, confirm each disk image in `sources/<asset_id>/` is
present, readable, non-empty, and actually a **disk** image. Detect type by **content**, never the
extension (`case-scan-sources` even files `.img`/`.raw` under *memory*). The helper does this itself, but
inspect here to report:

```bash
for ASSET in <asset_ids>; do
  SRC="./sources/$ASSET"
  for IMG in "$SRC"/*; do
    [[ -f "$IMG" ]] || continue
    [[ -r "$IMG" ]] || { echo "[$ASSET] NOT READABLE: $IMG"; continue; }
    [[ -s "$IMG" ]] || { echo "[$ASSET] ZERO BYTES: $IMG"; continue; }
    FB=$(file -b "$IMG")
    case "$FB" in
      *EWF*|*"Expert Witness"*) echo "[$ASSET] EWF disk: $(basename "$IMG")" ;;
      *)
        if mmls "$IMG" >/dev/null 2>&1 || [[ "$(head -c7 "$IMG" | xxd -p)" == eb52904e544653 ]]; then
          echo "[$ASSET] raw disk: $(basename "$IMG")"
        else
          echo "[$ASSET] not a disk (memory/container/other): $(basename "$IMG") — $FB"
        fi ;;
    esac
  done
done
```

**Exclude** non-disk files (memory → `/dfir-memory-volatility`; VMDK/VHD → `qemu-nbd`) and any
unreadable/zero-byte image from the mount batch. Optional EWF integrity check (see `/tools-mount-e01`):
`ewfverify "$SRC/"*.E01`.

---

## Step 2 — ewfmount for discovery (EWF images only; raw images skip this)

`gen_mount_commands.sh` (Step 4) does this itself — but the mechanics: **raw images need no ewfmount**
(TSK reads the `.dd` directly; loop-mount reads it directly). For each **EWF** image, a user-level
ewfmount exposes a raw `ewf1` so discovery can read it (one `e01-<imgbase>/` per EWF image):

```bash
SRC="./sources/$ASSET"
mkdir -p "$SRC/e01-base-dc-cdrive"                          # e01-<image filename minus extension>
ewfmount "$SRC/base-dc-cdrive.E01" "$SRC/e01-base-dc-cdrive/"   # NO sudo — discovery; keeps ewf1 user-owned
```

If a mount point is stale (`Transport endpoint is not connected`): `fusermount -u "$SRC/e01-base-dc-cdrive/"`
then retry.

> This user-level ewfmount is **for discovery only**. Root usually can't read a user FUSE mount, so the
> *actual* EWF mount in Step 4 is done with **`sudo ewfmount -X allow_other`** (root-mount; no
> `/etc/fuse.conf` change needed) which the helper emits ahead of the `sudo mount`. Raw images get a
> direct `sudo mount` with no ewfmount.

---

## Step 3 — Partition discovery (every filesystem volume, with its type)

The helper enumerates partitions itself, but inspect here so you can report them. The **disk** is the
`ewf1` for an EWF image, or the **raw image file itself** for a `.dd`:

```bash
DISK="./sources/$ASSET/e01-base-dc-cdrive/ewf1"   # EWF; or DISK="./sources/$ASSET/<image>.dd" for raw
mmls "$DISK"                                       # list every partition
fsstat -o <start_sector> "$DISK" | grep -i 'File System Type'   # type of each partition
```

- The helper enumerates **every** allocated partition (not just the first, not just NTFS), reads each
  one's filesystem type with `fsstat`, and mounts every recognized filesystem — **NTFS** (`-t ntfs-3g`,
  with a commented `ntfs3` fallback), **FAT12/16/32** (`-t vfat`) and **exFAT** (`-t exfat`). Each mounted
  partition becomes `mnt-NNN-<imgbase>` (`NNN` per partition of that image, always numbered). It also runs
  `fls` to note which volume holds `\Windows` (annotated in the emitted comment); partitions with no
  recognized filesystem (unallocated, ReFS, Linux, …) are detected, logged, and skipped.
- Offset of a partition = its start sector × sector size (512 unless the `mmls` header says otherwise).
- **No partition table** (`mmls` empty): the image is a whole volume — the helper probes the filesystem
  at offset 0 with `fsstat`. To eyeball an NTFS whole volume, check the VBR signature with `head`, not
  `dd` (`dd` is denied for evidence safety):
  ```bash
  head -c7 "$DISK" | xxd -p                               # expect: eb52904e544653 (NTFS)
  fsstat -o 0 "$DISK" | grep -i 'File System Type'        # confirms the filesystem at 0
  ```

---

## Step 4 — Emit the sudo commands, then have the operator run them

The privileged steps **cannot** run via the AI's Bash tool or `!` in the Claude Code prompt — neither
allocates a PTY, so sudo can't prompt for a password. So the skill does everything else as the user, then
hands the operator the sudo step **two ways**: as a **generated runnable script** (`./mount-readonly.sh`
at the case root — the copy-safe path) and as the **literal printed lines** (for review). The script
exists because the mount commands are long: relaying them through chat and pasting them lets the renderer
inject hard newlines at wrap points (e.g. splitting `-X` from its `allow_other` argument), breaking the
command. Running the script avoids any long-line paste; the script is plain text the operator reads first,
so nothing is hidden.

**4a — Produce the commands (as the user, autonomous).**

```bash
bash ~/.claude/skills/tools-mount/gen_mount_commands.sh
```

The helper iterates every `sources/<asset>/` directory and **every distinct disk image in it** (an asset
may have several; split-image segments like `.E02`/`.002` collapse into their first segment). It detects
each image's type by content, enumerates every partition with `mmls` (whole-volume images fall back to
`fsstat` at offset 0), reads each partition's filesystem type with `fsstat` to pick the mount driver,
notes the Windows volume with `fls` (a `\Windows` dir at the root — no mount, no root), creates the
user-owned `mnt-<NNN>-<imgbase>` mount points (numbered per partition, image stem trailing), writes the
runnable `./mount-readonly.sh`, and prints (`<fs>` = `ntfs-3g`, `vfat`, or `exfat` per the detected
filesystem):

Each command is **split one argument per line, joined with a trailing ` \`** (continuation lines indented
two spaces):

- **raw image** — a direct mount:
  ```
  sudo mount \
    -t <fs> \
    -o ro,loop,noatime,offset=<bytes>,uid=<uid>,gid=<gid>,fmask=0133,dmask=0022[,streams_interface=windows] \
    '<image>.dd' \
    'mnt-<NNN>-<imgbase>'
  ```
- **EWF image** — the root ewfmount (no `/etc/fuse.conf` change needed) then the mount:
  ```
  sudo fusermount -u \
    'e01-<imgbase>' 2>/dev/null
  sudo ewfmount \
    -X allow_other \
    '<image>.E01' \
    'e01-<imgbase>/'
  sudo mount \
    -t <fs> \
    -o ro,loop,noatime,offset=<bytes>,uid=<uid>,gid=<gid>,fmask=0133,dmask=0022[,streams_interface=windows] \
    'e01-<imgbase>/ewf1' \
    'mnt-<NNN>-<imgbase>'
  ```

`streams_interface=windows` is added for NTFS only (to reach ADS/UsnJrnl); FAT/exFAT mounts omit it. Short
per-argument lines don't soft-wrap, so they survive copy-paste at any terminal width, and `-X allow_other`
stays whole on one line (splitting it was the original break). The **same** commands are written verbatim
into `./mount-readonly.sh` for the no-paste path. A commented `ntfs3` fallback (same per-argument form,
each line `#`-prefixed — remove the `#`s to use) is printed below each NTFS mount. Containers (VMDK/VHD →
`qemu-nbd`) and memory images (`/dfir-memory-volatility`) are reported and skipped, not mounted. The
emitted commands are appended to `./audit/mount.log`.

**4b — Operator runs them in a separate terminal.** Tell the operator to open an **external terminal**
(Ctrl+Alt+T or any terminal outside Claude Code). Two equivalent ways (`ro` mounts — nothing touches the
evidence):

1. **Paste the printed commands** — relay them **verbatim inside a fenced code block, never reflowed or
   re-indented**. The per-argument ` \` form pastes correctly at any normal terminal width.
2. **Run the generated script** (the guaranteed fallback — no paste at all):
   ```bash
   cat /cases/<CASE_ID>/mount-readonly.sh        # review every command first
   sudo bash /cases/<CASE_ID>/mount-readonly.sh  # run all read-only mounts
   ```

Ask them to paste the terminal output back. If every command succeeded (no output is success for
`mount`), proceed to Step 5. **If any command errored, do not give up — go to Step 4c.**

**4c — If a mount command errors, diagnose and hand back a corrected command.** Ask the operator to
paste the **exact error text** (and the command they ran). Match it against the table below, explain the
cause in one line, and emit a **single corrected command** for them to run. Re-check the result; if it
still fails, fall back once more per the table, then (if still stuck) record the failure in
`./audit/artifact_failures.log` and surface it in Step 7 — never invent output or loop indefinitely.

| Error text (substring) | Cause | Corrected command / action |
|---|---|---|
| `bad usage` / a path or option printed as its own command + `Permission denied` on the `ewf1` path | A command broke on paste — a line wrapped (e.g. the long `-o <options>` token on a narrow terminal) and the ` \` no longer sat at end-of-line | Use the **no-paste path**: `sudo bash /cases/<CASE_ID>/mount-readonly.sh` (the helper writes every command there). Or widen the terminal and re-paste the per-argument block verbatim, keeping each trailing ` \` at the very end of its line |
| `Permission denied` *from mount itself* opening `ewf1`, **or** `failed to setup loop device` (EWF) | The EWF `ewf1` was exposed as a **user** FUSE mount that root can't read (the `sudo ewfmount -X allow_other` prep line was skipped, or plain `sudo ewfmount`/user `ewfmount` was run instead) | Run the **prep line** first: `sudo fusermount -u 'e01-<imgbase>' 2>/dev/null; sudo ewfmount -X allow_other '<image>.E01' 'e01-<imgbase>/'` then re-run the `sudo mount`. Root-run `allow_other` needs **no** `/etc/fuse.conf` edit and keeps `ewf1` user-readable. Never plain `sudo ewfmount` (no `-X`) — leaves `ewf1` root-only |
| `unclean file system` / `unsafe state` / `Windows is hibernated` / `dirty` | ntfs-3g refuses a hibernated/dirty volume | Add `force` to the ntfs-3g options: `sudo mount -t ntfs-3g -o ro,loop,noatime,offset=<bytes>,uid=<uid>,gid=<gid>,fmask=0133,dmask=0022,streams_interface=windows,force '<ewf1>' '<mnt>'` (still `ro`) — or use the `ntfs3` fallback line |
| `unknown filesystem type 'ntfs3'` | Kernel `ntfs3` driver absent (older kernel) | Use the **ntfs-3g** command instead (the primary line) |
| `unknown filesystem type 'exfat'` (exFAT volume) | exFAT driver not installed | `sudo apt-get install exfat-fuse exfatprogs`, then re-run the `sudo mount -t exfat …` line (still `ro`) |
| `wrong fs type` on a `-t vfat` mount, or a FAT volume won't mount | FAT12/16/32 driver/offset mismatch | Confirm the type with `fsstat -o <sector> '<disk>'`; `vfat` covers FAT12/16/32. Re-confirm the byte offset (sector × sector-size) and re-run with `-t vfat` (no `streams_interface`) |
| `wrong fs type` / `bad superblock` / `NTFS signature is missing` / `Invalid argument` | Wrong offset, or volume isn't NTFS | Re-confirm the offset with `mmls '<ewf1>'` / `fsstat -o <sector> '<ewf1>'`; rebuild the command with the corrected byte offset (sector × sector-size). If not NTFS, it isn't a Windows volume — skip it |
| `could not find any free loop device` / `cannot allocate memory` (and `losetup -a` shows loops exhausted) | Loop module not loaded or all loop devices in use — only if it is genuinely *not* the FUSE cause above | `sudo modprobe loop` (load it), then retry; free a stale loop with `sudo losetup -d /dev/loopN` (check `losetup -a` first) |
| `mount point does not exist` | The `mnt-NNN-<imgbase>` volume dir is missing (wrong cwd) | `mkdir -p '<mnt>'` then retry — or re-run the helper from the case root so it creates the dir |
| `already mounted` / `exclusively opened` | That volume is already mounted | Already done — verify with Step 5; to remount, unmount first (Step 8) |
| `only root can use` / `operation not permitted` | `sudo` was dropped | Re-run the command **with** `sudo` |
| `fuse: device not found` / `modprobe fuse` | FUSE module not loaded (blocks ewfmount) | `sudo modprobe fuse`, then re-run ewfmount (Step 2) and the mount |
| raw mount of a `.001`/`.002` split image fails / only part of the disk visible | `mount -o loop` reads only the first segment of a split raw image | Reassemble first: `affuse '<image>.001' /mnt/affuse_pt` (or `cat *.0?? > whole.dd`) and point the `sudo mount` at the reassembled raw device; then re-run the helper |
| container image (`.vmdk`/`.vhd`/`.vhdx`/`.qcow2`) won't loop-mount | These are not raw — `mount -o loop` can't read them | Expose a raw device first with `qemu-nbd` (`sudo modprobe nbd; sudo qemu-nbd -r -c /dev/nbd0 '<image>.vmdk'`), then mount `/dev/nbd0pN` read-only (see `/tools-mount-ntfs`); `sudo qemu-nbd -d /dev/nbd0` to detach |

For an error not in the table: read the stderr, identify the cause, and propose one corrected command —
do not guess blindly or retry the same command unchanged. Keep the read-only guarantee in every
correction (`ro` is never dropped).

---

## Step 5 — Guarantee readability (mount options, not chmod) and verify

On NTFS, file permissions come from the **driver + mount options**, so `chmod` on the mount is inert.
Readability is guaranteed by the `uid/gid/fmask/dmask` options above. The assistant only needs to
**verify** (reads need no sudo). For each asset:

```bash
for MNT in ./sources/$ASSET/*/; do
  MNT="${MNT%/}"
  [ -d "$MNT" ] || continue
  case "$(basename "$MNT")" in e01-*) continue ;; esac   # skip ewfmount FUSE dirs
  if mountpoint -q "$MNT" && ls -A "$MNT" >/dev/null 2>&1; then
    echo "[$ASSET] $(basename "$MNT") readable OK"
  else
    echo "[$ASSET] $(basename "$MNT") NOT readable — remount with the other driver"
  fi
done
```

(For an NTFS Windows volume, a stronger check reads a known file:
`head -c1 "$MNT/Windows/System32/config/SYSTEM"`; FAT/exFAT data volumes have no such path,
so a `mountpoint` + `ls -A` test is the general readability check.)

If the read test fails (or `ntfs-3g` errored at mount time), have the operator unmount the bad attempt
(Step 8) and run the **`ntfs3` fallback line** that `gen_mount_commands.sh` printed for that volume:

```bash
sudo mount -t ntfs3 -o ro,loop,noatime,offset=<bytes>,uid=<your-uid>,gid=<your-gid>,fmask=0133,dmask=0022 '<ewf1>' '<part_mnt>'
```

Then re-run the read test above.

**Once every NTFS volume reads OK, continue to Step 6 — do not stop here.** A verified-readable live
volume is the *precondition* for VSS, not the end of the run.

---

## Step 6 — Auto-mount VSS (delegated to `/tools-mount-vss`)

Once the live NTFS volumes are mounted and verified (Step 5), expose and mount their Volume Shadow
Copies automatically — no separate manual invocation. This is **delegated** to `/tools-mount-vss`, which
works over the *already-mounted* volume: each live `mnt-NNN-<imgbase>` is backed by a loop device, and
that device is reused as the `vshadowmount` source (the raw image is never re-read).

**This step always runs.** Reach it on every `/tools-mount` invocation — a first mount *and* an idempotent
rerun where Step 4 found the live volumes already mounted (no sudo emitted). The trigger for Step 6 is
"the live NTFS volumes are mounted and verified," not "Step 4 just mounted something." Run `6a` and check
its output even when this run did no live-mount work; `gen_vss_commands.sh` is itself idempotent (it
skips any `vss-*`/snapshot mount that is already present), so re-running it is safe and cheap. If a prior
run already mounted the shadow copies, `6c` simply confirms them — that is the expected steady state, not
a reason to skip.

**6a — Produce the VSS commands (as the user, autonomous).**

```bash
bash ~/.claude/skills/tools-mount-vss/gen_vss_commands.sh
```

The helper enumerates every mounted NTFS volume (`findmnt` reports `fuseblk`/`ntfs3`/`ntfs`, sudo-free),
resolves its backing device with `findmnt -n -o SOURCE <mnt>` (must be a `/dev/loop*`), creates the
user-owned `vss-<NNN>-<imgbase>` FUSE point, and writes the runnable `./mount-vss-readonly.sh`. Because
the snapshot count isn't known until `vshadowmount` runs (and the loop device is root-owned, so detection
needs root), the helper emits **one self-discovering block per volume** rather than a fixed list: it runs
`sudo vshadowmount -X allow_other /dev/loopN vss-<NNN>-<imgbase>/`, then a `for snap in …/vss*` loop that
loop-mounts each store read-only as `mnt-<NNN>-vss-<MMM>-<imgbase>` (`-t ntfs-3g`,
`streams_interface=windows`, no `offset=` — a `vssN` is already a whole volume). FAT/exFAT volumes and
non-loop mounts are noted and skipped; a volume with no shadow copies is a clean no-op.

**6b — Operator runs it in a separate terminal.** The VSS block is shell logic (the snapshot count is
discovered at run time), so the operator **runs the script** rather than pasting:

```bash
cat /cases/<CASE_ID>/mount-vss-readonly.sh        # review every command first
sudo bash /cases/<CASE_ID>/mount-vss-readonly.sh  # expose + mount all shadow copies (read-only)
```

**6c — Verify (as the user, no sudo).** After it runs, confirm the snapshot mounts are readable — same
test as Step 5, including the `mnt-*-vss-*` mounts:

```bash
for MNT in ./sources/$ASSET/mnt-*-vss-*/; do
  MNT="${MNT%/}"; [ -d "$MNT" ] || continue
  if mountpoint -q "$MNT" && ls -A "$MNT" >/dev/null 2>&1; then
    echo "[$ASSET] $(basename "$MNT") readable OK"
  else
    echo "[$ASSET] $(basename "$MNT") NOT readable"
  fi
done
```

VSS is **best-effort enrichment**: a volume with no VSS, a `vshadowmount` failure, or a missing libvshadow
is reported but **never halts** the case — proceed to Step 7. See `/tools-mount-vss` for the mechanics and
for targeted single-snapshot access.

---

## Step 7 — Halt and warn on failure (no silent fallback)

If the user declines sudo, or an asset still has no readable mount after the driver retry, **stop and
warn clearly**: name the asset, the reason (offset unresolved / driver error / read-test failure), and
what the operator can try. Do **not** silently switch to a different acquisition path. (A VSS failure is
**not** a halt condition — it is best-effort enrichment, reported as a note in Step 6.)

An un-mountable image is not a dead end for the case — the operator *may* choose the no-root path
(`/dfir-sleuthkit-file-recovery` works directly on `ewf1` with `-o <sector_offset>`, no mount needed) —
but that is an explicit operator decision, surfaced as a warning, never an automatic degrade.

---

## Step 8 — Unmount (`--unmount`)

Clean teardown for every asset, **inner mount before outer** — VSS snapshot mounts and their
`vshadowmount` FUSE point must come down *before* the live volume, because `vshadowmount` holds that
volume's loop device open:

```bash
for ASSET in <asset_ids>; do
  SRC="./sources/$ASSET"
  # 1) VSS snapshot loop-mounts first (mnt-NNN-vss-MMM-<imgbase>).
  for MNT in "$SRC"/mnt-*-vss-*/; do
    MNT="${MNT%/}"; [ -d "$MNT" ] || continue
    sudo umount "$MNT" 2>/dev/null
    rmdir "$MNT" 2>/dev/null || true
  done
  # 2) vshadowmount FUSE points (vss-NNN-<imgbase>) — releases the live volume's loop handle.
  for VSSD in "$SRC"/vss-*; do
    [ -d "$VSSD" ] || continue
    fusermount -u "$VSSD" 2>/dev/null || sudo umount "$VSSD" 2>/dev/null
    rmdir "$VSSD" 2>/dev/null || true
  done
  # 3) Live volume mounts (every remaining mnt-NNN-<imgbase>), then 4) outer ewfmounts (e01-<imgbase>).
  for MNT in "$SRC"/mnt-*/; do
    MNT="${MNT%/}"; [ -d "$MNT" ] || continue
    sudo umount "$MNT" 2>/dev/null || sudo fusermount -u "$MNT" 2>/dev/null
    rmdir "$MNT" 2>/dev/null || true
  done
  for EWFD in "$SRC"/e01-*; do
    [ -d "$EWFD" ] || continue
    fusermount -u "$EWFD" 2>/dev/null || sudo umount "$EWFD" 2>/dev/null
    rmdir "$EWFD" 2>/dev/null || true
  done
done
```

The `umount` lines need root, so — like the mount step — the operator runs them in a **separate
terminal** (sudo can't prompt through Claude Code; no PTY). The `fusermount -u` of the user's own
ewfmount/vshadowmount and the `rmdir`s need no sudo and can run as the user. So: emit the `sudo umount`
lines for the operator to paste, then do the `fusermount -u`/`rmdir` cleanup as the user.

---

## Notes

- Idempotent: `gen_mount_commands.sh` emits no command for an `mnt-NNN-<imgbase>` volume that is already a
  mountpoint, and `gen_vss_commands.sh` skips any `vss-*` FUSE point or snapshot mount already present, so
  `/tools-mount` is safe to call at the start of every `case-investigate` run. **An idempotent rerun still runs
  Step 6** — "live volumes already mounted, no sudo needed" is about the live mounts only; VSS is checked
  on every run, and the case isn't "ready" until the summary reports VSS state per NTFS volume.
- Multiple disk images per asset are all mounted; each EWF image gets its own `e01-<imgbase>/`, and each
  image's volumes are numbered `mnt-001-<imgbase>`, `mnt-002-<imgbase>`, … per partition (if two images share a
  stem the second is disambiguated, e.g. `mnt-001-<imgbase>-2`).
- Every recognized filesystem (NTFS, FAT12/16/32, exFAT) is mounted, not only the `\Windows` volume; the
  parse phase analyzes only the volumes holding `\Windows` and skips the rest.
- Split raw images (`.001/.002/…`): `mount -o loop` reads only the first segment — reassemble with
  `affuse` (or `cat`) first, then mount the reassembled device (Step 4c).
- BitLocker volumes: `bdemount` the volume first, then point the `sudo mount` at the plaintext device
  (see `/tools-mount-ntfs`). VMDK/VHD/VHDX/QCOW: use `qemu-nbd` to expose a raw device before mounting
  (Step 4c).
- Memory images (`.vmem/.mem/.dmp`) are not mounted — analyze with `/dfir-memory-volatility`.
- VSS: shadow copies of every NTFS volume are **auto-detected and mounted** after verification (Step 6,
  delegated to `/tools-mount-vss`, reusing the live volume's loop device). See that skill for the mechanics
  and for targeted single-snapshot access. Teardown order is handled in Step 8 (snapshots → `vss-*` FUSE →
  live volume → ewfmount).
