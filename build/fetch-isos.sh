#!/usr/bin/env bash
# Download Ventoy, SystemRescue, and Clonezilla. Verify publisher checksums.
# Optional: Hiren's BootCD PE (--with-winpe) or a local WinPE / WinRE / Windows ISO.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$here/lib.sh"
load_versions

root=$(redeem_root)
cache=$root/build/cache/isos
ventoy_cache=$root/build/cache/ventoy

WITH_WINPE=0
PROBE=0
WINPE_ISO=
WINPE_SHA256=

usage() {
  cat <<'EOF'
usage: fetch-isos.sh [--with-winpe]
                     [--winpe-iso FILE] [--winpe-sha256 HEX]
                     [--probe-winpe]

Downloads Ventoy, SystemRescue, and Clonezilla into build/cache and checks
the pinned SHA-256 values. --with-winpe also downloads Hiren's BootCD PE
x64 v1.0.8 (HBCD_PE_x64.iso) and checks HBCD_SHA256.

--winpe-iso copies a local ISO into build/cache/isos. A file whose SHA-256
matches the Hiren's pin is stored as HBCD_PE_x64.iso. Any other WinPE, WinRE,
or Windows install ISO must be passed with --winpe-sha256. The copy is refused
when the digest does not match. /dev paths are refused.

--probe-winpe sends a HEAD request to the Hiren's URL and does not download
the ISO body.
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --with-winpe)
      WITH_WINPE=1
      shift
      ;;
    --winpe-iso)
      WINPE_ISO=${2:-}
      [[ -n $WINPE_ISO ]] || die "--winpe-iso needs a path"
      shift 2
      ;;
    --winpe-sha256)
      WINPE_SHA256=${2:-}
      [[ -n $WINPE_SHA256 ]] || die "--winpe-sha256 needs a digest"
      shift 2
      ;;
    --probe-winpe)
      PROBE=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if [[ -n $WINPE_SHA256 && -z $WINPE_ISO ]]; then
  die "--winpe-sha256 requires --winpe-iso"
fi

# Refuse a device path before any download. A bad flag must not start a fetch.
if [[ -n $WINPE_ISO ]]; then
  if ! target_is_safe_image "$WINPE_ISO"; then
    die "refusing winpe iso path '$WINPE_ISO' (not a plain file)"
  fi
  [[ -f $WINPE_ISO ]] || die "missing winpe iso: $WINPE_ISO"
fi

probe_winpe() {
  local hdr code
  hdr=$(mktemp)
  code=$(curl -sIL --max-time 40 -A "redeem-fetch/1.0" -e "$HBCD_REFERER" \
    -o "$hdr" -w "%{http_code}" "$HBCD_URL" || true)
  printf 'probe %s -> HTTP %s\n' "$HBCD_URL" "$code"
  awk '
    {
      sub(/\r$/, "")
      low = tolower($0)
      if (low ~ /^http\// || low ~ /^location:/ || low ~ /^content-length:/ || low ~ /^content-type:/)
        print
    }
  ' "$hdr"
  rm -f "$hdr"
  [[ $code == 200 ]] || die "WinPE probe did not finish with HTTP 200"
}

if [[ $PROBE -eq 1 ]]; then
  probe_winpe
  exit 0
fi

mkdir -p "$cache" "$ventoy_cache"

install_winpe_file() {
  local src=$1 expect=$2 got dest_name
  got=$(sha256_file "$src")
  got=$(printf '%s' "$got" | tr '[:upper:]' '[:lower:]')
  if [[ -z $expect ]]; then
    if [[ $got == "$HBCD_SHA256" ]]; then
      dest_name=$HBCD_FILE
    else
      die "custom WinPE ISO does not match the pinned Hiren's checksum.
Pass --winpe-sha256 with the expected digest. Refusing an unverified copy.
got $got"
    fi
  else
    [[ $expect =~ ^[0-9a-fA-F]{64}$ ]] || die "--winpe-sha256 must be 64 hex characters"
    expect=$(printf '%s' "$expect" | tr '[:upper:]' '[:lower:]')
    if [[ $got != "$expect" ]]; then
      die "checksum mismatch for winpe iso
expected $expect
got      $got"
    fi
    if [[ $got == "$HBCD_SHA256" ]]; then
      dest_name=$HBCD_FILE
    else
      dest_name=$(basename -- "$src")
      [[ $dest_name == *.iso ]] || die "winpe iso file name must end in .iso"
      case $dest_name in
        *[!A-Za-z0-9._-]*) die "winpe iso file name has unexpected characters" ;;
      esac
    fi
  fi
  if [[ $src != "$cache/$dest_name" ]]; then
    cp -a -- "$src" "$cache/$dest_name"
  fi
  verify_sha256 "$cache/$dest_name" "$got"
  printf 'winpe iso ready: %s\n' "$cache/$dest_name"
}

