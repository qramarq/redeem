#!/bin/bash
# launchd StartOnMount runs this for every mount. It launches Redeem only when
# the pinned volume is the one that just appeared. Any other disk exits 0.
set -eu

uuid=${1:-}
if [[ -z $uuid ]]; then
    printf 'redeem: macos-usb-launch.sh needs the pinned UUID\n' >&2
    exit 2
fi

norm() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -d '-'
}
want=$(norm "$uuid")

if ! command -v diskutil >/dev/null 2>&1; then
    printf 'redeem: diskutil is not available\n' >&2
    exit 1
fi

state_dir="$HOME/Library/Application Support/redeem"
state_file="$state_dir/seen-volumes"
mkdir -p "$state_dir"
touch "$state_file"

now=$(date +%s)
match_mp=""
current=$(mktemp)

diskutil info -all 2>/dev/null | awk '
function trim(s) {
    sub(/^[[:space:]]+/, "", s)
    sub(/[[:space:]]+$/, "", s)
    return s
}
function dump() {
    if (dev != "" && mp != "" && mp != "Not applicable") {
        printf "%s\t%s\t%s\t%s\n", dev, vol, part, mp
    }
    dev = ""
    vol = ""
    part = ""
    mp = ""
}
/^[*]+$/ { dump(); next }
/^[[:space:]]*Device Identifier:/ { dev = trim(substr($0, index($0, ":") + 1)); next }
/^[[:space:]]*Volume UUID:/ { vol = trim(substr($0, index($0, ":") + 1)); next }
/^[[:space:]]*Disk \/ Partition UUID:/ { part = trim(substr($0, index($0, ":") + 1)); next }
/^[[:space:]]*Mount Point:/ { mp = trim(substr($0, index($0, ":") + 1)); next }
END { dump() }
' >"$current"

while IFS="$(printf '\t')" read -r dev vol part mp; do
    [[ -n $dev && -n $mp ]] || continue
    printf '%s\n' "$dev" >>"$current.ids"
    hit=0
    if [[ -n $vol && $(norm "$vol") == "$want" ]]; then
        hit=1
    fi
    if [[ -n $part && $(norm "$part") == "$want" ]]; then
        hit=1
    fi
    [[ $hit -eq 1 ]] || continue
    birth=0
    if [[ -d $mp ]]; then
        birth=$(stat -f %B "$mp" 2>/dev/null || printf '0')
    fi
    age=$((now - birth))
    seen=0
    if grep -qx "$dev" "$state_file"; then
        seen=1
    fi
    if [[ $age -le 30 || $seen -eq 0 ]]; then
        match_mp=$mp
    fi
done <"$current"

if [[ -f $current.ids ]]; then
    sort -u "$current.ids" >"$state_file"
else
    : >"$state_file"
fi
rm -f "$current" "$current.ids"

if [[ -z $match_mp ]]; then
    exit 0
fi

launcher=$match_mp/Start-Redeem-macOS.command
if [[ ! -f $launcher ]]; then
    printf 'redeem: %s has no Start-Redeem-macOS.command\n' "$match_mp" >&2
    exit 1
fi
chmod +x "$launcher" 2>/dev/null || true
if ! open "$launcher"; then
    bash "$launcher"
fi
