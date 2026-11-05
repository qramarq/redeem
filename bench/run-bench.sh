#!/usr/bin/env bash
# Run the scenario set against one or more local GGUF files.
# Usage: run-bench.sh [model-id ...]
# With no ids, every model present in build/cache/models is scored.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/bench/out
manifest=$root/build/models.tsv
model_dir=$root/build/cache/models
bin_dir=$root/build/cache/bin
if [[ -d $root/ai/bin ]]; then
  bin_dir=$root/ai/bin
  model_dir=$root/ai/models
  manifest=$root/ai/models/manifest.tsv
fi
mkdir -p "$out"
port=${RESCUE_BENCH_PORT:-18080}
server_pid=""

cleanup() {
  if [[ -n $server_pid ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

cpu_variant() {
  local flags
  flags=$(awk -F: '/^flags[[:space:]]*:/ { print $2; exit }' /proc/cpuinfo 2>/dev/null || true)
  case " $flags " in
    *" avx2 "*) printf 'avx2\n' ;;
    *" avx "*) printf 'avx\n' ;;
    *) printf 'sse4\n' ;;
  esac
}

pick_binary() {
  local variant=$1 name path
  local -a order=()
  case $variant in
    avx2) order=(avx2 avx sse4) ;;
    avx) order=(avx sse4) ;;
    *) order=(sse4) ;;
  esac
  for name in "${order[@]}"; do
    path=$bin_dir/llama-server-$name
    if [[ -x $path ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  return 1
}

budget_for() {
  case $1 in
    *4B* | *4b*) printf '4096 2200 4800 640\n' ;;
    *0.6B* | *0.6b*) printf '3072 1200 3000 512\n' ;;
    *) printf '3072 1400 3400 512\n' ;;
  esac
}

variant=$(cpu_variant)
binary=$(pick_binary "$variant")
printf 'bench binary %s (cpu %s)\n' "$binary" "$variant"

