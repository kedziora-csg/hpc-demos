#!/bin/bash
#
# Submit the runs: each queue x GPUs per node x memory placement.
#
#   ./submit_matrix.sh [main] [develop] [limits]     (default: main develop)
#
#   main      main queue (routed to gpu): 1, 2 and 4 GPUs per node, free
#             and membind -- 6 launch_cf runs of 4 steps, 7 nodes each mode
#   develop   the same in develop (routed to gpudev, shared nodes)
#   limits    develop's limits, submitted on their own so other develop jobs
#             do not hold GPUs meanwhile:
#               5 nodes of 1 GPU   an array of 5 (develop allows 4)
#               3 nodes of 4 GPUs  12 GPUs (a user may run 8 at once)
#
# Every run uses 4 steps, one per GPU, so 1 GPU per node takes 4 nodes, 2
# takes 2 and 4 takes 1.  Each line of submitted.log gives a run's case and
# job id (or qsub's refusal).  When they have finished, ./summarize.sh.

set -u
cd "$(dirname "$0")" || exit 1
[ -n "${PBS_ACCOUNT:-}" ] || { echo "ERROR: set PBS_ACCOUNT"; exit 1; }
which=("$@")
[ ${#which[@]} -gt 0 ] || which=(main develop)

# submit <label> <queue> <ngpus> <nsteps> <mode>
submit() {
    local label="$1" queue="$2" ngpus="$3" nsteps="$4" mode="$5" cf out
    cf=$(./gen_cmdfile_gpu.sh "$ngpus" "$nsteps" "$mode")
    out=$(./launch_cf_gpu.sh -A "$PBS_ACCOUNT" -l walltime=00:10:00 -N "gpubw_$label" \
              -q "$queue" --ngpus "$ngpus" "$cf" 2>&1)
    echo "$out"
    printf "%s %s ngpus=%s nsteps=%s mode=%s %s\n" "$label" "$queue" "$ngpus" "$nsteps" "$mode" \
        "$(tail -1 <<<"$out" | tr -s ' \n' ' ')" >>submitted.log
}

for w in "${which[@]}"; do
    case "$w" in
        main|develop)
            for n in 1 2 4; do
                for mode in free membind; do
                    submit "${w}_${n}gpu_$mode" "$w" "$n" 4 "$mode"
                done
            done ;;
        limits)
            submit develop_array5 develop 1 5 free
            submit develop_12gpu  develop 4 12 free ;;
        *)  echo "ERROR: unknown set $w"; exit 1 ;;
    esac
done
