#!/bin/bash
#
# Build the input files this example processes, by slicing one large NetCDF
# file into many small ones -- one per time step.
#
# The source defaults to an hourly ERA5 surface analysis file from the NSF NCAR
# Research Data Archive (dataset ds633.0), which is netCDF-4 and readable on
# GLADE from any NCAR system.  Point SRC somewhere else if you prefer:
#
#   SRC=/glade/derecho/scratch/$USER/my_output.nc ./make_data.sh
#
# VERIFY THE PATH BELOW before relying on it -- RDA reorganizes collections,
# and the per-year file listings at https://rda.ucar.edu/datasets/ds633.0/
# show the current GLADE location of every file.

set -u

SRC="${SRC:-/glade/campaign/collections/rda/data/ds633.0/e5.oper.an.sfc/202001/e5.oper.an.sfc.128_167_2t.ll025sc.2020010100_2020013123.nc}"
OUTDIR="${OUTDIR:-./data}"
NSLICES="${NSLICES:-256}"

command -v ncks >/dev/null || { echo "ERROR: ncks not found -- try \"module load nco\""; exit 1; }

if [ ! -r "${SRC}" ]; then
    cat <<MSG
ERROR: cannot read the source file

    ${SRC}

Set SRC to a NetCDF file you can read, e.g.

    SRC=/glade/campaign/collections/rda/data/ds633.0/... ./make_data.sh

The RDA per-year file listings show the current GLADE path for every file:
    https://rda.ucar.edu/datasets/ds633.0/
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
