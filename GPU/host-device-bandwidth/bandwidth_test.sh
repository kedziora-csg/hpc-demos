#!/bin/bash
#PBS -N bandwidth_test
#PBS -q main
#PBS -l select=1:ncpus=64:ngpus=4
#PBS -l walltime=00:20:00
#PBS -j oe
#
# How fast can data move between host memory and GPU memory on a Derecho GPU
# node, and what slows it down?
#
# A node has one 64-core AMD EPYC 7763 split into 4 NUMA domains, and 4 A100
# GPUs, each on its own PCIe 4.0 x16 link to one domain.  Two tools measure
# the copies:
#
#   bandwidthTest  the CUDA sample, shipped ready to run with the CUDA toolkit
#                  ($CUDA_HOME/extras/demo_suite).  One GPU at a time.
#   nvbandwidth    its successor, built by ./build_nvbandwidth.sh.  Can drive
#                  all 4 GPUs at once.
#
# Parts:
#
#   1 topology   which NUMA domain each GPU is attached to, and its PCIe link
#   2 memory     bandwidthTest on each GPU from its own domain: pinned (page-
#                locked) host memory against ordinary pageable memory, and
#                pageable memory from another domain
#   3 one GPU    nvbandwidth, one GPU at a time: host memory in the GPU's own
#                domain, then all of it in domain 0
#   4 four GPUs  nvbandwidth, all 4 GPUs copying at once, with host memory
#                  local       each GPU's buffer in its own domain
#                  one domain  every buffer in domain 0, as when one process
#                              allocates them all from one thread
#                  interleave  every buffer spread over all 4 domains
#   5 size       bandwidthTest on GPU 0, pinned, transfer sizes 4 KiB - 256 MiB
#
# Bandwidths are GB/s (10^9 bytes/s).  Everything the tools print goes to
# bandwidth_test.<host>.<time>.log; this script prints a summary.
#
# Run it on a GPU node, interactively or as a batch job:
#
#   qsub -I -A $PBS_ACCOUNT -q main -l select=1:ncpus=64:ngpus=4 -l walltime=00:20:00
#   ./bandwidth_test.sh
#
#   qsub -A $PBS_ACCOUNT bandwidth_test.sh
#
# Ask for the whole node (all 4 GPUs), so no other job's copies share the
# memory and links being measured.
#
# Environment:
#   CUDA_MODULE=cuda/12.9.0   the CUDA module (the one nvbandwidth was built with)
#   PARTS="1 2 3 4 5"         which parts to run

set -u

# a batch job starts in $HOME; run from the directory it was submitted from
if [ "${PBS_ENVIRONMENT:-}" = PBS_BATCH ]; then
    cd "${PBS_O_WORKDIR}" || exit 1
else
    cd "$(dirname "$0")" || exit 1
fi

module load "${CUDA_MODULE:-cuda/12.9.0}" || exit 1
bt="${CUDA_HOME}/extras/demo_suite/bandwidthTest"
nvb=./nvbandwidth
parts=" ${PARTS:-1 2 3 4 5} "

[ -x "$bt" ] || { echo "ERROR: no $bt"; exit 1; }
command -v numactl >/dev/null || { echo "ERROR: needs numactl"; exit 1; }
ngpus=$(nvidia-smi -L 2>/dev/null | grep -c '^GPU')
[ "$ngpus" -gt 0 ] || { echo "ERROR: no GPUs -- run this on a GPU node"; exit 1; }
if [[ "$parts" == *" 3 "* || "$parts" == *" 4 "* ]]; then
    [ -x "$nvb" ] || { echo "ERROR: no ./nvbandwidth -- run ./build_nvbandwidth.sh first"; exit 1; }
fi

log="bandwidth_test.$(hostname -s).$(date +%Y%m%d-%H%M%S).log"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# the NUMA domain a GPU's PCIe link is attached to
gpu_domain() {
    local bus
    bus=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader -i "$1")
    bus=${bus,,}                                    # 00000000:03:00.0
    cat "/sys/bus/pci/devices/${bus#0000}/numa_node" # 0000:03:00.0
}

# run a command, keep its output in the log and in $tmp
run() {
    echo "### $*" >>"$log"
    "$@" >"$tmp" 2>&1
    cat "$tmp" >>"$log"
}

# bandwidthTest --csv lines -> "H2D-Pinned 26.0" (GB/s, whichever unit it used)
bt_parse() {
    awk '/^bandwidthTest-/ {
        kind = $1; sub(/^bandwidthTest-/, "", kind); sub(/,$/, "", kind)
        bw = $4; if ($5 ~ /^MB/) bw /= 1000
        printf "%s %.1f\n", kind, bw }' "$tmp"
}

