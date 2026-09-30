#!/bin/bash
#
# ONE STEP of the command file: run several independent NCO operations over one
# NetCDF file.
#
#   * a time mean          (ncra)
#   * a compressed rewrite (ncks -4 -L 1)
#   * a time collapse      (ncwa)
#
# All three read the whole input file, so a step spends most of its life waiting
# on the filesystem rather than computing.  None of them needs to know the names
# of the variables inside, so this works on any NetCDF file.
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

# name of the time dimension; ./check_data.sh reports what your files use
timedim="${TIMEDIM:-time}"

[ -r "${infile}" ] || { echo "ERROR: cannot read ${infile}"; exit 1; }
mkdir -p "${outdir}"

base=$(basename "${infile}" .nc)
start=$(date +%s)

# average over the record dimension
ncra -O "${infile}" "${outdir}/${base}.timemean.nc" &

# rewrite with compression: reads everything, writes everything
ncks -O -4 -L 1 "${infile}" "${outdir}/${base}.compressed.nc" &

# collapse the time dimension
ncwa -O -a "${timedim}" "${infile}" "${outdir}/${base}.timecollapse.nc" &

# wait for this step's operations to finish before the step exits
wait

echo "step ${base} | ops 3 | seconds $(( $(date +%s) - start )) | host $(hostname -s) | PBS_ARRAY_INDEX=${PBS_ARRAY_INDEX:-0}"
