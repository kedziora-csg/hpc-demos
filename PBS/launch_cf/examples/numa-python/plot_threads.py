#!/usr/bin/env python3
"""
Plot every thread of a launch_cf run: when it finished, and whether it ran on
the NUMA domain holding its data.

Needs the per-thread lines climatology.py prints with --thread-report (which
run_step.sh passes).  Two kinds of figure:

  threads_<variant>.png  one node of a run: its 8 steps side by side, one bar
                         per thread.  A bar is colored by the domain the thread
                         was on as time went by -- its data's domain ("home"),
                         or another one ("away") -- and then grayed from when it
                         finished to when its step's slowest thread finished:
                         time it spent waiting, its core idle.
  threads_scatter.png    every thread of every run: finish time against its
                         own share of local time.

The domain is sampled at the end of each pass and stands for the whole pass,
so a bar's colors are accurate to about one pass (0.2-0.4 s).

Usage:
  python3 plot_threads.py                    launch_cf.log and launch_cf.pinned.log
  python3 plot_threads.py <run> [<run> ...]  launch_cf logs or stdout-<job id> dirs
  python3 plot_threads.py --index 2          the node that ran array index 2

Needs matplotlib (in npl-2026a).
"""

import argparse
import glob
import os
import re
import sys

import matplotlib
matplotlib.use("Agg")                    # write a file; no display needed
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

# Runs take the categorical slots in fixed order, the same colors as
# plot_local.py (unpinned blue, pinned orange).  Home/away is a different
# question, so it gets its own pair (aqua, violet) rather than reusing the run
# colors with another meaning; grays are for states that are not data.
SERIES = ["#2a78d6", "#eb6834", "#e87ba4"]
HOME = "#1baf7a"
AWAY = "#4a3aa7"
UNKNOWN = "#a3a29c"
WAITING = "#e4e3df"
SURFACE = "#fcfcfb"
TEXT = "#0b0b0b"
TEXT_2 = "#52514e"
GRID = "#e4e3df"


def step_dir(run):
    """stdout-<job id> directory for a launch_cf log, or the directory itself."""
    if os.path.isdir(run):
        return run
    if not os.path.exists(run):
        sys.exit(f"ERROR: {run} not found")
    with open(run) as f:
        ids = re.findall(r"^(\d+)(?:\[\])?(\.[A-Za-z0-9.-]+)", f.read(), re.M)
    if not ids:
        sys.exit(f"ERROR: no job id in {run}")
    num, suffix = ids[-1]
    return os.path.join(os.path.dirname(run), f"stdout-{num}{suffix}")


def fields(line):
    return dict(kv.split("=", 1) for kv in line.split() if "=" in kv)


def read_run(directory):
    """[{'report': {...}, 'threads': [{...}, ...]}, ...], one per finished step."""
    steps = []
    for path in sorted(glob.glob(os.path.join(directory, "step-*.out"))):
        threads, report = [], None
        with open(path) as f:
            for line in f:
                if line.startswith("thread="):
                    threads.append(fields(line))
                elif "GBps=" in line:
                    report = fields(line)
        if report and threads:
            steps.append({"report": report, "threads": threads})
    return steps


def home_of(thread):
    """The domain holding most of a thread's band, as 'D3', or None."""
    first = thread["memory_on"].split(",")[0]
    return first.split(":")[0] if first.startswith("D") and first[1] != "?" else None


def spans(thread):
    """[(domain, start, end), ...] from 'D3:0.0-41.3,D1:41.3-52.1'."""
    out = []
    for part in thread["timeline"].split(","):
        d, _, times = part.partition(":")
        a, _, b = times.partition("-")
        out.append((d, float(a), float(b)))
    return out


def style(ax):
    ax.set_facecolor(SURFACE)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    ax.tick_params(colors=TEXT_2, labelsize=8)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(TEXT_2)


