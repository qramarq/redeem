#!/usr/bin/env bash
# Read-only BitLocker inspection and file rescue.
# Unlock mounts are read-only. A recovery password is read from /dev/tty
# and is never accepted on the command line, written under /tmp/redeem, or logged.
#
# Header dump flags checked against cryptsetup 2.8.7 (cryptsetup-bitlkDump(8)
# and action_open_bitlk) and dislocker 0.7.3 (dislocker -h / dislocker-fuse(1)):
#   cryptsetup bitlkDump DEVICE
#   cryptsetup open --type bitlk --readonly --key-file=-|--key-file FILE
#   dislocker -r -V DEVICE --clearkey|--recovery-password|--user-password|-f FILE -- MNT
# This helper does not pass dislocker -k/--fvek or -K/--vmk, and it does not
# run dislocker-file (that writes a full plaintext image).
set -euo pipefail

SECRET=
DRY=0
CLEAR=0
BEK=
FIXTURE=
SMART_FORCE=
MODE=
POS1=
POS2=
PARSED=
declare -a tmpfiles=()

usage() {
  cat <<'EOF'
usage: rescue-bitlocker.sh <command> [options] [device] [mountpoint]

commands:
  inspect, status   Read-only header report. No key is requested.
  unlock            Map and mount read-only.
  lock              Unmount and close the mapper or dislocker mount.
  parse-dump        Print protector records for a fixture (test hook).

unlock methods (pick one):
  (default)         Prompt on /dev/tty. cryptsetup reads the secret on stdin
                    (--key-file=-). dislocker prompts on its own tty if needed.
  --clearkey        Suspended BitLocker / clear key. No secret.
  --bek FILE        External startup key (.bek). The path is not a secret.

options:
  --dry-run         Print the read-only commands. Do not open a device.
  --fixture FILE    Parse this bitlkDump or dislocker-metadata text.
  --smart-health    passed, failed, or unknown. Skips smartctl (tests).
  --readonly, -r    Accepted and ignored. Mounts are always read-only.

Refused: --rw, --password, --key, a 48-digit recovery password argument,
and any option that would dump a volume key. cryptsetup 2.3 or newer supplies
bitlkDump and open --type bitlk (SystemRescue 13.02 has 2.8.7). Older hosts
fall back to dislocker -r and mount -o loop,ro,nodev,nosuid,noexec.
EOF
}

die() {
  printf 'redeem-bitlocker: %s\n' "$*" >&2
  exit 1
}

refuse() {
  printf 'redeem-bitlocker: %s\n' "$*" >&2
  exit 2
}

wipe_secret() {
  set +x
  if [[ -n ${SECRET+x} ]]; then
    SECRET=
    unset SECRET
  fi
}

cleanup() {
  wipe_secret
  if ((${#tmpfiles[@]})); then
    rm -f "${tmpfiles[@]}"
  fi
}
trap cleanup EXIT

new_tmp() {
  local f
  f=$(mktemp)
  tmpfiles+=("$f")
  printf '%s\n' "$f"
}

forbid_secrets() {
  local arg
  for arg in "$@"; do
    case $arg in
      --rw | --read-write | --write | -w)
        refuse "read-write BitLocker mounts are refused. Linux unlock stays read-only."
        ;;
      --key | --password | --passphrase | --recovery-password | --user-password | -p | -u)
        refuse "refusing ${arg}. Type the secret at the local /dev/tty prompt. It is not accepted on the command line."
        ;;
      --key=* | --password=* | --passphrase=* | --recovery-password=* | --user-password=*)
        refuse "refusing a secret attached to ${arg%%=*}. It was not used."
        ;;
      --key-file | --key-file=*)
        refuse "refusing --key-file. Use --bek PATH for a .bek file, or type a passphrase at the local prompt."
        ;;
      --dump-volume-key | --volume-key-file | --volume-key-file=* | --master-key-file | --master-key-file=*)
        refuse "refusing a volume-key option. Header inspection does not dump key material."
        ;;
      -p* | -u*)
        refuse "refusing ${arg%%=*}. A password is not accepted on the command line."
        ;;
    esac
    if [[ $arg =~ ^[0-9]{6}(-[0-9]{6}){7}$ ]]; then
      refuse "refusing a recovery-password-shaped argument. It was not used."
    fi
  done
}

