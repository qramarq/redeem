#!/usr/bin/env bash
# Read-only storage diagnostics for redeem.
# Collects lsblk, blkid, smartctl -a, storage dmesg lines, efibootmgr -v,
# NTFS dirty-bit and BitLocker detection, and journalctl -p err.
# Nothing in this script writes to a block device. The only ntfsfix call is ntfsfix --no-action.
# BitLocker is detected and never unlocked.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: collect-diag.sh [--out FILE] [--max-bytes N]

Writes a trimmed diagnostic report. A fuller copy is saved beside it as
FILE with -full inserted before the extension. Default out is
/tmp/rescue-diag.txt and the default cap is 12000 bytes, sized for a
2k-4k token context once the knowledge pack and the reply are added.
EOF
}

OUT=${RESCUE_DIAG_OUT:-/tmp/rescue-diag.txt}
MAX_BYTES=12000

while [[ $# -gt 0 ]]; do
  case $1 in
    --out)
      OUT=${2:-}
      shift 2
      ;;
    --max-bytes)
      MAX_BYTES=${2:-}
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

if [[ ! $MAX_BYTES =~ ^[0-9]+$ || $MAX_BYTES -lt 500 ]]; then
  printf 'max-bytes must be an integer >= 500\n' >&2
  exit 2
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

as_root() {
  if [[ ${EUID} -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo -n "$@"
  else
    return 1
  fi
}

note() {
  printf '%s\n' "$*"
}

cap_file() {
  local file=$1 max=$2
  local size
  size=$(wc -c <"$file" | tr -d ' ')
  if ((size > max)); then
    head -c "$max" "$file" >"$file.trim"
    printf '\n[truncated]\n' >>"$file.trim"
    mv "$file.trim" "$file"
  fi
}

write_section() {
  local name=$1 src=$2 max=$3 dest=$4
  {
    printf '## %s\n' "$name"
    if [[ -s $src ]]; then
      cat "$src"
    else
      printf '(none)\n'
    fi
    printf '\n'
  } >"$dest"
  cap_file "$dest" "$max"
}

# --- host ---
{
  note "collected: $(date -Is 2>/dev/null || date)"
  note "uname: $(uname -a)"
  if [[ -r /proc/meminfo ]]; then
    awk '/MemTotal:|MemAvailable:/ {print}' /proc/meminfo
  fi
  if [[ -r /proc/cpuinfo ]]; then
    awk -F: '/^model name/ {gsub(/^ +/, "", $2); print "cpu:", $2; exit}' /proc/cpuinfo
    awk -F: '/^flags[[:space:]]*:/ {
      n = split($2, f, /[[:space:]]+/)
      isa = ""
      for (i = 1; i <= n; i++) {
        if (f[i] == "sse4_2" || f[i] == "avx" || f[i] == "avx2" || f[i] == "avx512f") {
          isa = isa " " f[i]
        }
      }
      print "isa:" isa
      exit
    }' /proc/cpuinfo
  fi
} >"$WORKDIR/host.txt"

# --- lsblk / blkid ---
if command -v lsblk >/dev/null 2>&1; then
  lsblk -o NAME,SIZE,TYPE,FSTYPE,FSVER,LABEL,UUID,RO,TRAN,MODEL,MOUNTPOINTS >"$WORKDIR/lsblk.txt" 2>&1 || true
else
  note "lsblk: not installed" >"$WORKDIR/lsblk.txt"
fi

if command -v blkid >/dev/null 2>&1; then
  if ! as_root blkid >"$WORKDIR/blkid.txt" 2>"$WORKDIR/blkid.err"; then
    blkid >"$WORKDIR/blkid.txt" 2>>"$WORKDIR/blkid.err" || true
  fi
  if [[ -s $WORKDIR/blkid.err ]]; then
    cat "$WORKDIR/blkid.err" >>"$WORKDIR/blkid.txt"
  fi
else
  note "blkid: not installed" >"$WORKDIR/blkid.txt"
fi

# --- disks for SMART ---
: >"$WORKDIR/disks.txt"
if command -v lsblk >/dev/null 2>&1; then
  while read -r name dtype; do
    [[ $dtype == disk ]] || continue
    case $name in
      loop* | zram* | ram* | fd* | nbd* | sr*) continue ;;
    esac
    printf '%s\n' "$name" >>"$WORKDIR/disks.txt"
  done < <(lsblk -dn -o NAME,TYPE)
