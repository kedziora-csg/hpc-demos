# Sourced by launch_cf.pbs on the compute node before any step runs.
#
# nvbandwidth needs the CUDA runtime it was built with (libcudart.so.12), so
# the CUDA module has to be loaded there -- the modules you have loaded when
# you submit are not carried into the job.

module load cuda/12.9.0
