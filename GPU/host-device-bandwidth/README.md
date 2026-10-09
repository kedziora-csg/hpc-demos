# Host–GPU Memory Bandwidth on Derecho

How fast can data move between a Derecho GPU node's host memory and its GPUs'
memory, and what slows it down? [`bandwidth_test.sh`](bandwidth_test.sh)
measures it on one node with two NVIDIA tools:

- **`bandwidthTest`**, the CUDA sample program. It comes ready to run with the
  CUDA toolkit, in `$CUDA_HOME/extras/demo_suite/`, and measures one GPU at a
  time.
- **[`nvbandwidth`](https://github.com/NVIDIA/nvbandwidth)**, its successor.
  It can drive all four GPUs at once. [`build_nvbandwidth.sh`](build_nvbandwidth.sh)
  builds it here.

`nvbench` is a different NVIDIA tool: a C++ library for timing CUDA kernels
you write yourself. It does not measure host–GPU copies.

In short (see [Results](#results)):

- **Pinned host memory** copies about 1.6 times faster to the GPU than ordinary
  pageable memory, and about twice as fast back.
- **For one GPU, NUMA placement does not matter.** The PCIe link limits the
  speed, wherever the host memory sits.
- **For four GPUs at once, it matters a lot.** With every GPU's host buffer in
  one NUMA domain, the node moves less than half as much data in one direction,
  and a sixth as much host-to-GPU data when copies go both ways.
- **Small copies are slow.** A copy needs to be about 1 MB or larger to get
  close to the link's speed.

## The node

A Derecho GPU node has one 64-core AMD EPYC 7763, split into four NUMA
domains, and four NVIDIA A100 (40 GB) GPUs. Each GPU has its own PCIe 4.0 x16
link to one domain:

| GPU | NUMA domain | cores           |
|-----|-------------|-----------------|
| 0   | 3           | 48–63, 112–127  |
| 1   | 2           | 32–47, 96–111   |
| 2   | 1           | 16–31, 80–95    |
| 3   | 0           | 0–15, 64–79     |

**The numbering runs in opposite directions.** GPU 0 is attached to domain 3,
not domain 0. Part 1 of the script prints this table from the node itself, and
`nvidia-smi topo -m` shows it too.

A PCIe 4.0 x16 link carries 32 GB/s in each direction before protocol
overhead, and about 27 GB/s of data in practice. The four GPUs are also linked
to each other by NVLink, which these tests do not use.

## Running it

Build `nvbandwidth` once, on a login node (about a minute):

    ./build_nvbandwidth.sh

Then run the test on a whole GPU node, as a batch job:

    qsub -A $PBS_ACCOUNT bandwidth_test.sh

or interactively:

    qsub -I -A $PBS_ACCOUNT -q main -l select=1:ncpus=64:ngpus=4 -l walltime=00:20:00
    ./bandwidth_test.sh

It takes about 11 minutes. Ask for all four GPUs even though some parts use
one, so no other job shares the memory and links being measured. The summary
goes to the job output, `bandwidth_test.o<jobid>`. Everything the tools print
goes to `bandwidth_test.<host>.<time>.log`. `PARTS="4 5"` runs only some
parts.

The script uses `numactl` to put the host memory in a chosen domain:

- `--membind=d` places all of the program's memory in domain `d`.
- `--interleave=all` spreads it page by page over all four domains.

`nvbandwidth` normally places each GPU's host buffer in that GPU's own domain.
`-d` turns that off, so the `numactl` setting decides.

## Results

From node deg0018 on 2026-10-09: CUDA 12.9, driver 580.65.06, `nvbandwidth`
v0.10. Part 4 was repeated on deg0005 and gave the same numbers to within
0.5 GB/s; its table gives the mean of the two runs. All bandwidths are in GB/s (10⁹ bytes/s). H2D is host to device
(GPU), and D2H is device to host.

### Pinned against pageable memory

Part 2, `bandwidthTest`, 32 MB copies, host memory in the GPU's own domain:

| memory   | H2D  | D2H      |
|----------|------|----------|
| pinned   | 26.0 | 21.6     |
| pageable | 15.8 | 9–11     |

**Pinned** (page-locked) memory cannot be moved or swapped out by the
operating system. Because of that, the GPU can read and write it directly.

**Pageable** memory is what `malloc` and NumPy return. The CUDA driver cannot
let the GPU use it directly. Instead, the CPU copies the data through a pinned
staging buffer of the driver's, and that extra copy costs 40–60% of the speed.

- In CUDA, allocate pinned memory with `cudaMallocHost` or `cudaHostAlloc`.
- In PyTorch, use `pin_memory=True` on a `DataLoader` or `tensor.pin_memory()`.

Pinned memory is held in RAM for as long as it is allocated, so it is best
kept for the buffers that are copied repeatedly.

Moving the pageable memory to another domain changed nothing (15.3–16.4 H2D).

### One GPU: placement does not matter

Part 3, `nvbandwidth`, 512 MiB pinned buffers, one GPU at a time:

| host memory in   | H2D  | D2H  |
|------------------|------|------|
| the GPU's domain | 26.8 | 26.1 |
| domain 0         | 26.8 | 26.2 |

Every GPU gave these numbers, including GPU 0, whose domain is three away from
domain 0. One PCIe link moves far less data than the connections between
domains can carry, so the link sets the speed.

`bandwidthTest` reports D2H about 4 GB/s lower than `nvbandwidth`, for copies
of 16 MB and more (see the [size table](#transfer-size)). Both tools time the
same kind of copy, and the reason for the gap was not investigated. The CUDA
samples warn that they "are not meant for performance measurements". For
numbers to rely on, use `nvbandwidth`.

### Four GPUs at once: placement matters

Part 4, `nvbandwidth`, all four GPUs copying at the same time. The table gives
the total over the four GPUs:

| host memory | H2D   | D2H   | both ways: H2D | both ways: D2H |
|-------------|-------|-------|----------------|----------------|
| local       | 107.1 | 104.5 | 83.6           | 84.8           |
| one domain  | 48.5  | 45.1  | 13.7           | 33.7           |
| interleave  | 107.1 | 103.4 | 46.9           | 87.0           |

The columns are:

- **H2D, D2H**: all four GPUs copy in one direction (`host_to_all_memcpy_ce`,
  `all_to_host_memcpy_ce`).
- **both ways**: every GPU copies to and from the host at the same time
  (`host_to_all_bidirectional_memcpy_ce`, `all_to_host_bidirectional_memcpy_ce`).

The rows are where the host memory was:

- **local**: each GPU's buffer was in that GPU's own domain.
- **one domain**: every buffer was in domain 0.
- **interleave**: every buffer was spread over all four domains.

**Why one domain is slow.** Each NUMA domain has two of the processor's eight
memory channels, a quarter of the node's memory bandwidth. One domain's memory
cannot keep up with four PCIe links, which together want 107 GB/s in each
direction. With
all of the host memory in domain 0, every GPU gets less than half its speed.
With copies going both ways, host-to-GPU traffic falls to a sixth.

**When it happens.** This is the case for a single process that allocates
pinned buffers for all four GPUs from one thread. Linux places a page in the
domain of the thread that first touches it, so every buffer lands in that
thread's domain. Some ways to avoid it:

- Run one process per GPU, each bound to its GPU's domain, for example with
  `numactl --cpunodebind=d --membind=d` (see the table under
  [The node](#the-node)).
- In a single process, allocate each GPU's buffers from a thread pinned to
  that GPU's domain. This is what `nvbandwidth` does by default. Before each
  allocation, it calls `nvmlDeviceSetCpuAffinity` to bind itself to the GPU's
  domain.
- `numactl --interleave=all` recovers the one-direction speed without changing
  the program. It does not recover the host-to-GPU speed when copies go both
  ways: three of the four GPUs dropped to 8.7 GB/s, on both nodes.

**Not tested here:** four processes each bound to the wrong domain, one GPU
each. That happens when ranks are bound to domains in order (rank 0 to domain
0) but rank *i* uses GPU *i*. Each domain would still serve only one GPU, but
all traffic would cross between domains. Part 3 shows that this costs nothing
for one GPU alone. It does not show what happens with all four at once.

### Transfer size

Part 5, `bandwidthTest`, GPU 0, pinned memory in its own domain:

| bytes  | H2D  | D2H  |
|--------|------|------|
| 4 KiB  | 0.8  | 1.5  |
| 16 KiB | 2.7  | 5.6  |
| 64 KiB | 9.6  | 12.2 |
| 256 KiB| 18.3 | 19.3 |
| 1 MiB  | 23.6 | 24.5 |
| 4 MiB  | 25.5 | 25.4 |
| 16 MiB | 26.0 | 21.6 |
| 64 MiB | 26.1 | 21.6 |
| 256 MiB| 26.1 | 22.4 |

Every copy has a fixed cost of a few microseconds before any data moves. For a
4 KiB copy, that cost is nearly all of the time. Copies need to be at least
about 1 MiB to reach most of the link's speed, so many small arrays move
faster if they are packed into one buffer and copied together.

### Measuring several GPUs: a trap

`bandwidthTest --device=all` does not run the GPUs at the same time. It
measures each GPU in turn and adds up the results. In a trial run it reported
104 GB/s H2D: four single-GPU results added up. It cannot show the
one-domain limit above, which appears only when the GPUs copy at the same
time. The `SUM` that `nvbandwidth` prints for `host_to_device_memcpy_ce` is
also a sum of separate runs. Only the `*_all_*` tests (`host_to_all_...`,
`all_to_host_...`) copy on all GPUs at once.
