#!/bin/bash
#
# ONE STEP of the command file: three common post-processing operations on one
# ERA5 file, run at the same time.
#
#   ncra                 average over the record (time) dimension
#   ncks -d lat,lon      cut out a region
#   ncks -4 -L 1         rewrite compressed
#
# All three stream the file rather than loading it, so each needs only a few
# hundred MB no matter how large the input is.  That is what lets this example
# work on the archive files as they are.
#
# The point of the example is the "&": a step is THREE processes, not one.  So
# a node holds cores/3 steps, and launch_cf is told that with --nthreads 3.
# Placement then matters:
#
#   * pinned  (taskset -c a-b)  a step's three processes stay on its own three
#                               cores, idle or not
#   * unpinned                  the Linux scheduler can use cores that other
#                               steps have left idle while they wait on I/O
#
# Usage: process_file.sh <input.nc> [output dir]

set -u

infile="${1:?usage: process_file.sh <input.nc> [output dir]}"
outdir="${2:-./out}"

# Region to cut out.  ERA5 longitudes run 0-360, latitudes 90 to -90.
lat_range="${LAT_RANGE:-20.,60.}"        # roughly North America
lon_range="${LON_RANGE:-230.,300.}"

[ -r "${infile}" ] || { echo "ERROR: cannot read ${infile}"; exit 1; }
mkdir -p "${outdir}"

# MEASURE=1 appends "<peak KB>|<seconds>|<command>" per process to mem.log.
# Summarize with:
#   awk -F'|' '{g=$1/1048576; if(g>m)m=g} END {printf "largest op %.2f GB\n", m}' out.*/mem.log
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

${measure} ncra -O "${infile}" "${outdir}/${base}.timemean.nc" &

${measure} ncks -O -d latitude,"${lat_range}" -d longitude,"${lon_range}" \
                   "${infile}" "${outdir}/${base}.region.nc" &

${measure} ncks -O -4 -L 1 "${infile}" "${outdir}/${base}.compressed.nc" &

# wait for this step's operations to finish before the step exits
wait

echo "step ${base} | ops 3 | seconds $(( $(date +%s) - start )) | host $(hostname -s) | PBS_ARRAY_INDEX=${PBS_ARRAY_INDEX:-0}"
