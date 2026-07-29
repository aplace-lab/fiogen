#!/usr/bin/env bash
#
#   ./fiogen.sh workloads/app12.csv /ldata/ldata /rdata/rdata
#   ./fiogen.sh workloads/app1.csv workloads/app2.csv /rdata/rdata
#
#   RUNTIME=180   seconds per target
#   RAMP=10       seconds discarded at the start
#   SCALE=1       multiply every rate; pct_of_target is measured against it
#   MAX=0         1 = no rate limit, run flat out
#   FSYNC=1       0 = drop the flush-after-each-file barrier
#   SMOOTH=10     seconds of rolling average over the reported rates; 1 = raw
#   ONLY=         regex of test names to include, e.g. 'a1d6|a2d6'
#   KEEP=0        1 = leave the written files behind
#   OUT=          output directory (default ./fio-<timestamp>)
#   PAR=32        parallel workers used to warm and to delete the file tree
#   WARM=1        0 = skip the dentry pre-warm (see warm_dir() below)
#
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNTIME=${RUNTIME:-180}; RAMP=${RAMP:-10}; SCALE=${SCALE:-1}
MAX=${MAX:-0}; FSYNC=${FSYNC:-1}; KEEP=${KEEP:-0}; SMOOTH=${SMOOTH:-10}
PAR=${PAR:-32}; WARM=${WARM:-1}
STAMP=$(date +%Y%m%d-%H%M%S)

CSV_HEADER="target,test,sec,files_per_s,bw_kib_s,lat_us,samples,pct_of_target"

usage() { awk 'NR < 3 {next} !/^#/ {exit} {sub(/^# ?/, ""); print}' "$0"; exit 1; }

throttle() { while (( $(jobs -rp | wc -l) >= PAR )); do wait -n || true; done; }

time_phase() { # time_phase <label> <cmd>...
  local label=$1 start=$SECONDS; shift
  "$@"
  printf '    %-8s %4ds\n' "$label" "$((SECONDS - start))" >&2
}