version_at_least() {
  local min=$1 got=$2
  local IFS=.
  local -a need have
  read -r -a need <<<"${min}"
  read -r -a have <<<"${got}"
  local i nv hv
  for i in 0 1 2; do
    nv=${need[$i]:-0}
    hv=${have[$i]:-0}
    if ((10#$hv > 10#$nv)); then
      return 0
    fi
    if ((10#$hv < 10#$nv)); then
      return 1
    fi
  done
  return 0
}

cryptsetup_version() {
  cryptsetup --version 2>/dev/null | awk 'NR == 1 { print $2; exit }'
}

cryptsetup_supports_bitlk() {
  # Dry-run only prints commands. Do not exec cryptsetup, even for --version.
  if [[ $DRY -eq 1 ]]; then
    return 0
  fi
  command -v cryptsetup >/dev/null 2>&1 || return 1
  local ver
  ver=$(cryptsetup_version)
  [[ -n $ver ]] || return 1
  version_at_least 2.3 "$ver"
}

scrub_text() {
  sed -E \
    -e 's/[0-9]{6}(-[0-9]{6}){7}/[redacted]/g' \
    -e '/[Ss]alt:/d' \
    -e '/^[[:space:]]*Key:[[:space:]]*$/d' \
    -e '/^[[:space:]]*[0-9A-Fa-f]{32,}[[:space:]]*$/d'
}

parse_dump_file() {
  local src=$1 dest=$2 prog
  prog=$(new_tmp)
  cat >"$prog" <<'EOF'
function prefix(guid,    hex, i, c) {
  hex = ""
  gsub(/[{}]/, "", guid)
  for (i = 1; i <= length(guid); i++) {
    c = substr(guid, i, 1)
    if (c ~ /[0-9A-Fa-f]/) hex = hex c
  }
  return toupper(substr(hex, 1, 8))
}

function emit() {
  if (guid == "") return
  gsub(/[{}]/, "", guid)
  id = prefix(guid)
  if (ptype == "") ptype = "unknown"
  if (ptype == "clear-key") clear = 1
  printf "protector\t%s\t%s\t%s\n", id, guid, ptype
  guid = ""
  ptype = ""
}

function grab_guid(line) {
  if (match(line, /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/))
    return substr(line, RSTART, RLENGTH)
  return ""
}

BEGIN { clear = 0; in_slot = 0; in_vmk = 0 }

{
  sub(/\r$/, "")
  sub(/^[[:space:]]+/, "")
}

/^Info for BITLK/ { source = "cryptsetup-bitlkDump"; next }
/dislocker-metadata/ { if (source == "") source = "dislocker-metadata"; next }

/^Version:/ {
  sub(/^Version:[[:space:]]*/, "")
  version = $0
  next
}
/^Description:/ {
  sub(/^Description:[[:space:]]*/, "")
  description = $0
  next
}
/^Created:/ {
  sub(/^Created:[[:space:]]*/, "")
  created = $0
  next
}
/^Cipher name:/ {
  sub(/^Cipher name:[[:space:]]*/, "")
  cipher = $0
  next
}
/^Cipher mode:/ {
  sub(/^Cipher mode:[[:space:]]*/, "")
  cipher_mode = $0
  next
}
/^Cipher key:/ {
  if (match($0, /[0-9]+/)) bits = substr($0, RSTART, RLENGTH)
  next
}
/Encryption Type:/ {
  sub(/^.*Encryption Type:[[:space:]]*/, "")
  sub(/[[:space:]]*\(.*/, "")
  if (cipher == "") cipher = $0
  next
}
/Epoch Timestamp:/ && created == "" {
  if (match($0, /that to say /)) created = substr($0, RSTART + 12)
  else if (match($0, /being /)) created = substr($0, RSTART + 6)
  next
}
/Dataset GUID:/ {
  g = grab_guid($0)
  if (g != "" && volume_guid == "") volume_guid = g
  next
}
/^[0-9]+: VMK$/ { emit(); in_slot = 1; next }
/^[0-9]+: FVEK$/ { emit(); in_slot = 0; next }
/ENTRY TYPE VMK/ {
  if (source == "") source = "dislocker-metadata"
  emit()
  in_vmk = 1
  next
}
/\[\* Recovery Key GUID \*\]/ {
  g = grab_guid($0)
  if (g != "") { guid = g; ptype = "recovery-password" }
  next
}
/Recovery Key GUID:/ {
  g = grab_guid($0)
  if (g != "" && guid == "") guid = g
  next
}
/^Protection:/ {
  prot = $0
  sub(/^Protection:[[:space:]]*/, "", prot)
  if (prot ~ /clear key/) ptype = "clear-key"
  else if (prot ~ /TPM and PIN/) ptype = "tpm-pin"
  else if (prot ~ /with TPM/) ptype = "tpm"
  else if (prot ~ /startup key/) ptype = "external-key"
  else if (prot ~ /recovery passphrase/) ptype = "recovery-password"
  else if (prot ~ /with passphrase/) ptype = "passphrase"
  else if (prot ~ /smart card/) ptype = "smart-card"
  else ptype = "unknown"
  next
}
/`--> KEY$/ { if ((in_vmk || guid != "") && ptype == "") ptype = "clear-key"; next }
/`--> TPM_ENCODED/ { if (ptype == "" || ptype == "passphrase") ptype = "tpm"; next }
/`--> EXTERNAL KEY/ { if (ptype == "" || ptype == "passphrase") ptype = "external-key"; next }
/`--> STRETCH KEY/ { if (ptype == "") ptype = "passphrase"; next }
/^Salt:/ { next }
/^Key data size:/ { next }
/^GUID:/ {
  g = grab_guid($0)
  if (g == "") next
  if (in_slot) guid = g
  else if (volume_guid == "") volume_guid = g
  next
}

END {
  emit()
  if (source == "") source = "unparsed"
  printf "source\t%s\n", source
  printf "version\t%s\n", version
  printf "cipher\t%s\n", cipher
  printf "cipher_mode\t%s\n", cipher_mode
  printf "cipher_key_bits\t%s\n", bits
  printf "description\t%s\n", description
  printf "created\t%s\n", created
  printf "volume_guid\t%s\n", volume_guid
  printf "clear_key\t%s\n", (clear ? "yes" : "no")
}
EOF
  awk -f "$prog" "$src" >"$dest"
}

capture_header() {
  local dev=$1 dest=$2 err ran=0
  err=$(new_tmp)
  : >"$dest"
  if cryptsetup_supports_bitlk; then
    ran=1
    if command -v timeout >/dev/null 2>&1; then
      timeout 20 cryptsetup bitlkDump "$dev" >"$dest" 2>"$err" || true
    else
      cryptsetup bitlkDump "$dev" >"$dest" 2>"$err" || true
    fi
  fi
  if ! grep -q 'Info for BITLK' "$dest" && command -v dislocker-metadata >/dev/null 2>&1; then
    ran=1
    dislocker-metadata -v -V "$dev" >"$dest" 2>"$err" || true
  fi
  if [[ $ran -eq 0 ]]; then
    printf 'cryptsetup >= 2.3 and dislocker-metadata are not installed\n' >"$dest"
  fi
  if ! grep -q -E 'Info for BITLK|dislocker-metadata|ENTRY TYPE VMK|Version:' "$dest"; then
    {
      printf 'header tools failed\n'
      scrub_text <"$err" | head -n 15
    } >"$dest"
  fi
}

load_machine() {
  local dev=${1:-} raw
  raw=$(new_tmp)
  PARSED=$(new_tmp)
  if [[ -n $FIXTURE ]]; then
    [[ -f $FIXTURE ]] || die "fixture not found"
    cp -- "$FIXTURE" "$raw"
  elif [[ $DRY -eq 1 ]]; then
    printf 'dry-run: cryptsetup bitlkDump %q\n' "$dev"
    printf 'dry-run: dislocker-metadata -v -V %q\n' "$dev"
    printf 'header was not read\n'
    return 2
  else
    [[ -n $dev ]] || die "inspect needs a device or --fixture"
    capture_header "$dev" "$raw"
  fi
  parse_dump_file "$raw" "$PARSED"
  return 0
}

smart_health() {
  local dev=${1:-} parent line
  if [[ -n $SMART_FORCE ]]; then
    case $SMART_FORCE in
      passed | failed | unknown) printf '%s\n' "$SMART_FORCE" ;;
      *) die "--smart-health must be passed, failed, or unknown" ;;
    esac
    return 0
  fi
  if [[ -n $FIXTURE || -z $dev ]]; then
    printf 'unknown\n'
    return 0
  fi
  if ! command -v smartctl >/dev/null 2>&1; then
    printf 'unknown\n'
    return 0
  fi
  parent=
  if command -v lsblk >/dev/null 2>&1; then
    parent=$(lsblk -no PKNAME -- "$dev" 2>/dev/null | awk 'NR == 1 { print; exit }')
  fi
  if [[ -z $parent ]]; then
    parent=$(basename -- "$dev")
  fi
  line=$(smartctl -H "/dev/$parent" 2>/dev/null || true)
  if grep -qi 'FAILED' <<<"$line"; then
    printf 'failed\n'
  elif grep -Eqi 'PASSED|Health Status: OK' <<<"$line"; then
    printf 'passed\n'
  else
    printf 'unknown\n'
  fi
}

firmware_notes() {
  local var val bytes tpm
  printf 'firmware:\n'
  local found=0
  for var in /sys/firmware/efi/efivars/SecureBoot-*; do
    [[ -e $var ]] || continue
    found=1
    if bytes=$(od -An -t u1 -- "$var" 2>/dev/null); then
      val=$(awk '{ print $NF }' <<<"$bytes")
      if [[ $val == 1 ]]; then
        printf '  Secure Boot: enabled\n'
      elif [[ $val == 0 ]]; then
        printf '  Secure Boot: disabled\n'
      else
        printf '  Secure Boot: present, value not 0 or 1\n'
      fi
    else
      printf '  Secure Boot: EFI variable is not readable\n'
    fi
  done
  if [[ $found -eq 0 ]]; then
    printf '  Secure Boot: EFI variable not found (not UEFI, or efivarfs is absent)\n'
  fi
  if command -v mokutil >/dev/null 2>&1; then
    mokutil --sb-state 2>&1 | sed 's/^/  /' || true
  fi
  found=0
  for tpm in /sys/class/tpm/tpm*; do
    [[ -e $tpm ]] || continue
    found=1
    printf '  TPM device: %s\n' "$tpm"
    if [[ -r $tpm/tpm_version_major ]]; then
      printf '  tpm_version_major: %s\n' "$(cat "$tpm/tpm_version_major")"
    fi
  done
  if [[ $found -eq 0 ]]; then
    printf '  TPM: no device under /sys/class/tpm\n'
  fi
  if command -v efibootmgr >/dev/null 2>&1; then
    printf '  efibootmgr -v (read-only):\n'
    efibootmgr -v 2>&1 | head -n 40 | sed 's/^/    /' || true
  else
    printf '  efibootmgr: not installed\n'
  fi
}

print_report() {
  local dev=${1:-} health source version cipher cipher_mode bits description created volume_guid clear
  local -a ids=() types=() guids=()
  source='' version='' cipher='' cipher_mode='' bits='' description='' created='' volume_guid='' clear=''
  local key a b c
  while IFS=$'\t' read -r key a b c || [[ -n ${key:-} ]]; do
    [[ -n ${key:-} ]] || continue
    case $key in
      source) source=$a ;;
      version) version=$a ;;
      cipher) cipher=$a ;;
      cipher_mode) cipher_mode=$a ;;
      cipher_key_bits) bits=$a ;;
      description) description=$a ;;
      created) created=$a ;;
      volume_guid) volume_guid=$a ;;
      clear_key) clear=$a ;;
      protector)
        ids+=("$a")
        guids+=("$b")
        types+=("$c")
        ;;
    esac
  done <"$PARSED"
  if [[ $source == unparsed || -z $source ]]; then
    die "no BitLocker header recognized"
  fi
  health=$(smart_health "$dev")
  printf 'source: %s\n' "$source"
  if [[ -n $dev ]]; then
    printf 'device: %s\n' "$dev"
  elif [[ -n $FIXTURE ]]; then
    printf 'device: (fixture)\n'
  fi
  printf 'version: %s\n' "${version:-unknown}"
  printf 'cipher: %s\n' "${cipher:-unknown}"
  printf 'cipher_mode: %s\n' "${cipher_mode:-unknown}"
  printf 'cipher_key_bits: %s\n' "${bits:-unknown}"
  printf 'description: %s\n' "${description:-unknown}"
  printf 'created: %s\n' "${created:-unknown}"
  printf 'volume_guid: %s\n' "${volume_guid:-unknown}"
  printf 'clear_key: %s\n' "${clear:-no}"
  printf 'smart_health: %s\n' "$health"
  local i has_recovery=0 has_tpm=0 has_external=0 has_pass=0
  if [[ ${#ids[@]} -eq 0 ]]; then
    printf 'protectors: none\n'
  fi
  for i in "${!ids[@]}"; do
    printf 'key_id: %s guid: %s type: %s\n' "${ids[$i]}" "${guids[$i]}" "${types[$i]}"
    case ${types[$i]} in
      recovery-password) has_recovery=1 ;;
      tpm | tpm-pin) has_tpm=1 ;;
      external-key) has_external=1 ;;
      passphrase) has_pass=1 ;;
    esac
  done
  printf '\n'
  if [[ $clear == yes ]]; then
    cat <<EOF
