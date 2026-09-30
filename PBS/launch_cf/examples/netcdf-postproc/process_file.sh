#!/bin/bash
#
# ONE STEP of the command file: run several independent NCO operations over one
# NetCDF file.
#
#   * a mean over the record dimension (ncra)
#   * a compressed rewrite             (ncks -4 -L 1)
#   * a collapse of the record dimension (ncwa)
#
# All three read the whole input file, so a step spends most of its life waiting
# on the filesystem rather than computing.  None of them needs to know what
# variables are inside -- ERA5 files hold a single variable each, and the name
# differs from file to file -- so this works on any NetCDF file.
#
# The important detail is the "&": a step runs its operations at the same time,
# so one step is several processes.  That is what makes placement interesting:
#
#   * pinned  (taskset -c N)  a step's operations share one core and take turns,
#                             even while other cores sit idle
#   * unpinned                the Linux scheduler can run them on cores that
#                             neighbouring steps have left idle while those steps
#                             wait on their own I/O
#
# Usage: process_file.sh <input.nc> [output dir]

set -u

infile="${1:?usage: process_file.sh <input.nc> [output dir]}"
outdir="${2:-./out}"

[ -r "${infile}" ] || { echo "ERROR: cannot read ${infile}"; exit 1; }

# The dimension to collapse is whichever one is UNLIMITED -- "time" in the ERA5
# analysis files, "forecast_initial_time" in the forecast ones.  Ask the file
# rather than assuming; override with TIMEDIM if you want a different one.
recdim="${TIMEDIM:-$(ncdump -h "${infile}" | awk '/UNLIMITED/ {print $1; exit}')}"
if [ -z "${recdim}" ]; then
    echo "ERROR: ${infile} has no unlimited dimension; set TIMEDIM to the one to collapse"
    exit 1
fi
mkdir -p "${outdir}"

# MEASURE=1 records each operation's peak resident memory and elapsed time in
# ${outdir}/mem.log, one line per process:
#
#     <peak KB>|<seconds>|<command>
#
# Summarize a finished run with:
#
#   awk -F'|' '{g=$1/1048576; if(g>m)m=g; t+=g}
#              END {printf "largest op %.2f GB, sum %.1f GB over %d ops\n", m, t, NR}' \
#       out.unpinned/mem.log
#
# That sum is an upper bound for one node: it assumes every process peaked at
# the same moment.  For what a node actually reached, read the job's own
# accounting instead -- "qstat -xf <jobid> | grep resources_used.mem".
measure=""
if [ -n "${MEASURE:-}" ]; then
    if [ -x /usr/bin/time ]; then
        measure="/usr/bin/time -f %M|%e|%C -o ${outdir}/mem.log -a"
    else
        echo "warning: MEASURE=1 but /usr/bin/time not found; not measuring" >&2
    fi
fi

base=$(basename "${infile}" .nc)
start=$(date +%s)

# average over the record dimension
${measure} ncra -O "${infile}" "${outdir}/${base}.timemean.nc" &

# rewrite with compression: reads everything, writes everything
${measure} ncks -O -4 -L 1 "${infile}" "${outdir}/${base}.compressed.nc" &

# collapse the record dimension
${measure} ncwa -O -a "${recdim}" "${infile}" "${outdir}/${base}.timecollapse.nc" &

# wait for this step's operations to finish before the step exits
wait

echo "step ${base} | ops 3 | recdim ${recdim} | seconds $(( $(date +%s) - start )) | host $(hostname -s) | PBS_ARRAY_INDEX=${PBS_ARRAY_INDEX:-0}"