# Dir per job clone
job_dirs() { # job_dirs <target> <test> <count>
  local d="$1/$2/$STAMP" j out=
  for ((j = 0; j < $3; j++)); do out+="$d/$j:"; done
  out=${out%:}
  (( ${#out} < 8192 )) || {
    echo "$2: $3 directories under $d need ${#out} bytes of fio's 8192" \
         "byte limit - use a shorter target path" >&2
    return 1
  }
  printf '%s' "$out"
}

# Substitute {{KEY}} placeholders in a template.
render() { # render <template> KEY=VALUE...
  local tpl=$1 kv; shift
  local -a sed_args=()
  for kv in "$@"; do sed_args+=(-e "s|{{${kv%%=*}}}|${kv#*=}|g"); done
  sed "${sed_args[@]}" "$tpl"
}

# Turn the workload CSV into one line per test
plan() {
  awk -F'[,[:space:]]+' -v scale="$SCALE" -v unlimited="$MAX" -v dur="$((RUNTIME + RAMP))" '
    /^[[:space:]]*#/ || NF < 5 { next }
    {
      name = $1; period = $2; bytes = $3; files = $4; count = $5
      per_job = files * scale / (period * count)          # files/s one job owes
      rate    = unlimited ? 0 : int(per_job * bytes + 0.5)
      nrfiles = int(per_job * dur * (unlimited ? 10 : 1) + 1)
      if (nrfiles > 20000) nrfiles = 20000
      printf "%s %d %d %d %d %.0f\n", name, bytes, count, rate, nrfiles,
             per_job * count * bytes
    }
  ' "${WORKLOADS[@]}" | { [[ -n ${ONLY:-} ]] && grep -E "^($ONLY) " || cat; }
}

build_job_file() { # build_job_file <target> <logdir>
  local dirs
  render "$HERE/templates/global.fio" RUNTIME="$RUNTIME" RAMP="$RAMP" FSYNC="$FSYNC"
  while read -r name bytes count rate nrfiles _; do
    dirs=$(job_dirs "$1" "$name" "$count")
    render "$HERE/templates/job.fio" \
      NAME="$name" LOGDIR="$2" DIRS="$dirs" \
      COUNT="$count" BYTES="$bytes" RATE="$rate" NRFILES="$nrfiles"
  done <<< "$PLAN"
}

prepare() { # prepare <target>
  local name count nrfiles d j
  while read -r name _ count _ nrfiles _; do
    d="$1/$name/$STAMP"
    for ((j = 0; j < count; j++)); do
      mkdir -p "$d/$j"
      [[ $WARM == 1 ]] || continue
      throttle
      warm_dir "$d/$j/$j" "$nrfiles" &
    done
  done <<< "$PLAN"
  wait || true
}

# Stat every file fio is about to create
warm_dir() { # warm_dir <prefix> <nrfiles>
  local f
  for ((f = 0; f < $2; f++)); do [[ -e "$1.$f" ]] || true; done
}

scrub() { # scrub <target>
  local name count j
  while read -r name _ count _; do
    for ((j = 0; j < count; j++)); do
      throttle
      rm -rf "${1:?}/$name/$STAMP/$j" &
    done
  done <<< "$PLAN"
  wait || true
  while read -r name _; do rm -rf "${1:?}/$name"; done <<< "$PLAN"
}

collect() { # collect <label> <logdir>
  while read -r name bytes _ _ _ target_bps; do
    [[ -e "$2/${name}_bw.log" ]] || continue
    awk -F'[,[:space:]]+' -v label="$1" -v test="$name" -v bytes="$bytes" -v target="$target_bps" \
        -v win="$SMOOTH" '
      FILENAME ~ /_iops/ { samples[int($1/1000)]++;      next }
      FILENAME ~ /_bw/   { bw[int($1/1000)]     += $2;   next }
                         { sec = int($1/1000); lat[sec] += $2; n[sec]++ }
      END {
        if (win < 1) win = 1
        for (sec in bw) if (sec + 0 > last) last = sec + 0
        for (sec = 1; sec <= last; sec++) {
          if (!(sec in bw)) continue
          lo = sec - int((win - 1) / 2); hi = lo + win - 1
          if (hi > last) { hi = last; lo = hi - win + 1 }
          if (lo < 1)    { lo = 1;    hi = (win < last ? win : last) }
          sbw = slat = k = 0
          for (i = lo; i <= hi; i++) {
            if (!(i in bw)) continue
            sbw += bw[i]; slat += n[i] ? lat[i] / n[i] : 0; k++
          }
          avg = sbw / k; bps = avg * 1024
          printf "%s,%s,%d,%.2f,%d,%.1f,%d,%.1f\n", label, test, sec,
                 bps / bytes, avg, slat / k / 1000,
                 samples[sec], bps / target * 100
        }
      }
    ' "$2/${name}"_{iops,bw,lat}.log
  done <<< "$PLAN"
}

run_target() { # run_target <target>
  local target=$1 label logdir
  label=$(basename "$target"); logdir="$OUT/$label"
  mkdir -p "$logdir"

  build_job_file "$target" "$logdir" > "$OUT/$label.fio"
  echo "==> $label ($target)"
  time_phase "prepare" prepare "$target"
  sync
  time_phase "run" fio --alloc-size=262144 "$OUT/$label.fio" \
      --output-format=json --output="$OUT/$label.json"
  collect "$label" "$logdir" >> "$OUT/results.csv"

  [[ $KEEP == 1 ]] || time_phase "clean" scrub "$target"
}

WORKLOADS=(); TARGETS=()
for arg in "$@"; do
  case $arg in
    *.csv) [[ -f $arg ]] || { echo "no such workload: $arg" >&2; exit 1; }
           WORKLOADS+=("$arg") ;;
        *) TARGETS+=("$arg") ;;
  esac
done
[[ ${#WORKLOADS[@]} -gt 0 && ${#TARGETS[@]} -gt 0 ]] || usage

PLAN=$(plan)   # fixed for the whole run; every loop below reads it
[[ -n $PLAN ]] || { echo "no tests selected${ONLY:+ by ONLY=$ONLY}" >&2; exit 1; }

dupes=$(awk '{print $1}' <<< "$PLAN" | sort | uniq -d)
[[ -z $dupes ]] || { echo "duplicate test names across workloads: $dupes" >&2; exit 1; }

OUT=${OUT:-./fio-$STAMP}
mkdir -p "$OUT"
echo "$CSV_HEADER" > "$OUT/results.csv"
cat "${WORKLOADS[@]}" > "$OUT/workload.csv"

for target in "${TARGETS[@]}"; do run_target "$target"; done
echo "==> $OUT/results.csv"