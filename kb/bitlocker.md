# BitLocker

BitLocker (and Windows "device encryption") is FVE metadata. A locked volume has no mountable NTFS superblock. Do not run `ntfsfix`, `fsck`, or `chkdsk` on it. A sector clone made with GNU ddrescue or Clonezilla stays encrypted. Linux cannot turn the volume into plain NTFS in place. That conversion is `manage-bde -off` on Windows.

Never ask the owner to paste a recovery password into this chat. Never print a 48-digit key, and never put one on a command line. A key typed here would be invented. Invented keys are a failure.

## How to recognize it

Any one of these is enough:

- `blkid` or `lsblk` reports `TYPE="BitLocker"` / `FSTYPE=BitLocker`.
- The volume boot sector contains the eight-byte signature `-FVE-FS-` at offset 3. Reading those eight bytes with `dd` is a read.
- `cryptsetup bitlkDump <partition>` prints `Info for BITLK` when cryptsetup is 2.3 or newer. SystemRescue 13.02 ships cryptsetup 2.8.7. The dump does not need a key. Do not pass a volume-key dump option.
- `dislocker-metadata -V <partition>` is the fallback when cryptsetup is older or missing. `dislocker-find` only searches. Its exit code is the number of volumes it found.

`redeem-bitlocker inspect <partition>` runs that dump, prints protector ids and types, and does not prompt.

Linux LUKS is different (`TYPE="crypto_LUKS"`, or `cryptsetup isLuks`). Do not open it. Say it is Linux disk encryption and stop.

## Header fields that are safe to repeat

Repeat only what the dump shows:

- BitLocker version, cipher name, cipher mode, and key size in bits.
- Volume description and creation time.
- Each protector GUID, the first 8 hex characters of that GUID (the Key ID prefix), and the type.

Protector types in a cryptsetup `bitlkDump`:

| Dump text | Meaning |
| --- | --- |
| VMK protected with clear key | Suspended BitLocker, or OEM device encryption not yet activated. No recovery key is required. |
| VMK protected with TPM | TPM auto-unlock. Linux cannot use the TPM. |
| VMK protected with TPM and PIN | TPM plus a PIN. |
| VMK protected with recovery passphrase | 48-digit recovery password. |
| VMK protected with passphrase | User password (common on BitLocker To Go). |
| VMK protected with startup key | External key file, usually `.bek` on a USB drive. |
| VMK protected with smart card | Smart card. Not usable from this stick. |

Microsoft, Entra, and Active Directory show the same id as those 8 characters: the first eight hex digits of the protector GUID, with the dashes removed, written in uppercase. Do not invent an id that is not in the dump.

Salts, nonces, and key bytes from `dislocker-metadata -v` are not identifiers. Do not copy them into the chat.

## Clear key: no recovery key required

`clear_key: yes` means Windows left a clear key on the volume. That happens when BitLocker is suspended for Windows Update or a BIOS update, and on some Home PCs whose device encryption was never activated.

Mount it read-only immediately:

```sh
redeem-bitlocker unlock --clearkey /dev/nvme0n1p3 /mnt/windows
```

cryptsetup 2.8 tries a null passphrase first inside `cryptsetup open --type bitlk --readonly`, which uses the clear key and does not prompt. This helper then passes an empty key file so a missing clear key does not fall through into a password prompt. If cryptsetup is missing, the fallback is `dislocker -r -V <partition> --clearkey -- <fuse-dir>` and `mount -o loop,ro,nodev,nosuid,noexec`.

`--clearkey` will not open a volume whose report says `clear_key: no`.

## When the owner has a key

Read-only file rescue on Linux, from SystemRescue or another host:

```sh
redeem-bitlocker inspect /dev/nvme0n1p3
redeem-bitlocker unlock /dev/nvme0n1p3 /mnt/windows
redeem-bitlocker unlock --bek /path/to/file.bek /dev/nvme0n1p3 /mnt/windows
redeem-bitlocker lock /mnt/windows
```

The passphrase is read from `/dev/tty` (`read -r -s`) and handed to `cryptsetup open --type bitlk --readonly --key-file=-`. It is not a command argument. If cryptsetup fails, dislocker prompts on the same terminal (`--recovery-password` or `--user-password` with no value, so the secret stays off argv). The mount options are `ro,nodev,nosuid,noexec`. `--rw`, `--password`, and `--key` are refused.

Permanent removal is not a Linux command. On a healthy disk, from full Windows or from Hiren's BootCD PE (Ventoy menu, `HBCD_PE_x64.iso`):

```text
BitLocker-Windows.bat status
BitLocker-Windows.bat unlock C:
BitLocker-Windows.bat remove C:
```

`remove` runs `manage-bde -off C:` only after the owner types `DECRYPT C:`. Watch `manage-bde -status C:` until `Percentage Encrypted: 0.0%` and `Conversion Status: Fully Decrypted`. That is a **WRITE**. It rewrites every encrypted sector. Keep the PC on AC power.

Hiren's BootCD PE v1.0.8 may need Secure Boot turned off on some firmware. SystemRescue on this stick boots through the Ventoy MOK with Secure Boot left on. Turning Secure Boot off can make TPM BitLocker ask for the recovery key on the next Windows boot. Turn it back on before that boot if BitLocker is still enabled and you want TPM auto-unlock.

## No recovery key

Work in this order.

1. `redeem-bitlocker inspect <partition>`. If `clear_key: yes`, use `--clearkey` and copy files read-only. Stop.
2. If a TPM protector is present and Windows only started asking for a key after a firmware or boot change, put the firmware back: Secure Boot on, CSM/Legacy off, and the previous boot order. Boot the internal disk, not the USB stick. TPM-only BitLocker then unlocks itself. This Linux session cannot speak to the TPM. The diagnostics include Secure Boot, `efibootmgr -v`, and `/sys/class/tpm`.
3. Match the 8-character Key ID:
   - Personal device: https://account.microsoft.com/devices/recoverykey
   - Work or school: Microsoft Entra ID, or the Active Directory computer object
   - A USB drive created when encryption was turned on (`.bek`, used with `--bek` or `BitLocker-Windows.bat unlock C: --bek E:\key.bek`)
   - A printout or PDF the owner already saved
4. If no key exists anywhere and the TPM still will not unlock the volume, the remaining step is a clean reinstall or repartition. That destroys the encrypted files. It needs the owner's explicit OK. Verify SMART first. A failing disk gets a read-only clone onto a different healthy disk before anyone repartitions.

Do not claim BitLocker AES can be cracked, guessed, or bypassed from this stick. Do not try key lists.

## Failing disks

If SMART says the disk is failing, copy files with a read-only mount or take a sector image onto a different disk. Do not run `manage-bde -off`. In-place decryption rewrites every encrypted sector and can finish the disk off. `BitLocker-Windows.bat remove` refuses a disk that reports failing or unhealthy status.

`redeem-bitlocker unlock` may still mount read-only on a failing disk so files can be copied. It prints a warning. It does not decrypt in place.
