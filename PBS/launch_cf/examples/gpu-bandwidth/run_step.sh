#!/bin/bash
#
# One launch_cf step: measure host <-> GPU copy bandwidth on one of the job's
# GPUs with nvbandwidth, and record where the step ran.
#
#   run_step.sh <slot> [free|membind]
#
#   slot     which of the job's GPUs to use, 0 .. ngpus-1, in the order of
#            CUDA_VISIBLE_DEVICES.  gen_cmdfile_gpu.sh gives each step on a
#            node its own slot.
#   free     (default) no placement: the host buffers land in the NUMA domain
#            of whichever core the step runs on, like most programs' memory
#   membind  numactl --membind=<d>: the host buffers go in the GPU's own
#            domain d, whichever cores the job was given
#
# PBS limits a job to the GPUs and cores it asked for, so a step can see only
# its own job's GPUs.  nvbandwidth runs with -d, so it does not move itself
# to the GPU's cores; where its memory goes is up to "mode".
#
# The last line of the output is a RESULT line for ./summarize.sh.
#
# Environment:
#   NVBANDWIDTH=<path>  the nvbandwidth binary (default: the one built by
#                       GPU/host-device-bandwidth/build_nvbandwidth.sh)
#   NVB_SAMPLES=10      samples per test, each 16 copies of 1 GiB: about 6 s
#                       per direction at full speed, so steps started
#                       together are copying at the same time

set -u
slot="$1"
mode="${2:-free}"
here=$(cd "$(dirname "$0")" && pwd)
nvb="${NVBANDWIDTH:-$here/../../../../GPU/host-device-bandwidth/nvbandwidth}"
samples="${NVB_SAMPLES:-10}"

[ -x "$nvb" ] || { echo "ERROR: no $nvb -- run GPU/host-device-bandwidth/build_nvbandwidth.sh"; exit 1; }
IFS=, read -ra gpus <<<"${CUDA_VISIBLE_DEVICES:-}"
[ "$slot" -lt "${#gpus[@]}" ] ||
    { echo "ERROR: slot $slot, but this job has ${#gpus[@]} GPUs (CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-})"; exit 1; }
uuid="${gpus[$slot]}"

# the NUMA domain of the GPU's PCIe link
bus=$(nvidia-smi -i "$uuid" --query-gpu=pci.bus_id --format=csv,noheader)
bus="${bus,,}"
gpu_dom=$(cat "/sys/bus/pci/devices/${bus#0000}/numa_node")

# the cores this job may use, and their domains
cpus=$(awk '/^Cpus_allowed_list/ {print $2}' /proc/self/status)
cpu_doms=$(numactl --show | awk '/^nodebind:/ { for (i = 2; i <= NF; i++) printf "%s%s", (i > 2 ? "," : ""), $i }')

case "$mode" in
    free)    pre=() ;;
    membind) pre=(numactl --membind="$gpu_dom") ;;
    *)       echo "ERROR: mode $mode is not free or membind"; exit 1 ;;
esac

echo "host $(hostname -s)  job ${PBS_JOBID:-none}  queue ${PBS_QUEUE:-none}"
echo "job GPUs ${#gpus[@]}: ${CUDA_VISIBLE_DEVICES:-}"
echo "slot $slot: $uuid  bus $bus  NUMA domain $gpu_dom"
echo "job cores $cpus  (domains $cpu_doms)  mode $mode"

out=$(mktemp)
trap 'rm -f "$out"' EXIT
t0=$(date +%s.%N)
CUDA_VISIBLE_DEVICES="$uuid" "${pre[@]}" "$nvb" -d -b 1024 -i "$samples" \
    -t host_to_device_memcpy_ce device_to_host_memcpy_ce >"$out" 2>&1 &
pid=$!

# 3 s in, the first test is copying from its 1 GiB pinned host buffer: see
# which domains the process's memory is in (MiB per domain, from numa_maps)
sleep 3
mem=$(awk '{ ps = 4; for (i = 2; i <= NF; i++) if ($i ~ /^kernelpagesize_kB=/) { split($i, a, "="); ps = a[2] }
             for (i = 2; i <= NF; i++) if ($i ~ /^N[0-9]+=/) { split(substr($i, 2), a, "="); kb[a[1]] += a[2] * ps } }
           END { for (n in kb) if (kb[n] >= 64 * 1024) printf "%s%s:%d", (s++ ? "," : ""), n, kb[n] / 1024 }' \
          "/proc/$pid/numa_maps" 2>/dev/null)
wait "$pid"
status=$?
t1=$(date +%s.%N)
cat "$out"

# the one row of each test's matrix: " 0     26.78"
read -r h2d d2h < <(awk '/^Running / { t = $2 } /^ 0 / { v[t] = $2 }
    END { print v["host_to_device_memcpy_ce."], v["device_to_host_memcpy_ce."] }' "$out")
echo "memory in domain:MiB  ${mem:-unknown}"
printf "RESULT queue=%s job=%s host=%s ngpus=%d slot=%d gpu_dom=%s cpus=%s cpu_doms=%s mode=%s mem=%s h2d=%s d2h=%s t0=%.1f t1=%.1f status=%d\n" \
    "${PBS_QUEUE:-none}" "${PBS_JOBID:-none}" "$(hostname -s)" "${#gpus[@]}" "$slot" "$gpu_dom" \
    "$cpus" "$cpu_doms" "$mode" "${mem:-unknown}" "${h2d:-NA}" "${d2h:-NA}" "$t0" "$t1" "$status"
exit "$status"
