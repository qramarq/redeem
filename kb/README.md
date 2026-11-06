# Offline knowledge pack

Short, checked notes for disk and boot triage. `scripts/rescue-ai` splits these files on `##` headings and pulls a few chunks with a small BM25 ranker (`scripts/kb-retrieve.awk`). There are no embeddings and no network lookup.

The pack is a reminder, not a license to write. Commands that change a disk are marked **WRITE** and still need a person to say yes. BitLocker file rescue on Linux is read-only. Permanent removal is a Windows WRITE on a healthy disk.

| File | Use it for |
| --- | --- |
| `smart-attributes.md` | ATA SMART counters and NVMe health log fields |
| `storage-dmesg.md` | Kernel storage and filesystem error lines |
| `clone-first.md` | Imaging a suspect disk with GNU ddrescue or Clonezilla |
| `grub-efi.md` | EFI boot entries and GRUB, read first |
| `ntfs-dirty.md` | NTFS dirty flag and Windows Fast Startup |
| `bitlocker.md` | BitLocker header ids, read-only unlock, and removal |
