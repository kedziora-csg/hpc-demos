# NUMA Placement for Threaded Python

[`../netcdf-postproc`](../netcdf-postproc) found that pinning made no
difference to independent, single-threaded steps. This example tests the case
that README pointed to instead: **one process whose threads share memory**,
doing work fast enough that memory bandwidth limits its speed.

It has two parts:

- **A single-node trial.** `numa_test.sh` measures whether placement changes
  the speed of this kind of work on a Derecho node. It does: binding each
  process to a NUMA domain gives a full node 1.6 times the throughput (see
  [Results](#results)).
- **A `launch_cf` version.** Real steps, one month of ERA5 each, eight to a
  node, with an unpinned and a pinned command file to compare, as in
  [`../thread-placement`](../thread-placement). Its results are still to come.

The ideas behind it are in [`ThreadedAppIdea.md`](ThreadedAppIdea.md).

## The computation

[`climatology.py`](climatology.py) holds one month of hourly ERA5 2 m
temperature in memory (744 × 721 × 1440 float32, 3.1 GB). It splits the grid
into latitude bands, one per thread, and each thread computes the time mean
and standard deviation of its band, over and over, for a fixed time.

- **The threads really run at once.** NumPy releases the GIL inside each call,
  and the script sets `OMP_NUM_THREADS`, `BLIS_NUM_THREADS` and similar
  variables to 1, so its 16 threads are the only threads.
- **The work is limited by memory bandwidth.** Each pass reads the array twice
  and does about one flop per value, and the array is 50 times the L3 cache of
  a NUMA domain.
- **Reading the file isn't timed.** The field is read once into `/dev/shm`, so
  neither GLADE nor the HDF5 lock in netCDF4 is part of the measurement.

Each run prints one line: its throughput, the NUMA domains its threads ran on,
the domains holding its memory, and `local`, the share of the threads' time
spent on the domain that holds their own band. `climatology.py` finds where the
pages are with the `move_pages` system call, and where the threads run with
`sched_getcpu`.

## The trial

A Derecho node has 8 NUMA domains of 16 cores (see
[`../thread-placement/lscpu.txt`](../thread-placement/lscpu.txt)), so
[`numa_test.sh`](numa_test.sh) runs 8 processes of 16 threads, one per domain,
as `launch_cf` would run 8 steps per node. They load first, then compute
together for 20 seconds, so they compete for memory bandwidth throughout.

| case           | placement                                                      |
| -------------- | -------------------------------------------------------------- |
| `8 free`       | none. The main thread reads the array, so all of it lands in one domain |
| `8 touch`      | none, but each thread copies its own band, so its pages start where it is |
| `8 bind`       | `numactl --cpunodebind=d --membind=d`: threads and memory in domain *d* |
| `8 bind+pin`   | as `bind`, with each thread pinned to its own core             |
| `8 interleave` | `numactl --cpunodebind=d --interleave=all`: memory spread over all 8 domains |
| `1 free`       | one process alone on the node, unpinned                        |
| `1 bind`       | one process alone, bound to domain 0                           |

The last two show why the comparison needs a full node: a process alone has
the node's memory system to itself, so its placement hardly matters.

## Running it

On Derecho, from this directory:

```
qsub -I -A $PBS_ACCOUNT -q main -l select=1:ncpus=128 -l walltime=00:30:00
./numa_test.sh               # 3 repeats of 20 s; or ./numa_test.sh <repeats> <seconds>
```

or as a batch job, `qsub -A $PBS_ACCOUNT numa_test.sh`. The script activates
the `npl-2026a` conda environment if NumPy and netCDF4 aren't already
available. It reads `e5.oper.an.sfc.128_167_2t` for January 2020 from GDEX on
GLADE. Set `ERA5_MONTH=YYYYMM` for another month, `ERA5_FILE` for any NetCDF
file with a 3-D field, or `SYNTHETIC=744` for random data of the same shape.

Each run prints a summary line, and every process's own line goes to
`numa_test.<host>.<time>.log`. The header also reports whether the kernel's
automatic NUMA balancing is on; see [below](#automatic-numa-balancing-was-off).

## Results

One Derecho node (`dec0603`), January 2020 2 m temperature, 3 repeats of 20 s.
The kernel's automatic NUMA balancing was off, so pages stayed where they were
first placed. Node throughput is the sum over the processes; it is the mean of
the three repeats, with the range of single processes beside it.

| case           | node GB/s | range of repeats | per process GB/s | local |
| -------------- | --------- | ---------------- | ---------------- | ----- |
| `8 bind`       | **288.3** | 287.6 – 288.9    | 35.1 – 36.7      | 100%  |
| `8 bind+pin`   | **289.9** | 289.6 – 290.4    | 35.8 – 36.8      | 100%  |
| `8 touch`      | 194.1     | 188.6 – 202.5    | 21.0 – 28.6      | 33%   |
| `8 free`       | 177.4     | 158.3 – 198.8    | 12.0 – 32.2      | 69%   |
| `8 interleave` | 172.6     | 172.5 – 172.9    | 20.3 – 22.9      | 12%   |
| `1 free`       | 38.2      | 37.4 – 39.6      |                  | 33%   |
| `1 bind`       | 36.6      | 36.2 – 37.2      |                  | 100%  |

### Binding to a NUMA domain is worth 1.6 times

With each process bound to its own domain, every process ran at 35–37 GB/s and
the node at 288 GB/s, the same in every repeat. That is about 70% of the node's
peak memory bandwidth (two DDR4-3200 channels, 51 GB/s, per domain). Unbound,
the node averaged 177 GB/s, and single processes ranged from 12 to 32 GB/s.

In a `launch_cf` job that spread matters more than the average. A node is
done only when its slowest step is, and in each repeat the slowest unbound
process ran at 12–18.5 GB/s, a third to a half of the speed of a bound one.

### Unbound, memory piles up in a few domains

The main thread reads the array, so every page of a process lands in the
domain that one thread happened to be on, and its 16 compute threads then
read it from wherever the scheduler puts them. The log shows two costs:

- **Remote reads.** On average 31% of a free process's thread time was spent
  on a domain other than the one holding its data.
- **Shared memory channels.** Eight main threads landing in eight different
  domains would be luck. In every repeat at least one pair of processes had
  their memory in the same domain (two pairs in two of the three), and one or
  two domains held nobody's memory at all. A pair sharing a domain shared its
  bandwidth: in repeat 2, the two processes with memory in domain 3 got 12.0
  and 22.0 GB/s, 34 GB/s together, about what one bound process gets alone.
  The idle domains' channels went unused.

### Fixes without binding don't hold

- **First touch in each thread (`touch`)** put each band's pages where its
  thread was when it copied the band. But the scheduler then moved the
  threads, so only 33% of thread time stayed local, and the node gained just
  9% over `free`. First touch only keeps memory local if the threads stay
  where they are.
- **Interleaving (`interleave`)** spreads every process's memory evenly over
  all 8 domains, so no domain is overloaded and the result hardly varies, but
  7/8 of all reads are remote. It came out slightly below `free`, at 60% of
  `bind`. (Processes on odd-numbered domains ran at 22.5–22.9 GB/s and those
  on even ones at 20.3–20.6, in every repeat. We didn't find out why.)

### Pinning threads inside the domain adds nothing

`bind+pin` was 0.5% faster than `bind`: in every repeat, but too little to
matter. Once `numactl` keeps a process's threads and memory in one domain,
where the scheduler puts each thread among those 16 cores doesn't matter. That
agrees with [`../netcdf-postproc`](../netcdf-postproc), where the scheduler
placed independent processes at least as well as pinning did.

### One process alone doesn't show it

On an otherwise idle node, a single unbound process ran at 38 GB/s, slightly
faster than a bound one, though only a third of its thread time was local.
All its memory was in one domain, so it was limited by that domain's two
memory channels however its threads were placed. A placement test with one
process on an idle node would find nothing to fix, as `netcdf-postproc` did;
the effect appears only when every domain is busy.

### Automatic NUMA balancing was off

Linux can fix placement by itself. With automatic NUMA balancing on
(`/proc/sys/kernel/numa_balancing` = 1), the kernel briefly makes a slice of
each process's memory inaccessible, about 256 MB at a time, and learns from
the page faults that follow which domain uses which pages. It then moves
pages to the domain using them, or threads to the domain holding their
memory.

On Derecho it is off (0), and only root can change it. That is usual on HPC
systems:

| | on | off |
| --- | --- | --- |
| **for** | fixes poor placement, such as `free`'s, with no change to the code; follows programs whose access pattern changes | no scanning or page-copying overhead; no jitter in a job whose ranks wait for the slowest; timings repeat |
| **against** | scanning and moving pages cost CPU time even for well-placed processes, and add jitter; slow to act (many seconds to cover a 3 GB array, so little help in a 20 s run); can bounce pages that threads in several domains share, or crowd processes into one domain | poor placement stays poor for the life of the process: placement is the user's job |

So the `free` and `touch` results here are the full cost of poor placement,
with nothing correcting it. With balancing on, they would probably improve
over a long run, and `bind` would not change: memory bound with `--membind` is
not moved. On a system where it is on, compare the counters
`numa_hint_faults`, `numa_hint_faults_local` and `numa_pages_migrated` in
`/proc/vmstat` before and after a run to see how much it did.

### Conclusions

- For threaded, memory-bound work on a full Derecho node, bind each process
  to one NUMA domain, with `numactl --cpunodebind=d --membind=d`. On this
  workload that gave 1.6 times the throughput and made every process run at
  the same speed.
- Binding the CPUs and the memory together is what matters. Pinning
  individual threads on top of it added nothing.
- Measure placement on a full node. A single process on an idle node shows
  no difference.

## The `launch_cf` version

The same computation as real `launch_cf` steps: each step reads one month of
ERA5 2 m temperature and computes its mean and standard deviation with 16
threads. `launch_cf --nthreads 16 --steps-per-node 8` puts eight steps on a
node, one per NUMA domain's worth of cores. Two command files differ only in
placement:

```
./run_step.sh unpinned .../e5.oper.an.sfc.128_167_2t.ll025sc.2019010100_2019013123.nc
numactl --cpunodebind=0 --membind=0 ./run_step.sh pinned .../e5.oper.an.sfc.128_167_2t.ll025sc.2019010100_2019013123.nc
```

Two things differ from the trial:

- **A step has a fixed amount of work**, 200 passes per thread, rather than a
  fixed time, so a slow placement shows up as a slow step, and the node is
  busy until its slowest step finishes. A real analysis would make one pass;
  the repeats stand in for heavier work, so that the compute phase (about
  35 s when pinned) is long enough to measure next to loading.
- **Each step reads its file from GLADE itself.** The load is timed and
  reported, but kept out of the throughput. The steps on a node then wait for
  each other in a node-local directory and start computing together, so that
  a step that loads early doesn't finish before a late one starts.

| file                         | role                                                    |
| ---------------------------- | ------------------------------------------------------- |
| `gen_cmdfile_numa.sh`        | write `cmdfile` or, with `pin`, `cmdfile.pinned`        |
| `run_step.sh`                | one step: `climatology.py` on one month                 |
| `config_env.sh`              | sourced on the compute node: activates `npl-2026a`      |
| `submit_launch_cf.sh`        | submit the unpinned run                                 |
| `submit_launch_cf_pinned.sh` | submit the pinned run                                   |
| `compare_runs.sh`            | compare the runs by their steps                         |

From this directory on a Derecho login node, with `$PBS_ACCOUNT` set:

```
./gen_cmdfile_numa.sh            # 24 months from January 2019 -> cmdfile
./gen_cmdfile_numa.sh pin        #                              -> cmdfile.pinned
./submit_launch_cf.sh
./submit_launch_cf_pinned.sh
./compare_runs.sh                # once both have finished
```

`START=YYYYMM` and `NSTEPS` choose other months. `NSTEPS` must be a multiple
of 8, because the steps on a node wait for eight of them. `make numa-cmdfiles`
in the parent directory writes both command files.

`compare_runs.sh` reports each run's step throughput (mean, minimum and
maximum), its mean step time, and `node s`, the time of each node's slowest
step, averaged over nodes. That last is what placement costs a `launch_cf`
job.
