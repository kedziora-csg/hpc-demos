#!/bin/bash

# Pinned: every step, and the three NCO processes it starts, are confined to
# that step's own block of three cores.  Once both runs have finished, compare
# their step times with
#
#   ./compare_runs.sh
#
# which reads the job ids from launch_cf.log and launch_cf.pinned.log.

launch_cf -A $PBS_ACCOUNT -l walltime=00:20:00 \
  --nthreads 3 \
  ./cmdfile.pinned |& tee launch_cf.pinned.log
