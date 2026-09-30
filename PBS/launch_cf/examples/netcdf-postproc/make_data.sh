#!/bin/bash
#
# Point the example at a set of ERA5 files.
#
# ERA5 lives on GLADE in the NSF NCAR Geoscience Data Exchange (GDEX, formerly
# the RDA) as dataset d633000.  It is already one file per variable per period,
# which is the shape a command file wants, so there is nothing to build: we just
# make symlinks.  Every operation in process_file.sh streams, so the archive
# files can be used whole.
#
# Run ./check_data.sh first; it locates the dataset and reports what is there.
#
#   ./make_data.sh                        # 128 files from the default product
#   NFILES=256 ./make_data.sh             # more steps
#   PRODUCT=e5.oper.an.sfc ./make_data.sh # a different ERA5 product
#   COPY=1 ./make_data.sh                 # real copies instead of symlinks
#   SRCDIR=/some/other/dir ./make_data.sh # somewhere else entirely

set -u

DSID="${DSID:-d633000}"
PRODUCT="${PRODUCT:-e5.oper.fc.sfc.meanflux}"
OUTDIR="${OUTDIR:-./data}"
NFILES="${NFILES:-128}"

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

n=0
while read -r f; do
    [ ${n} -ge ${NFILES} ] && break
    dest="${OUTDIR}/$(basename "${f}")"
    if [ ! -e "${dest}" ] && [ ! -L "${dest}" ]; then
        if [ -n "${COPY:-}" ]; then cp "${f}" "${dest}"; else ln -s "${f}" "${dest}"; fi
    fi
    n=$(( n + 1 ))
done < <(find "${SRCDIR}" -name '*.nc' | sort)

staged=$(ls -1 "${OUTDIR}" | wc -l | tr -d ' ')
[ "${staged}" -gt 0 ] || { echo "ERROR: no .nc files found under ${SRCDIR}"; exit 1; }
echo "Staged ${staged} files ($([ -n "${COPY:-}" ] && echo copies || echo symlinks))"
[ "${staged}" -lt "${NFILES}" ] && echo "  (only ${staged} available; asked for ${NFILES})"
exit 0