Clear key: yes. This volume is suspended, or OEM device encryption is still using a clear key (Windows Update, a BIOS update, or a device that was never activated). Mount it read-only now. No recovery key is required:

  redeem-bitlocker unlock --clearkey ${dev:-DEVICE} [MOUNTPOINT]

cryptsetup 2.8 tries a null passphrase first inside open --type bitlk, which uses the clear key when it is present, then stops. This helper passes an empty --key-file so a missing clear key does not fall through to a prompt. The dislocker fallback is: dislocker -r -V DEVICE --clearkey -- MOUNT
EOF
  else
    cat <<EOF
Clear key: no. --clearkey will not open this volume.
EOF
  fi
  if [[ $has_recovery -eq 1 || $has_external -eq 1 || $has_pass -eq 1 ]]; then
    printf '\nKey protector IDs (first 8 hex characters of the protector GUID):\n'
    for i in "${!ids[@]}"; do
      case ${types[$i]} in
        recovery-password | external-key | passphrase)
          printf '  %s  %s\n' "${ids[$i]}" "${types[$i]}"
          ;;
      esac
    done
    cat <<'EOF'

Match a recovery-password id at https://account.microsoft.com/devices/recoverykey
Also check Microsoft Entra ID, on-premises Active Directory, a printed or PDF copy, and USB .bek files.
Do not paste the 48-digit password into an AI chat. Type it at the local prompt:

  redeem-bitlocker unlock DEVICE [MOUNTPOINT]

