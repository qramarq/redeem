#!/usr/bin/env bash
# Install a watcher that starts Redeem only for one filesystem UUID.
# Empty, wildcard, and malformed UUIDs are refused. --dry-run prints the
# files and does not write /etc, LaunchAgents, or the user profile.
set -eu

usage() {
    cat <<'EOF'
usage: install-watcher.sh --os linux|macos --uuid <UUID> [--dry-run] [--uninstall]
       install-watcher.sh --detect [--os linux|macos]

--uuid is the filesystem UUID printed by --detect (exFAT XXXX-XXXX or a
128-bit UUID). The watcher ignores every other disk.
--dry-run prints the generated files and writes nothing.
--uninstall removes the watcher.
EOF
}

die() {
    printf 'redeem: %s\n' "$*" >&2
    exit 1
}

refuse_uuid() {
    printf 'redeem: refusing UUID %q (empty, wildcard, or malformed)\n' "${1-}" >&2
    exit 2
}

# Prints the canonical UUID or returns 1.
canonicalize_uuid() {
    local u=${1-} lower
    [[ -n $u ]] || return 1
    if [[ $u == *'*'* || $u == *'?'* || $u == *'['* || $u == *']'* || $u == *' '* || $u == *'/'* || $u == *$'\n'* || $u == *$'\t'* ]]; then
        return 1
    fi
    lower=$(printf '%s' "$u" | tr '[:upper:]' '[:lower:]')
    case $lower in
        any | all | none | wildcard | nil) return 1 ;;
    esac
    if printf '%s' "$u" | grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'; then
        [[ $lower != 00000000-0000-0000-0000-000000000000 ]] || return 1
        printf '%s\n' "$lower"
        return 0
    fi
    if printf '%s' "$u" | grep -Eq '^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$'; then
        [[ $lower != 0000-0000 ]] || return 1
        printf '%s\n' "$u" | tr '[:lower:]' '[:upper:]'
        return 0
    fi
    if printf '%s' "$u" | grep -Eq '^[0-9A-Fa-f]{8}$'; then
        [[ $lower != 00000000 ]] || return 1
        u=$(printf '%s' "$u" | tr '[:lower:]' '[:upper:]')
        printf '%s-%s\n' "${u:0:4}" "${u:4:4}"
        return 0
    fi
    return 1
}

xml_escape() {
    local s=$1
    s=${s//&/&amp;}
    s=${s//</&lt;}
    s=${s//>/&gt;}
    printf '%s' "$s"
}

OS=""
UUID_RAW=""
DRY=0
UNINSTALL=0
DETECT=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --os)
            [[ $# -ge 2 ]] || die "missing operating system after --os"
            OS=$2
            shift 2
            ;;
        --uuid)
            [[ $# -ge 2 ]] || refuse_uuid ""
            UUID_RAW=$2
            shift 2
            ;;
        --dry-run)
            DRY=1
            shift
            ;;
        --uninstall)
            UNINSTALL=1
            shift
            ;;
        --detect)
            DETECT=1
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

here=$(cd "$(dirname "$0")" && pwd)
user_name=$(id -un)
user_id=$(id -u)

detect_linux() {
    local dev uuid
    if ! command -v blkid >/dev/null 2>&1; then
        die "blkid is not available"
    fi
    dev=$(blkid -L Ventoy 2>/dev/null || true)
    if [[ -z $dev ]]; then
        die "no volume labeled Ventoy. Mount the stick, then re-run --detect."
    fi
    uuid=$(blkid -o value -s UUID -- "$dev" 2>/dev/null || true)
    [[ -n $uuid ]] || die "blkid did not report ID_FS_UUID for $dev"
    printf '%s\n' "$uuid"
}

detect_macos() {
    command -v diskutil >/dev/null 2>&1 || die "diskutil is not available"
    diskutil info -all 2>/dev/null | awk '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        /^[[:space:]]*Volume Name:/ { name = trim(substr($0, index($0, ":") + 1)) }
        /^[[:space:]]*Volume UUID:/ { vol = trim(substr($0, index($0, ":") + 1)) }
        /^[*]+$/ {
            if (name == "Ventoy" && vol != "") { print vol; found = 1 }
            name = ""
            vol = ""
        }
        END {
            if (name == "Ventoy" && vol != "") print vol
            if (!found && name != "Ventoy") exit 1
        }
    ' || die "no mounted volume named Ventoy"
}

if [[ $DETECT -eq 1 ]]; then
    if [[ -z $OS ]]; then
        case $(uname -s) in
            Darwin) OS=macos ;;
            Linux) OS=linux ;;
            *) die "use install-watcher.ps1 -Detect on Windows" ;;
        esac
    fi
    case $OS in
        linux) detect_linux ;;
        macos) detect_macos ;;
        *) die "unknown operating system: $OS" ;;
    esac
    exit 0
