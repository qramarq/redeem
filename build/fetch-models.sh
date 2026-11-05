#!/usr/bin/env bash
# Download the pinned GGUF files and check the Hugging Face blob hashes.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$here/lib.sh"

root=$(redeem_root)
dest_dir=$root/build/cache/models
manifest=$root/build/models.tsv
mkdir -p "$dest_dir"

only=${1:-}

while IFS=$'\t' read -r id local_file repo remote_file sha bytes _min role; do
  [[ -n $id && $id != \#* ]] || continue
  if [[ -n $only && $id != "$only" && $role != "$only" ]]; then
    continue
  fi
  dest=$dest_dir/$local_file
  url=https://huggingface.co/${repo}/resolve/main/${remote_file}
  if [[ -f $dest ]]; then
    printf 'present %s\n' "$dest"
  else
    printf 'download %s (%s bytes)\n' "$id" "$bytes"
    rtk_err curl -fL --retry 3 --retry-delay 2 -o "$dest.partial" "$url"
    mv "$dest.partial" "$dest"
  fi
  got_bytes=$(wc -c <"$dest" | tr -d ' ')
  if [[ $got_bytes != "$bytes" ]]; then
    die "$local_file is $got_bytes bytes, expected $bytes"
  fi
  verify_sha256 "$dest" "$sha"
  printf 'model %s role %s\n' "$id" "$role"
done <"$manifest"