A .bek file is:

  redeem-bitlocker unlock --bek /path/to/file.bek DEVICE [MOUNTPOINT]
EOF
  fi
  if [[ $has_tpm -eq 1 && $clear != yes ]]; then
    cat <<'EOF'

TPM protector: cryptsetup and dislocker cannot use the TPM from this Linux session.
If Windows started asking for a recovery key after a firmware change, restore Secure Boot, turn CSM/Legacy back off, and restore the boot order. Then boot the internal disk, not this USB. TPM-only BitLocker unlocks itself when the firmware matches.
Do not leave Secure Boot disabled unless the owner already has the recovery key.
EOF
  fi
  printf '\n'
  case $health in
    failed)
      cat <<'EOF'
SMART health: failed. The disk under this volume looks like it is failing. Copy files off with a read-only mount. Do not run manage-bde -off. In-place decryption rewrites every encrypted sector.
EOF
      ;;
    passed)
      cat <<'EOF'
SMART health: passed. After the volume is unlocked, Windows or Hiren's BootCD PE can remove BitLocker with manage-bde -off (BitLocker-Windows.bat remove). That WRITE waits until someone types the confirmation phrase.
EOF
      ;;
    *)
      cat <<'EOF'
SMART health: unknown. Do not run manage-bde -off until smartctl or Windows says the disk is healthy. Copy files read-only first if you are unsure.
EOF
      ;;
  esac
  cat <<'EOF'

