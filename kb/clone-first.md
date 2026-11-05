# Clone the disk before any repair

If SMART or dmesg says the disk is losing sectors, every write to that disk can turn a weak sector into a lost file. The preservation step is a sector copy onto a **different, healthy** disk. The rescue USB is a small stick. It is not the place for a multi-terabyte image.

A clone is a **WRITE** to the destination. It is a read of the source. Wait for an explicit human OK. Never swap the two paths.

## GNU ddrescue, not dd

The tool is GNU ddrescue (`ddrescue`, Debian package `gddrescue`). It is not `dd_rescue`, and it is not `dd conv=noerror,sync`. The mapfile is why: you can stop and resume, and a second pass retries only the gaps.

**WRITE** to the image and the mapfile, both on a healthy disk:

```
ddrescue -f -n /dev/SOURCE /path/on/healthy/disk.img /path/on/healthy/disk.map
ddrescue -d -f -r3 /dev/SOURCE /path/on/healthy/disk.img /path/on/healthy/disk.map
```

- `-n` / `--no-scrape`: first pass, skip the slow retry of bad areas.
- Second command: `-r3` retries the gaps three times. `-d` uses direct disk access.
- `-f` is required when the destination is a device. For a file it is optional. The destination in these examples is a file.
- Read the mapfile (`cat` is enough) before declaring the copy finished. Non-rescued bytes are still missing.

Do not add `of=` the way `dd` does. ddrescue takes input, output, mapfile as three positional arguments.

`dd if=/dev/zero of=/dev/...` and `dd if=/dev/urandom` wipe a disk. They are never a rescue step.

## Clonezilla

Clonezilla (the live ISO on this stick) is the right tool for a **healthy** disk when you want a filesystem-aware image: device-image, beginner mode, source is the disk you are saving, destination is another disk.

On a disk that is already throwing medium errors, prefer ddrescue. Clonezilla's partclone path reads the filesystem and can stop in a hole. For an unknown or BitLocker volume, Clonezilla falls back to a sector copy, which is safe but has no ddrescue mapfile.

Clonezilla's destination is a **WRITE**. Confirm the source and the destination by size and model from `lsblk` before starting.

## After the image exists

Run `testdisk`, `e2fsck -n`, `ntfsinfo`, or a mount **on the image** (loop device on the image file), not on the original, until you know the original is healthy. Mounting the image read-only is the default.