download_hbcd() {
  local dest=$cache/$HBCD_FILE
  if [[ -f $dest ]]; then
    verify_sha256 "$dest" "$HBCD_SHA256"
    printf 'present %s\n' "$dest"
    return 0
  fi
  printf 'download %s\n' "$HBCD_URL"
  # The official URL redirects. curl -fL follows it. A browser User-Agent and
  # the site Referer are sent; a 2026-11-06 HEAD succeeded without them too.
  rtk_err curl -fL --retry 3 --retry-delay 2 \
    -A "redeem-fetch/1.0" \
    -e "$HBCD_REFERER" \
    -o "$dest.partial" "$HBCD_URL"
  mv "$dest.partial" "$dest"
  verify_sha256 "$dest" "$HBCD_SHA256"
}

# Check a local WinPE file before the other downloads. A bad digest must not
# start a multi-gigabyte fetch.
if [[ -n $WINPE_ISO ]]; then
  install_winpe_file "$WINPE_ISO" "$WINPE_SHA256"
fi

fetch() {
  local url=$1 dest=$2
  if [[ -f $dest ]]; then
    printf 'present %s\n' "$dest"
    return 0
  fi
  printf 'download %s\n' "$url"
  rtk_err curl -fL --retry 3 --retry-delay 2 -o "$dest.partial" "$url"
  mv "$dest.partial" "$dest"
}

fetch "$VENTOY_URL" "$ventoy_cache/$VENTOY_FILE"
verify_sha256 "$ventoy_cache/$VENTOY_FILE" "$VENTOY_SHA256"

fetch "$SYSRESCUE_URL" "$cache/$SYSRESCUE_FILE"
verify_sha256 "$cache/$SYSRESCUE_FILE" "$SYSRESCUE_SHA256"
sha_tmp=$(mktemp)
rtk_err curl -fsSL -o "$sha_tmp" "$SYSRESCUE_SHA256_URL"
if ! grep -q "$SYSRESCUE_SHA256" "$sha_tmp"; then
  die "SystemRescue checksum file does not contain the pinned hash"
fi
rm -f "$sha_tmp"
printf 'upstream sha256 file agrees for %s\n' "$SYSRESCUE_FILE"

fetch "$CLONEZILLA_URL" "$cache/$CLONEZILLA_FILE"
verify_sha256 "$cache/$CLONEZILLA_FILE" "$CLONEZILLA_SHA256"
sha_tmp=$(mktemp)
rtk_err curl -fsSL -o "$sha_tmp" "$CLONEZILLA_SHA256_URL"
if ! grep -q "$CLONEZILLA_SHA256" "$sha_tmp"; then
  die "Clonezilla CHECKSUMS.TXT does not contain the pinned hash"
fi
rm -f "$sha_tmp"
printf 'upstream checksum list agrees for %s\n' "$CLONEZILLA_FILE"

if [[ $WITH_WINPE -eq 1 && -z $WINPE_ISO ]]; then
  download_hbcd
fi
