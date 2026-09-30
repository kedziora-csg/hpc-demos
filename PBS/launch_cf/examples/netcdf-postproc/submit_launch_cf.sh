#!/bin/bash

# Unpinned: the Linux scheduler decides where each step's ncks processes run.

launch_cf -A $PBS_ACCOUNT -l walltime=00:20:00 \
  ./cmdfile |& tee launch_cf.log
