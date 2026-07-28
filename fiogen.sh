#!/usr/bin/env bash
#
#   ./fiogen.sh workloads/app12.csv /ldata/ldata /rdata/rdata
#   ./fiogen.sh workloads/app1.csv workloads/app2.csv /rdata/rdata
#
#   RUNTIME=180   seconds per target
#   RAMP=10       seconds discarded at the start
#   SCALE=1       multiply every rate; pct_of_target is measured against it
#   MAX=0         1 = no rate limit, run flat out
#   FSYNC=1       0 = drop the fsync-on-close barrier
#   ONLY=         regex of test names to include, e.g. 'a1d6|a2d6'
#   KEEP=0        1 = leave the written files behind
#   OUT=          output directory (default ./fio-<timestamp>)
#
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNTIME=${RUNTIME:-180}; RAMP=${RAMP:-10}; SCALE=${SCALE:-1}
MAX=${MAX:-0}; FSYNC=${FSYNC:-1}; KEEP=${KEEP:-0}

CSV_HEADER="target,test,sec,files_per_s,bw_kib_s,lat_us,samples,pct_of_target"

usage() { sed -n '3,24p' "$0" | sed 's/^# \?//'; exit 1; }

# Substitute {{KEY}} placeholders in a template.
render() { # render <template> KEY=VALUE...
  local tpl=$1 kv; shift
  local -a sed_args=()
  for kv in "$@"; do sed_args+=(-e "s|{{${kv%%=*}}}|${kv#*=}|g"); done
  sed "${sed_args[@]}" "$tpl"
}

# Turn the workload CSV into one line per test
plan() {
  awk -F'[,[:space:]]+' -v scale="$SCALE" -v unlimited="$MAX" '
    /^[[:space:]]*#/ || NF < 5 { next }
    {
      name = $1; period = $2; bytes = $3; files = $4; count = $5
      rate    = unlimited ? 0 : int(files * bytes * scale / (period * count) + 0.5)
      nrfiles = int(5 * files * scale / (period * count))
      if (nrfiles < 16)  nrfiles = 16
      if (nrfiles > 256) nrfiles = 256
      printf "%s %d %d %d %d %.0f\n", name, bytes, count, rate, nrfiles,
             files * bytes * scale / period
    }
  ' "${WORKLOADS[@]}" | { [[ -n ${ONLY:-} ]] && grep -E "^($ONLY) " || cat; }
}

build_job_file() { # build_job_file <target> <logdir>
  render "$HERE/templates/global.fio" RUNTIME="$RUNTIME" RAMP="$RAMP" FSYNC="$FSYNC"
  while read -r name bytes count rate nrfiles _; do
    render "$HERE/templates/job.fio" \
      NAME="$name" TARGET="$1" LOGDIR="$2" \
      COUNT="$count" BYTES="$bytes" RATE="$rate" NRFILES="$nrfiles"
  done < <(plan)
}

collect() { # collect <label> <logdir>
  while read -r name bytes _ _ _ target_bps; do
    [[ -e "$2/${name}_bw.log" ]] || continue
    awk -F'[,[:space:]]+' -v label="$1" -v test="$name" -v bytes="$bytes" -v target="$target_bps" '
      FILENAME ~ /_iops/ { samples[int($1/1000)]++;      next }
      FILENAME ~ /_bw/   { bw[int($1/1000)]     += $2;   next }
                         { sec = int($1/1000); lat[sec] += $2; n[sec]++ }
      END {
        for (sec in bw) {
          bps = bw[sec] * 1024
          printf "%s,%s,%d,%.2f,%d,%.1f,%d,%.1f\n", label, test, sec,
                 bps / bytes, bw[sec], n[sec] ? lat[sec] / n[sec] / 1000 : 0,
                 samples[sec], bps / target * 100
        }
      }
    ' "$2/${name}"_{iops,bw,lat}.log | sort -t, -k3n
  done < <(plan)
}

run_target() { # run_target <target>
  local target=$1 label logdir names name
  label=$(basename "$target"); logdir="$OUT/$label"
  names=$(plan | awk '{print $1}')
  mkdir -p "$logdir"
  for name in $names; do mkdir -p "$target/$name"; done

  build_job_file "$target" "$logdir" > "$OUT/$label.fio"
  echo "==> $label ($target)"
  sync
  fio --alloc-size=262144 "$OUT/$label.fio" \
      --output-format=json --output="$OUT/$label.json"
  collect "$label" "$logdir" >> "$OUT/results.csv"

  if [[ $KEEP != 1 ]]; then
    for name in $names; do rm -rf "${target:?}/$name"; done
  fi
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

dupes=$(plan | awk '{print $1}' | sort | uniq -d)
[[ -z $dupes ]] || { echo "duplicate test names across workloads: $dupes" >&2; exit 1; }

OUT=${OUT:-./fio-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
echo "$CSV_HEADER" > "$OUT/results.csv"
cat "${WORKLOADS[@]}" > "$OUT/workload.csv"

for target in "${TARGETS[@]}"; do run_target "$target"; done
echo "==> $OUT/results.csv"