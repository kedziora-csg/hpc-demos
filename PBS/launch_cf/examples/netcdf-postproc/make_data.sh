#!/bin/bash
#
# Build the input files this example processes, by slicing one large NetCDF
# file into many small ones -- one per time step.
#
# The source defaults to an hourly ERA5 file from the NSF NCAR Geoscience Data
# Exchange (GDEX, dataset d633000), which is netCDF-4 and readable on GLADE from
# any NCAR system.  Point SRC somewhere else if you prefer:
#
#   SRC=/glade/derecho/scratch/$USER/my_output.nc ./make_data.sh
#
# Run ./check_data.sh first -- it locates the dataset on GLADE and prints the
# SRC line to use.

set -u

# The Geoscience Data Exchange (GDEX, formerly the RDA) keeps ERA5 on GLADE as
# dataset d633000.  The collection moved and was renamed, so rather than hard
# coding one path we look in the places it is known to live and take the first
# NetCDF file we find.  Run ./check_data.sh first: it reports exactly what is
# there and prints the SRC= line to paste here or set in the environment.
DSID="${DSID:-d633000}"

if [ -z "${SRC:-}" ]; then
    for root in /glade/campaign/collections/gdex/data /gdex/data \
                /glade/campaign/collections/rda/data; do
        [ -d "${root}/${DSID}" ] || continue
        SRC=$(find "${root}/${DSID}" -name '*.nc' -print -quit 2>/dev/null)
        [ -n "${SRC}" ] && break
    done
fi
SRC="${SRC:-}"

OUTDIR="${OUTDIR:-./data}"
NSLICES="${NSLICES:-256}"

command -v ncks >/dev/null || { echo "ERROR: ncks not found -- try \"module load nco\""; exit 1; }

if [ -z "${SRC}" ] || [ ! -r "${SRC}" ]; then
    cat <<MSG
ERROR: cannot read the source file

    ${SRC}

Set SRC to a NetCDF file you can read, e.g.

    SRC=/glade/campaign/collections/rda/data/ds633.0/... ./make_data.sh

Run ./check_data.sh to locate the data, or search the dataset id at
https://gdex.ucar.edu and follow Data Access -> NCAR HPC Data Access.
MSG
    exit 1
fi

mkdir -p "${OUTDIR}"

echo "Slicing ${NSLICES} time steps out of"
echo "  ${SRC}"
echo "into ${OUTDIR}/ ..."

for i in $(seq 0 $(( NSLICES - 1 ))); do
    out=$(printf "%s/slice_%05d.nc" "${OUTDIR}" "${i}")
    [ -f "${out}" ] && continue          # already built; delete ./data to start over
    ncks -O -d time,${i},${i} "${SRC}" "${out}" || {
        echo "ERROR: ncks failed on time index ${i} -- does the source have ${NSLICES} time steps?"
        exit 1
    }
done

echo "Wrote $(ls -1 ${OUTDIR}/slice_*.nc | wc -l) files, $(du -sh ${OUTDIR} | cut -f1) total"