fi

# --- smartctl -a, then a short extract ---
: >"$WORKDIR/smart-full.txt"
: >"$WORKDIR/smart.txt"
if ! command -v smartctl >/dev/null 2>&1; then
  note "smartctl: not installed (smartmontools)" >"$WORKDIR/smart.txt"
else
  if [[ ! -s $WORKDIR/disks.txt ]]; then
    note "no non-virtual disks listed by lsblk" >"$WORKDIR/smart.txt"
  fi
  while read -r name; do
    [[ -n $name ]] || continue
    dev=/dev/$name
    raw=$WORKDIR/smart-$name.txt
    if ! as_root timeout 25 smartctl -a "$dev" >"$raw" 2>&1; then
      printf 'smartctl exit nonzero for %s\n' "$dev" >>"$raw"
    fi
    {
      printf '### %s\n' "$dev"
      cat "$raw"
      printf '\n'
    } >>"$WORKDIR/smart-full.txt"
    {
      printf '### %s\n' "$dev"
      summary=$(awk '
        /^(Device Model:|Model Family:|Model Number:|Serial Number:|Firmware Version:|User Capacity:|Total NVM Capacity:|Namespace 1 Size\/Capacity:|SMART overall-health|SMART\/Health Information)/ { print; next }
        /^(Critical Warning:|Temperature:|Available Spare:|Available Spare Threshold:|Percentage Used:|Data Units Written:|Media and Data Integrity Errors:|Error Information Log Entries:|Warning  Comp. Temperature Time:|Power On Hours:)/ { print; next }
        /^ID#/ { print; keep = 1; next }
        /^$/ { keep = 0 }
        keep == 1 && ($1 ~ /^(5|9|187|188|194|196|197|198|199)$/) { print }
        /SMART overall-health self-assessment test result/ { print }
        /Unable to detect|SMART support is:|A mandatory SMART command failed|Read Device Identity failed/ { print }
      ' "$raw")
      if [[ -n $summary ]]; then
        printf '%s\n' "$summary"
      else
        head -n 20 "$raw"
      fi
      printf '\n'
    } >>"$WORKDIR/smart.txt"
  done <"$WORKDIR/disks.txt"
fi

# --- dmesg storage / IO ---
: >"$WORKDIR/dmesg-raw.txt"
if command -v dmesg >/dev/null 2>&1; then
  if ! as_root dmesg -T >"$WORKDIR/dmesg-raw.txt" 2>"$WORKDIR/dmesg.err"; then
    dmesg >"$WORKDIR/dmesg-raw.txt" 2>>"$WORKDIR/dmesg.err" || true
  fi
else
  note "dmesg: not installed" >"$WORKDIR/dmesg.err"
fi
if [[ -s $WORKDIR/dmesg-raw.txt ]]; then
  grep -Ei 'I/O error|buffer I/O|medium error|unrecovered read|ext4-fs error|ext4-fs \(.*\): warning|remounting filesystem read-only|xfs \(.*\): .*error|btrfs error|btrfs: error|hard resetting link|COMRESET|nvme .*timeout|nvme .*reset|blk_update_request|print_req_error|sense key|critical medium|UDMA CRC|unsafe shutdown|device descriptor read/64|not accepting address|uas_eh_abort' \
    "$WORKDIR/dmesg-raw.txt" >"$WORKDIR/dmesg.txt" || true
  if [[ ! -s $WORKDIR/dmesg.txt ]]; then
    note "no storage or filesystem error lines matched" >"$WORKDIR/dmesg.txt"
  fi
else
  note "dmesg unavailable" >"$WORKDIR/dmesg.txt"
  if [[ -s $WORKDIR/dmesg.err ]]; then
    cat "$WORKDIR/dmesg.err" >>"$WORKDIR/dmesg.txt"
  fi
fi

# --- efibootmgr ---
if command -v efibootmgr >/dev/null 2>&1; then
  if ! as_root efibootmgr -v >"$WORKDIR/efi.txt" 2>&1; then
    note "efibootmgr failed (often: not booted in EFI mode, or no efivarfs)" >>"$WORKDIR/efi.txt"
  fi
else
  note "efibootmgr: not installed" >"$WORKDIR/efi.txt"
fi

# --- partitions: NTFS dirty (read-only) and BitLocker signature ---
: >"$WORKDIR/parts.txt"
if command -v lsblk >/dev/null 2>&1; then
  while read -r name ptype fstype; do
    [[ $ptype == part ]] || continue
    case $name in
      loop* | zram* | ram*) continue ;;
    esac
    printf '%s %s\n' "$name" "${fstype:-unknown}" >>"$WORKDIR/parts.txt"
  done < <(lsblk -ln -o NAME,TYPE,FSTYPE)
