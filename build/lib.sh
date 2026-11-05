#!/usr/bin/env bash
# Shared helpers for redeem build scripts.
# A build must never open a real disk. Image files and loop devices whose
# backing file is one of those images are the only legal targets.

if [[ -z ${REDEEM_LIB_LOADED:-} ]]; then
  REDEEM_LIB_LOADED=1
else
  return 0
fi

redeem_root() {
  local here
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  cd "$here/.." && pwd
}

die() {
  printf 'redeem: %s\n' "$*" >&2
  exit 1
}

# True (return 0) only for a regular file path that is not a device node
# and does not live under /dev, /sys, or /proc. The file may not exist yet.
target_is_safe_image() {
  local path=$1
  local real parent
  if [[ -z $path || $path == -* ]]; then
    return 1
  fi
  case $path in
    /dev|/dev/*|/sys|/sys/*|/proc|/proc/*) return 1 ;;
  esac
  if [[ -e $path ]]; then
    real=$(readlink -f -- "$path")
  else
    parent=$(dirname -- "$path")
    if [[ ! -d $parent ]]; then
      return 1
    fi
    real=$(readlink -f -- "$parent")/$(basename -- "$path")
  fi
  case $real in
    /dev|/dev/*|/sys|/sys/*|/proc|/proc/*) return 1 ;;
  esac
  if [[ -b $real || -c $real || -b $path || -c $path ]]; then
    return 1
  fi
  if [[ -e $path && ! -f $path ]]; then
    return 1
  fi
  return 0
}

assert_safe_image() {
  local path=$1
  if ! target_is_safe_image "$path"; then
    die "refusing '$path' (not a plain image file). redeem never writes a real block device."
  fi
}

# Confirm a loop device is attached to the image we just created.
assert_loop_backs_image() {
  local loop=$1 image=$2
  local base backing want
  case $loop in
    /dev/loop*) ;;
    *) die "refusing non-loop device '$loop'" ;;
  esac
  base=${loop#/dev/}
  if [[ ! -r /sys/block/$base/loop/backing_file ]]; then
    die "$loop has no loop backing file"
  fi
  backing=$(readlink -f -- "$(cat "/sys/block/$base/loop/backing_file")")
  want=$(readlink -f -- "$image")
  if [[ $backing != "$want" ]]; then
    die "$loop backs '$backing', not '$want'"
  fi
}

sha256_file() {
  sha256sum -- "$1" | awk '{print $1}'
}

verify_sha256() {
  local file=$1 expect=$2
  local got
  [[ -f $file ]] || die "missing $file"
  got=$(sha256_file "$file")
  if [[ $got != "$expect" ]]; then
    die "checksum mismatch for $file
expected $expect
got      $got"
  fi
  printf 'checksum ok %s %s\n' "$got" "$(basename -- "$file")"
}

# rtk (https://github.com/rtk-ai/rtk) collapses noisy command output.
# It is a developer tool. It is not copied onto the rescue USB.
rtk_err() {
  if command -v rtk >/dev/null 2>&1; then
    rtk err -- "$@"
  else
    "$@"
  fi
}

load_versions() {
  local root
  root=$(redeem_root)
  # shellcheck disable=SC1091
  source "$root/build/versions.env"
}
