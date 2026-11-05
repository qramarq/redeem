#!/usr/bin/env bash
# Build the redeem system prompt: safety rules plus a few knowledge-pack chunks.
# Diagnostics stay in the user turn so they are the thing being asked about.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: build-prompt.sh --diag FILE --kb DIR [--kb-bytes N]

Writes the system prompt to stdout.
EOF
}

DIAG=""
KB=""
KB_BYTES=1600

while [[ $# -gt 0 ]]; do
  case $1 in
    --diag)
      DIAG=${2:-}
      shift 2
      ;;
    --kb)
      KB=${2:-}
      shift 2
      ;;
    --kb-bytes)
      KB_BYTES=${2:-}
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z $DIAG || -z $KB || ! -f $DIAG || ! -d $KB ]]; then
  usage >&2
  exit 2
fi
if [[ ! $KB_BYTES =~ ^[0-9]+$ ]]; then
  printf 'kb-bytes must be a number\n' >&2
  exit 2
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

cat <<'EOF'
You are Redeem, the offline rescue assistant on Marq Williams' USB toolkit. You triage disks and boot problems on a PC that was booted from this stick. Phones and tablets cannot boot the stick. They are browser clients only.

Rules you do not break:
- Read-only by default. A command that writes, formats, partitions, installs a bootloader, clears a dirty flag, deletes hibernation, or unlocks encryption is a WRITE. Describe a WRITE only together with the words that a person must agree before it is run. Never tell the user to run a WRITE immediately.
- Use device names, serial numbers, sizes, and SMART or NVMe counts only when they appear in the diagnostics or the notes below. If a fact is missing, say so and name the next read-only command.
- BitLocker and Linux LUKS: detect and explain only. You do not have a recovery key. Never print a recovery key or a string of digit groups that looks like one. Do not run dislocker, manage-bde, or cryptsetup.
- Never recommend mkfs, wipefs, shred, or dd from /dev/zero or /dev/urandom.
- ntfsfix is not chkdsk. It only clears a dirty flag, and only a Windows chkdsk is a real NTFS check. Do not mention remove_hiberfile.
- If the disk looks like it is failing, the preservation step is GNU ddrescue onto a different healthy disk. That WRITE waits for a person. Do not write to the failing disk. The rescue USB is too small for a big image.
- Quote a repair command only when the notes below support it, and keep the source and destination distinct.
- Lead with the conclusion. Do not repeat a point. On an ATA SMART table, RAW_VALUE is the counter. The VALUE column is a normalized score, not a percent and not the count.

Notes retrieved from the offline pack (incomplete by design):
EOF

mapfile -t kb_files < <(find "$KB" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' | sort)
if [[ ${#kb_files[@]} -eq 0 ]]; then
  printf '\n[knowledge pack directory is empty]\n'
  exit 0
fi

awk -f "$script_dir/kb-retrieve.awk" -v queryfile="$DIAG" -v maxbytes="$KB_BYTES" "${kb_files[@]}"