fi

case $OS in
    linux | macos) ;;
    *) die "use --os linux or --os macos (Windows: install-watcher.ps1)" ;;
esac

as_root() {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

show_or_write() {
    local path=$1
    local mode=$2
    local body=$3
    local root_write=${4:-0}
    if [[ $DRY -eq 1 ]]; then
        printf '\n===== %s =====\n' "$path"
        printf '%s\n' "$body"
        return 0
    fi
    if [[ $root_write -eq 1 ]]; then
        as_root mkdir -p -- "$(dirname -- "$path")"
        printf '%s\n' "$body" | as_root tee "$path" >/dev/null
        as_root chmod "$mode" "$path"
    else
        mkdir -p -- "$(dirname -- "$path")"
        printf '%s\n' "$body" >"$path"
        chmod "$mode" "$path"
    fi
}

copy_script() {
    local src=$1 dest=$2 mode=$3 root_write=$4
    [[ -f $src ]] || die "missing $src"
    if [[ $DRY -eq 1 ]]; then
        printf '\n===== %s =====\n' "$dest"
        cat "$src"
        return 0
    fi
    if [[ $root_write -eq 1 ]]; then
        as_root mkdir -p -- "$(dirname -- "$dest")"
        as_root cp "$src" "$dest"
        as_root chmod "$mode" "$dest"
    else
        mkdir -p -- "$(dirname -- "$dest")"
        cp "$src" "$dest"
        chmod "$mode" "$dest"
    fi
}

uninstall_linux() {
    local paths=(
        /etc/udev/rules.d/99-redeem-usb.rules
        /etc/systemd/system/redeem-usb.service
        /usr/local/lib/redeem/usb-launch.sh
        "$HOME/.config/systemd/user/redeem-usb.service"
        "$HOME/.local/lib/redeem/usb-launch.sh"
    )
    if [[ $DRY -eq 1 ]]; then
        printf '# redeem watcher dry-run uninstall (linux)\n'
        printf '# would remove:\n'
        printf '%s\n' "${paths[@]}"
        return 0
    fi
    as_root systemctl disable --now redeem-usb.service >/dev/null 2>&1 || true
    systemctl --user disable --now redeem-usb.service >/dev/null 2>&1 || true
    as_root rm -f /etc/udev/rules.d/99-redeem-usb.rules \
        /etc/systemd/system/redeem-usb.service \
        /usr/local/lib/redeem/usb-launch.sh
    rm -f "$HOME/.config/systemd/user/redeem-usb.service" \
        "$HOME/.local/lib/redeem/usb-launch.sh"
    as_root systemctl daemon-reload >/dev/null 2>&1 || true
    as_root udevadm control --reload-rules >/dev/null 2>&1 || true
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    printf 'redeem: linux watcher removed\n'
}

uninstall_macos() {
    local plist="$HOME/Library/LaunchAgents/com.redeem.usbwatcher.plist"
    local script="$HOME/Library/Application Support/redeem/macos-usb-launch.sh"
    if [[ $DRY -eq 1 ]]; then
        printf '# redeem watcher dry-run uninstall (macos)\n'
        printf '# would remove:\n%s\n%s\n' "$plist" "$script"
        return 0
    fi
    if [[ $(uname -s) == Darwin ]]; then
        launchctl bootout "gui/${user_id}" "$plist" >/dev/null 2>&1 || true
    fi
    rm -f "$plist" "$script"
    printf 'redeem: macOS watcher removed\n'
}

if [[ $UNINSTALL -eq 1 ]]; then
    case $OS in
        linux) uninstall_linux ;;
        macos) uninstall_macos ;;
    esac
    exit 0
