#!/usr/bin/env bash
# Download Ventoy, SystemRescue, and Clonezilla. Verify publisher checksums.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$here/lib.sh"
load_versions

root=$(redeem_root)
cache=$root/build/cache/isos
ventoy_cache=$root/build/cache/ventoy
mkdir -p "$cache" "$ventoy_cache"

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
