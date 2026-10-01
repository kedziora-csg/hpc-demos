#!/bin/bash
#
# The serial phase, after launch_cf has run every step.
#
# The parallel phase reduced each input file to a region; this joins those
# pieces into the finished products.  It is deliberately NOT part of the command
# file: it has to wait for every step, so it runs once, afterwards.  That
# split -- an embarrassingly parallel phase followed by a small gather -- is the
# usual shape of this kind of analysis.
#
# Usage: ./gather.sh [output dir of a run]     (default ./out.unpinned)

set -u
d="${1:-./out.unpinned}"
[ -d "${d}" ] || { echo "ERROR: no such directory: ${d}"; exit 1; }

command -v ncrcat >/dev/null || { echo "ERROR: NCO not loaded -- module load nco"; exit 1; }

n=$(ls -1 "${d}"/*.mean.nc 2>/dev/null | wc -l | tr -d ' ')
[ "${n}" -gt 0 ] || { echo "ERROR: no *.mean.nc in ${d} -- has the job finished?"; exit 1; }
echo "Gathering ${n} files from ${d}/"

# a continuous regional time series across every input period
ncrcat -O "${d}"/*.series.nc  "${d}/regional_timeseries.nc"

# the climatology: mean of the per-file means
ncra   -O "${d}"/*.mean.nc    "${d}/regional_climatology.nc"

# and the extreme of the per-file extremes
ncra   -O -y max "${d}"/*.max.nc "${d}/regional_maximum.nc"

echo
ls -lh "${d}"/regional_*.nc | awk '{print "  "$9"  "$5}'
echo
echo "Inspect with:  ncdump -h ${d}/regional_climatology.nc"
