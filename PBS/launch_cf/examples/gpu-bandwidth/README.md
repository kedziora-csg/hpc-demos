# GPU Steps: Host–GPU Bandwidth Under `launch_cf`

This example runs one GPU per `launch_cf` step on Derecho's GPU nodes. Each
step measures how fast its GPU copies data to and from host memory, using
`nvbandwidth` from [`GPU/host-device-bandwidth`](../../../../GPU/host-device-bandwidth).
It records where PBS put the step: which node, GPU, cores and memory.

The runs cover both GPU queues: **main** (routed to `gpu`, whole nodes) and
**develop** (routed to `gpudev`, shared nodes). In each queue they use 1, 2
and 4 GPUs per node. So the example also checks the Derecho queues table in
NCAR/HPC-Docs (`docs/pbs/charging.md`) against what the queues actually do;
see [The queues table](#the-queues-table).

What it found (see [Results](#results)):

- **`launch_cf` cannot ask for GPUs**, so this example submits through a small
  wrapper, [`launch_cf_gpu.sh`](launch_cf_gpu.sh).
- **A job sees only the GPUs and cores it asked for,** in both queues. A main
  queue job that asks for 1 GPU and 1 core gets the whole node to itself, but
  can use only that one GPU and core.
- **The cores PBS gives a GPU job usually sit in NUMA domain 0, whichever GPUs
  it got.** With one core per step, every step's host memory then lands in
  domain 0. Four steps on four GPUs copy at 12 GB/s each instead of 26.8. The
  same happened between two separate develop jobs that shared a node.
- **`numactl --membind` to each GPU's own domain restores full speed** in every
  case, without asking for more cores.

## Running it

Build `nvbandwidth` first, if [`GPU/host-device-bandwidth`](../../../../GPU/host-device-bandwidth)
has not been run yet:

    ../../../../GPU/host-device-bandwidth/build_nvbandwidth.sh

Then submit the runs from this directory:

    ./submit_matrix.sh                 # main and develop: 12 launch_cf runs
    ./submit_matrix.sh limits          # develop's array and GPU limits, on their own
    ./summarize.sh                     # once they have finished

Each run is 4 steps, one per GPU, and takes under a minute per node. At 1 GPU
per node that is 4 array subjobs, at 2 it is 2, and at 4 it is a single job.
Every run is submitted twice, once with each memory placement:

- **free**: no placement. A step's host memory lands in the domain of
  whichever core it runs on, as with most programs.
- **membind**: `numactl --membind=<d>`, with *d* the domain of the step's own
  GPU.

The files:

| file | what it does |
|------|--------------|
| [`launch_cf_gpu.sh`](launch_cf_gpu.sh) | submits a command file like `launch_cf`, with `ngpus` in the select statement |
| [`gen_cmdfile_gpu.sh`](gen_cmdfile_gpu.sh) | writes a command file of `run_step.sh` lines, giving each step on a node its own GPU |
| [`run_step.sh`](run_step.sh) | one step: runs `nvbandwidth` on one GPU and records the node, GPU, cores and memory domains |
| [`config_env.sh`](config_env.sh) | loads the CUDA module on the node, before the steps run |
| [`submit_matrix.sh`](submit_matrix.sh) | submits every case and logs the job ids in `submitted.log` |
| [`summarize.sh`](summarize.sh) | prints one table per run from the steps' `RESULT` lines |

## Why a wrapper

`launch_cf` builds its select statement without `ngpus`, and it refuses any
argument containing `select`. PBS will not accept `-l ngpus` for the whole job
alongside a select statement either:

    qsub: "-lresource=" cannot be used with "select" or "place", resource is: ngpus

So neither the installed `launch_cf` nor the version in NCAR/pbstools PR 13
can request a GPU. [`launch_cf_gpu.sh`](launch_cf_gpu.sh) does `launch_cf`'s
job-array arithmetic itself. It writes a select statement with one GPU per
step and submits `launch_cf`'s own PBS script, `share/launch_cf.pbs`,
unchanged. That script runs one step per MPI slot of the node
(`mpiprocs`), so GPU steps need nothing more from it. A `--ngpus` option in
`launch_cf` would make the wrapper unnecessary.

**Each step must use its own GPU.** PBS sets `CUDA_VISIBLE_DEVICES` to the
job's GPUs, and all the steps on a node share that list. `gen_cmdfile_gpu.sh`
therefore gives each step on a node a different slot, 0 to ngpus−1, and
`run_step.sh` narrows `CUDA_VISIBLE_DEVICES` to that one GPU.

## Results

All 13 runs were made on 2026-10-09 with CUDA 12.9, driver 580.65.06 and
`nvbandwidth` v0.10. Every step copied 1 GiB at a time from pinned memory: 10
samples of 16 copies, reporting the median. A GPU's PCIe link carries
26.8 GB/s to the GPU and 26.2 GB/s back, on its own
(see [`GPU/host-device-bandwidth`](../../../../GPU/host-device-bandwidth#results)).

Mean bandwidth per GPU, in GB/s:

| queue → execution queue | GPUs per node | free H2D | free D2H | membind H2D | membind D2H |
|-------------------------|---------------|----------|----------|-------------|-------------|
| main → gpu              | 1             | 26.8     | 26.2     | 26.8        | 26.2        |
| main → gpu              | 2             | 24.6     | 23.0     | 26.8        | 26.2        |
| main → gpu              | 4             | 12.1     | 10.9     | 26.8        | 26.2        |
| develop → gpudev        | 1             | 26.8     | 26.1     | 26.8        | 26.3        |
| develop → gpudev        | 2             | 18.8     | 10.9     | 26.8        | 26.2        |
| develop → gpudev        | 4             | 12.1     | 10.9     | 26.8        | 26.2        |

H2D is host to device (GPU), and D2H is device to host.

### What each job could use

PBS places every job in a cgroup that holds only the GPUs and cores it
requested. This is true in both queues:

- **GPUs.** `nvidia-smi` and `CUDA_VISIBLE_DEVICES` show only the job's GPUs.
- **Cores.** `ncpus=N` gives N cores and their second hardware threads. With
  `ncpus=1` that is cores 0 and 64, which are the same physical core.
- **Memory.** The job may use memory in all four NUMA domains.

In the main queue the node is still exclusive: `place=scatter:exclhost`, so no
other job runs on it. A 1-GPU main job therefore holds a whole node but can use
one GPU and one core of it.

### Where the cores were

The cores were in domain 0 in almost every job, wherever its GPUs were:

| run | cores | GPUs' domains | memory, free |
|-----|-------|---------------|--------------|
| main, 1 GPU, 4 subjobs on 4 nodes | 0 | 2 (every subjob got the same GPU) | domain 0 |
| main, 2 GPUs, 2 subjobs on 2 nodes | 0–1 | 2 and 0 | domain 0 |
| main and develop, 4 GPUs | 0–3 | 2, 0, 3, 1 | domain 0 |
| develop, 2 GPUs, 2 subjobs on one node | 0–1 and 2–3 | 2, 0 and 3, 1 | domain 0 |
| develop, 1 GPU, 4 subjobs on one node | 32, 0, 48, 16 | 2, 0, 3, 1 | each GPU's own |

The exception was the 1-GPU develop runs. In each of the two arrays, all four
subjobs shared one node, and each got a core in its own GPU's domain. The 1-GPU
main subjobs did not: each got core 0, with its GPU in domain 2. These few runs
do not show what rule PBS follows.

**Why one domain is slow.** With memory free, a step's pinned host buffer
lands in its core's domain. One domain's memory cannot feed several PCIe links
at once:

- With 4 GPUs, every GPU ran at 12 GB/s, matching the "one domain" case of
  [`GPU/host-device-bandwidth`](../../../../GPU/host-device-bandwidth#four-gpus-at-once-placement-matters).
- With 2 GPUs per node in main, two links shared domain 0, and the cost was
  small: 24–25 GB/s H2D and 22–24 GB/s D2H.
- With 2 GPUs per node in develop, both subjobs landed on one node, both with
  cores in domain 0. So four GPUs were fed from domain 0 by **two separate
  jobs**, and D2H fell to about 11 GB/s on all four. On a shared node, another job's placement
  can slow yours.

One GPU on its own ran at full speed even with its memory in another domain,
as it did in [`GPU/host-device-bandwidth`](../../../../GPU/host-device-bandwidth#one-gpu-placement-does-not-matter).

**The fix** is to bind each step's memory to its GPU's domain. A job may use
memory in every domain whatever cores it has, so `numactl --membind` works with
one core per step. `run_step.sh membind` looks up the domain from the GPU's PCI
address:

    bus=$(nvidia-smi -i "$uuid" --query-gpu=pci.bus_id --format=csv,noheader)
    cat /sys/bus/pci/devices/<bus, lower case, 4-digit domain>/numa_node

In a main job, asking for `ncpus=64` gives the job every core, at no extra
charge if the node is charged in full anyway, as the table says. However, it
does not say where each step's memory goes; binding does.

## The queues table

These are checks of the Derecho queues table in `docs/pbs/charging.md`
(NCAR/HPC-Docs PR 403), for the GPU queues. They were made on 2026-10-09
using:

- **held submissions** (`qsub -h`, then `qdel`) to see what `qsub` accepts.
  Held jobs are not routed, so this checks only the limits of the routing
  queues (`main`, `develop`), not those of `gpu` and `gpudev`.
- **the runs above.**
- **the queue settings**, from `qstat -Qf` and `pbsnodes`.

| table says | found |
|------------|-------|
| main: GPU jobs run in **gpu** | Every job with `ngpus` ran in `gpu`. |
| gpu: 12 hours | `walltime=12:00:00` accepted. `12:01:00` refused: "the queue limit is 43200 seconds". |
| gpu: 82 nodes, 4 GPUs per node | 82 nodes have `ngpus=4`, `ncpus=64` and about 487 GB. The `gpu` queue allows at most 256 GPUs (64 nodes) per job (`resources_max.ngpus`); this was not tested. |
| gpu: exclusive use | `place=scatter:exclhost`. Four 1-GPU subjobs went to four nodes. A job can use only the GPUs and cores it requested; see [What each job could use](#what-each-job-could-use). |
| develop: GPU jobs run in **gpudev** | Yes. |
| gpudev: 6 hours | `06:00:00` accepted. `06:01:00` refused: "the queue limit is 21600 seconds". |
| gpudev: 8 GPUs | Per job: 9 GPUs refused by `qsub` ("Job violates queue and/or server resource limits"). Per user: `max_run_res.ngpus = [u:PBS_GENERIC=8]`. One job array of 3 subjobs, each 1 node with 4 GPUs (12 GPUs in all): subjobs 0 and 1 ran together (8 GPUs), and subjob 2 started only when they finished. Across all the develop runs, no more than 8 GPUs ran at once. |
| gpudev: 487 GB per node | A 1-GPU job with `mem=487gb` ran. One with `mem=488gb` stayed queued, until deleted: "Insufficient amount of resource mem". A job that does not ask gets the queue default, **120 GB**, per chunk. |
| gpudev: 4 indices per job array | A 5-index array was refused by `qsub`: "Array job exceeds server or queue size limit" (`max_array_size = 4` on `develop`). The limit is per array: two 4-index arrays ran at the same time, 8 subjobs in all. |
| gpudev: shared nodes | `place=scatter:shared`. Four 1-GPU subjobs shared one node, and two 2-GPU subjobs shared another. |
| charges: gpu per node (4 GPUs), gpudev per GPU requested | Not visible from a job. SAM takes job records daily; the job ids are below. |

Job ids, for checking the charges in SAM:

| run | main → gpu | develop → gpudev |
|-----|------------|------------------|
| 1 GPU per node, free | 7774085 (4 subjobs) | 7774091 (4 subjobs) |
| 1 GPU per node, membind | 7774086 (4 subjobs) | 7774092 (4 subjobs) |
| 2 GPUs per node, free | 7774087 (2 subjobs) | 7774093 (2 subjobs) |
| 2 GPUs per node, membind | 7774088 (2 subjobs) | 7774094 (2 subjobs) |
| 4 GPUs per node, free | 7774089 | 7774095 |
| 4 GPUs per node, membind | 7774090 | 7774096 |
| 3 nodes of 4 GPUs (limits) | | 7774120 (3 subjobs) |
| `mem=487gb` | | 7774135 |

Each subjob ran for 20–60 s. If the table is right, a 1-GPU subjob in `gpu`
is charged for 4 GPUs, and one in `gpudev` for 1.
