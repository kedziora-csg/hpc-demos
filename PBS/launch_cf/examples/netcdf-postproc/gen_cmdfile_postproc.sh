#!/bin/bash
#
# Write a command file with one step per input NetCDF file.
#
# Each step runs ./process_file.sh, which runs several NCO operations over its
# file at the same time (see the comments there).
#
# Passing "pin" as the second argument prefixes every step with
#
#     taskset -c <core>
#
# which locks that step -- and therefore all of its concurrent ncks processes --
# onto a single core.  Generate both files, submit both, and compare how long
# the array took.  launch_cf hands out steps to nodes in blocks of "steps per
# node", so the core number simply cycles 0,1,...,127,0,1,... down the file.
#
# Usage:  ./gen_cmdfile_postproc.sh [output file] [pin]
#           default output: ./cmdfile

#------------------------------------------------------------------
datadir="./data"             # where make_data.sh put the input files
cores_per_node=128           # cores on a Derecho compute node
ops_per_step=3               # concurrent operations process_file.sh starts
node_memory_gb=235           # usable memory on a Derecho compute node

# A step is not one process: it starts ${ops_per_step} at once.  So the number
# of steps a node can hold is cores / ops, not cores -- otherwise the node runs
# 3x more processes than it has cores, and 3x more memory than budgeted.
# Tell launch_cf the same thing when you submit:
#
#     launch_cf --nthreads ${ops_per_step} ...
#
# which makes it compute this same steps/node and request ompthreads to match.
steps_per_node=$(( cores_per_node / ops_per_step ))

# Each run writes to its own directory.  Both runs process the same inputs and
# name their outputs after them, so a shared directory would mean the two runs
# overwriting each other's files -- and if they happen to run at the same time,
# writing the same file at the same time.
outdir_unpinned="./out.unpinned"
outdir_pinned="./out.pinned"
#------------------------------------------------------------------

output="${1:-./cmdfile}"

# with "pin", each step is confined to one core
pin=""
outdir="${outdir_unpinned}"
if [ "${2:-}" = "pin" ]; then
    pin="yes"
    outdir="${outdir_pinned}"
fi

files=( ${datadir}/*.nc )
if [ ${#files[@]} -eq 0 ] || [ ! -r "${files[0]}" ]; then
    echo "ERROR: no input files in ${datadir}/ -- run ./make_data.sh first"
    exit 1
fi

#------------------------------------------------------------------
# Memory check.
#
# Every step runs ${ops_per_step} operations at once, and every one of those
# reads a whole variable into memory -- uncompressed, which for NetCDF-4 input
# is far larger than the file on disk.  With a full node of steps that is
#
#     steps/node x ops/step x (memory for one operation)
#
# and if it exceeds the node, the job takes the node down rather than failing
# politely.  So measure one operation instead of guessing, and refuse to write a
# command file that cannot fit.  FORCE=1 overrides.
# Measure every operation and add them up: a step runs all three at once, and a
# node runs ${steps_per_node} steps at once.  All three stream here, so each
# costs a few hundred MB regardless of input size -- but measure rather than
# assume, because not every NCO operator streams (ncwa loads the whole array
# and needs roughly 10x its size).
step_kb=0
measured=""
if [ -x /usr/bin/time ] && command -v ncra >/dev/null; then
    probe="${files[0]}"
    tmp=$(mktemp -d)
    for op in "ncra -O" \
              "ncks -O -d latitude,20.,60. -d longitude,230.,300." \
              "ncks -O -4 -L 1"; do
        kb=$(/usr/bin/time -f "%M" ${op} "${probe}" "${tmp}/probe.nc" 2>&1 >/dev/null | tail -1)
        case "${kb}" in ''|*[!0-9]*) continue ;; esac
        printf "  %-42s %6.2f GB\n" "${op}" "$(awk "BEGIN{print ${kb}/1048576}")"
        step_kb=$(( step_kb + kb ))
        measured="yes"
    done
    rm -rf "${tmp}"
fi

if [ -n "${measured}" ]; then
    step_gb=$(awk "BEGIN {printf \"%.2f\", ${step_kb}/1048576}")
    total_gb=$(awk "BEGIN {printf \"%.0f\", ${step_kb}*${steps_per_node}/1048576}")
    echo "  ---------------------------------"
    echo "  one step (${ops_per_step} concurrent ops): ${step_gb} GB"
    echo "  ${steps_per_node} steps/node -> ${total_gb} GB; node has ${cores_per_node} cores and ${node_memory_gb} GB"
    if [ "${total_gb}" -gt "${node_memory_gb}" ] && [ -z "${FORCE:-}" ]; then
        cat <<MSG

REFUSING to write ${output}: a full node of these steps needs about ${total_gb} GB
but a node has ${node_memory_gb} GB.  The job would exhaust the node's memory.

Stage smaller inputs, e.g.

    NFILES=32 ./make_data.sh    -- fewer steps, or drop an operation

or set FORCE=1 if you know what you are doing.
MSG
        exit 1
    fi
else
    echo "warning: could not measure operation memory (need /usr/bin/time and NCO);"
    echo "         check that steps/node x per-step memory fits in ${node_memory_gb} GB"
fi

{
    echo "# ${#files[@]} steps, one per NetCDF file in ${datadir}/"
    if [ -n "${pin}" ]; then
        echo "# Each step is pinned to a single core with taskset."
    else
        echo "# Steps are not pinned; the Linux scheduler places them."
    fi
    echo "#"
    echo "# Output goes to ${outdir}/"
    echo "#"
    echo "# Each step starts ${ops_per_step} processes, so --nthreads ${ops_per_step} is what tells"
    echo "# launch_cf to put only ${steps_per_node} steps on a node instead of ${cores_per_node}."
    echo "#"
    echo "# Submit with:"
    echo "#   launch_cf -A \$PBS_ACCOUNT -l walltime=00:20:00 \\"
    echo "#             --nthreads ${ops_per_step} ${output}"
    echo "#"
    echo "# Generated by gen_cmdfile_postproc.sh"

    step=0
    for f in "${files[@]}"; do
        if [ -n "${pin}" ]; then
            # give the step the block of cores it is entitled to, not a single
            # core -- pinning 3 processes to 1 core would be a straw man
            slot=$(( step % steps_per_node ))
            lo=$(( slot * ops_per_step ))
            hi=$(( lo + ops_per_step - 1 ))
            echo "taskset -c ${lo}-${hi} ./process_file.sh ${f} ${outdir}"
        else
            echo "./process_file.sh ${f} ${outdir}"
        fi
        step=$(( step + 1 ))
    done
} > "${output}"

echo "Wrote ${#files[@]} steps to ${output}"
echo " -> output directory ${outdir}/"
echo " -> submit with --nthreads ${ops_per_step} (${steps_per_node} steps/node, $(( steps_per_node * ops_per_step )) processes on ${cores_per_node} cores)"
if [ -n "${pin}" ]; then
    echo " -> each step pinned to one core with taskset"
else
    echo " -> steps unpinned, placed by the Linux scheduler"
fi
