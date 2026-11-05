# NTFS dirty bit and Fast Startup

Windows sets the NTFS dirty flag when it does not shut down cleanly, when it schedules `chkdsk`, or when Fast Startup (hybrid shutdown) hibernates the kernel. A dirty volume is not permission to "fix" it from Linux.

## How to see it, without writing

- `ntfsinfo -m /dev/PARTITION` prints volume flags. `0x0001` is `DIRTY`. Other bits can be set at the same time. Trust the word `DIRTY` in the tool output.
- `ntfsfix --no-action /dev/PARTITION` (also `-n`) is a dry run. It must not be used without `--no-action` here. Plain `ntfsfix` writes.
- `ntfsinfo` also reports when Windows is hibernated. Fast Startup leaves `hiberfil.sys` and the volume looks mounted or hibernated.

`blkid` showing `TYPE="ntfs"` only means the filesystem type. It does not clear the flag.

## Mounting

A read-write mount of a dirty or hibernated NTFS can corrupt it, and it throws away a hibernated Windows session. Mount read-only:

```
mount -t ntfs3 -o ro /dev/PARTITION /mnt
```

or, with ntfs-3g:

```
mount -t ntfs-3g -o ro /dev/PARTITION /mnt
```

If the driver refuses even a read-only mount, do not force it. Clone the partition or work from an image.

## What repair actually is

- The real check is Windows `chkdsk C: /f`. That is a **WRITE**, done by booting Windows or Windows recovery media, after a person agrees.
- `ntfsfix` without `--no-action` only clears the dirty bit and asks Windows to check later. It is not `chkdsk` and it does not rebuild a damaged filesystem. Do not describe it as a repair.
- `remove_hiberfile` deletes the hibernated session, including unsaved work. Do not use it to get the volume to mount.

Copying files off a read-only mount is the safe way to look at data. If the dirty bit arrived together with I/O errors, clone first and treat the disk as suspect.
