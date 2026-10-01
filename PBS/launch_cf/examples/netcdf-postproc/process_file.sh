#!/bin/bash
#
# ONE STEP of the command file: reduce one ERA5 file to three regional
# diagnostics, computing all three at the same time.
#
#   ncra           regional time MEAN     -> the file's contribution to a climatology
#   ncra -y max    regional time MAXIMUM  -> the companion extremes field
#   ncks           regional TIME SERIES   -> full time resolution, region only
#
# Each reads the same input, applies the same lat/lon hyperslab, and makes a
# different reduction, so they are independent and run concurrently.  All three
# stream the file rather than loading it, so each costs a few hundred MB
# whatever the input size.
#
# Once every step has run, ./gather.sh joins the pieces into the finished
# products: a continuous regional time series and a climatology over all files.
#
# The point for launch_cf is the "&": a step is THREE processes, not one.  A
# node therefore holds cores/3 steps, which is what --nthreads 3 tells it.
# Placement then matters:
#
#   * pinned  (taskset -c a-b)  a step's three processes stay on its own three
#                               cores whether they are busy or blocked on I/O
#   * unpinned                  the scheduler can use cores that other steps
#                               have left idle while they wait on their own I/O
#
# Usage: process_file.sh <input.nc> [output dir]

set -u

infile="${1:?usage: process_file.sh <input.nc> [output dir]}"
outdir="${2:-./out}"

# The region to study.  ERA5 longitudes run 0-360, latitudes 90 to -90.
# The default is roughly the contiguous United States.
lat_range="${LAT_RANGE:-25.,50.}"
lon_range="${LON_RANGE:-235.,295.}"

[ -r "${infile}" ] || { echo "ERROR: cannot read ${infile}"; exit 1; }
mkdir -p "${outdir}"

# MEASURE=1 records each operation's peak resident memory and elapsed time.
# Each process writes its OWN file under <outdir>/mem/ -- 126 steps x 3 ops all
# appending to one log would race on a parallel filesystem.
#
# Summarize a finished run with:
#
#   cat out.unpinned/mem/*.log | awk -F'|' '
#       {g=$1/1048576; t+=g; if(g>m)m=g}
#       END {printf "%d ops, largest %.2f GB, mean %.2f GB\n", NR, m, t/NR}'
#
base=$(basename "${infile}" .nc)
m_mean="" ; m_max="" ; m_series=""
if [ -n "${MEASURE:-}" ]; then
    if [ -x /usr/bin/time ]; then
        mkdir -p "${outdir}/mem"
        t="/usr/bin/time -f %M|%e|%C -o"
        m_mean="${t} ${outdir}/mem/${base}.mean.log"
        m_max="${t} ${outdir}/mem/${base}.max.log"
        m_series="${t} ${outdir}/mem/${base}.series.log"
    else
        echo "warning: MEASURE=1 but /usr/bin/time not found; not measuring" >&2
    fi
fi

region="-d latitude,${lat_range} -d longitude,${lon_range}"
start=$(date +%s)

${m_mean} ncra -O        ${region} "${infile}" "${outdir}/${base}.mean.nc"   &
${m_max} ncra -O -y max ${region} "${infile}" "${outdir}/${base}.max.nc"    &
${m_series} ncks -O        ${region} "${infile}" "${outdir}/${base}.series.nc" &

# wait for this step's three reductions before the step exits
wait

echo "step ${base} | ops 3 | seconds $(( $(date +%s) - start )) | host $(hostname -s) | PBS_ARRAY_INDEX=${PBS_ARRAY_INDEX:-0}"