# nvbandwidth output -> one line per test: its name, each GPU's value, and for
# the tests where the GPUs copy at the same time, their total
nvb_parse() {
    awk -v label="$1" '
        /^Running / { t = $2; sub(/\.$/, "", t) }
        t != "" && /^ 0 / { row = ""; for (i = 2; i <= NF; i++) row = row sprintf("%7.1f", $i) }
        /^SUM / {
            total = (t ~ /all/) ? sprintf("   total %6.1f", $3) : ""
            printf "  %-11s %-38s%s%s\n", label, t, row, total }' "$tmp"
}

echo "bandwidth_test on $(hostname -s), $ngpus GPUs, $(date)"
echo "full output: $log"
echo "bandwidth_test on $(hostname -s), $(date)" >"$log"

declare -a dom
for ((g = 0; g < ngpus; g++)); do dom[g]=$(gpu_domain "$g"); done

if [[ "$parts" == *" 1 "* ]]; then
    echo
    echo "== 1 topology"
    run nvidia-smi topo -m
    run nvidia-smi --query-gpu=index,name,pci.bus_id,pcie.link.gen.max,pcie.link.width.max --format=csv
    for ((g = 0; g < ngpus; g++)); do
        IFS=', ' read -r gen width < <(nvidia-smi -i "$g" --format=csv,noheader \
            --query-gpu=pcie.link.gen.max,pcie.link.width.max)
        printf "  GPU %d   NUMA domain %s   PCIe gen %s x%s\n" "$g" "${dom[g]}" "$gen" "$width"
    done
    run numactl -H
    grep '^node [0-9]* cpus' "$tmp" | sed 's/^/  /' | cut -c1-60
fi

if [[ "$parts" == *" 2 "* ]]; then
    echo
    echo "== 2 memory: bandwidthTest, 32 MB copies, GB/s"
    printf "  %-5s %-8s %-9s %8s %8s\n" GPU domain memory H2D D2H
    for ((g = 0; g < ngpus; g++)); do
        d=${dom[g]}
        far=$(( (d + 2) % 4 ))
        for case in "pinned $d" "pageable $d" "pageable $far"; do
            set -- $case
            run numactl --cpunodebind="$2" --membind="$2" \
                "$bt" --device="$g" --memory="$1" --htod --dtoh --csv
            read -r h2d d2h < <(bt_parse | awk '/^H2D/{h=$2} /^D2H/{d=$2} END{print h, d}')
            where=$([ "$2" = "$d" ] && echo "$2 own" || echo "$2")
            printf "  %-5s %-8s %-9s %8s %8s\n" "$g" "$where" "$1" "$h2d" "$d2h"
        done
    done
fi

if [[ "$parts" == *" 3 "* ]]; then
    echo
    echo "== 3 one GPU at a time: nvbandwidth, 512 MiB pinned buffers, GB/s"
    printf "  %-11s %-38s" host test
    for ((g = 0; g < ngpus; g++)); do printf "%7s" "GPU$g"; done; echo
    tests=(-t host_to_device_memcpy_ce device_to_host_memcpy_ce)
    run "$nvb" "${tests[@]}";                                  nvb_parse own
    run numactl --cpunodebind=0 --membind=0 "$nvb" -d "${tests[@]}"; nvb_parse domain0
fi

if [[ "$parts" == *" 4 "* ]]; then
    echo
    echo "== 4 four GPUs at once: nvbandwidth, 512 MiB pinned buffers, GB/s"
    echo "   (the bidirectional tests report one direction; the other runs at the same time)"
    printf "  %-11s %-38s" host test
    for ((g = 0; g < ngpus; g++)); do printf "%7s" "GPU$g"; done; echo
    tests=(-t host_to_all_memcpy_ce all_to_host_memcpy_ce
              host_to_all_bidirectional_memcpy_ce all_to_host_bidirectional_memcpy_ce)
    run "$nvb" "${tests[@]}";                                  nvb_parse local
    run numactl --cpunodebind=0 --membind=0 "$nvb" -d "${tests[@]}"; nvb_parse "one domain"
    run numactl --interleave=all "$nvb" -d "${tests[@]}";      nvb_parse interleave
fi

if [[ "$parts" == *" 5 "* ]]; then
    echo
    echo "== 5 transfer size: bandwidthTest, GPU 0, pinned, from its own domain, GB/s"
    printf "  %10s %8s %8s\n" bytes H2D D2H
    for ((s = 4096; s <= 268435456; s *= 4)); do
        run numactl --cpunodebind="${dom[0]}" --membind="${dom[0]}" \
            "$bt" --device=0 --memory=pinned --htod --dtoh --csv \
                  --mode=range --start=$s --end=$s --increment=$s
        read -r h2d d2h < <(bt_parse | awk '/^H2D/{h=$2} /^D2H/{d=$2} END{print h, d}')
        printf "  %10d %8s %8s\n" "$s" "$h2d" "$d2h"
    done
fi