A sector clone (ddrescue or Clonezilla) stays encrypted. Do not run ntfsfix, fsck, or chkdsk on a locked BitLocker partition. This stick cannot crack or bypass BitLocker AES.
Linux cannot convert the volume to plain NTFS. Permanent removal is manage-bde -off on a healthy disk, from Windows or from Hiren's BootCD PE on the Ventoy menu.
EOF
  if [[ -z $FIXTURE && $DRY -eq 0 ]]; then
    printf '\n'
    firmware_notes
  fi
}

state_dir() {
  if [[ -d /run && -w /run ]]; then
    printf '/run/redeem-bitlocker\n'
  else
    printf '%s/redeem-bitlocker-state\n' "${TMPDIR:-/tmp}"
  fi
}

mapper_name() {
  local base
  base=$(basename -- "$1")
  base=${base//[^A-Za-z0-9]/_}
  printf 'redeembl_%s\n' "$base"
}

mount_ro() {
  local src=$1 dest=$2 kind=$3
  local -a opts
  if [[ $kind == loop ]]; then
    opts=(-o "loop,ro,nodev,nosuid,noexec")
  else
    opts=(-o "ro,nodev,nosuid,noexec")
  fi
  local joined
  joined="${opts[*]}"
  case $joined in
    *rw*) die "internal error: read-write mount blocked" ;;
  esac
  case $joined in
    *ro*) ;;
    *) die "internal error: mount is not read-only" ;;
  esac
  if [[ $DRY -eq 1 ]]; then
    printf 'dry-run: mount -o %s %q %q\n' "${opts[1]}" "$src" "$dest"
    return 0
  fi
  mkdir -p -- "$dest"
  mount "${opts[@]}" "$src" "$dest"
}

