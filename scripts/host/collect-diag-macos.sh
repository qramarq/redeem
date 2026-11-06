#!/bin/bash
# Read-only macOS storage and boot notes for redeem.
# FileVault and APFS are status only. This script does not unlock a volume.
set -eu

usage() {
    cat <<'EOF'
usage: collect-diag-macos.sh [--out FILE] [--max-bytes N]

Collects diskutil list, diskutil info, APFS layout, FileVault status, and
recent storage log lines. Nothing is unlocked, repaired, or erased.
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

section() {
    printf '\n## %s\n' "$1"
    if [[ -n ${2:-} ]]; then
        printf '%s\n' "$2"
    else
        printf '%s\n' '(none)'
    fi
}

cap_cmd() {
    local title=$1
    shift
    local body
    body=$("$@" 2>&1 | head -c 4000 || true)
    section "$title" "$body"
}

{
    printf '%s\n' '# redeem macOS diagnostics (read-only, no repairs applied)'
    printf 'collected: %s\n' "$(date)"
    if command -v sw_vers >/dev/null 2>&1; then
        sw_vers 2>&1 || true
    fi
    printf 'uname: %s\n' "$(uname -a)"

    if command -v diskutil >/dev/null 2>&1; then
        cap_cmd 'diskutil list' diskutil list
        cap_cmd 'diskutil info' diskutil info -all
        cap_cmd 'apfs' diskutil apfs list
    else
        section 'diskutil' 'diskutil: not available'
    fi

    if command -v fdesetup >/dev/null 2>&1; then
        # status only. fdesetup unlock and diskutil apfs unlockVolume are not used.
        cap_cmd 'filevault' fdesetup status
    else
        section 'filevault' 'fdesetup: not available. FileVault was not unlocked.'
    fi

    if command -v log >/dev/null 2>&1; then
        logs=$(log show --style compact --last 1d --predicate 'eventMessage CONTAINS[c] "I/O error" OR eventMessage CONTAINS[c] "disk error" OR subsystem CONTAINS "com.apple.DiskArbitration"' 2>/dev/null | head -n 40 || true)
        section 'storage-log' "$logs"
    else
        section 'storage-log' 'log: not available'
    fi
} >"$OUT.full"

mkdir -p "$(dirname -- "$OUT")"
head -c "$MAX_BYTES" "$OUT.full" >"$OUT"
if [[ $(wc -c <"$OUT.full" | tr -d ' ') -gt $MAX_BYTES ]]; then
    printf '\n[truncated]\n' >>"$OUT"
fi
rm -f "$OUT.full"
printf 'wrote %s (%s bytes)\n' "$OUT" "$(wc -c <"$OUT" | tr -d ' ')"
