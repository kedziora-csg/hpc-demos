#!/bin/bash
#
# launch_cf for GPU steps: submit a command file as launch_cf does, with
# GPUs in each node's select statement.
#
# launch_cf itself cannot request GPUs.  It writes the select statement
# without ngpus, refuses any argument containing "select", and PBS refuses a
# job-wide -l ngpus alongside a select:
#
#   qsub: "-lresource=" cannot be used with "select" or "place", resource is: ngpus
#
# So this script does launch_cf's job-array arithmetic itself and submits
# launch_cf's own PBS script, launch_cf.pbs, which needs nothing changed: it
# runs one step per MPI slot of the node (mpiprocs), whatever they use.
#
# Usage:
#   ./launch_cf_gpu.sh -A <account> -l walltime=HH:MM:SS [options] [cmdfile]
#
#   --ngpus N            GPUs per node, and one step per GPU (default 4)
#   --nthreads N         cores per step (default 1): ncpus = N x ngpus
#   --mem SIZE           memory per node (default: the queue's default,
#                        487gb in gpu, 120gb in gpudev)
#   -q, --queue Q        main (default) or develop
#   --dry-run            print the qsub command instead of running it
#
# Anything else is passed on to qsub, as launch_cf does.  The command file
# defaults to ./cmdfile; ./config_env.sh is sourced on the node if present.

set -u
ngpus=4
nthreads=1
mem=""
queue=main
cmdfile=./cmdfile
dry=""
pbs_args=()

while [ $# -gt 0 ]; do
    case "$1" in
        --ngpus)             ngpus="$2"; shift 2 ;;
        --nthreads)          nthreads="$2"; shift 2 ;;
        --mem)               mem=":mem=$2"; shift 2 ;;
        -q|--queue)          queue="$2"; shift 2 ;;
        --dry-run)           dry=echo; shift ;;
        -J|*select*)         echo "ERROR: $1 is set from the command file and --ngpus"; exit 1 ;;
        *)  if [ -f "$1" ]; then cmdfile="$1"; else pbs_args+=("$1"); fi; shift ;;
    esac
done

launch_cf=$(command -v launch_cf) || { echo "ERROR: no launch_cf in PATH"; exit 1; }
pbs_script="$(dirname "$(readlink -f "$launch_cf")")/../share/launch_cf.pbs"
[ -r "$pbs_script" ] || { echo "ERROR: cannot find $pbs_script"; exit 1; }
[ -r "$cmdfile" ] || { echo "ERROR: cannot read command file $cmdfile"; exit 1; }

# steps: lines that are neither blank nor comments, as launch_cf counts them
nsteps=$(grep -c -v -E '^[[:space:]]*(#|$)' "$cmdfile")
[ "$nsteps" -gt 0 ] || { echo "ERROR: no steps in $cmdfile"; exit 1; }
steps_per_node=$ngpus
[ "$nsteps" -lt "$steps_per_node" ] && steps_per_node=$nsteps
nsubjobs=$(( (nsteps + steps_per_node - 1) / steps_per_node ))

# PBS will not take a one-entry array (-J 0-0), so one node is a plain job,
# as in launch_cf; launch_cf.pbs handles both
array=()
[ "$nsubjobs" -gt 1 ] && array=(-J "0-$((nsubjobs - 1))")

select="1:ncpus=$((steps_per_node * nthreads)):mpiprocs=$steps_per_node:ompthreads=$nthreads:ngpus=$steps_per_node$mem"
echo "$nsteps steps in $cmdfile -> $nsubjobs node(s), $steps_per_node steps and GPUs each, queue $queue"

$dry qsub -v command_file="$cmdfile",n_total_steps="$nsteps",max_start_delay=0 \
     -r y -q "$queue" -l select="$select" "${array[@]}" "${pbs_args[@]}" "$pbs_script"