write_state() {
  local dev=$1 name=$2 mnt=$3 fuse=$4 method=$5 dir file
  [[ $DRY -eq 1 ]] && return 0
  dir=$(state_dir)
  case $dir in
    /tmp/redeem | /tmp/redeem/*) die "refusing to store state under /tmp/redeem" ;;
  esac
  mkdir -p -- "$dir"
  chmod 700 "$dir"
  file=$dir/$name.state
  umask 077
  cat >"$file" <<EOF
device=${dev}
mapper=${name}
mountpoint=${mnt}
fuse=${fuse}
method=${method}
EOF
  chmod 600 "$file"
  printf 'state: %s\n' "$file"
}

need_root() {
  [[ $DRY -eq 1 ]] && return 0
  if [[ ${EUID} -ne 0 ]]; then
    die "root is required to open a read-only mapper. Nothing was opened."
  fi
}

check_bek() {
  [[ -n $BEK ]] || return 0
  case $BEK in
    /dev | /dev/*) refuse "a .bek path must be a regular file, not a device node" ;;
  esac
  if [[ $DRY -eq 0 ]]; then
    [[ -f $BEK ]] || die "bek file not found"
    if [[ -b $BEK || -c $BEK ]]; then
      refuse "bek path is a device node"
    fi
  fi
}

prompt_secret() {
  set +x
  if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    die "need /dev/tty to read a BitLocker secret locally"
  fi
  printf '%s' "$1" >/dev/tty
  IFS= read -r -s SECRET </dev/tty || true
  printf '\n' >/dev/tty
  if [[ -z ${SECRET:-} ]]; then
    refuse "empty secret. Nothing was sent to cryptsetup or dislocker."
  fi
  printf 'Read %s characters from /dev/tty. The value is not stored.\n' "${#SECRET}" >/dev/tty
}

open_cryptsetup_stdin() {
  local dev=$1 name=$2 rc=0
  set +x
  printf '%s' "$SECRET" | cryptsetup open --type bitlk --readonly --key-file=- --tries=1 --batch-mode "$dev" "$name" || rc=$?
  wipe_secret
  return "$rc"
}

open_cryptsetup_keyfile() {
  local dev=$1 name=$2 file=$3
  cryptsetup open --type bitlk --readonly --key-file="$file" --tries=1 --batch-mode "$dev" "$name"
}

dislocker_mount() {
  local dev=$1 fuse=$2 mode=$3
  local -a cmd
  case $mode in
    clearkey) cmd=(dislocker -r -V "$dev" --clearkey -- "$fuse") ;;
    bek) cmd=(dislocker -r -V "$dev" -f "$BEK" -- "$fuse") ;;
    recovery) cmd=(dislocker -r -V "$dev" --recovery-password -- "$fuse") ;;
    user) cmd=(dislocker -r -V "$dev" --user-password -- "$fuse") ;;
    *) die "unknown dislocker mode" ;;
  esac
  if [[ $DRY -eq 1 ]]; then
    printf 'dry-run:'
    printf ' %q' "${cmd[@]}"
    printf '\n'
    return 0
  fi
  mkdir -p -- "$fuse"
  "${cmd[@]}"
}

cmd_parse_dump() {
  local src
  if [[ -n $FIXTURE ]]; then
    src=$FIXTURE
  elif [[ -n $POS1 ]]; then
    src=$POS1
  else
    src=$(new_tmp)
    cat >"$src"
  fi
  [[ -f $src ]] || die "parse-dump needs --fixture or a file"
  PARSED=$(new_tmp)
  parse_dump_file "$src" "$PARSED"
  scrub_text <"$PARSED"
  if ! grep -q $'^source\t' "$PARSED"; then
    die "parser produced no record"
  fi
  if grep -q $'^source\tunparsed$' "$PARSED"; then
    die "no BitLocker header recognized"
  fi
}

cmd_inspect() {
  local dev=${POS1:-}
  if [[ -z $dev && -z $FIXTURE ]]; then
    die "inspect needs a device or --fixture"
  fi
  if [[ -n $dev ]]; then
    case $dev in
      *$'\n'*) die "invalid device path" ;;
    esac
  fi
  local rc=0
  load_machine "$dev" || rc=$?
  if [[ $rc -eq 2 ]]; then
    return 0
  fi
  print_report "$dev"
}

unlock_with_cryptsetup() {
  local dev=$1 name=$2 mnt=$3 mode=$4 empty rc
  if ! cryptsetup_supports_bitlk; then
    return 1
  fi
  if [[ $DRY -eq 1 ]]; then
    case $mode in
      clearkey)
        printf 'dry-run: cryptsetup open --type bitlk --readonly --key-file=<empty-file> --tries=1 --batch-mode %q %q\n' "$dev" "$name"
        ;;
      bek)
        printf 'dry-run: cryptsetup open --type bitlk --readonly --key-file=%q --tries=1 --batch-mode %q %q\n' "$BEK" "$dev" "$name"
        ;;
      pass)
        printf 'dry-run: cryptsetup open --type bitlk --readonly --key-file=- --tries=1 --batch-mode %q %q\n' "$dev" "$name"
        ;;
    esac
    mount_ro "/dev/mapper/$name" "$mnt" plain
    return 0
  fi
  case $mode in
    clearkey)
      empty=$(new_tmp)
      : >"$empty"
      open_cryptsetup_keyfile "$dev" "$name" "$empty" || return $?
      ;;
    bek)
      open_cryptsetup_keyfile "$dev" "$name" "$BEK" || return $?
      ;;
    pass)
      prompt_secret "BitLocker recovery password or passphrase (input stays on this terminal): "
      rc=0
      open_cryptsetup_stdin "$dev" "$name" || rc=$?
      [[ $rc -eq 0 ]] || return "$rc"
      ;;
  esac
  if ! mount_ro "/dev/mapper/$name" "$mnt" plain; then
    cryptsetup close "$name" 2>/dev/null || true
    die "read-only mount failed. The mapper was closed."
  fi
  write_state "$dev" "$name" "$mnt" "" cryptsetup
  printf 'mounted read-only: %s\n' "$mnt"
}

unlock_with_dislocker() {
  local dev=$1 name=$2 mnt=$3 mode=$4 fuse dir
  command -v dislocker >/dev/null 2>&1 || return 1
  dir=$(state_dir)
  fuse=$dir/fuse-$name
  if [[ $mode == pass && $DRY -eq 0 ]]; then
    printf 'cryptsetup did not open the volume. dislocker will prompt on this terminal. The secret is not passed on its command line.\n' >/dev/tty
    if dislocker_mount "$dev" "$fuse" recovery; then
      :
    elif dislocker_mount "$dev" "$fuse" user; then
      :
    else
      return 1
    fi
  else
    local which=$mode
    [[ $mode == pass ]] && which=recovery
    dislocker_mount "$dev" "$fuse" "$which" || return 1
  fi
  if [[ $DRY -eq 1 ]]; then
    mount_ro "$fuse/dislocker-file" "$mnt" loop
    return 0
  fi
  mount_ro "$fuse/dislocker-file" "$mnt" loop
  write_state "$dev" "$name" "$mnt" "$fuse" dislocker
  printf 'mounted read-only: %s\n' "$mnt"
}

cmd_unlock() {
  local dev=${POS1:-} mnt=${POS2:-/mnt/redeem-bitlocker} name mode
  [[ -n $dev ]] || die "unlock needs a device"
  case $dev in
    *$'\n'*) die "invalid device path" ;;
  esac
  case $mnt in
    /dev | /dev/*) refuse "refusing to mount onto a /dev path" ;;
    *$'\n'*) die "invalid mount path" ;;
  esac
  if [[ $CLEAR -eq 1 && -n $BEK ]]; then
    refuse "use either --clearkey or --bek, not both"
  fi
  check_bek
  if [[ $CLEAR -eq 1 ]]; then
    mode=clearkey
  elif [[ -n $BEK ]]; then
    mode=bek
  else
    mode=pass
  fi
  name=$(mapper_name "$dev")
  need_root
  if [[ $DRY -eq 0 ]]; then
    local health
    health=$(smart_health "$dev")
    if [[ $health == failed ]]; then
      printf 'warning: SMART health failed. The mount stays read-only. Copy files off. Do not run manage-bde -off.\n' >&2
    fi
  fi
  if [[ $DRY -eq 1 ]]; then
    unlock_with_cryptsetup "$dev" "$name" "$mnt" "$mode" || true
    unlock_with_dislocker "$dev" "$name" "$mnt" "$mode" || true
    return 0
  fi
  if unlock_with_cryptsetup "$dev" "$name" "$mnt" "$mode"; then
    return 0
  fi
  if unlock_with_dislocker "$dev" "$name" "$mnt" "$mode"; then
    return 0
  fi
  if [[ $mode == clearkey ]]; then
    die "no usable clear key. The volume was not opened."
  fi
  die "read-only unlock failed. The volume was not left mounted."
}

read_state_file() {
  local file=$1 line
  ST_DEVICE='' ST_MAPPER='' ST_MOUNT='' ST_FUSE='' ST_METHOD=''
  while IFS= read -r line || [[ -n $line ]]; do
    case $line in
      device=*) ST_DEVICE=${line#device=} ;;
      mapper=*) ST_MAPPER=${line#mapper=} ;;
      mountpoint=*) ST_MOUNT=${line#mountpoint=} ;;
      fuse=*) ST_FUSE=${line#fuse=} ;;
      method=*) ST_METHOD=${line#method=} ;;
    esac
  done <"$file"
}

cmd_lock() {
  local target=${POS1:-} dir file match=
  [[ -n $target ]] || die "lock needs a mountpoint, mapper name, or device"
  case $target in
    *$'\n'*) die "invalid lock target" ;;
  esac
  dir=$(state_dir)
  if [[ -d $dir ]]; then
    local f
    for f in "$dir"/*.state; do
      [[ -f $f ]] || continue
      read_state_file "$f"
      if [[ $target == "$ST_MOUNT" || $target == "$ST_MAPPER" || $target == "$ST_DEVICE" || $target == "$f" ]]; then
        match=$f
        break
      fi
    done
  fi
  if [[ -z $match ]]; then
    if [[ $DRY -eq 1 ]]; then
      case $target in
        redeembl_*)
          printf 'dry-run: cryptsetup close %q\n' "$target"
          ;;
        /*)
          printf 'dry-run: umount %q\n' "$target"
          ;;
        *)
          die "lock target must be a mount path or a redeembl_ mapper name"
          ;;
      esac
      return 0
    fi
    die "no redeem-bitlocker state matches that target. Nothing was closed."
  fi
  read_state_file "$match"
  case $ST_MAPPER in
    redeembl_* | "") ;;
    *) die "refusing to close unexpected mapper name" ;;
  esac
  if [[ $DRY -eq 1 ]]; then
    [[ -n $ST_MOUNT ]] && printf 'dry-run: umount %q\n' "$ST_MOUNT"
    [[ -n $ST_FUSE ]] && printf 'dry-run: umount %q\n' "$ST_FUSE"
    [[ -n $ST_MAPPER ]] && printf 'dry-run: cryptsetup close %q\n' "$ST_MAPPER"
    return 0
  fi
  if [[ -n $ST_MOUNT ]]; then
    umount "$ST_MOUNT" 2>/dev/null || true
  fi
  if [[ -n $ST_FUSE ]]; then
    if command -v fusermount3 >/dev/null 2>&1; then
      fusermount3 -u "$ST_FUSE" 2>/dev/null || umount "$ST_FUSE" 2>/dev/null || true
    elif command -v fusermount >/dev/null 2>&1; then
      fusermount -u "$ST_FUSE" 2>/dev/null || umount "$ST_FUSE" 2>/dev/null || true
    else
      umount "$ST_FUSE" 2>/dev/null || true
    fi
  fi
  if [[ $ST_METHOD == cryptsetup && -n $ST_MAPPER ]] && command -v cryptsetup >/dev/null 2>&1; then
    if cryptsetup status "$ST_MAPPER" >/dev/null 2>&1; then
      cryptsetup close "$ST_MAPPER"
    fi
  fi
  rm -f -- "$match"
  printf 'locked %s\n' "$target"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      inspect | status | unlock | lock | parse-dump | version-at-least)
        [[ -z $MODE ]] || die "one command only"
        MODE=$1
        shift
        ;;
      --dry-run)
        DRY=1
        shift
        ;;
      --clearkey)
        CLEAR=1
        shift
        ;;
      --bek)
        [[ $# -ge 2 ]] || die "--bek needs a path"
        BEK=$2
        shift 2
        ;;
      --fixture)
        [[ $# -ge 2 ]] || die "--fixture needs a path"
        FIXTURE=$2
        shift 2
        ;;
      --smart-health)
        [[ $# -ge 2 ]] || die "--smart-health needs a value"
        SMART_FORCE=$2
        shift 2
        ;;
      --readonly | -r)
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        if [[ -z $POS1 ]]; then
          POS1=$1
        elif [[ -z $POS2 ]]; then
          POS2=$1
        else
          die "unexpected argument"
        fi
        shift
        ;;
    esac
  done
  while [[ $# -gt 0 ]]; do
    if [[ -z $POS1 ]]; then
      POS1=$1
    elif [[ -z $POS2 ]]; then
      POS2=$1
    else
      die "unexpected argument"
    fi
    shift
  done
}

main() {
  if [[ $# -eq 0 ]]; then
    usage >&2
    exit 2
  fi
  forbid_secrets "$@"
  parse_args "$@"
  case $MODE in
    inspect | status) cmd_inspect ;;
    unlock) cmd_unlock ;;
    lock) cmd_lock ;;
    parse-dump) cmd_parse_dump ;;
    version-at-least)
      [[ -n $POS1 && -n $POS2 ]] || die "version-at-least MIN GOT"
      if version_at_least "$POS1" "$POS2"; then
        printf 'yes\n'
        exit 0
      fi
      printf 'no\n'
      exit 1
      ;;
    "")
      usage >&2
      exit 2
      ;;
  esac
}

if [[ ${REDEEM_BITLOCKER_SOURCE_ONLY:-0} == 1 ]]; then
  # Sourced for tests. `return` is the sourced exit. Executing with this
  # variable set is not a supported path.
  # shellcheck disable=SC2317
  return 0
fi
main "$@"
