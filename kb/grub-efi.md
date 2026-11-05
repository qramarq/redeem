# GRUB and EFI boot triage

Disk and Linux boot problems are the job. A missing boot entry is not a dead disk. Check SMART and dmesg before rewriting a bootloader.

## Read-only checks

- `efibootmgr -v` lists firmware boot entries and the file path each one uses. `BootCurrent` is the entry that just booted.
- The EFI System Partition is a FAT filesystem, partition type GUID `C12A7328-F81F-11D2-BA4B-00A0C93EC93B`. `lsblk -o NAME,PARTTYPE,FSTYPE,LABEL` shows it. Typical size is 100–512 MB.
- Mount that partition **read-only** and list it. Files that matter:
  - `EFI/BOOT/BOOTX64.EFI` — fallback path, what firmware tries when no NVRAM entry matches
  - `EFI/Microsoft/Boot/bootmgfw.efi` — Windows Boot Manager
  - `EFI/ubuntu/`, `EFI/fedora/`, or `EFI/grub/grubx64.efi` — common Linux GRUB paths
  - `EFI/systemd/systemd-bootx64.efi` — systemd-boot
- `bootctl status` when systemd-boot is installed. It is a read.

If the firmware entry's path is missing on the FAT partition, the firmware has nothing to start. If the file is present and there is no `efibootmgr` line for it, the NVRAM entry is gone but the files may be fine. Those are different repairs.

Intel RST / RAID mode makes Windows disks invisible or oddly named in Linux. `lspci` and the kernel log show the mode. Do not flip the firmware from RAID to AHCI as a casual step. On a BitLocker machine that change demands the recovery key, and this toolkit will not unlock BitLocker.

## Repairs are writes

Everything below is a **WRITE**. It needs a human OK. If the disk looks sick, clone it first.

- Linux, UEFI, from a chroot or with the ESP mounted at `/mnt/efi`:
  `grub-install --target=x86_64-efi --efi-directory=/mnt/efi --bootloader-id=GRUB`
  then `grub-mkconfig -o /boot/grub/grub.cfg`
  Confirm the disk in `--efi-directory` is the ESP you listed, not the rescue USB.
- Legacy BIOS: `grub-install /dev/DISK` writes the MBR of that whole disk. Name the disk from `lsblk`. The rescue USB must not be the target.
- Windows: if `bootmgfw.efi` is missing, use Windows installation media and its repair environment. `bootrec /fixboot` and `bcdboot` are writes, and they belong in that environment, not in an invented `bcdedit` command with made-up GUIDs. From Linux, do not fabricate a BCD.

A GRUB `grub>` prompt with a healthy disk usually means `grub.cfg` or the prefix path is wrong. `ls` at that prompt is read-only. Reinstalling GRUB is the write that follows, after a person agrees.
