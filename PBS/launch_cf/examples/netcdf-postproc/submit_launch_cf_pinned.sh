#!/bin/bash

# Pinned: every step, and all of the ncks processes it starts, are confined to
# a single core.  Compare the "Done: ... took N seconds" lines from the two
# runs' launch_cf.o* files:
#
#   grep "^Done:" launch_cf.o*

launch_cf -A $PBS_ACCOUNT -l walltime=00:20:00 \
  --nthreads 3 \
  ./cmdfile.pinned |& tee launch_cf.pinned.log
