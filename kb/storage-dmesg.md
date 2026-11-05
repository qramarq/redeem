# Storage lines in dmesg

These are real kernel messages. A line that is not in the diagnostic was not seen. USB timeouts and disk media errors are different failures.

## The disk cannot serve a sector

- `blk_update_request: I/O error, dev sdX, sector N`
- `print_req_error: I/O error, dev nvme0n1, sector N`
- `Buffer I/O error on dev sdX, logical block N`
- `Sense Key : Medium Error` and `Add. Sense: Unrecovered read error`
- `critical medium error`

Medium Error / unrecovered read means the device tried and could not return that sector. That is a failing disk or a failing flash translation layer. Stop writing to it. The next preservation step is a clone onto a different disk (see clone-first), after a person agrees.

The sector number is useful only if it was printed. Do not make one up.

## Filesystem gave up

- `EXT4-fs error (device sdX)` followed by `Remounting filesystem read-only`
- `XFS (sdX): metadata I/O error`
- `BTRFS error (device sdX)` or `BTRFS: error (device sdX) in ...`

The filesystem went read-only to limit damage. Do not remount it read-write to "see if it works." Copy what you can from a read-only mount, or clone the block device first if the errors are I/O errors underneath.

`EXT4-fs (device): warning: mounting fs with errors` means the journal or superblock wants `fsck`. **WRITE.** Run `e2fsck` only against a clone, or against the original after a person agrees and a copy exists. Prefer `e2fsck -n` (no changes) as the next read-only look.

## Link resets are not always dead media

- `ata3: hard resetting link` and `COMRESET`
- `nvme nvme0: I/O ... timeout` then `nvme nvme0: resetting controller`
- `ATA bus error` and `UDMA CRC` sense data

One reset that recovers can be a cable, a dock, or power. Resets together with medium errors or a climbing pending-sector count are the disk. Say which evidence you actually have.

## USB and the adapter

- `device descriptor read/64, error -110` (timeout)
- `usb ... device not accepting address`
- `uas_eh_abort_handler`

A USB-SATA bridge can drop commands while the drive itself is fine. Move the disk to a different port or a direct SATA/NVMe slot before calling the disk dead. `smartctl` may need `-d sat` behind a USB bridge. That flag is still a read.

## What not to do

Do not format, `mkfs`, `wipefs`, or zero the device to clear an I/O error. That deletes the remaining readable data.