fi

: >"$WORKDIR/ntfs.txt"
: >"$WORKDIR/bitlocker.txt"
while read -r name fstype; do
  [[ -n $name ]] || continue
  dev=/dev/$name
  fstype_lc=$(printf '%s' "$fstype" | tr '[:upper:]' '[:lower:]')

  sig=""
  if sig=$(as_root dd if="$dev" bs=1 skip=3 count=8 status=none 2>/dev/null); then
    :
  else
    sig=""
  fi

  if [[ $fstype_lc == bitlocker || $sig == "-FVE-FS-" ]]; then
    {
      printf '%s  BitLocker detected' "$dev"
      if [[ $sig == "-FVE-FS-" ]]; then
        printf ' (boot-sector signature -FVE-FS- at offset 3)'
      fi
      if [[ $fstype_lc == bitlocker ]]; then
        printf ' (blkid TYPE=BitLocker)'
      fi
      printf '\n'
      printf 'read-only: volume stays locked. Do not unlock it from this toolkit.\n'
    } >>"$WORKDIR/bitlocker.txt"
    continue
  fi

  if [[ $fstype_lc == crypto_luks ]]; then
    printf '%s  crypto_LUKS (Linux disk encryption). Detect only. Do not open.\n' "$dev" >>"$WORKDIR/bitlocker.txt"
    continue
  fi

  if [[ $fstype_lc == ntfs ]]; then
    {
      printf '### %s\n' "$dev"
      if command -v ntfsinfo >/dev/null 2>&1; then
        as_root ntfsinfo -m "$dev" 2>&1 | awk '
          BEGIN { n = 0 }
          /Volume Flags|Dirty|DIRTY|hibernat|Hibernat|Volume Name|Serial Number|Volume State/ { print; n++ }
          n >= 20 { exit }
        ' || true
      else
        note "ntfsinfo: not installed"
      fi
      if command -v ntfsfix >/dev/null 2>&1; then
        note "ntfsfix --no-action (read-only dry run):"
        as_root ntfsfix --no-action "$dev" 2>&1 || true
      else
        note "ntfsfix: not installed"
      fi
      printf '\n'
    } >>"$WORKDIR/ntfs.txt"
  fi
done <"$WORKDIR/parts.txt"

if command -v dislocker-find >/dev/null 2>&1; then
  # Exit status is the number of BitLocker volumes found, not success/failure.
  dislocker_out=$WORKDIR/dislocker.txt
  as_root dislocker-find >"$dislocker_out" 2>&1 || true
  if [[ -s $dislocker_out ]]; then
    if grep -Eq 'Error|Traceback|NoMethodError|exception' "$dislocker_out"; then
      note "dislocker-find failed to run. BitLocker detection used blkid and the -FVE-FS- signature instead." >>"$WORKDIR/bitlocker.txt"
    else
      {
        note "dislocker-find (lists volumes, does not decrypt):"
        cat "$dislocker_out"
      } >>"$WORKDIR/bitlocker.txt"
    fi
  fi
else
  note "dislocker-find: not installed" >>"$WORKDIR/bitlocker.txt"
fi

if [[ ! -s $WORKDIR/ntfs.txt ]]; then
  note "no NTFS partitions seen" >"$WORKDIR/ntfs.txt"
fi
if [[ ! -s $WORKDIR/bitlocker.txt ]]; then
  note "no BitLocker signature and no crypto_LUKS partition seen" >"$WORKDIR/bitlocker.txt"
fi

