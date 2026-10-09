#!/bin/bash
#
# Write a command file of run_step.sh steps, one per GPU.
#
#   ./gen_cmdfile_gpu.sh <ngpus> <nsteps> [free|membind] [file]
#
#   ngpus    GPUs per node, as given to launch_cf_gpu.sh --ngpus
#   nsteps   steps in all; launch_cf runs them ngpus to a node
#   mode     free (default) or membind, see run_step.sh
#   file     default cmdfile.<ngpus>gpu.<nsteps>.<mode>
#
# launch_cf hands steps to nodes in blocks of ngpus, in file order, so the
# slot -- which of the node's GPUs a step uses -- cycles 0 .. ngpus-1 down
# the file.

set -u
[ $# -ge 2 ] || { sed -n '3,12p' "$0"; exit 1; }
ngpus="$1"
nsteps="$2"
mode="${3:-free}"
file="${4:-cmdfile.${ngpus}gpu.${nsteps}.${mode}}"

{
    echo "# $nsteps steps, $ngpus GPUs per node, mode $mode -- written by $(basename "$0")"
    for ((s = 0; s < nsteps; s++)); do
        echo "./run_step.sh $((s % ngpus)) $mode"
    done
} >"$file"
echo "$file"