fi

uuid=$(canonicalize_uuid "$UUID_RAW") || refuse_uuid "$UUID_RAW"

if [[ $DRY -eq 1 ]]; then
    printf '# redeem watcher dry-run (%s)\n' "$OS"
    printf '# uuid: %s\n' "$uuid"
    printf '# no host paths written\n'
fi

if [[ $OS == linux ]]; then
    rule="/etc/udev/rules.d/99-redeem-usb.rules"
    rule_body="# redeem: exact filesystem UUID only. Wildcards are not accepted.
ACTION==\"add\", SUBSYSTEM==\"block\", ENV{ID_FS_UUID}==\"${uuid}\", TAG+=\"systemd\", ENV{SYSTEMD_WANTS}=\"redeem-usb.service\", ENV{SYSTEMD_USER_WANTS}=\"redeem-usb.service\""
    system_unit="/etc/systemd/system/redeem-usb.service"
    system_body="[Unit]
Description=Redeem when the pinned USB is plugged in

[Service]
Type=oneshot
User=${user_name}
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/${user_id}
ExecStart=/usr/local/lib/redeem/usb-launch.sh ${uuid}"
    user_unit="$HOME/.config/systemd/user/redeem-usb.service"
    user_body="[Unit]
Description=Redeem when the pinned USB is plugged in

[Service]
Type=oneshot
ExecStart=%h/.local/lib/redeem/usb-launch.sh ${uuid}"
    show_or_write "$rule" 644 "$rule_body" 1
    show_or_write "$system_unit" 644 "$system_body" 1
    show_or_write "$user_unit" 644 "$user_body" 0
    copy_script "$here/linux-usb-launch.sh" /usr/local/lib/redeem/usb-launch.sh 755 1
    copy_script "$here/linux-usb-launch.sh" "$HOME/.local/lib/redeem/usb-launch.sh" 755 0
    if [[ $DRY -eq 0 ]]; then
        as_root systemctl daemon-reload
        systemctl --user daemon-reload >/dev/null 2>&1 || true
        as_root udevadm control --reload-rules
        printf 'redeem: linux watcher installed for %s\n' "$uuid"
        printf 'redeem: unplug and plug the stick to start it\n'
    fi
else
    plist="$HOME/Library/LaunchAgents/com.redeem.usbwatcher.plist"
    dest="$HOME/Library/Application Support/redeem/macos-usb-launch.sh"
    esc_dest=$(xml_escape "$dest")
    esc_uuid=$(xml_escape "$uuid")
    plist_body="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
    <key>Label</key>
    <string>com.redeem.usbwatcher</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${esc_dest}</string>
        <string>${esc_uuid}</string>
    </array>
    <key>StartOnMount</key>
    <true/>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>"
    show_or_write "$plist" 644 "$plist_body" 0
    copy_script "$here/macos-usb-launch.sh" "$dest" 755 0
    if [[ $DRY -eq 0 && $(uname -s) == Darwin ]]; then
        launchctl bootout "gui/${user_id}" "$plist" >/dev/null 2>&1 || true
        launchctl bootstrap "gui/${user_id}" "$plist" >/dev/null 2>&1 || launchctl load "$plist"
    fi
    if [[ $DRY -eq 0 ]]; then
        printf 'redeem: macOS watcher installed for %s\n' "$uuid"
    fi
fi