# --- journalctl -p err ---
if command -v journalctl >/dev/null 2>&1; then
  if ! as_root journalctl -p err -b --no-pager -n 40 -o short-iso >"$WORKDIR/journal.txt" 2>&1; then
    note "journalctl failed" >>"$WORKDIR/journal.txt"
  fi
else
  note "journalctl: not installed" >"$WORKDIR/journal.txt"
fi

# Keep the untrimmed bundle, capped so a noisy disk cannot fill /tmp.
{
  printf '# redeem diagnostics full (read-only, no repairs applied)\n\n'
  for src in host.txt lsblk.txt blkid.txt smart-full.txt dmesg.txt efi.txt ntfs.txt bitlocker.txt journal.txt; do
    printf '## %s\n' "${src%.txt}"
    cat "$WORKDIR/$src" 2>/dev/null || true
    printf '\n'
  done
} >"$WORKDIR/full.txt"
cap_file "$WORKDIR/full.txt" 1048576

# Trimmed report. Per-section caps sum to about the caller's budget.
host_b=700
lsblk_b=1600
blkid_b=1000
smart_b=3200
dmesg_b=1600
efi_b=1200
ntfs_b=1400
bit_b=900
journal_b=1000

write_section host "$WORKDIR/host.txt" "$host_b" "$WORKDIR/sec-host.txt"
write_section lsblk "$WORKDIR/lsblk.txt" "$lsblk_b" "$WORKDIR/sec-lsblk.txt"
write_section blkid "$WORKDIR/blkid.txt" "$blkid_b" "$WORKDIR/sec-blkid.txt"
write_section smart "$WORKDIR/smart.txt" "$smart_b" "$WORKDIR/sec-smart.txt"
write_section dmesg "$WORKDIR/dmesg.txt" "$dmesg_b" "$WORKDIR/sec-dmesg.txt"
write_section efibootmgr "$WORKDIR/efi.txt" "$efi_b" "$WORKDIR/sec-efi.txt"
write_section ntfs "$WORKDIR/ntfs.txt" "$ntfs_b" "$WORKDIR/sec-ntfs.txt"
write_section bitlocker "$WORKDIR/bitlocker.txt" "$bit_b" "$WORKDIR/sec-bitlocker.txt"
write_section journal "$WORKDIR/journal.txt" "$journal_b" "$WORKDIR/sec-journal.txt"

{
  printf '# redeem diagnostics (read-only, no repairs applied)\n'
  printf '# cap: %s bytes\n\n' "$MAX_BYTES"
  # Important sections first so a hard cap drops the journal, not SMART.
  cat \
    "$WORKDIR/sec-smart.txt" \
    "$WORKDIR/sec-dmesg.txt" \
    "$WORKDIR/sec-ntfs.txt" \
    "$WORKDIR/sec-bitlocker.txt" \
    "$WORKDIR/sec-efi.txt" \
    "$WORKDIR/sec-lsblk.txt" \
    "$WORKDIR/sec-blkid.txt" \
    "$WORKDIR/sec-host.txt" \
    "$WORKDIR/sec-journal.txt"
} >"$WORKDIR/trimmed.txt"

# Final hard cap. Drop the journal and then dmesg first if we are over,
# by cutting the already-capped file from the end.
size=$(wc -c <"$WORKDIR/trimmed.txt" | tr -d ' ')
if ((size > MAX_BYTES)); then
  head -c "$MAX_BYTES" "$WORKDIR/trimmed.txt" >"$WORKDIR/trimmed.txt.cut"
  printf '\n[report truncated to %s bytes]\n' "$MAX_BYTES" >>"$WORKDIR/trimmed.txt.cut"
  mv "$WORKDIR/trimmed.txt.cut" "$WORKDIR/trimmed.txt"
fi

mkdir -p "$(dirname -- "$OUT")"
cp "$WORKDIR/trimmed.txt" "$OUT"
full_out=${OUT%.txt}-full.txt
if [[ $full_out == "$OUT" ]]; then
  full_out=$OUT.full
fi
cp "$WORKDIR/full.txt" "$full_out"
printf 'wrote %s (%s bytes) and %s\n' "$OUT" "$(wc -c <"$OUT" | tr -d ' ')" "$full_out"
