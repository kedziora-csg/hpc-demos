#!/bin/bash
#
# Run this on Derecho BEFORE make_data.sh.  It answers the questions the rest
# of the example depends on and prints exactly what to put in make_data.sh:
#
#   1. where the GDEX (formerly RDA) copy of ERA5 lives on GLADE
#   2. whether the files hold one variable or many
#   3. what the time dimension is called and how big the files are
#
# Usage: ./check_data.sh [dataset id]      (default d633000 = ERA5)

set -u
dsid="${1:-d633000}"

echo "== 1. locating ${dsid} =========================================="
root=""
for candidate in /glade/campaign/collections/gdex/data /gdex/data \
                 /glade/campaign/collections/rda/data; do
    if [ -d "${candidate}/${dsid}" ]; then
        root="${candidate}"
        echo "   found: ${candidate}/${dsid}"
    elif [ -d "${candidate}" ]; then
        echo "   ${candidate} exists but has no ${dsid}"
    fi
done
[ -n "${root}" ] || { echo "   NOT FOUND -- check https://gdex.ucar.edu, search ${dsid},"
                      echo "   then Data Access -> NCAR HPC Data Access"; exit 1; }

echo
echo "== 2. what is under ${root}/${dsid} ============================="
ls "${root}/${dsid}" | head -20
if [ -x /glade/u/apps/contrib/gdexls ]; then
    echo "   -- gdexls says:"
    /glade/u/apps/contrib/gdexls "${root}/${dsid}/" 2>/dev/null | head -10
fi

echo
echo "== 3. a sample file ============================================="
sample=$(find "${root}/${dsid}" -name '*.nc' -print -quit 2>/dev/null)
[ -n "${sample}" ] || { echo "   no .nc files found -- this dataset may live on object storage;"
                        echo "   see the README in ${root}"; exit 1; }
echo "   ${sample}"
ls -lh "${sample}" | awk '{print "   size: "$5}'

command -v ncdump >/dev/null || module load nco 2>/dev/null
if command -v ncdump >/dev/null; then
    echo
    echo "   variables in it:"
    ncdump -h "${sample}" | sed -n '/^variables:/,/^\/\//p' | grep -E "^\s+\w+ \w+\(" | head -12
    echo
    echo "   dimensions:"
    ncdump -h "${sample}" | sed -n '/^dimensions:/,/^variables:/p' | grep "=" | head -6
else
    echo "   (load NCO or netcdf to inspect the file: module load nco)"
fi

echo
echo "== 4. put this in make_data.sh =================================="
echo "   SRC=\"${sample}\""
