# redeem

Offline rescue USB for disk and boot triage. This repository is the source for the stick: a Ventoy menu, SystemRescue 13.02, Clonezilla live 3.3.3-37, and an `ai/` tree that runs a local [llama.cpp](https://github.com/ggml-org/llama.cpp) server with no network.

Build the payload on a working Linux PC, copy it onto a 64 GB USB stick by hand, boot the suspect PC from that stick, and run `rescue-ai` inside SystemRescue.

Phones and tablets cannot boot from USB. On the same Wi-Fi network or a hotspot they are browser clients only, through `rescue-ai --lan`.

## Safety

Read-only by default. `rescue-ai` collects diagnostics and talks. It does not partition, format, mount a patient disk read-write, clear NTFS flags, install a bootloader, or unlock encryption.

A command that would change a disk is a **WRITE**. The assistant is instructed to label it and wait for an explicit human OK. The scripts never send that OK.

BitLocker is detect-and-explain only. There is no `dislocker` mount, no `manage-bde`, and no guessed recovery key. A sector clone of a BitLocker volume stays encrypted.

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
./build/assemble-ai.sh
./scripts/test-offline.sh
```

What each script writes:

| Command | Result |
| --- | --- |
| `fetch-isos.sh` | `build/cache/ventoy/ventoy-1.1.18-linux.tar.gz`, `build/cache/isos/systemrescue-13.02-amd64.iso`, `build/cache/isos/clonezilla-live-3.3.3-37-amd64.iso` |
| `fetch-models.sh` | three GGUF files in `build/cache/models/` (3,789,195,520 bytes together) |
| `build-llama.sh` | `build/cache/bin/llama-server-avx2`, `llama-server-avx`, `llama-server-sse4` from llama.cpp `v0.9.0` |
| `assemble-ai.sh` | `ai/` (scripts, `kb/`, `models/manifest.tsv`, binaries, GGUF files, `ai/boot/autorun`) |
| `test-offline.sh` | shellcheck, rubric self-test, BM25 retrieval, `collect-diag.sh`, and the image-script device refusal. No model load. |

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

## Step 2: Prepare the 64 GB USB stick (manual, one time)

Run the commands in this step from the repository root. Ventoy 1.1.18 erases the disk you give it. The ISOs plus models use a few GB. Leave the rest of the stick empty. It is too small to be the only copy of a large disk, and the stick you booted from is a poor image destination.

### 1. Identify the stick

Plug in the USB stick. Leave the PC's internal disks alone.

```sh
lsblk -o NAME,SIZE,MODEL,TRAN
```

Use the whole-disk row whose `TRAN` is `usb` and whose `SIZE` is about 64G. The name looks like `sdb`. Partitions (`sdb1`) are the wrong target for the installer. In the commands below, replace `sdX` with that name. If two USB disks are present, unplug the one you are not installing.

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
```

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

If the machine shows a Linpus lite error or a security violation and never offers the MOK screen, this stick will not boot there. Disabling Secure Boot can make Windows ask for the BitLocker recovery key on the next boot. Do that only when the owner already has the 48-digit key. This toolkit will not type it. There is no signed Ubuntu ISO on this stick as a fallback.

### 3. Choose an ISO at the Ventoy menu

| Menu entry | Use it when |
| --- | --- |
| `systemrescue-13.02-amd64.iso` | You want diagnostics, `rescue-ai`, or GNU ddrescue. |
| `clonezilla-live-3.3.3-37-amd64.iso` | The disk still reads cleanly and you want a filesystem-aware image onto a different disk. |

Boot SystemRescue for Step 4. Reboot into Clonezilla only for the imaging case in [Clone before any repair](#clone-before-any-repair).

## Step 4: Run `rescue-ai` inside SystemRescue

SystemRescue drops you in a root shell. It does not run `boot/autorun` at boot. That file is not inside the ISO. You start it by hand.

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
3. **Read-only dump** in `/tmp/redeem/rescue-diag.txt` (trimmed) and `/tmp/redeem/rescue-diag-full.txt` (fuller, capped at 1 MiB). `collect-diag.sh` runs `lsblk`, `blkid`, `smartctl -a`, storage lines from `dmesg`, `efibootmgr -v`, `ntfsinfo`, `ntfsfix --no-action`, a BitLocker signature check, and `journalctl -p err`. A missing tool is recorded. Nothing is repaired.
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
| `ai/scripts/collect-diag.sh` | Read-only collector. |
| `ai/scripts/build-prompt.sh` | Safety rules plus retrieved notes. |
| `ai/scripts/kb-retrieve.awk` | BM25 over `kb/`. |
| `ai/scripts/rescue-chat.py` | OpenAI-compatible client and terminal chat. |
| `ai/boot/autorun` | Finder, copied by `assemble-ai.sh`. |
| `boot/autorun` | Optional second copy of that finder. |

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

ARM64 is not in this tree. The SystemRescue and Clonezilla ISOs pinned here are amd64, and `build-llama.sh` does not build an aarch64 `llama-server`. Snapdragon Windows laptops, ARM Macs, and ARM boards will not boot this stick. Phones and tablets stay browser clients (`--lan`).

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
scripts/rescue-ai          launcher
scripts/collect-diag.sh    read-only lsblk, blkid, smartctl, dmesg, efibootmgr, NTFS, BitLocker, journal
scripts/build-prompt.sh    safety rules plus retrieved notes
scripts/kb-retrieve.awk    BM25 over kb/
scripts/rescue-chat.py     OpenAI-compatible client and CLI
scripts/test-offline.sh    shellcheck, rubric, collector, device refusal
kb/                        knowledge pack
boot/autorun               manual finder, not an ISO patch
build/versions.env         pinned ISO, Ventoy, and llama.cpp versions
build/models.tsv           pinned GGUF names, hashes, sizes, roles
build/lib.sh               checksums, rtk wrapper, image-path refusal
build/fetch-isos.sh        Ventoy, SystemRescue, Clonezilla
build/fetch-models.sh      three GGUF files
build/build-llama.sh       avx2 / avx / sse4 llama-server
build/assemble-ai.sh       ai/ tree
build/make-test-image.sh   sparse image only, refuses /dev
build/qemu-boot-test.sh    headless boot of that image
bench/                     scenarios, rubric, runner, RESULTS.md
```

## Licenses

The shell and Python in this repository are for building and running the stick. Llama 3.2 weights are under the Llama 3.2 Community License. Both Qwen3 GGUF files are Apache-2.0. Ventoy is GPL-3.0. SystemRescue and Clonezilla keep their own licenses. Weights and ISOs are downloaded, not vendored.
