#!/usr/bin/env python3
"""Parse step-*.out files in a directory into a CSV.

Usage: parse_steps.py <directory> [-o output.csv] [--lscpu lscpu.txt]

Each step-*.out file is expected to contain a line like:
    job 1 | host dec2452 | core 229 | thread 0 of 1 | PBS_ARRAY_INDEX=0

If an lscpu.txt file (output of `lscpu`) is available, it is used to map
each hardware thread ("core" above, i.e. a Linux CPU id) to its physical
core, based on the "NUMA node<N> CPU(s):" lines and "Thread(s) per core:".
A "physical core" column is added to the CSV, and a warning is printed to
stderr for any host that reuses the same physical core across more than
one job (i.e. two jobs scheduled onto sibling hardware threads).
"""
import argparse
import csv
import glob
import os
import re
import sys
from collections import defaultdict

LINE_RE = re.compile(
    r"job\s+(?P<job>\d+)\s*\|\s*"
    r"host\s+(?P<host>\S+)\s*\|\s*"
    r"core\s+(?P<core>\d+)\s*\|\s*"
    r"thread\s+(?P<thread>\d+)\s+of\s+\d+\s*\|\s*"
    r"PBS_ARRAY_INDEX=(?P<array_index>\d+)"
)

THREADS_PER_CORE_RE = re.compile(r"Thread\(s\) per core:\s*(\d+)")
NUMA_NODE_RE = re.compile(r"NUMA node\d+ CPU\(s\):\s*(\S+)")


def expand_range(range_str):
    """Expand a single 'a-b' or 'a' token into a list of ints."""
    if "-" in range_str:
        lo, hi = range_str.split("-")
        return list(range(int(lo), int(hi) + 1))
    return [int(range_str)]


def parse_lscpu(path):
    """Build a mapping of CPU id -> physical core id from lscpu output.

    Each 'NUMA node<N> CPU(s):' line lists comma-separated ranges, one
    range per hardware thread slot (as many ranges as Thread(s) per
    core). Ranges are parallel: the CPU at position i in each range is
    a sibling hardware thread of the same physical core, identified
    here by the CPU id at position i of the first range.
    """
    threads_per_core = None
    node_lines = []
    with open(path) as f:
        for line in f:
            m = THREADS_PER_CORE_RE.search(line)
            if m:
                threads_per_core = int(m.group(1))
            m = NUMA_NODE_RE.search(line)
            if m:
                node_lines.append(m.group(1))

    if threads_per_core is None or not node_lines:
        raise ValueError(f"could not find NUMA/thread info in {path}")

    cpu_to_physical = {}
    for cpu_list in node_lines:
        ranges = [expand_range(tok) for tok in cpu_list.split(",")]
        if len(ranges) != threads_per_core:
            raise ValueError(
                f"expected {threads_per_core} CPU ranges (Thread(s) per core) "
                f"but found {len(ranges)} in '{cpu_list}'"
            )
        core_count = len(ranges[0])
        for pos in range(core_count):
            physical = ranges[0][pos]
            for r in ranges:
                cpu_to_physical[r[pos]] = physical
    return cpu_to_physical


def parse_file(path):
    with open(path) as f:
        for line in f:
            m = LINE_RE.search(line)
            if m:
                return m.groupdict()
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", help="Directory containing step-*.out files")
    parser.add_argument(
        "-o", "--output", default="steps.csv", help="Output CSV path (default: steps.csv)"
    )
    parser.add_argument(
        "--lscpu",
        default="lscpu.txt",
        help="Path to lscpu output used to map cores to physical cores (default: lscpu.txt)",
    )
    args = parser.parse_args()

    pattern = os.path.join(args.directory, "step-*.out")
    files = sorted(glob.glob(pattern))
    if not files:
        print(f"No files matching {pattern}", file=sys.stderr)
        sys.exit(1)

    cpu_to_physical = None
    if os.path.exists(args.lscpu):
        cpu_to_physical = parse_lscpu(args.lscpu)
    else:
        print(
            f"warning: {args.lscpu} not found, skipping physical core mapping",
            file=sys.stderr,
        )

    rows = []
    for path in files:
        parsed = parse_file(path)
        if parsed is None:
            print(f"warning: no match found in {path}", file=sys.stderr)
            continue
        if cpu_to_physical is not None:
            core = int(parsed["core"])
            if core not in cpu_to_physical:
                print(
                    f"warning: core {core} in {path} not found in {args.lscpu}",
                    file=sys.stderr,
                )
                parsed["physical_core"] = ""
            else:
                parsed["physical_core"] = cpu_to_physical[core]
        else:
            parsed["physical_core"] = ""
        rows.append(parsed)

    fieldnames = ["job", "host", "core", "thread", "array_index", "physical_core"]
    with open(args.output, "w", newline="") as out:
        writer = csv.DictWriter(out, fieldnames=fieldnames)
        writer.writerow(
            {
                "job": "job number",
                "host": "host name",
                "core": "core number",
                "thread": "thread",
                "array_index": "array index",
                "physical_core": "physical core",
            }
        )
        writer.writerows(rows)

    print(f"Wrote {len(rows)} rows to {args.output}")

    if cpu_to_physical is not None:
        seen = defaultdict(list)
        for row in rows:
            if row["physical_core"] == "":
                continue
            seen[(row["host"], row["physical_core"])].append(row["job"])
        conflicts = {k: v for k, v in seen.items() if len(v) > 1}
        if conflicts:
            print(
                f"warning: found {len(conflicts)} physical core(s) reused "
                f"on the same host:",
                file=sys.stderr,
            )
            for (host, physical_core), jobs in conflicts.items():
                print(
                    f"  host {host}, physical core {physical_core}: jobs {', '.join(jobs)}",
                    file=sys.stderr,
                )
        else:
            print("No repeated physical cores found on any host.")


if __name__ == "__main__":
    main()
