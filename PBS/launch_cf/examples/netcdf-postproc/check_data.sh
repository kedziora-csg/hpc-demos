#!/bin/bash
#
# Survey the ERA5 collection on GLADE and pick a product to run the example on.
#
# The only thing the example really needs from the data is FILE SIZE: every
# operation in process_file.sh streams, so memory is bounded whatever you pick,
# but file size sets how long a step runs.  ~73 MB files give steps of a few
# seconds, which is too short to measure placement against; bigger files give a
# cleaner signal.
#
# Usage:
#   ./check_data.sh                 survey products and their file sizes
#   ./check_data.sh 500             also recommend the product nearest 500 MB
#   ./check_data.sh 500 d633000     a different dataset

set -u
target_mb="${1:-}"
dsid="${2:-d633000}"

echo "== 1. locating ${dsid} =========================================="
root=""
for candidate in /glade/campaign/collections/gdex/data /gdex/data \
                 /glade/campaign/collections/rda/data; do
    if [ -d "${candidate}/${dsid}" ]; then
        [ -z "${root}" ] && root="${candidate}"
        echo "   ${candidate}/${dsid}"
    fi
done
[ -n "${root}" ] || { echo "   NOT FOUND -- search ${dsid} at https://gdex.ucar.edu,"
                      echo "   then Data Access -> NCAR HPC Data Access"; exit 1; }
ds="${root}/${dsid}"

echo
echo "== 2. products and their file sizes ============================="
printf "   %-34s %8s %10s %12s\n" "product" "files" "volume" "avg file"
printf "   %-34s %8s %10s %12s\n" "----------------------------------" "--------" "----------" "------------"

table=$(mktemp)
GDEXLS=/glade/u/apps/contrib/gdexls
if [ -x "${GDEXLS}" ]; then
    # gdexls prints: <type><id>  <volume>  <file count>  <description>
    # volume carries a K/M/G/T suffix; turn it into an average file size.
    "${GDEXLS}" "${ds}/" 2>/dev/null | awk '
        /^G/ {
            id=$1; sub(/^G/,"",id); vol=$2; cnt=$3+0
            u=substr(vol,length(vol),1); v=vol+0
            m = (u=="T") ? v*1024*1024 : (u=="G") ? v*1024 : (u=="M") ? v : (u=="K") ? v/1024 : v/1048576
            if (cnt>0) printf "%s %d %s %.1f\n", id, cnt, vol, m/cnt
        }' > "${table}"
fi

if [ ! -s "${table}" ]; then
    # no gdexls, or nothing parsed: sample a few files from each product instead
    for d in "${ds}"/*/; do
        [ -d "${d}" ] || continue
        p=$(basename "${d}")
        avg=$(find "${d}" -name '*.nc' -type f 2>/dev/null | head -3 | xargs -r ls -l 2>/dev/null \
              | awk '{s+=$5; n++} END {if(n) printf "%.1f", s/n/1048576}')
        [ -n "${avg}" ] && echo "${p} ? sampled ${avg}" >> "${table}"
    done
fi

[ -s "${table}" ] || { echo "   (no products found under ${ds})"; exit 1; }
sort -k4 -n "${table}" | while read -r p cnt vol avg; do
    printf "   %-34s %8s %10s %9s MB\n" "${p}" "${cnt}" "${vol}" "${avg}"
done

echo
echo "== 3. recommendation ============================================"
if [ -z "${target_mb}" ]; then
    echo "   Re-run with a target file size in MB to get a suggestion, e.g."
    echo "     ./check_data.sh 500"
else
    # smallest product whose files are at least the target; the point of asking
    # for a size is to make steps run longer, so round up rather than nearest
    best=$(awk -v t="${target_mb}" '
        $4+0 >= t+0 { if (p=="" || $4+0 < a+0) { p=$1; a=$4 } }
        { if (mx=="" || $4+0 > mx+0) { mp=$1; mx=$4 } }
        END { if (p!="") print p, a, "atleast"; else print mp, mx, "below" }' "${table}")
    set -- ${best}
    prod="${1}"; size="${2}"
    if [ "${3}" = "atleast" ]; then
        echo "   at least ${target_mb} MB: ${prod} (~${size} MB per file)"
    else
        echo "   nothing reaches ${target_mb} MB; largest is ${prod} (~${size} MB per file)"
    fi
    echo
    echo "   PRODUCT=${prod} ./make_data.sh"
fi
rm -f "${table}"

echo
echo "== 4. sanity check on one file =================================="
sample=$(find "${ds}" -name '*.nc' -print -quit 2>/dev/null)
if [ -z "${sample}" ]; then
    echo "   no .nc files found -- this dataset may live on object storage"
    exit 1
fi
echo "   ${sample}"
ls -lh "${sample}" | awk '{print "   readable, "$5}'
if command -v ncdump >/dev/null; then
    ncdump -h "${sample}" | sed -n '/^dimensions:/,/^variables:/p' | grep "=" | sed 's/^/   /'
else
    echo "   (module load nco to see its dimensions)"
fi
