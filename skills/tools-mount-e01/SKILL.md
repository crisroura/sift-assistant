# Skill: tools-mount-e01 — Mount EWF/E01 Disk Images

## Overview

Mounts an Expert Witness Format (EWF / E01) disk image read-only using `ewfmount` (FUSE).
The FUSE mount exposes a raw disk file (`ewf1`) that is then loop-mounted by `/tools-mount-ntfs`.

**Tool:** `ewfmount` (system PATH) — part of libewf

---

## Case Path Convention

| Path | Purpose |
|------|---------|
| `./sources/<asset_id>/<image>.E01` | Evidence file (read-only, never modified) |
| `./sources/<asset_id>/e01-<imgbase>/` | FUSE mount point — created at mount time, named from the image (`base-dc-cdrive.E01` → `e01-base-dc-cdrive`) |
| `./sources/<asset_id>/e01-<imgbase>/ewf1` | Raw disk exposed by ewfmount |

---

## Commands

### Verify image before mounting
```bash
ewfverify ./sources/<asset_id>/<image>.E01
ewfinfo  ./sources/<asset_id>/<image>.E01
```

### Mount
```bash
ASSET="<asset_id>"
SRC="./sources/$ASSET"
IMG="base-dc-cdrive"          # the image filename stem (your .E01 minus its extension)

mkdir -p "$SRC/e01-$IMG"
ewfmount "$SRC/$IMG.E01" "$SRC/e01-$IMG/"   # NO sudo — keep ewf1 user-owned and readable

# Confirm
ls -lh "$SRC/e01-$IMG/ewf1"
```

### Multi-segment images (E01, E02, … or .e01, .e02, …)
`ewfmount` automatically discovers all segments when given the first file.
```bash
ewfmount "$SRC/$IMG.E01" "$SRC/e01-$IMG/"   # NO sudo
```

### Unmount
```bash
fusermount -u "$SRC/e01-$IMG/" 2>/dev/null || sudo umount "$SRC/e01-$IMG/"
rmdir "$SRC/e01-$IMG/"
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `ewfmount: unable to open EWF file(s)` | Check file path; verify all segments present |
| `Transport endpoint is not connected` | Mount point stale — fusermount -u first, then re-mount |
| `fuse: failed to open /dev/fuse` | Add the user to the `fuse` group (`sudo usermod -aG fuse $USER`); do NOT sudo ewfmount — that makes `ewf1` root-owned and unreadable to the analysis tools |
| Slow mount on large images | Normal for ewfmount; verify with `ls ewf1` after a few seconds |

---

## Notes

- `ewfmount` is read-only by design — it cannot write to the evidence file.
- Run `ewfmount` **as the user, never sudo**. A root-owned `ewf1` is unreadable to the analysis
  tools; only the later `mount -o loop` (in `/tools-mount`) needs root.
- The `ewf1` file is a virtual raw image; pass it to `mmls`, `mount`, or `log2timeline.py`.
- Do not use `xmount` as a substitute — it does not support multi-segment EWF on all SIFT builds.
