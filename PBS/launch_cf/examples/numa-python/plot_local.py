#!/usr/bin/env python3
"""
Plot each launch_cf step's compute time against its share of local thread time.

Every step-*.out ends with climatology.py's report line, which gives the
step's compute time (seconds) and "local", the share of its threads' time
spent on the NUMA domain holding their own data.  One dot per step, one color
per run.

Months differ in length by up to 10% (28 to 31 days), so steps with the same
placement still differ a little in time; February is the shortest.

Usage:
  python3 plot_local.py                      launch_cf.log and launch_cf.pinned.log
  python3 plot_local.py <run> [<run> ...]    launch_cf logs or stdout-<job id> dirs
  python3 plot_local.py -o local.png --csv local.csv

Needs matplotlib (in npl-2026a).
"""

import argparse
import csv
import glob
import os
import re
import sys

import matplotlib
matplotlib.use("Agg")                    # write a file; no display needed
import matplotlib.pyplot as plt

# Categorical slots in fixed order, one per run, plus the ink and surface the
# text and marks sit on.  The first three slots stay distinguishable for
# colorblind readers in a scatter, so more than three runs is refused.
SERIES = ["#2a78d6", "#eb6834", "#1baf7a"]
SURFACE = "#fcfcfb"
TEXT = "#0b0b0b"
TEXT_2 = "#52514e"
GRID = "#e4e3df"


def step_dir(run):
    """stdout-<job id> directory for a launch_cf log, or the directory itself."""
    if os.path.isdir(run):
        return run
    with open(run) as f:
        # qsub prints the job id, e.g. 7672405[].desched1; the logs directory
        # is named after it without the "[]"
        ids = re.findall(r"^(\d+)(?:\[\])?(\.[A-Za-z0-9.-]+)", f.read(), re.M)
    if not ids:
        sys.exit(f"ERROR: no job id in {run}")
    num, suffix = ids[-1]
    return os.path.join(os.path.dirname(run), f"stdout-{num}{suffix}")


def reports(directory):
    """The report fields of every step that finished, as dicts."""
    out = []
    for path in sorted(glob.glob(os.path.join(directory, "step-*.out"))):
        with open(path) as f:
            lines = [l for l in f if "GBps=" in l]
        if lines:
            fields = dict(kv.split("=", 1) for kv in lines[-1].split() if "=" in kv)
            if fields.get("local", "?") != "?":
                out.append(fields)
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("runs", nargs="*",
                   default=["launch_cf.log", "launch_cf.pinned.log"],
                   help="launch_cf logs or stdout-<job id> directories")
    p.add_argument("-o", "--output", default="local_vs_time.png")
    p.add_argument("--csv", help="also write the points to this CSV file")
    args = p.parse_args()
    if len(args.runs) > len(SERIES):
        sys.exit(f"ERROR: at most {len(SERIES)} runs on one plot")

    runs = []
    for run in args.runs:
        d = step_dir(run)
        steps = reports(d)
        if not steps:
            sys.exit(f"ERROR: no step reports in {d}/ (has the job run?)")
        # name a run by its variant label, e.g. "pinned", and its job id
        name = f"{steps[0].get('variant', run)} ({os.path.basename(d)[7:]})"
        runs.append((name, steps))

    plt.rcParams.update({"font.size": 10, "axes.edgecolor": TEXT_2,
                         "text.color": TEXT, "axes.labelcolor": TEXT_2,
                         "xtick.color": TEXT_2, "ytick.color": TEXT_2})
    fig, ax = plt.subplots(figsize=(7.5, 5), dpi=150)
    fig.patch.set_facecolor(SURFACE)
    ax.set_facecolor(SURFACE)

    ymax = 0.0
    for color, (name, steps) in zip(SERIES, runs):
        x = [float(s["local"]) for s in steps]
        y = [float(s["seconds"]) for s in steps]
        ymax = max(ymax, max(y))
        # a ring in the surface color keeps overlapping dots apart
        ax.scatter(x, y, s=64, color=color, edgecolors=SURFACE, linewidths=1.5,
                   label=name, zorder=3)
        mean_x, mean_y = sum(x) / len(x), sum(y) / len(y)
        # steps that all sit at one x hide behind each other; say how many
        if min(x) == max(x):
            ax.annotate(f"{len(steps)} steps, all at {x[0]:.0f}%", (x[0], mean_y),
                        xytext=(-12, 0), textcoords="offset points",
                        ha="right", va="center", fontsize=9, color=TEXT_2)
        print(f"{name:32s} {len(steps):3d} steps  local {mean_x:5.1f}%  "
              f"{mean_y:6.1f} s mean, {max(y):6.1f} s slowest")

    ax.set_xlim(-3, 103)
    ax.set_ylim(0, ymax * 1.12)          # from zero, so ratios read true
    ax.set_xlabel("local: share of thread time on the domain holding its data (%)")
    ax.set_ylabel("compute time per step (s)")
    ax.grid(True, color=GRID, linewidth=0.8, zorder=0)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    ax.legend(frameon=False, loc="upper right", labelcolor=TEXT)
    fig.suptitle("Step compute time vs. local thread time", x=0.08, ha="left",
                 fontsize=12, color=TEXT)
    ax.set_title("one dot per launch_cf step; months of 28 to 31 days, so "
                 "times also vary by up to 10%", loc="left", fontsize=9,
                 color=TEXT_2)
    fig.tight_layout()
    fig.savefig(args.output, facecolor=SURFACE)
    print(f"wrote {args.output}")

    if args.csv:
        with open(args.csv, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["run", "step", "host", "index", "local", "seconds",
                        "GBps", "threads_on", "memory_on"])
            for name, steps in runs:
                for s in steps:
                    w.writerow([name] + [s.get(k, "") for k in
                                ("step", "host", "index", "local", "seconds",
                                 "GBps", "threads_on", "memory_on")])
        print(f"wrote {args.csv}")


if __name__ == "__main__":
    main()
