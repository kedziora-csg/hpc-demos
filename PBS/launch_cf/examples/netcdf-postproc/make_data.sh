#!/bin/bash
#
# Stage the input files this example processes.
#
# ERA5 lives on GLADE in the NSF NCAR Geoscience Data Exchange (GDEX, formerly
# the RDA) as dataset d633000.  Its files are already one-file-per-variable-per
# -period, which is exactly the shape a command file wants, so rather than
# building inputs we simply point at a set of them.
#
# The archive files are small on disk but large in memory: an ERA5 meanflux
# file is ~73 MB compressed and ~1.5 GB once a tool reads the variable in.  With
# 128 steps per node each running 3 concurrent operations, using them whole
# needs ~574 GB on a 235 GB node -- it will OOM the node.
#
# So we stage SUBSETS: NRECS records out of each file, which cuts the in-memory
# size in the same proportion.  Set NRECS=0 to stage whole files (only sensible
# with few steps per node).
#
# Run ./check_data.sh first; it locates the dataset and reports what is there.
#
#   ./make_data.sh                      # 128 files from the default product
#   NFILES=256 ./make_data.sh           # more steps
#   PRODUCT=e5.oper.an.sfc ./make_data.sh
#   NRECS=8 ./make_data.sh              # keep more records per file
#   SRCDIR=/some/other/dir ./make_data.sh

set -u

DSID="${DSID:-d633000}"
# e5.oper.fc.sfc.meanflux files are ~73 MB, big enough for the steps to be
# I/O bound without making the example take an hour.  e5.oper.an.sfc holds the
# hourly surface analyses, but those files are several GB each.
PRODUCT="${PRODUCT:-e5.oper.fc.sfc.meanflux}"
OUTDIR="${OUTDIR:-./data}"
NFILES="${NFILES:-128}"
NRECS="${NRECS:-4}"          # records kept per file; 0 = whole file

# find the dataset: GDEX is canonical, the others are kept for compatibility
if [ -z "${SRCDIR:-}" ]; then
    for root in /glade/campaign/collections/gdex/data /gdex/data \
                /glade/campaign/collections/rda/data; do
        if [ -d "${root}/${DSID}/${PRODUCT}" ]; then
            SRCDIR="${root}/${DSID}/${PRODUCT}"
            break
        fi
    done
fi
SRCDIR="${SRCDIR:-}"

if [ -z "${SRCDIR}" ] || [ ! -d "${SRCDIR}" ]; then
    cat <<MSG
ERROR: cannot find ${DSID}/${PRODUCT} on GLADE.

Run ./check_data.sh to see what is available, or search the dataset id at
https://gdex.ucar.edu and follow Data Access -> NCAR HPC Data Access.
Set SRCDIR to a directory of NetCDF files to use something else.
MSG
    exit 1
fi

mkdir -p "${OUTDIR}"

echo "Staging up to ${NFILES} files from"
echo "  ${SRCDIR}"
if [ "${NRECS}" -eq 0 ]; then
    echo "  (whole files -- watch the memory footprint, see the comments above)"
else
    echo "  (keeping ${NRECS} records of each)"
fi

n=0
while read -r f; do
    [ ${n} -ge ${NFILES} ] && break
    dest="${OUTDIR}/$(basename "${f}")"
    if [ -e "${dest}" ] || [ -L "${dest}" ]; then
        n=$(( n + 1 )); continue
    fi
    if [ "${NRECS}" -eq 0 ]; then
        cp "${f}" "${dest}"
    else
        # the record dimension is named differently in the analysis and forecast
        # products, so ask the file which one is UNLIMITED
        rec=$(ncdump -h "${f}" | awk '/UNLIMITED/ {print $1; exit}')
        if [ -z "${rec}" ]; then
            echo "  skipping ${dest}: no unlimited dimension"
            continue
        fi
        ncks -O -d "${rec},0,$(( NRECS - 1 ))" "${f}" "${dest}" || {
            echo "ERROR: ncks failed subsetting ${f}"; exit 1; }
    fi
    n=$(( n + 1 ))
done < <(find "${SRCDIR}" -name '*.nc' | sort)

staged=$(ls -1 "${OUTDIR}" | wc -l | tr -d ' ')
if [ "${staged}" -eq 0 ]; then
    echo "ERROR: no .nc files found under ${SRCDIR}"
    exit 1
fi
echo "Staged ${staged} files in ${OUTDIR}/, $(du -sh "${OUTDIR}" | cut -f1) total"
[ "${staged}" -lt "${NFILES}" ] && echo "  (only ${staged} available; asked for ${NFILES})"
exit 0
