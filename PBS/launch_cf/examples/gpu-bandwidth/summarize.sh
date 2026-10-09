#!/bin/bash
#
# Tabulate the RESULT lines of every finished step under ./stdout-*/, one row
# per step, grouped by run (launch_cf job).  The case names come from
# submitted.log, written by submit_matrix.sh.
#
#   ./summarize.sh            all runs
#   ./summarize.sh 7773800    only these runs (job ids, without [] or .desched1)
#
# Columns:
#   node, sub   the node, and the subjob of the array
#   gpu, dom    which of the job's GPUs the step used (slot/GPUs in the job),
#               and the NUMA domain that GPU is attached to
#   cores, dom  the cores PBS gave the job, and their NUMA domains
#   memory      domain:MiB of the step's host memory while it copied
#   H2D D2H     GB/s, host to GPU and back, median of 10 samples of 16 copies
#               of 1 GiB
#   start secs  when the step started, seconds after the run's first step,
#               and how long it took: steps on one node that overlap were
#               copying at the same time

cd "$(dirname "$0")" || exit 1
filter=" $* "

grep -h '^RESULT ' stdout-*/step-*.out 2>/dev/null |
awk -v filter="$filter" '
    BEGIN {
        while ((getline line < "submitted.log") > 0) {
            nf = split(line, w, " "); id = w[nf]; sub(/\[\]/, "", id); sub(/\..*/, "", id); label[id] = w[1]
        }
    }
    {
        delete f
        for (i = 2; i <= NF; i++) { split($i, kv, "="); f[kv[1]] = substr($i, length(kv[1]) + 2) }
        run = f["job"]; sub(/\[.*/, "", run); sub(/\..*/, "", run)
        if (filter != "  " && index(filter, " " run " ") == 0) next
        sub_ = f["job"]; sub(/^[^\[]*/, "", sub_); sub(/\].*/, "]", sub_)
        n = ++count[run]
        row[run, n] = sprintf("  %-8s %-4s %-4s %-4s %-14s %-6s %-12s %6.1f %6.1f",
            f["host"], sub_, f["slot"] "/" f["ngpus"], f["gpu_dom"], f["cpus"], f["cpu_doms"],
            f["mem"], f["h2d"], f["d2h"])
        t0[run, n] = f["t0"]; t1[run, n] = f["t1"]
        if (!(run in first) || f["t0"] < first[run]) first[run] = f["t0"]
        if (!(run in seen)) { seen[run] = 1; order[++nruns] = run; queue[run] = f["queue"]; mode[run] = f["mode"] }
        h2d[run] += f["h2d"]; d2h[run] += f["d2h"]
    }
    END {
        for (r = 1; r <= nruns; r++) {
            run = order[r]
            printf "\n%s  %s  queue %s  mode %s  %d steps, mean H2D %.1f D2H %.1f\n", run,
                (run in label ? label[run] : "?"), queue[run], mode[run], count[run],
                h2d[run] / count[run], d2h[run] / count[run]
            printf "  %-8s %-4s %-4s %-4s %-14s %-6s %-12s %6s %6s %6s %5s\n", "node", "sub", "gpu", "dom",
                "cores", "dom", "memory", "H2D", "D2H", "start", "secs"
            for (n = 1; n <= count[run]; n++)
                printf "%s %6.0f %5.0f\n", row[run, n], t0[run, n] - first[run], t1[run, n] - t0[run, n]
        }
    }'
