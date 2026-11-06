#!/usr/bin/env bash
# Copy scripts, the knowledge pack, and any built binaries and models into ai/.
# ai/ is gitignored. The source of truth stays in scripts/ and kb/.
# --slim copies only the Llama-3.2-1B-Instruct GGUF.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$here/lib.sh"

root=$(redeem_root)
SLIM=0
dest=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --slim)
      SLIM=1
      shift
      ;;
    -h | --help)
      cat <<'EOF'
usage: assemble-ai.sh [--slim] [DEST]

--slim copies only Llama-3.2-1B-Instruct Q4_K_M into ai/models.
DEST defaults to ./ai. Also builds usb-root/ventoy via assemble-ventoy.sh.
EOF
      exit 0
      ;;
    *)
      [[ -z $dest ]] || die "unknown argument: $1"
      dest=$1
      shift
      ;;
  esac
done
dest=${dest:-$root/ai}
mkdir -p "$dest/bin" "$dest/models" "$dest/kb" "$dest/scripts" "$dest/boot"

cp -a "$root/scripts/rescue-ai" \
  "$root/scripts/collect-diag.sh" \
  "$root/scripts/build-prompt.sh" \
  "$root/scripts/kb-retrieve.awk" \
  "$root/scripts/rescue-chat.py" \
  "$root/scripts/host/collect-diag-macos.sh" \
  "$root/scripts/host/rescue-windows.ps1" \
  "$root/scripts/host/install-watcher.sh" \
  "$root/scripts/host/install-watcher.ps1" \
  "$root/scripts/host/linux-usb-launch.sh" \
  "$root/scripts/host/macos-usb-launch.sh" \
  "$root/scripts/host/windows-volume-watcher.ps1" \
  "$root/boot/redeem-autostart" \
  "$dest/scripts/"
cp -a "$root/kb/." "$dest/kb/"
cp -a "$root/boot/autorun" "$dest/boot/autorun"
cp -a "$root/build/models.tsv" "$dest/models/manifest.tsv"
chmod +x "$dest/scripts/rescue-ai" "$dest/scripts/collect-diag.sh" \
  "$dest/scripts/build-prompt.sh" "$dest/scripts/collect-diag-macos.sh" \
  "$dest/scripts/install-watcher.sh" "$dest/scripts/linux-usb-launch.sh" \
  "$dest/scripts/macos-usb-launch.sh" "$dest/scripts/redeem-autostart"

shopt -s nullglob
bins=("$root/build/cache/bin"/llama-server-*)
if [[ ${#bins[@]} -gt 0 ]]; then
  cp -a "${bins[@]}" "$dest/bin/"
fi
shopt -u nullglob

if [[ $SLIM -eq 1 ]]; then
  while IFS=$'\t' read -r id file _; do
    [[ -n $id && $id != \#* ]] || continue
    [[ $id == llama32-1b ]] || continue
    if [[ -f $root/build/cache/models/$file ]]; then
      cp -a "$root/build/cache/models/$file" "$dest/models/"
    fi
  done <"$root/build/models.tsv"
else
  shopt -s nullglob
  models=("$root/build/cache/models"/*.gguf)
  if [[ ${#models[@]} -gt 0 ]]; then
    cp -a "${models[@]}" "$dest/models/"
  fi
  shopt -u nullglob
fi

stage_host() {
  local name=$1
  local src=$root/build/cache/host-bin/$name
  [[ -d $src ]] || return 0
  mkdir -p "$dest/bin/$name"
  cp -a "$src"/. "$dest/bin/$name/"
}
stage_host win-x64
stage_host macos-arm64
stage_host macos-x64

"$root/build/assemble-ventoy.sh"

printf 'assembled %s\n' "$dest"
find "$dest" -maxdepth 2 -type d -o -type f | sort
