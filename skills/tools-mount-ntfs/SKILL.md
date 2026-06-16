# Skill: tools-mount-ntfs — Mount NTFS Filesystem from Disk Image

## Overview

Mounts an NTFS filesystem partition read-only from a raw disk image (typically `ewf1`
exposed by `/tools-mount-e01`). Uses `mmls` to find the correct partition offset, then
`mount -o ro,loop,noatime` to expose the filesystem.

**Tools:** `mmls` (TSK, system PATH), `mount` (system, requires sudo)

---

## Case Path Convention

| Path | Purpose |
|------|---------|
| `./sources/<asset_id>/e01-<imgbase>/ewf1` | Raw disk from ewfmount |
| `./sources/<asset_id>/mnt-001-<imgbase>/` | NTFS mount point — created at mount time |

---

## Commands

### Find partition offset
```bash
ASSET="<asset_id>"
SRC="./sources/$ASSET"

mmls "$SRC/e01-<imgbase>/ewf1"
```

Output example:
```
DOS Partition Table
Offset Sector: 0
Units are in 512-byte sectors

      Slot      Start        End          Length       Description
000:  Meta      0000000000   0000000000   0000000001   Primary Table (#0)
001:  -------   0000000000   0000002047   0000002048   Unallocated
002:  000:000   0000002048   0000206847   0000204800   NTFS / exFAT (0x07)
003:  000:001   0000206848   ...
```

The NTFS partition is sector `2048`. Calculate byte offset:

```bash
# 512-byte sectors (most disk images)
OFFSET_SECTOR=2048
OFFSET_BYTES=$(( OFFSET_SECTOR * 512 ))

# 4K-native drives (Advanced Format)
OFFSET_BYTES=$(( OFFSET_SECTOR * 4096 ))
```

Verify sector size first:
```bash
fsstat "$SRC/e01-<imgbase>/ewf1" -o 2048 2>/dev/null | grep "Sector Size"
```

### Mount NTFS
```bash
OFFSET_BYTES=1048576   # example: 2048 * 512

mkdir -p "$SRC/mnt-001-<imgbase>"
sudo mount -o ro,loop,noatime,offset="$OFFSET_BYTES" \
  "$SRC/e01-<imgbase>/ewf1" \
  "$SRC/mnt-001-<imgbase>/"

# Confirm
ls "$SRC/mnt-001-<imgbase>/Windows/"
```

### Unmount
```bash
sudo umount "$SRC/mnt-001-<imgbase>/"
rmdir "$SRC/mnt-001-<imgbase>/"
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `wrong fs type` | Verify offset; try `fsstat` to confirm NTFS at offset |
| `mount: /dev/loop already in use` | `sudo losetup -a` to list; use free loop device |
| `bad superblock` | Wrong offset — recheck `mmls` output |
| Files visible but garbled | 4K-sector image — recalculate with sector size 4096 |

---

## Notes

- Always mount read-only (`ro`). Never drop the `ro` flag.
- `noatime` prevents access-time updates on the loop device.
- For BitLocker-encrypted volumes, use `bdemount` first, then loop-mount the plaintext image.
- For VMDK/VHD images, use `qemu-nbd` or `imagemounter` as an alternative to ewfmount.