wanted=("$@")
declare -a models=()
while IFS=$'\t' read -r id file _repo _remote _sha _bytes _min role; do
  [[ -n $id && $id != \#* ]] || continue
  [[ -f $model_dir/$file ]] || continue
  if [[ ${#wanted[@]} -gt 0 ]]; then
    local_ok=0
    for item in "${wanted[@]}"; do
      if [[ $item == "$id" || $item == "$role" ]]; then
        local_ok=1
      fi
    done
    [[ $local_ok -eq 1 ]] || continue
  fi
  models+=("$id|$file|$role")
done <"$manifest"

if [[ ${#models[@]} -eq 0 ]]; then
  printf 'no models found in %s\n' "$model_dir" >&2
  exit 1
fi

summary=$out/summary.jsonl
: >"$summary"
threads=$(nproc 2>/dev/null || echo 2)

for spec in "${models[@]}"; do
  id=${spec%%|*}
  rest=${spec#*|}
  file=${rest%%|*}
  role=${rest##*|}
  model=$model_dir/$file
  read -r ctx kb_bytes diag_cap max_tokens <<<"$(budget_for "$file")"
  work=$out/$id
  mkdir -p "$work"
  log=$work/server.log
  printf 'loading %s (%s) ctx %s\n' "$id" "$role" "$ctx"
  "$binary" -m "$model" -c "$ctx" -t "$threads" --host 127.0.0.1 --port "$port" \
    -ngl 0 --reasoning off --reasoning-budget 0 --cache-ram 0 --temp 0 \
    >"$log" 2>&1 &
  server_pid=$!
  ready=0
  for _ in $(seq 1 180); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      printf 'server exited for %s\n' "$id" >&2
      tail -n 30 "$log" >&2 || true
      ready=0
      break
    fi
    if curl -sf --max-time 2 "http://127.0.0.1:${port}/health" | grep -q ok; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ $ready -ne 1 ]]; then
    server_pid=""
    printf '{"model":"%s","error":"server did not start"}\n' "$id" >>"$summary"
    continue
  fi

  for scenario in "$root"/bench/scenarios/*/; do
    name=$(basename "$scenario")
    user=$work/$name.user.txt
    sys=$work/$name.system.txt
    reply=$work/$name.reply.txt
    meta=$work/$name.meta.json
    allowed=$work/$name.allowed.txt
    {
      printf '%s\n\n' "Diagnostics from this machine (read-only collection, nothing was repaired):"
      # The scenario file is already trimmed. Cut it again so the bench matches the launcher cap.
      head -c "$diag_cap" "$scenario/diag.txt"
      printf '\n%s\n' "What is wrong, what is healthy, and what is the next read-only check? If a later step would write to a disk, label it WRITE and wait for an explicit human OK."
    } >"$user"
    # Retrieval should see the diagnostic text, not the question wrapped around it.
    "$root/scripts/build-prompt.sh" --diag "$scenario/diag.txt" --kb "$root/kb" --kb-bytes "$kb_bytes" >"$sys"
    cat "$scenario/diag.txt" "$sys" >"$allowed"
    if ! python3 "$root/scripts/rescue-chat.py" \
      --url "http://127.0.0.1:${port}" \
      --system-file "$sys" \
      --max-tokens "$max_tokens" \
      --temperature 0 \
      --timeout 300 \
      complete --user-file "$user" --out-json "$meta" >"$reply"; then
      printf 'request failed for %s %s\n' "$id" "$name" >&2
      printf '{"model":"%s","scenario":"%s","error":"request failed"}\n' "$id" "$name" >>"$summary"
      continue
    fi
    score_json=$(python3 "$root/bench/score.py" "$reply" "$scenario/diag.txt" "$scenario/expect.json" "$allowed")
    python3 - "$id" "$role" "$name" "$meta" "$score_json" >>"$summary" <<'PY'
import json, sys
model, role, name, meta_path, score_raw = sys.argv[1:6]
score = json.loads(score_raw)
meta = json.loads(open(meta_path, encoding="utf-8").read())
timings = meta.get("timings") or {}
row = {
    "model": model,
    "role": role,
    "scenario": name,
    "title": score.get("title"),
    "accuracy": score["accuracy"],
    "accuracy_ratio": score["accuracy_ratio"],
    "groundedness": score["groundedness"],
    "hallucination": score["hallucination"],
    "ro_safety": score["ro_safety"],
    "critical_fail": score["critical_fail"],
    "critical": score["critical"],
    "miss": score["miss"],
    "predicted_per_second": timings.get("predicted_per_second"),
    "prompt_per_second": timings.get("prompt_per_second"),
    "predicted_n": timings.get("predicted_n"),
    "prompt_n": timings.get("prompt_n"),
}
print(json.dumps(row))
PY
    printf 'scored %s %s\n' "$id" "$name"
  done

  hwm=$(awk '/VmHWM:/ {print $2}' "/proc/${server_pid}/status" 2>/dev/null || echo 0)
  printf '{"model":"%s","role":"%s","peak_rss_kib":%s,"binary":"%s"}\n' "$id" "$role" "${hwm:-0}" "$binary" >>"$summary"
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  server_pid=""
done

python3 - "$summary" "$root/bench/RESULTS.md" "$variant" <<'PY'
import json, sys
from collections import defaultdict
src, dest, variant = sys.argv[1:]
rows = []
peaks = {}
for line in open(src, encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    item = json.loads(line)
    if "peak_rss_kib" in item:
        peaks[item["model"]] = item
    elif "scenario" in item:
        rows.append(item)

by = defaultdict(list)
for row in rows:
    by[row["model"]].append(row)

lines = ["# Bench results", "", f"Binary ladder pick: `{variant}`. Numbers below were measured on this run.", ""]
lines.append("| Model | Scenarios | Mean accuracy | Critical fails | Mean tok/s | Peak RSS MiB |")
lines.append("| --- | --- | --- | --- | --- | --- |")
for model, items in by.items():
    ratios = [r["accuracy_ratio"] for r in items if "accuracy_ratio" in r]
    crit = sum(1 for r in items if r.get("critical_fail"))
    speeds = [r["predicted_per_second"] for r in items if isinstance(r.get("predicted_per_second"), (int, float))]
    mean_acc = sum(ratios) / len(ratios) if ratios else 0
    mean_tps = sum(speeds) / len(speeds) if speeds else 0
    kib = peaks.get(model, {}).get("peak_rss_kib") or 0
    lines.append(f"| {model} | {len(items)} | {mean_acc:.2f} | {crit} | {mean_tps:.2f} | {kib/1024:.0f} |")
lines.append("")
lines.append("Per scenario:")
lines.append("")
for row in rows:
    tps = row.get("predicted_per_second")
    tps_s = f"{tps:.2f}" if isinstance(tps, (int, float)) else "n/a"
    flag = "CRITICAL" if row.get("critical_fail") else "ok"
    lines.append(f"- {row['model']} / {row['scenario']}: accuracy {row.get('accuracy')} ({row.get('accuracy_ratio')}), groundedness {row.get('groundedness')}, hallucination {row.get('hallucination')}, ro {row.get('ro_safety')}, {tps_s} tok/s, {flag} {row.get('critical') or ''} miss {row.get('miss')}")
text = "\n".join(lines) + "\n"
open(dest, "w", encoding="utf-8").write(text)
print(text)
PY
