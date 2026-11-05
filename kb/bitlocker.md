# BitLocker: detect and explain, never unlock

This stick does not unlock BitLocker. It does not ask for a recovery key, it does not try keys, and it does not run `dislocker`, `manage-bde`, or `cryptsetup` against the volume. A key printed by the model would be invented. Invented keys are a failure, not a suggestion.

## How to recognize it

Any one of these is enough:

- `blkid` reports `TYPE="BitLocker"`.
- The volume boot sector contains the eight-byte signature `-FVE-FS-` at offset 3. Reading those eight bytes with `dd` is a read.
- `dislocker-find` lists the device. That command only searches. It does not decrypt. Its exit code is the number of volumes it found, not a normal success/failure code.

The volume will not have a mountable NTFS superblock while BitLocker is locked. Do not run `ntfsfix` on it.

Linux LUKS is a different thing (`TYPE="crypto_LUKS"`). Same rule: do not open it. Say it is Linux disk encryption and stop.

## Where a real key comes from

The recovery password is 48 digits, eight groups of six, that the owner or their organization already saved. Typical places, which you can name without claiming you looked:

- The Microsoft account devices page, for a personal device signed into that account.
- A printed or PDF copy the owner made.
- Entra ID (Azure AD) or on-premises Active Directory, for a managed PC.
- A USB key they saved when encryption was turned on.

You do not have that password. Do not produce an example that looks like one.

## What is safe to do

A sector clone (GNU ddrescue or a Clonezilla disk image) copies ciphertext. The image stays encrypted. That is the right preservation step when the disk itself is failing. It does not reveal files.

Reading the files requires Windows (or another machine the owner controls) and the owner's own key. Changing Secure Boot, the boot mode, or the TPM can make Windows ask for that key at the next boot. Do not disable Secure Boot on a BitLocker disk unless the owner already has the key in their hands. This toolkit still will not type it.

"Device encryption" on a Home edition PC is still BitLocker (FVE metadata). Detect it the same way.