def plot_node(name, steps, index, xmax, output):
    steps = [s for s in steps if s["report"].get("index") == index]
    if not steps:
        print(f"{name}: no steps ran as array index {index}; skipped")
        return
    steps.sort(key=lambda s: s["report"].get("step", ""))
    ncols = 2
    nrows = (len(steps) + ncols - 1) // ncols
    fig, axes = plt.subplots(nrows, ncols, figsize=(10, 2.1 * nrows + 1.2),
                             dpi=150, sharex=True, squeeze=False)
    fig.patch.set_facecolor(SURFACE)

    for ax, step in zip(axes.flat, steps):
        style(ax)
        r = step["report"]
        end = float(r["seconds"])
        threads = sorted(step["threads"], key=lambda t: int(t["thread"]))
        for t in threads:
            y = int(t["thread"])
            home = home_of(t)
            for d, a, b in spans(t):
                color = UNKNOWN if home is None else (HOME if d == home else AWAY)
                ax.barh(y, b - a, left=a, height=0.8, color=color, linewidth=0)
            done = float(t["seconds"])
            if end - done > 0.05:
                ax.barh(y, end - done, left=done, height=0.8, color=WAITING,
                        linewidth=0)
        ax.set_ylim(len(threads) - 0.5, -0.5)      # thread 0 at the top
        ax.set_yticks([0, len(threads) - 1])
        ax.set_xlim(0, xmax)
        ax.grid(True, axis="x", color=GRID, linewidth=0.6, zorder=0)
        ax.set_axisbelow(True)
        ax.set_title(f"{r.get('step', '?')}   data in {r.get('memory_on', '?')}"
                     f"   local {r.get('local', '?')}%   {end:.0f} s",
                     loc="left", fontsize=9, color=TEXT)
    for ax in axes.flat[len(steps):]:
        ax.set_visible(False)
    for ax in axes[-1]:
        ax.set_xlabel("seconds from the start of computing", fontsize=9,
                      color=TEXT_2)
    for ax in axes[:, 0]:
        ax.set_ylabel("thread", fontsize=9, color=TEXT_2)

    host = steps[0]["report"].get("host", "?")
    fig.suptitle(f"{name}: the {len(steps)} steps on {host} (array index "
                 f"{index}), one bar per thread", x=0.02, ha="left",
                 fontsize=12, color=TEXT)
    fig.legend(handles=[Patch(color=HOME, label="on its data's domain"),
                        Patch(color=AWAY, label="on another domain"),
                        Patch(color=WAITING, label="finished, waiting for "
                              "the step's slowest thread")],
               loc="upper left", bbox_to_anchor=(0.02, 0.965), ncol=3,
               frameon=False, fontsize=9, labelcolor=TEXT)
    fig.tight_layout(rect=(0, 0, 1, 0.93))
    fig.savefig(output, facecolor=SURFACE)
    plt.close(fig)
    print(f"wrote {output}")


def plot_scatter(runs, output):
    fig, ax = plt.subplots(figsize=(7.5, 5), dpi=150)
    fig.patch.set_facecolor(SURFACE)
    style(ax)
    ymax = 0.0
    for color, (name, steps) in zip(SERIES, runs):
        pts = [(float(t["local"]), float(t["seconds"]))
               for s in steps for t in s["threads"] if t["local"] != "?"]
        if not pts:
            continue
        x, y = zip(*pts)
        ymax = max(ymax, max(y))
        ax.scatter(x, y, s=25, color=color, edgecolors=SURFACE, linewidths=0.8,
                   label=f"{name}, {len(pts)} threads", zorder=3)
        # threads that all sit at one x hide behind each other; say how many
        if min(x) == max(x):
            ax.annotate(f"{len(pts)} threads, all at {x[0]:.0f}%",
                        (x[0], sum(y) / len(y)), xytext=(-12, 0),
                        textcoords="offset points", ha="right", va="center",
                        fontsize=9, color=TEXT_2)
    ax.set_xlim(-3, 103)
    ax.set_ylim(0, ymax * 1.12)
    ax.grid(True, color=GRID, linewidth=0.8, zorder=0)
    ax.set_xlabel("thread's local share: time on its data's domain (%)",
                  color=TEXT_2)
    ax.set_ylabel("time for the thread's 200 passes (s)" if all(
        t.get("passes") == "200" for _, st in runs for s in st
        for t in s["threads"]) else "thread finish time (s)", color=TEXT_2)
    ax.legend(frameon=False, loc="upper right", labelcolor=TEXT, fontsize=9)
    fig.suptitle("Thread finish time vs. its own local share", x=0.08,
                 ha="left", fontsize=12, color=TEXT)
    ax.set_title("one dot per thread, every step of every run", loc="left",
                 fontsize=9, color=TEXT_2)
    fig.tight_layout()
    fig.savefig(output, facecolor=SURFACE)
    plt.close(fig)
    print(f"wrote {output}")


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("runs", nargs="*",
                   default=["launch_cf.log", "launch_cf.pinned.log"],
                   help="launch_cf logs or stdout-<job id> directories")
    p.add_argument("--index", help="array index (node) to draw; default the "
                   "lowest in each run")
    p.add_argument("--outdir", default=".")
    args = p.parse_args()
    if len(args.runs) > len(SERIES):
        sys.exit(f"ERROR: at most {len(SERIES)} runs on one plot")

    runs = []
    for run in args.runs:
        d = step_dir(run)
        steps = read_run(d)
        if not steps:
            sys.exit(f"ERROR: no steps with per-thread lines in {d}/ -- "
                     "was it run with --thread-report?")
        runs.append((steps[0]["report"].get("variant", run), steps))

    plt.rcParams.update({"font.size": 10, "text.color": TEXT})
    # one time scale for every node figure, so they compare at a glance
    xmax = 1.05 * max(float(s["report"]["seconds"]) for _, st in runs for s in st)
    for name, steps in runs:
        index = args.index or min((s["report"].get("index", "-") for s in steps),
                                  key=lambda i: (not i.isdigit(), int(i) if i.isdigit() else 0))
        plot_node(name, steps, index, xmax,
                  os.path.join(args.outdir, f"threads_{name}.png"))
    plot_scatter(runs, os.path.join(args.outdir, "threads_scatter.png"))


if __name__ == "__main__":
    main()
