#!/bin/bash
#
# ONE STEP of the command file: split one NetCDF file into one file per variable.
#
# This is the shape of a lot of real post-processing -- pulling individual
# fields out of model or reanalysis output before analysing them.
#
# The important detail for this example is the "&" below.  A step extracts
# several variables at once, so one step is several ncks processes, and each
# of them spends most of its life waiting on the filesystem rather than
# computing.  That is what makes the placement question interesting:
#
#   * pinned  (taskset -c N)  all of this step's ncks processes share one core
#                             and take turns, even while other cores are idle
#   * unpinned                the Linux scheduler is free to run them on cores
#                             that neighbouring steps have left idle while they
#                             wait on their own I/O
#
# Usage: process_file.sh <input.nc> [output dir]

set -u

infile="${1:?usage: process_file.sh <input.nc> [output dir]}"
outdir="${2:-./out}"

# variables to pull out; override with e.g. VARS="t q" in config_env.sh
vars="${VARS:-VAR_2T VAR_2D SP TCC}"

[ -r "${infile}" ] || { echo "ERROR: cannot read ${infile}"; exit 1; }
mkdir -p "${outdir}"

base=$(basename "${infile}" .nc)
start=$(date +%s)

for var in ${vars}; do
    # -O overwrite, -v select one variable
    ncks -O -v "${var}" "${infile}" "${outdir}/${base}.${var}.nc" &
done

# wait for this step's extractions to finish before the step exits
wait

nvars=$(set -- ${vars}; echo ${#})
echo "step ${base} | vars ${nvars} | seconds $(( $(date +%s) - start )) | host $(hostname -s) | PBS_ARRAY_INDEX=${PBS_ARRAY_INDEX:-0}"
