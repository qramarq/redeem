#!/usr/bin/env bash
# Copy scripts, the knowledge pack, and any built binaries and models into ai/.
# ai/ is gitignored. The source of truth stays in scripts/ and kb/.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$here/lib.sh"

root=$(redeem_root)
dest=${1:-$root/ai}
mkdir -p "$dest/bin" "$dest/models" "$dest/kb" "$dest/scripts" "$dest/boot"

cp -a "$root/scripts/rescue-ai" \
  "$root/scripts/collect-diag.sh" \
  "$root/scripts/build-prompt.sh" \
  "$root/scripts/kb-retrieve.awk" \
  "$root/scripts/rescue-chat.py" \
  "$dest/scripts/"
cp -a "$root/kb/." "$dest/kb/"
cp -a "$root/boot/autorun" "$dest/boot/autorun"
cp -a "$root/build/models.tsv" "$dest/models/manifest.tsv"
chmod +x "$dest/scripts/rescue-ai" "$dest/scripts/collect-diag.sh" "$dest/scripts/build-prompt.sh"

shopt -s nullglob
bins=("$root/build/cache/bin"/llama-server-*)
models=("$root/build/cache/models"/*.gguf)
if [[ ${#bins[@]} -gt 0 ]]; then
  cp -a "${bins[@]}" "$dest/bin/"
fi
if [[ ${#models[@]} -gt 0 ]]; then
  cp -a "${models[@]}" "$dest/models/"
fi
shopt -u nullglob

printf 'assembled %s\n' "$dest"
find "$dest" -maxdepth 2 -type d -o -type f | sort
