#!/bin/bash
# Double-click in Finder. Read-only macOS triage. --lan is not used.
# /bin/bash on macOS is 3.2, so this file stays clear of bash 4 features.
set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
PORT=${RESCUE_PORT:-8080}
TMP=${RESCUE_TMP:-/tmp/redeem}
mkdir -p "$TMP"
SERVER_PID=""

cleanup() {
    if [[ -n $SERVER_PID ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

free_mb() {
    local ps
    ps=$(sysctl -n hw.pagesize)
    vm_stat | awk -v ps="$ps" '
        function num(s) { gsub(/[^0-9]/, "", s); return s + 0 }
        /Pages free/ { f = num($NF) }
        /Pages inactive/ { i = num($NF) }
        /Pages speculative/ { s = num($NF) }
        END { printf "%d\n", (f + i + s) * ps / 1024 / 1024 }
    '
}

endpoint_ok() {
    local base code
    base=${1%/}
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "$base/v1/models" || true)
    if [[ $code == 200 ]]; then
        return 0
    fi
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "$base/health" || true)
    [[ $code == 200 ]]
}

pick_model() {
    local free=$1 want=${RESCUE_MODEL:-}
    local id file path path_4b="" path_1b="" path_06=""
    local manifest=$ROOT/ai/models/manifest.tsv
    [[ -f $manifest ]] || return 1
    while IFS="$(printf '\t')" read -r id file _rest; do
        case $id in
            "" | \#*) continue ;;
        esac
        path=$ROOT/ai/models/$file
        [[ -f $path ]] || continue
        if [[ -n $want && ( $id == "$want" || $file == *"$want"* ) ]]; then
            printf '%s\n' "$path"
            return 0
        fi
        case $id in
            qwen3-4b) path_4b=$path ;;
            llama32-1b) path_1b=$path ;;
            qwen3-0.6b) path_06=$path ;;
        esac
    done <"$manifest"
    [[ -z $want ]] || return 1
    if [[ $free -ge 5120 && -n $path_4b ]]; then
        printf '%s\n' "$path_4b"
        return 0
    fi
    if [[ $free -ge 1536 && -n $path_1b ]]; then
        printf '%s\n' "$path_1b"
        return 0
    fi
    if [[ -n $path_06 ]]; then
        printf '%s\n' "$path_06"
        return 0
    fi
    if [[ -n $path_1b ]]; then
        printf '%s\n' "$path_1b"
        return 0
    fi
    if [[ -n $path_4b ]]; then
        printf '%s\n' "$path_4b"
        return 0
    fi
    return 1
}

printf 'redeem: read-only session. Writes happen only after an explicit human OK.\n'
printf 'redeem: FileVault and APFS encryption are detect-and-explain only.\n'

diag=$TMP/rescue-diag.txt
bash "$ROOT/ai/scripts/collect-diag-macos.sh" --out "$diag" --max-bytes 8000
sys=$TMP/system.txt
bash "$ROOT/ai/scripts/build-prompt.sh" --diag "$diag" --kb "$ROOT/ai/kb" --kb-bytes 1400 >"$sys"
user_file=$TMP/user.txt
{
    printf '%s\n\n' "Diagnostics from this machine (read-only collection, nothing was repaired):"
    cat "$diag"
    printf '\n%s\n' "What is wrong, what is healthy, and what is the next read-only check? If a later step would write to a disk, label it WRITE and wait for an explicit human OK."
} >"$user_file"

remote=""
if [[ -n ${RESCUE_ENDPOINT:-} ]] && endpoint_ok "$RESCUE_ENDPOINT"; then
    remote=${RESCUE_ENDPOINT%/}
    printf 'redeem: using RESCUE_ENDPOINT %s\n' "$remote"
fi

model=""
binary=""
ctx=3072
tokens=512
if [[ -z $remote ]]; then
    free=$(free_mb)
    printf 'redeem: MemAvailable-style estimate %s MiB\n' "$free"
    if ! model=$(pick_model "$free"); then
        printf 'redeem: no GGUF in %s\n' "$ROOT/ai/models" >&2
        exit 1
    fi
    case $(uname -m) in
        arm64) binary=$ROOT/ai/bin/macos-arm64/llama-server ;;
        x86_64) binary=$ROOT/ai/bin/macos-x64/llama-server ;;
        *)
            printf 'redeem: unsupported CPU %s\n' "$(uname -m)" >&2
            exit 1
            ;;
    esac
    if [[ ! -f $binary ]]; then
        printf 'redeem: missing %s (run build/fetch-host-binaries.sh)\n' "$binary" >&2
        exit 1
    fi
    chmod +x "$binary" 2>/dev/null || true
    case $model in
        *4B* | *4b*) ctx=4096; tokens=640 ;;
        *) ctx=3072; tokens=512 ;;
    esac
    threads=$(sysctl -n hw.ncpu 2>/dev/null || printf '2')
    if [[ $threads -gt 8 ]]; then
        threads=8
    fi
    help=$("$binary" --help 2>&1 || true)
    args=("$binary" -m "$model" -c "$ctx" -t "$threads" --host 127.0.0.1 --port "$PORT" -ngl 0)
    case $help in
        *--reasoning*) args+=(--reasoning off) ;;
    esac
    case $help in
        *--cache-ram*) args+=(--cache-ram 0) ;;
    esac
    case $help in
        *--temp*) args+=(--temp 0.2) ;;
    esac
    case $help in
        *--jinja*) args+=(--jinja) ;;
    esac
    log=$TMP/llama-server.log
    "${args[@]}" >"$log" 2>&1 &
    SERVER_PID=$!
    printf 'redeem: model %s\n' "$model"
    printf 'redeem: binary %s\n' "$binary"
    ready=0
    i=0
    while [[ $i -lt 180 ]]; do
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            printf 'llama-server exited early. Last log lines:\n' >&2
            tail -n 40 "$log" >&2 || true
            exit 1
        fi
        if curl -sf --max-time 2 "http://127.0.0.1:${PORT}/health" | grep -q ok; then
            ready=1
            break
        fi
        i=$((i + 1))
        sleep 1
    done
    if [[ $ready -ne 1 ]]; then
        printf 'llama-server did not become ready\n' >&2
        tail -n 40 "$log" >&2 || true
        exit 1
    fi
    base=http://127.0.0.1:${PORT}
else
    base=$remote
fi

py=$(command -v python3 || true)
if [[ -z $py ]]; then
    printf 'redeem: python3 is required for the first diagnosis turn\n' >&2
    exit 1
fi
reply=$TMP/first-turn.txt
"$py" "$ROOT/ai/scripts/rescue-chat.py" \
    --url "$base" \
    --system-file "$sys" \
    --max-tokens "$tokens" \
    --temperature 0.2 \
    complete --user-file "$user_file" --out-json "$TMP/first-turn.json" | tee "$reply"

ui=http://127.0.0.1:${PORT}
if [[ -n $remote ]]; then
    ui=$remote
fi
printf '\nredeem: web UI %s\n' "$ui"
if ! open "$ui"; then
    printf 'redeem: the browser did not open. Use the URL above in this terminal.\n'
fi
if [[ -n $SERVER_PID ]]; then
    printf 'redeem: server is running. Ctrl-C stops it.\n'
    wait "$SERVER_PID" || true
fi
