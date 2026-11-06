#!/usr/bin/env bash
# Optional portable CPU llama-server builds for Windows and macOS.
# Linux SystemRescue keeps using the binaries from build-llama.sh.
# Archives are the b12110 release assets that llama.cpp v0.9.0 points at.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$here/lib.sh"
load_versions

root=$(redeem_root)
dist=$root/build/cache/host-bin/dist
stage_root=$root/build/cache/host-bin
mkdir -p "$dist"

fetch_one() {
    local file=$1 url=$2 sha=$3 dest_name=$4 binary=$5
    local archive=$dist/$file dest=$stage_root/$dest_name tmp
    if [[ -f $archive ]]; then
        printf 'present %s\n' "$archive"
    else
        printf 'download %s\n' "$url"
        rtk_err curl -fL --retry 3 --retry-delay 2 -o "$archive.partial" "$url"
        mv "$archive.partial" "$archive"
    fi
    verify_sha256 "$archive" "$sha"
    tmp=$(mktemp -d)
    case $archive in
        *.zip) unzip -q "$archive" -d "$tmp" ;;
        *.tar.gz) tar -xzf "$archive" -C "$tmp" ;;
        *) die "unknown archive type: $archive" ;;
    esac
    # Official macOS archives unpack into one top directory. Windows zips do not.
    local top=$tmp
    local entries=()
    shopt -s nullglob
    entries=("$tmp"/*)
    shopt -u nullglob
    if [[ ${#entries[@]} -eq 1 && -d ${entries[0]} ]]; then
        top=${entries[0]}
    fi
    [[ -f $top/$binary ]] || die "$binary not found in $file"
    rm -rf "$dest"
    mkdir -p "$dest"
    cp -a "$top"/. "$dest/"
    rm -rf "$tmp"
    printf 'staged %s (%s)\n' "$dest" "$binary"
}

fetch_one "$LLAMA_HOST_WIN_X64_FILE" "$LLAMA_HOST_WIN_X64_URL" "$LLAMA_HOST_WIN_X64_SHA256" \
    win-x64 llama-server.exe
fetch_one "$LLAMA_HOST_MACOS_ARM64_FILE" "$LLAMA_HOST_MACOS_ARM64_URL" "$LLAMA_HOST_MACOS_ARM64_SHA256" \
    macos-arm64 llama-server
fetch_one "$LLAMA_HOST_MACOS_X64_FILE" "$LLAMA_HOST_MACOS_X64_URL" "$LLAMA_HOST_MACOS_X64_SHA256" \
    macos-x64 llama-server
