#!/bin/bash
#
# Build NVIDIA's nvbandwidth (https://github.com/NVIDIA/nvbandwidth) here, as
# ./nvbandwidth, for the A100 GPUs of Derecho's GPU nodes.
#
# Run it on a login node: no GPU is needed, because the architecture is given
# (sm_80) rather than detected.  It takes about a minute.
#
#   ./build_nvbandwidth.sh            the release the README results came from
#   NVB_TAG=v0.11 ./build_nvbandwidth.sh
#
# The CUDA module must be the one bandwidth_test.sh loads, so the binary finds
# the same runtime on the compute node.

set -eu
tag="${NVB_TAG:-v0.10}"
cuda="${CUDA_MODULE:-cuda/12.9.0}"

cd "$(dirname "$0")"
module load gcc "$cuda" cmake

if [ ! -d nvbandwidth-src ]; then
    git clone --quiet https://github.com/NVIDIA/nvbandwidth.git nvbandwidth-src
fi
git -C nvbandwidth-src fetch --quiet --tags
git -C nvbandwidth-src checkout --quiet "$tag"

cmake -S nvbandwidth-src -B nvbandwidth-build \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=80
cmake --build nvbandwidth-build -j 8
cp nvbandwidth-build/nvbandwidth .
./nvbandwidth --version
