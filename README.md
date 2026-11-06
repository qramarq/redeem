# redeem

Offline rescue USB for disk and boot triage. This repository is the source for the stick: a Ventoy menu, SystemRescue 13.02, Clonezilla live 3.3.3-37, and an `ai/` tree that runs a local [llama.cpp](https://github.com/ggml-org/llama.cpp) server with no network.

Build the payload on a working Linux PC, copy it onto a USB stick by hand, and boot the suspect PC from that stick. With the Ventoy tree in place, SystemRescue starts `rescue-ai` on its own. Plugging the stick into a computer that is already running is a double-click, not a reboot.

Phones and tablets cannot boot from USB. On the same Wi-Fi network or a hotspot they are browser clients only, through `rescue-ai --lan`.

## Safety

Read-only by default. `rescue-ai` collects diagnostics and talks. It does not partition, format, mount a patient disk read-write, clear NTFS flags, or install a bootloader.

A command that would change a disk is a **WRITE**. The assistant is instructed to label it and wait for an explicit human OK. The scripts never send that OK.

BitLocker file rescue on Linux is `redeem-bitlocker`, and the mount is read-only. Permanent removal is `manage-bde -off` from Windows or Hiren's BootCD PE, only on a healthy disk after a confirmation phrase. The assistant must not ask for a recovery key in chat and must not invent one. A sector clone of a BitLocker volume stays encrypted. Details are in the BitLocker section below.

The only `ntfsfix` call in this tree is `ntfsfix --no-action`. That is a read.

`build/make-test-image.sh` and `build/qemu-boot-test.sh` accept a regular image file. They refuse `/dev/*` and any block or character device. Nothing in this repository writes a physical stick. You install Ventoy yourself, on the disk `lsblk` shows is the USB stick.

## Step 1: Build the payload on a working Linux PC

Run every command in this step from the repository root.

### 1. Install packages

Ubuntu 24.04 or another glibc 2.39 system is the build host this tree was checked on. The `llama-server` binaries still link glibc dynamically (libgcc and libstdc++ are static; OpenMP and OpenSSL are off). SystemRescue 13 can run a glibc 2.39 binary. A newer glibc on the build PC can produce a binary the live ISO will not load.

```sh
sudo apt-get update
sudo apt-get install -y \
  build-essential cmake ninja-build git curl ca-certificates \
  python3 shellcheck \
  qemu-system-x86 dosfstools udev parted mtools exfatprogs \
  smartmontools ntfs-3g
```

`parted` supplies `partprobe`. `dosfstools` supplies `mkfs.vfat`. `udev` supplies `udevadm`. `mtools` is required only for `make-test-image.sh --serial-console`. `smartmontools` and `ntfs-3g` let `collect-diag.sh` read SMART data and run `ntfsfix --no-action` on the build PC. A normal desktop kernel mounts exFAT directly. If it cannot, the image script falls back to Ventoy's `tool/x86_64/mount.exfat-fuse`.

### 2. Install rtk

[rtk](https://github.com/rtk-ai/rtk) is a developer tool. It is not copied onto the USB. The fetch and compile scripts call `rtk err -- <command>` when `rtk` is on `PATH`, and they keep that command's exit code. If `rtk` is absent, the same command runs with its full output.

```sh
curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
rtk gain
```

`rtk gain` prints a savings dashboard. That is this project. Another project named rtk (Rust Type Kit) does not. Add the `PATH` line to your shell profile if a new terminal cannot find `rtk`.

### 3. Download, compile, assemble, test

Pinned URLs and checksums are in `build/versions.env` and `build/models.tsv`. The fetch scripts also compare the SystemRescue `.sha256` file and Clonezilla `CHECKSUMS.TXT` to the pin and stop if the publisher file disagrees. Downloads land in `build/cache/`. That directory, `build/src/`, `build/work/`, and `ai/` are gitignored.

```sh
./build/fetch-isos.sh
./build/fetch-models.sh
./build/build-llama.sh
./build/fetch-host-binaries.sh   # optional: Windows and macOS llama-server
./build/assemble-ai.sh
./scripts/test-offline.sh
```

A 4 GB stick uses the slim profile. It downloads and copies only Llama-3.2-1B-Instruct Q4_K_M:

```sh
./build/fetch-models.sh --slim
./build/assemble-ai.sh --slim
```

What each script writes:

| Command | Result |
| --- | --- |
| `fetch-isos.sh` | `build/cache/ventoy/ventoy-1.1.18-linux.tar.gz`, `build/cache/isos/systemrescue-13.02-amd64.iso`, `build/cache/isos/clonezilla-live-3.3.3-37-amd64.iso`. `--with-winpe` also fetches `HBCD_PE_x64.iso` |
| `fetch-models.sh` | three GGUF files in `build/cache/models/` (3,789,195,520 bytes together). `--slim` fetches only the 1B model |
| `build-llama.sh` | `build/cache/bin/llama-server-avx2`, `llama-server-avx`, `llama-server-sse4` from llama.cpp `v0.9.0` |
| `fetch-host-binaries.sh` | optional CPU `llama-server` for Windows x64 and macOS arm64/x64, from llama.cpp `b12110` (the binary build named by the `v0.9.0` release) |
| `assemble-ai.sh` | `ai/` (scripts, `kb/`, `models/manifest.tsv`, binaries, GGUF files, `ai/boot/autorun`) and `usb-root/ventoy/` |
| `assemble-ventoy.sh` | `usb-root/ventoy/` (auto-boot config and the initramfs injection). Called by `assemble-ai.sh` |
| `test-offline.sh` | shellcheck, rubric self-test, BM25 retrieval, `collect-diag.sh`, the image-script device refusal, Ventoy JSON, and watcher dry-runs. No model load. |

Confirm the payload before touching a stick:

```sh
ls -l build/cache/bin/llama-server-avx2 \
      build/cache/bin/llama-server-avx \
      build/cache/bin/llama-server-sse4
ls -l build/cache/models/*.gguf
test -x ai/scripts/rescue-ai && echo ai tree ok
```

Optional, still on the build PC: `./scripts/rescue-ai --dry-run` collects a read-only dump under `/tmp/redeem/`, prints the CPU binary and the RAM model, and does not start a server.

### 4. Optional: QEMU before real hardware

This builds a sparse image file and boots that file. It does not write a USB stick.

```sh
./build/make-test-image.sh --serial-console
./build/qemu-boot-test.sh
```

`make-test-image.sh` needs `sudo`. It creates `build/cache/rescue-test.img` (16G sparse, override with `--image FILE` and `--size 16G`), attaches a loop device to that file, checks `/sys/block/loopN/loop/backing_file`, and runs `Ventoy2Disk.sh -I -g -s` on that loop only. `-I` force-installs into the image. The stick procedure in Step 2 uses `-i` and a real device, which you type yourself.

`--serial-console` rewrites GRUB on the **image** (`serial`, `terminal_input`, `terminal_output`) so `qemu-boot-test.sh` can log the menu. That image is serial-only. Do not boot it on a PC, and do not pass `--serial-console` when you prepare the USB stick. The stick gets Ventoy's normal menu from `Ventoy2Disk.sh` in Step 2.

`qemu-boot-test.sh` runs `qemu-system-x86_64 -nographic` against the image (or against a path you pass as the first argument). It uses KVM when `/dev/kvm` is readable, otherwise TCG. The guest is stopped after `QEMU_SECONDS` (default 75). `timeout` exiting 124 is the expected stop. A passing run prints `boot log contains a firmware or bootloader marker` and writes `artifacts/qemu-serial.log`. The recorded log shows SeaBIOS, `Booting from Hard Disk...`, and Ventoy's `VTloading` line. The menu did not finish drawing before the timeout, and SystemRescue itself was not booted in the guest.

`./build/make-test-image.sh --refuse-test` checks that `/dev/sda` and `/dev/nvme0n1` are rejected and a regular file is accepted. `test-offline.sh` already runs that check.

## USB size

Two profiles. The scripts still refuse to flash a stick. You copy onto the stick yourself in Step 2.

| Profile | What is on the stick | Payload | Stick |
| --- | --- | --- | --- |
| Full | SystemRescue 13.02, Clonezilla live 3.3.3-37, the 0.6B, 1B, and 4B GGUFs, Linux `llama-server`, and the optional Windows and macOS CPU binaries | about 6.0-6.3 GB | **8 GB or larger**. 16 GB, or a 64 GB Toughmax, leaves room |
| Slim | SystemRescue 13.02 and Llama-3.2-1B-Instruct Q4_K_M | about 2.5 GB | **4 GB** |
| Full + WinPE | The full set plus Hiren's BootCD PE x64 v1.0.8 (`--with-winpe`) | about 9.1-9.4 GB | **16 GB or larger** |

Pinned sizes: the SystemRescue ISO is 1,381,629,952 bytes. The three GGUF files are 3,789,195,520 bytes together. The 1B file alone is 807,694,464 bytes. Slim is that ISO plus the 1B file, built with `--slim`. Hiren's BootCD PE x64 v1.0.8 is 3,291,686,912 bytes (about 3.06 GB) when `fetch-isos.sh --with-winpe` is used. Ventoy's own partitions sit on top of the payload, which is why the slim stick is planned as 2.5 GB rather than the raw sum and the WinPE stick is planned as 9.1-9.4 GB.

`./build/fetch-host-binaries.sh` is optional. Skip it on a slim 4 GB stick if the extra Windows and macOS binaries would crowd the filesystem.

## Step 2: Prepare the USB stick (manual, one time)

Run the commands in this step from the repository root. Ventoy 1.1.18 erases the disk you give it. Use an 8 GB or larger stick for the full profile, or a 4 GB stick for `--slim`. Leave the rest of the stick empty. It is too small to be the only copy of a large disk, and the stick you booted from is a poor image destination.

### 1. Identify the stick

Plug in the USB stick. Leave the PC's internal disks alone.

```sh
lsblk -o NAME,SIZE,MODEL,TRAN
```

Use the whole-disk row whose `TRAN` is `usb` and whose `SIZE` is the stick you mean to erase (4G for slim, 8G or larger for the full profile). The name looks like `sdb`. Partitions (`sdb1`) are the wrong target for the installer. In the commands below, replace `sdX` with that name. If two USB disks are present, unplug the one you are not installing.

### 2. Install Ventoy (GPT, Secure Boot support)

`fetch-isos.sh` downloads the tarball and does not extract it.

```sh
tar -xzf build/cache/ventoy/ventoy-1.1.18-linux.tar.gz -C build/cache/ventoy
(
  cd build/cache/ventoy/ventoy-1.1.18
  sudo ./Ventoy2Disk.sh -i -g -s /dev/sdX
)
```

Ventoy asks twice. Read the device name in each prompt. Type `y` only when it is the USB stick.

- `-i` installs. It stops if Ventoy is already on that disk.
- `-g` writes a GPT.
- `-s` enables Secure Boot support. That is also Ventoy's default. Pass it anyway.

The data partition is `/dev/sdX1`, exFAT, label `Ventoy`. The small EFI partition is `/dev/sdX2`, label `VTOYEFI`. Confirm before you copy:

```sh
lsblk -o NAME,SIZE,LABEL,FSTYPE,TRAN /dev/sdX
```

### 3. Copy the payload

exFAT does not keep Unix owners. The copy flags match `make-test-image.sh`.

```sh
sudo mkdir -p /mnt/ventoy
sudo mount /dev/sdX1 /mnt/ventoy
findmnt -o TARGET,SOURCE,FSTYPE,LABEL /mnt/ventoy
sudo cp --no-preserve=mode,ownership \
  build/cache/isos/systemrescue-13.02-amd64.iso \
  build/cache/isos/clonezilla-live-3.3.3-37-amd64.iso \
  /mnt/ventoy/
sudo mkdir -p /mnt/ventoy/ai
sudo cp -r --no-preserve=mode,ownership ai/. /mnt/ventoy/ai/
sudo cp -r --no-preserve=mode,ownership usb-root/. /mnt/ventoy/
```

Optional WinPE image, after `./build/fetch-isos.sh --with-winpe` or a verified `--winpe-iso` copy:

```sh
sudo cp --no-preserve=mode,ownership \
  build/cache/isos/HBCD_PE_x64.iso \
  /mnt/ventoy/
```

`usb-root/` puts `Start-Redeem-Linux.sh`, `Start-Redeem.desktop`, `Start-Redeem-macOS.command`, `Start-Redeem-Windows.bat`, and `BitLocker-Windows.bat` at the root of `LABEL=Ventoy`, and `ventoy/` next to them. The stock ISO files are copied unchanged. Ventoy applies `ventoy/ventoy.json` in memory at boot. SystemRescue stays the 5 second default. `HBCD_PE_x64.iso` is listed only when that file is on the stick.

Skip the Clonezilla copy on a slim 4 GB stick. The full profile keeps it.

Optional: `assemble-ai.sh` already put a finder at `ai/boot/autorun`. To also have it at `boot/autorun` on the stick:

```sh
sudo mkdir -p /mnt/ventoy/boot
sudo cp --no-preserve=mode,ownership boot/autorun /mnt/ventoy/boot/autorun
```

Then:

```sh
sync
sudo umount /mnt/ventoy
```

`VTOYEFI` stays as Ventoy wrote it. Do not copy ISOs there.

### Why the repo scripts refuse `/dev`

`build/lib.sh` (`target_is_safe_image`) returns failure for an empty path, a path under `/dev`, `/sys`, or `/proc`, a block device, or a character device. `assert_safe_image` then exits with `redeem never writes a real block device`. The QEMU image path is a normal file. The loop device is created from that file and checked against `backing_file` before Ventoy runs. There is no flag that redirects this at a physical disk. You erase a stick only by running Ventoy's own `Ventoy2Disk.sh` on the `sdX` you read from `lsblk`.

## Step 3: Boot a dead or suspect PC (including Secure Boot)

### 1. Pick the USB from the UEFI boot menu

Insert the stick, power on, and open the firmware boot menu. The key depends on the PC (often F12, Esc, F10, or F2). Select the USB entry. Do not boot the internal disk.

### 2. First boot on a Secure Boot machine: enroll Ventoy's MOK

SystemRescue and Clonezilla are unsigned. Ventoy 1.1.18 still starts them after the firmware trusts Ventoy's loader. Enrollment is once per computer, stored in firmware NVRAM. Ventoy 1.1.14 and later (this stick is 1.1.18) ships the UEFI CA 2023 shim, so a machine that enrolled an older Ventoy key has to enroll this one.

1. In firmware setup, enable **Allow Microsoft 3rd Party UEFI CA** if that switch exists. Some machines hide Ventoy until it is on.
2. At the blue MOK screen, choose **Enroll key from disk**.
3. Open the **VTOYEFI** partition and select `ENROLL_THIS_KEY_IN_MOKMANAGER.cer`.
4. Choose **Continue**, **Yes**, then **Reboot**.

After that loader is trusted, Ventoy's default does not re-check every EFI file inside an ISO. You are trusting Ventoy's boot path. SystemRescue itself is not signed.

If the machine shows a Linpus lite error or a security violation and never offers the MOK screen, this stick will not boot there. Disabling Secure Boot can make Windows ask for the BitLocker recovery key on the next boot. Do that only when the owner already has the 48-digit key, or when you are booting Hiren's BootCD PE to remove BitLocker and you will turn Secure Boot back on before the next Windows boot if BitLocker is still enabled. This toolkit will not type the key. There is no signed Ubuntu ISO on this stick as a fallback.

### 3. Ventoy boots SystemRescue with no keypress

`ventoy/ventoy.json` sets `VTOY_DEFAULT_IMAGE` to `/systemrescue-13.02-amd64.iso` and `VTOY_MENU_TIMEOUT` to 5. Ventoy highlights SystemRescue and boots it after 5 seconds. Press the down arrow during those 5 seconds to pick Clonezilla instead.

| Menu entry | Use it when |
| --- | --- |
| `systemrescue-13.02-amd64.iso` | Diagnostics, `rescue-ai`, or GNU ddrescue. This is the default. |
| `clonezilla-live-3.3.3-37-amd64.iso` | The disk still reads cleanly and you want a filesystem-aware image onto a different disk. |
| `HBCD_PE_x64.iso` | Optional. Offline `manage-bde -off` on a dead Windows PC. Present only after `--with-winpe` or `--winpe-iso`. Not the default. v1.0.8 may need Secure Boot off; SystemRescue does not, once the Ventoy MOK is enrolled. |

The ISO file on the stick is the stock SystemRescue 13.02 image. Its SHA-256 stays `ad4d670b72859d887c7960142a9a9d36a3e50446694a035e254442f65d6e7572`. Ventoy's `conf_replace` swaps the boot menus in memory:

- UEFI reads `/boot/grub/grubsrcd.cfg` from the ISO and uses `/ventoy/grubsrcd.cfg` instead.
- BIOS reads `/sysresccd/boot/syslinux/sysresccd_sys.cfg` and uses `/ventoy/sysresccd_sys.cfg` instead.

Those copies append `sysrescuecfg=/redeem.yaml` to the default entry and set the SystemRescue menu to 2 seconds (`set timeout=2`, syslinux `TIMEOUT 20`). The volume label in that menu is still `RESCUE1302`. After Ventoy's 5 seconds and SystemRescue's 2 seconds, the machine continues into the live system.

## Zero-click boot

SystemRescue reads `/redeem.yaml` from the initramfs. Ventoy's injection plugin unpacks `/ventoy/redeem-initramfs.tar.gz` there. The ISO on disk is not edited. A small live-injection hook then copies `/usr/local/bin/redeem-autostart` onto the live root before `switch_root`.

`redeem.yaml` sets:

- `global.dostartx: true`. `tty1` is left unset so X.Org can take tty1.
- `autorun` with `ar_disable: false`, `ar_nowait: true`, `ar_ignorefail: true`, and an exec entry that runs `/usr/local/bin/redeem-autostart --stage mount`.
- `gui_autostart` with `terminal: true` running `/usr/local/bin/redeem-autostart --stage gui`.

`--stage mount` waits up to 15 seconds for `LABEL=Ventoy`. If that label is missing, it scans partitions read-only for `ai/scripts/rescue-ai` and mounts the match at `/mnt/ventoy` with `-o ro`. It also starts a oneshot systemd unit, `redeem-fallback.service`, which runs `--stage fallback`.

`--stage gui` runs when the desktop is up. It starts `/mnt/ventoy/ai/scripts/rescue-ai` with `--lan` left off. That collects read-only diagnostics, prints and saves the first diagnosis turn, and opens Firefox at `http://127.0.0.1:8080`.

`--stage fallback` waits 22 seconds. If `/tmp/.X11-unix/X0` exists or an `Xorg` process is running, or if `llama-server` is already running, it exits and does not start a second server. If X did not start, it runs `chvt 2` when that command exists and starts `rescue-ai --cli` on tty2.

`--lan` stays off unless you start `rescue-ai` yourself and pass it.

## Plug into a computer that is already on

You do not have to reboot. The launchers live at the root of `LABEL=Ventoy`. All of them leave `--lan` off. `Start-Redeem-*.sh`, `.command`, and `.bat` do not unlock BitLocker, FileVault, or LUKS. `BitLocker-Windows.bat` is a separate tool. It does not run unless you start it.

| File | What a double-click does |
| --- | --- |
| `Start-Redeem-Linux.sh` and `Start-Redeem.desktop` | Runs `ai/scripts/rescue-ai` on a Linux desktop and opens `http://127.0.0.1:8080`. With no display, it uses `--cli`. |
| `Start-Redeem-macOS.command` | Finder opens Terminal. `ai/scripts/collect-diag-macos.sh` records `diskutil list`, `diskutil info`, APFS layout, `fdesetup status`, and recent storage log lines. BM25 runs over `ai/kb/*.md`. `llama-server` comes from `ai/bin/macos-arm64/` or `ai/bin/macos-x64/`, or from `RESCUE_ENDPOINT` when that server answers. The first turn is printed and the browser opens. |
| `Start-Redeem-Windows.bat` | Explorer runs `ai/scripts/rescue-windows.ps1`. It records `Get-Disk`, `Get-PhysicalDisk`, `Get-Partition`, `Get-Volume`, BitLocker status (protector ids and types only), and recent Disk/NTFS System log errors. It ranks `ai/kb/*.md`, starts `ai/bin/win-x64/llama-server.exe` (CPU, model picked from `Win32_OperatingSystem.FreePhysicalMemory`), prints the first turn, and opens the browser. |
| `BitLocker-Windows.bat` | Status, local unlock, or `manage-bde -off` removal. Does not start the model. A recovery key is typed at the local prompt or read from a `.bek` path. |

exFAT does not keep a Unix execute bit. On Linux, `bash Start-Redeem-Linux.sh` works if the kernel refuses to exec the file. On macOS, a `.command` file needs the execute bit the first time; Finder will offer to set it.

Host binaries are optional and are not part of the Linux boot path. `./build/fetch-host-binaries.sh` checks the pinned SHA-256, then `assemble-ai.sh` copies them into `ai/bin/win-x64/`, `ai/bin/macos-arm64/`, and `ai/bin/macos-x64/`. The Windows and macOS archives are llama.cpp `b12110`, the binary build named by the `v0.9.0` release. They are CPU builds (`llama-b12110-bin-win-cpu-x64.zip`, `llama-b12110-bin-macos-arm64.tar.gz`, `llama-b12110-bin-macos-x64.tar.gz`).

## Optional: start when this stick is plugged in

This is for a computer you own. It does not run on the suspect PC unless you install it there yourself. The watcher starts Redeem only when the filesystem UUID matches the one you pass. An empty UUID, `*`, `any`, or anything that is not an exFAT serial (`XXXX-XXXX` or 8 hex digits) or a 128-bit UUID is refused.

Print the UUID, then install. `--dry-run` prints the files and does not write them. `--uninstall` removes them.

Linux, from the stick or from this repository:

```sh
./scripts/host/install-watcher.sh --detect
./scripts/host/install-watcher.sh --os linux --uuid ABCD-1234 --dry-run
./scripts/host/install-watcher.sh --os linux --uuid ABCD-1234
```

`--detect` prints `ID_FS_UUID` for the volume labeled `Ventoy`. The install writes a udev rule that matches that exact `ENV{ID_FS_UUID}`, a system unit, and a `systemd --user` unit. Both units run `linux-usb-launch.sh`, which mounts the volume read-only when it is not already mounted and starts `Start-Redeem-Linux.sh`. A second plug event does not start a second server.

macOS:

```sh
./scripts/host/install-watcher.sh --os macos --uuid ABCD-1234 --dry-run
./scripts/host/install-watcher.sh --os macos --uuid ABCD-1234
```

That writes `~/Library/LaunchAgents/com.redeem.usbwatcher.plist` with `StartOnMount`. The wrapper reads `diskutil info`. If the volume that just mounted is not the pinned UUID, it exits. A match opens `Start-Redeem-macOS.command`.

Windows, in PowerShell:

```powershell
.\scripts\host\install-watcher.ps1 -Detect
.\scripts\host\install-watcher.ps1 -Uuid ABCD-1234 -DryRun
.\scripts\host\install-watcher.ps1 -Uuid ABCD-1234
```

`-DryRun` and `-Uninstall` do the same jobs as the shell flags. The task starts `windows-volume-watcher.ps1`, which waits for a volume arrival and compares the volume serial and the partition GUID to `-Uuid`. Any other disk is ignored. A match starts `Start-Redeem-Windows.bat`.

Uninstall:

```sh
./scripts/host/install-watcher.sh --os linux --uninstall
./scripts/host/install-watcher.sh --os macos --uninstall
```

```powershell
.\scripts\host\install-watcher.ps1 -Uninstall
```

## Step 4: Run `rescue-ai` inside SystemRescue

With the `ventoy/` tree from Step 2, you do not type this. The zero-click path mounts the stick read-only, starts X, and runs `rescue-ai`. If X fails, tty2 runs `rescue-ai --cli` after 22 seconds. The steps below are the same work, done by hand, when you booted without that tree or you want to start it again.

### 1. Mount the Ventoy partition read-only

`rescue-ai` does not write its own folder. It writes the diagnostic dump, the prompt, the server log, and the first reply under `/tmp/redeem/` (override the directory with `RESCUE_TMP`). The Ventoy partition can stay read-only.

```sh
lsblk -f
```

If `LABEL=Ventoy` already has a mountpoint, use that path below in place of `/mnt/ventoy`. If it is not mounted:

```sh
mkdir -p /mnt/ventoy
mount -o ro LABEL=Ventoy /mnt/ventoy
```

Run the launcher from `/root`, so the server process is not sitting on the USB as its current directory.

```sh
cd /root
```

### 2. Start it

```sh
/mnt/ventoy/ai/scripts/rescue-ai
```

If you copied `boot/autorun` onto the stick, this finder searches `/run`, `/mnt`, `/media`, and `/root` for `ai/scripts/rescue-ai` and execs it:

```sh
/mnt/ventoy/boot/autorun
```

The assembled tree also has the same finder at `/mnt/ventoy/ai/boot/autorun`. Or locate the launcher yourself:

```sh
find /run /mnt /media /root -path '*/ai/scripts/rescue-ai' -type f -exec {} \;
```

exFAT does not store a Unix execute bit. SystemRescue's default exFAT mount mode can run the script. If the shell reports `Permission denied`, run `bash /mnt/ventoy/ai/scripts/rescue-ai`.

### 3. What runs on its own

1. **CPU binary.** `/proc/cpuinfo` flags pick a ladder. `avx2` tries `ai/bin/llama-server-avx2`, then `llama-server-avx`, then `llama-server-sse4`. `avx` without `avx2` starts at `llama-server-avx`. Anything else uses `llama-server-sse4`. An AVX2 binary is never started unless the flags include `avx2`.
2. **RAM model.** `MemAvailable` from `/proc/meminfo` picks the GGUF. At least 5120 MiB selects Qwen3-4B-Instruct-2507 Q4_K_M. Otherwise at least 1536 MiB selects Llama-3.2-1B-Instruct Q4_K_M. Below that, Qwen3-0.6B Q4_K_M. A missing file falls through to a model that is present.
3. **Read-only dump** in `/tmp/redeem/rescue-diag.txt` (trimmed) and `/tmp/redeem/rescue-diag-full.txt` (fuller, capped at 1 MiB). `collect-diag.sh` runs `lsblk`, `blkid`, `smartctl -a`, storage lines from `dmesg`, `efibootmgr -v`, Secure Boot state, TPM devices under `/sys/class/tpm`, `ntfsinfo`, `ntfsfix --no-action`, a BitLocker header inspection (protector ids and types, no key), and `journalctl -p err`. A missing tool is recorded. Nothing is repaired and no recovery key is collected.
4. **BM25 retrieval.** `kb-retrieve.awk` ranks `ai/kb/*.md` sections. No embeddings and no network.
5. **First diagnosis turn.** The dump is the first user message. The reply is printed and saved to `/tmp/redeem/first-turn.txt`.
6. **UI.** Context is 4096 for the 4B model and 3072 for the 1B and 0.6B models. The server is CPU-only (`-ngl 0`), with `--cache-ram 0` and `--reasoning off` when that binary supports them. Threads are `nproc`, capped at 8.

The web UI is `http://127.0.0.1:8080`.

- Text console (no `DISPLAY`): after the first answer, the same terminal accepts follow-up questions when stdin is a TTY. `--cli` forces that mode.
- Graphical session: SystemRescue's console does not set `DISPLAY`. Run `startx`, open a terminal there, and start `rescue-ai` from that terminal. The launcher opens the UI with `xdg-open` or Firefox. Ctrl-C in that terminal stops the server.

Files written on a normal run, all under `/tmp/redeem/`:

| File | Contents |
| --- | --- |
| `rescue-diag.txt` | trimmed diagnostics |
| `rescue-diag-full.txt` | fuller diagnostics |
| `system.txt` | safety rules plus retrieved notes |
| `user.txt` | the first question, with the dump |
| `llama-server.log` | local server log |
| `first-turn.txt` | first reply |
| `first-turn.json` | raw completion payload |

## Common modes and flags

```text
rescue-ai [--lan] [--cli] [--dry-run] [--no-chat]
          [--model ID] [--port N] [--context N]
```

On the stick, prefix the command with `/mnt/ventoy/ai/scripts`. From a git checkout, `./scripts/rescue-ai` uses `build/cache/bin` and `build/cache/models`.

| Flag or variable | Effect |
| --- | --- |
| `--cli` | Chat in this terminal after the first turn. |
| `--lan` | Bind `0.0.0.0` and print `http://<lan-ip>:8080` for a phone or tablet on the same network. |
| `RESCUE_API_KEY` | If set, and the binary accepts `--api-key`, the server requires it. The bundled client sends `Authorization: Bearer`. Unset means no authentication. |
| `RESCUE_ENDPOINT` | OpenAI-compatible base URL. If `GET /v1/models` or `GET /health` returns HTTP 200 within 3 seconds, local weights stay unloaded. Otherwise the USB model is used. |
| `--dry-run` | Collect diagnostics, print the binary, model, context, and retrieved headings. Do not start a server. |
| `--no-chat` | Print the first answer and exit. The local server is stopped. |
| `--model ID` | Force a manifest id (`qwen3-4b`, `llama32-1b`, `qwen3-0.6b`) or a substring of the GGUF filename. `RESCUE_MODEL` is the same knob. |
| `--port N` | Listen port. Default `8080`. `RESCUE_PORT` is the same knob. |
| `--context N` | Override the context length (4096 or 3072). |
| `RESCUE_TMP` | Directory for the dump and logs. Default `/tmp/redeem`. |
| `RESCUE_ROOT` | Directory that contains `kb/`. Default is the parent of `scripts/`. |

### Phone or tablet on the LAN

The phone does not boot the stick. On the booted PC, a trusted LAN or a hotspot:

```sh
export RESCUE_API_KEY='choose-a-long-random-string'
/mnt/ventoy/ai/scripts/rescue-ai --lan
```

Open the printed `http://<lan-ip>:8080` in the phone browser. If the page asks for an API key, use `RESCUE_API_KEY`. Do not publish that port on the internet. Omit `RESCUE_API_KEY` only on a network you fully trust. The server then has no authentication.

### Stronger machine on the LAN

```sh
export RESCUE_ENDPOINT=http://192.168.1.20:8080
/mnt/ventoy/ai/scripts/rescue-ai
```

Replace the address with the LAN server. A dead endpoint falls back to the USB model. The diagnostics are still the first turn.

### Other launcher examples

```sh
/mnt/ventoy/ai/scripts/rescue-ai --cli
/mnt/ventoy/ai/scripts/rescue-ai --dry-run
/mnt/ventoy/ai/scripts/rescue-ai --no-chat
/mnt/ventoy/ai/scripts/rescue-ai --model llama32-1b --context 3072 --port 8080
```

### Diagnostics only

`collect-diag.sh` writes a report and exits. It does not start a model. Default output is `/tmp/rescue-diag.txt` (`RESCUE_DIAG_OUT`), cap 12000 bytes (minimum 500). A fuller file is saved beside it with `-full` inserted before the extension (`/tmp/rescue-diag-full.txt`), capped at 1 MiB. When not root, privileged commands run through `sudo -n` if passwordless sudo works. Inside SystemRescue you are root.

```sh
/mnt/ventoy/ai/scripts/collect-diag.sh --out /tmp/rescue-diag.txt --max-bytes 12000
```

From a git checkout the same script is `./scripts/collect-diag.sh`.

## BitLocker

Two different jobs. Linux can read files. Only Windows can remove BitLocker.

### Read-only file rescue (Linux)

SystemRescue 13.02 already has cryptsetup 2.8.7 and dislocker 0.7.3. On the stick the helper is `/mnt/ventoy/ai/scripts/redeem-bitlocker` (the same file as `rescue-bitlocker.sh`).

```sh
redeem-bitlocker inspect /dev/nvme0n1p3
redeem-bitlocker unlock /dev/nvme0n1p3 /mnt/windows
redeem-bitlocker unlock --clearkey /dev/nvme0n1p3 /mnt/windows
redeem-bitlocker unlock --bek /path/to/file.bek /dev/nvme0n1p3 /mnt/windows
redeem-bitlocker lock /mnt/windows
```

`inspect` prints the BitLocker version, cipher, description, and each protector's 8-character Key ID and type. It does not ask for a key. `unlock` mounts `ro,nodev,nosuid,noexec`. A recovery password is read from `/dev/tty` and is not accepted as `--password` or `--key`. `--rw` is refused.

### Permanent removal (Windows or Hiren's BootCD PE)

Linux cannot convert the volume to plain NTFS. On a running Windows PC, or from Hiren's BootCD PE on the Ventoy menu:

```text
BitLocker-Windows.bat status
BitLocker-Windows.bat unlock C:
BitLocker-Windows.bat remove C:
```

`remove` checks disk health, reminds you about AC power, and runs `manage-bde -off` only after you type `DECRYPT C:`. Watch `manage-bde -status C:` until `Percentage Encrypted: 0.0%` and `Conversion Status: Fully Decrypted`. If SMART or `Get-Disk` says the disk is failing, the helper refuses. Copy files off read-only first. `manage-bde -off` rewrites every encrypted sector.

Build the optional ISO with `./build/fetch-isos.sh --with-winpe`, or place your own verified WinPE / WinRE / Windows ISO with `--winpe-iso PATH --winpe-sha256 HEX`. Hiren's v1.0.8 may need Secure Boot disabled. SystemRescue on this stick does not, after the Ventoy MOK is enrolled. If you disable Secure Boot only to boot Hiren's, turn it back on before the next Windows boot when BitLocker is still on and you want the TPM to unlock by itself.

`BitLocker-Windows.bat` uses `manage-bde.exe`, which WinPE and full Windows both have. If `powershell.exe` is missing, the `.bat` file still runs status, `.bek` unlock, the `manage-bde -Password` prompt, and removal. It will not put a 48-digit recovery password on a command line. That path uses PowerShell's in-process WMI call.

### No recovery key

1. `redeem-bitlocker inspect <partition>`. If it reports `clear_key: yes`, the volume is suspended (Windows Update, a BIOS update, or OEM device encryption that was never activated). `redeem-bitlocker unlock --clearkey <partition>` mounts it read-only with no key.
2. If the only usable protector is TPM, put Secure Boot, CSM/Legacy, and the boot order back, then boot the internal disk instead of the USB stick. Windows unlocks itself. The diagnostics show Secure Boot, `efibootmgr -v`, and `/sys/class/tpm` so you can see what this boot changed.
3. Match the 8-character Key ID from the dump at https://account.microsoft.com/devices/recoverykey, in Entra ID, in Active Directory, or on a USB `.bek` file.
4. If no key exists and the TPM cannot unlock the volume, check SMART. A healthy disk can be reinstalled or repartitioned only with the owner's OK. A failing disk is cloned read-only onto a different disk first. This stick cannot crack BitLocker AES.

### Clone before any repair

If SMART or `dmesg` says the disk is losing sectors, a write to that disk can turn a weak sector into a lost file. Image it onto a **different, healthy disk** first. The rescue USB is not the destination.

That copy is a **WRITE** to the destination and a read of the source. Wait for an explicit human OK. Confirm source and destination with `lsblk -o NAME,SIZE,MODEL,TRAN` before you start. Swapping the two paths overwrites the disk you meant to save.

**Failing disk: stay in SystemRescue and use GNU ddrescue** (`ddrescue`). That is the tool in `kb/clone-first.md`. On Debian and Ubuntu the package name is `gddrescue`. The binary is `ddrescue`, not `dd_rescue`, and not `dd conv=noerror,sync`. The mapfile is how you stop and resume.

**WRITE** to the image and the mapfile, both on a healthy disk. Replace `/dev/SOURCE` with the failing disk. `-f` is required when the destination is a device. In these examples the destination is a file, so `-f` is optional. Do not add `of=`. ddrescue takes input, output, and mapfile as three positional arguments.

```sh
ddrescue -f -n /dev/SOURCE /path/on/healthy/disk.img /path/on/healthy/disk.map
ddrescue -d -f -r3 /dev/SOURCE /path/on/healthy/disk.img /path/on/healthy/disk.map
```

`-n` skips the slow retry on the first pass. The second command retries the gaps three times (`-r3`) with direct disk access (`-d`). Read the mapfile before you call the copy finished. `dd if=/dev/zero` or `dd if=/dev/urandom` onto a device wipes it. That is never a rescue step.

**Healthy disk, filesystem-aware image: reboot and choose Clonezilla** at the Ventoy menu. Use device-image, beginner mode. The source is the disk you are saving. The destination is another disk. Clonezilla's destination is a **WRITE**. On a disk that is already throwing medium errors, prefer ddrescue. Clonezilla's partclone path reads the filesystem and can stop in a hole. For an unknown or BitLocker volume, Clonezilla falls back to a sector copy, which stays encrypted and has no ddrescue mapfile.

After an image file exists, run `testdisk`, `e2fsck -n`, `ntfsinfo`, or a read-only mount on the image, not on the original, until you know the original is healthy.

## Stick layout

| Path on the exFAT partition (`LABEL=Ventoy`) | What |
| --- | --- |
| `systemrescue-13.02-amd64.iso` | SystemRescue 13.02 amd64. The live system for `rescue-ai`. |
| `clonezilla-live-3.3.3-37-amd64.iso` | Clonezilla live 3.3.3-37 amd64. Imaging a disk that still reads. |
| `ai/bin/llama-server-avx2` | llama.cpp `v0.9.0` `llama-server`, AVX2. |
| `ai/bin/llama-server-avx` | Same, AVX and not AVX2. |
| `ai/bin/llama-server-sse4` | Same, SSE4.2 and no AVX. |
| `ai/models/Llama-3.2-1B-Instruct-Q4_K_M.gguf` | Default model. 807,694,464 bytes. |
| `ai/models/Qwen3-0.6B-Q4_K_M.gguf` | Emergency model. 484,220,320 bytes. |
| `ai/models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf` | Upgrade model. 2,497,280,736 bytes. |
| `ai/models/manifest.tsv` | Copy of `build/models.tsv`. |
| `ai/kb/` | Offline notes. Under 1 MB. No embeddings. |
| `ai/scripts/rescue-ai` | Launcher. |
| `ai/scripts/collect-diag.sh` | Read-only collector, including BitLocker header ids and firmware state. |
| `ai/scripts/redeem-bitlocker` | Read-only BitLocker inspect, unlock, and lock. Same bytes as `rescue-bitlocker.sh`. |
| `ai/scripts/build-prompt.sh` | Safety rules plus retrieved notes. |
| `ai/scripts/kb-retrieve.awk` | BM25 over `kb/`. |
| `ai/scripts/rescue-chat.py` | OpenAI-compatible client and terminal chat. |
| `ai/boot/autorun` | Finder, copied by `assemble-ai.sh`. |
| `ai/scripts/redeem-autostart` | Same helper the initramfs injection installs. |
| `ai/scripts/collect-diag-macos.sh` | Read-only macOS collector. |
| `ai/scripts/rescue-windows.ps1` | Read-only Windows collector and launcher. BitLocker ids and types only. |
| `ai/scripts/bitlocker-windows.ps1` | Windows and WinPE BitLocker status, unlock, and removal. |
| `ai/bin/win-x64/llama-server.exe` | Optional. Present after `fetch-host-binaries.sh`. |
| `ai/bin/macos-arm64/llama-server` | Optional. Apple silicon. |
| `ai/bin/macos-x64/llama-server` | Optional. Intel Mac. |
| `ventoy/ventoy.json` | 5 second Ventoy timeout, default ISO, injection, conf_replace. |
| `ventoy/redeem-initramfs.tar.gz` | `/redeem.yaml` and `/usr/local/bin/redeem-autostart`. |
| `ventoy/grubsrcd.cfg` | In-memory UEFI menu. Default entry has `sysrescuecfg=/redeem.yaml`. |
| `ventoy/sysresccd_sys.cfg` | In-memory BIOS menu. Same parameter, 2 second timeout. |
| `Start-Redeem-Linux.sh` | Linux desktop launcher. |
| `Start-Redeem.desktop` | Same launcher from a file manager. |
| `Start-Redeem-macOS.command` | macOS launcher. |
| `Start-Redeem-Windows.bat` | Windows launcher. |
| `BitLocker-Windows.bat` | BitLocker status, unlock, and removal. |
| `HBCD_PE_x64.iso` | Optional Hiren's BootCD PE. Not the default boot entry. |
| `boot/autorun` | Optional second copy of the finder. |

`/dev/sdX2` (`VTOYEFI`) is Ventoy's EFI partition. Leave it for the firmware and the MOK certificate. There is no Ubuntu ISO in this version.

## Model selection

`rescue-ai` reads `MemAvailable` before it loads weights. `--model` skips the RAM test and requires that file to exist.

| MemAvailable | Id | File | Role |
| --- | --- | --- | --- |
| 5120 MiB or more | `qwen3-4b` | Qwen3-4B-Instruct-2507 Q4_K_M | upgrade. Apache-2.0. Context 4096. |
| 1536 MiB up to 5119 MiB | `llama32-1b` | Llama-3.2-1B-Instruct Q4_K_M | default, including a 4 GB machine. Llama 3.2 Community License. Context 3072. |
| below 1536 MiB | `qwen3-0.6b` | Qwen3-0.6B Q4_K_M | emergency. Apache-2.0. Context 3072. |

`--cache-ram 0` keeps the server from growing an extra cache on a tight host. `--reasoning off` skips Qwen3 thinking traces so the reply fits the cap (640 tokens on the 4B model, 512 on the others).

## CPU builds

The launcher walks **down** the ladder above. It never runs an AVX2 binary on a CPU without AVX2. OpenMP and OpenSSL are off. libgcc and libstdc++ are linked statically. The shared dependency that remains is glibc.

## ARM64

The bootable images are amd64. `build-llama.sh` does not build an aarch64 `llama-server`, so Snapdragon Windows laptops, ARM Macs, and ARM boards will not boot this stick. A Mac that is already running can use `Start-Redeem-macOS.command` and `ai/bin/macos-arm64/llama-server`. Phones and tablets stay browser clients (`--lan`).

## Benchmark summary

Full table and per-scenario lines: `bench/RESULTS.md`. Rubric: `bench/RUBRIC.md`. Host for the recorded run: 4 vCPU Intel Xeon with AVX2, Ubuntu 24.04, llama.cpp `v0.9.0` (`llama-server-avx2`). These are not weak-laptop numbers. Generation speed is `timings.predicted_per_second`. Peak RSS is the server process VmHWM.

The pass bar is a mean accuracy ratio of at least 0.80 and zero critical fails. None of the three models cleared it.

| Model | Scenarios | Mean accuracy | Critical fails | Mean tok/s | Peak RSS MiB |
| --- | --- | --- | --- | --- | --- |
| llama32-1b | 6 | 0.54 | 0 | 25.61 | 1453 |
| qwen3-0.6b | 6 | 0.33 | 0 | 33.93 | 1094 |
| qwen3-4b | 6 | 0.71 | 1 | 6.87 | 4772 |

The 4B critical fail is an example `ddrescue` onto `/dev/sdb` and `/dev/sdb2`, devices that were not in that diagnostic. The 1B and 0.6B runs had zero critical fails.

`./bench/run-bench.sh` (optional model ids as arguments) starts `llama-server` per model on `127.0.0.1` port `RESCUE_BENCH_PORT` (default 18080) and rewrites `bench/RESULTS.md`. It needs the binaries and GGUF files from Step 1.

## Repository layout

```text
scripts/rescue-ai                 Linux launcher
scripts/collect-diag.sh           read-only lsblk, blkid, smartctl, dmesg, efibootmgr, Secure Boot, TPM, NTFS, BitLocker, journal
scripts/rescue-bitlocker.sh       read-only BitLocker inspect, unlock, and lock
scripts/build-prompt.sh           safety rules plus retrieved notes
scripts/kb-retrieve.awk           BM25 over kb/
scripts/rescue-chat.py            OpenAI-compatible client and CLI
scripts/test-offline.sh           shellcheck, rubric, collector, device refusal, Ventoy, watchers
scripts/host/                     macOS and Windows collectors, BitLocker helper, UUID watcher installers
boot/autorun                      manual finder
boot/redeem-autostart             mount, GUI, and tty2 fallback stages
boot/redeem.yaml                  SystemRescue dostartx and autorun config
boot/systemrescue-13.02/          stock 13.02 grub and syslinux text, checked against the ISO
boot/live-injection/              copies redeem-autostart onto the live root
usb-root/                         launchers copied to the stick root
build/versions.env                pinned ISO, Ventoy, llama.cpp, and host binary checksums
build/models.tsv                  pinned GGUF names, hashes, sizes, roles
build/lib.sh                      checksums, rtk wrapper, image-path refusal
build/fetch-isos.sh               Ventoy, SystemRescue, Clonezilla; optional Hiren's with --with-winpe
build/fetch-models.sh             GGUF files; --slim keeps the 1B model
build/fetch-host-binaries.sh      optional Windows and macOS llama-server
build/build-llama.sh              avx2 / avx / sse4 llama-server
build/assemble-ai.sh              ai/ tree; calls assemble-ventoy.sh
build/assemble-ventoy.sh          usb-root/ventoy, ISO left unchanged
build/make-test-image.sh          sparse image only, refuses /dev
build/qemu-boot-test.sh           headless boot of that image
bench/                            scenarios, rubric, runner, RESULTS.md
```

## Licenses

The shell and Python in this repository are for building and running the stick. Llama 3.2 weights are under the Llama 3.2 Community License. Both Qwen3 GGUF files are Apache-2.0. Ventoy is GPL-3.0. SystemRescue and Clonezilla keep their own licenses. Weights and ISOs are downloaded, not vendored.
