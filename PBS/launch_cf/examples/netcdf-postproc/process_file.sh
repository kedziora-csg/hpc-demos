#!/bin/bash
#
# ONE STEP of the command file: reduce one ERA5 file to three regional
# diagnostics, computing all three at the same time.
#
#   ncra           regional time MEAN     -> the mean over this file's period
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
# The step exits non-zero if any of its operations fails, and only finished
# outputs are given their final names, so gather.sh never sees a partial file.
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

# ERA5 forecast products (e5.oper.fc.*) have TWO time dimensions: the record
# dimension forecast_initial_time and, inside each record, forecast_hour.  ncra
# reduces only the record dimension, so the mean and maximum are finished over
# forecast_hour with ncwa.  ncwa loads the whole array, but by then the array is
# the small regional result, so that costs nothing.  Analysis products
# (e5.oper.an.*) have a single time dimension and skip this.
inner_time_dim="${INNER_TIME_DIM:-forecast_hour}"
if ! ncks --cdl -m "${infile}" 2>/dev/null | grep -Eq "^[[:space:]]+${inner_time_dim} = "; then
    inner_time_dim=""
fi

# MEASURE=1 records each operation's peak resident memory and elapsed time.
# Each process writes its OWN file under <outdir>/mem/ -- every step's three
# ops all appending to one log would race on a parallel filesystem.
#
# Summarize a finished run with:
#
#   cat out.unpinned/mem/*.log | awk -F'|' '
#       {g=$1/1048576; t+=g; if(g>m)m=g}
#       END {printf "%d ops, largest %.2f GB, mean %.2f GB\n", NR, m, t/NR}'
#
base=$(basename "${infile}" .nc)
memdir=""
if [ -n "${MEASURE:-}" ]; then
    if [ -x /usr/bin/time ]; then
        memdir="${outdir}/mem"
        mkdir -p "${memdir}"
    else
        echo "warning: MEASURE=1 but /usr/bin/time not found; not measuring" >&2
    fi
fi

region="-d latitude,${lat_range} -d longitude,${lon_range}"

# reduce <name> <ncwa options, or "" for none> <NCO operator and options...>
#
# Runs one operation on this step's input into <base>.<name>.nc.  The work is
# done under a temporary name and renamed only once it has succeeded; any
# output left by an earlier run is removed first, so a failure leaves nothing
# for gather.sh to pick up by mistake.
reduce() {
    local name="$1" inner="$2"; shift 2
    local out="${outdir}/${base}.${name}.nc"
    local tmp="${outdir}/${base}.${name}.tmp"
    local meas=""
    [ -n "${memdir}" ] && meas="/usr/bin/time -f %M|%e|%C -o ${memdir}/${base}.${name}.log"
    rm -f "${out}"

    if ! ${meas} "$@" ${region} "${infile}" "${tmp}"; then
        echo "ERROR: ${name}: $* failed on ${infile}" >&2
        rm -f "${tmp}"
        return 1
    fi
    if [ -n "${inner}" ] && [ -n "${inner_time_dim}" ]; then
        if ! ncwa -O -a "${inner_time_dim}" ${inner} "${tmp}" "${tmp}.2"; then
            echo "ERROR: ${name}: ncwa over ${inner_time_dim} failed" >&2
            rm -f "${tmp}" "${tmp}.2"
            return 1
        fi
        mv -f "${tmp}.2" "${tmp}"
    fi
    mv -f "${tmp}" "${out}"
}

start=$(date +%s.%N)

pids=() ; names=()
reduce mean   "-y avg" ncra -O        & pids+=($!) ; names+=(mean)
reduce max    "-y max" ncra -O -y max & pids+=($!) ; names+=(max)
reduce series ""       ncks -O        & pids+=($!) ; names+=(series)

# wait for each of this step's three reductions, noting any that failed
failed=()
for i in "${!pids[@]}"; do
    wait "${pids[$i]}" || failed+=("${names[$i]}")
done

secs=$(awk -v a="${start}" -v b="$(date +%s.%N)" 'BEGIN {printf "%.2f", b-a}')
echo "step ${base} | ops 3 | failed ${#failed[@]} | seconds ${secs} | host $(hostname -s) | PBS_ARRAY_INDEX=${PBS_ARRAY_INDEX:-0}"

if [ ${#failed[@]} -gt 0 ]; then
    echo "ERROR: ${base}: failed: ${failed[*]}" >&2
    exit 1
fi
exit 0
