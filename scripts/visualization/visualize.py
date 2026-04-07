#!/usr/bin/env python3
"""Benchmark comparison chart generator for AWS Aurora vs OCI MySQL HeatWave.

Parses sysbench log files and monitoring CSVs to produce publication-quality
PNG charts comparing throughput, latency, error rates, and system metrics.
"""

import argparse
import csv
import glob
import os
import re
import sys
from collections import defaultdict

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np


RE_INTERVAL = re.compile(
    r"\[\s*(\d+)s\s*\].*thds:\s*(\d+)\s+tps:\s*([\d.]+)\s+qps:\s*([\d.]+)"
    r".*lat \(ms,95%\):\s*([\d.]+)\s+err/s:\s*([\d.]+)"
)

RE_TRANSACTIONS = re.compile(r"transactions:\s+(\d+)")
RE_QUERIES = re.compile(r"queries:\s+(\d+)")
RE_P95 = re.compile(r"95th percentile:\s+([\d.]+)")
RE_P99 = re.compile(r"99th percentile:\s+([\d.]+)")
RE_AVG_LAT = re.compile(r"avg:\s+([\d.]+)")
RE_ERRORS_TOTAL = re.compile(r"errors:\s+(\d+)")


class IntervalRow:
    """Single report-interval sample."""

    __slots__ = ("time_s", "threads", "tps", "qps", "lat95", "err_s")

    def __init__(self, time_s, threads, tps, qps, lat95, err_s):
        self.time_s = int(time_s)
        self.threads = int(threads)
        self.tps = float(tps)
        self.qps = float(qps)
        self.lat95 = float(lat95)
        self.err_s = float(err_s)


class SummaryStats:
    """Final summary extracted from a sysbench log."""

    __slots__ = ("transactions", "queries", "p95", "p99", "avg_lat", "errors")

    def __init__(self):
        self.transactions = 0
        self.queries = 0
        self.p95 = 0.0
        self.p99 = 0.0
        self.avg_lat = 0.0
        self.errors = 0


def parse_sysbench_log(path):
    """Return (list[IntervalRow], SummaryStats) from a sysbench log file."""
    intervals = []
    summary = SummaryStats()
    with open(path, "r") as fh:
        for line in fh:
            m = RE_INTERVAL.search(line)
            if m:
                intervals.append(IntervalRow(*m.groups()))
                continue
            m = RE_TRANSACTIONS.search(line)
            if m:
                summary.transactions = int(m.group(1))
            m = RE_QUERIES.search(line)
            if m:
                summary.queries = int(m.group(1))
            m = RE_P95.search(line)
            if m:
                summary.p95 = float(m.group(1))
            m = RE_P99.search(line)
            if m:
                summary.p99 = float(m.group(1))
            m = RE_AVG_LAT.search(line)
            if m:
                summary.avg_lat = float(m.group(1))
            m = RE_ERRORS_TOTAL.search(line)
            if m:
                summary.errors = int(m.group(1))
    return intervals, summary


def discover_oltp_logs(directory):
    """Find oltp_{threads}t_run{N}.log files.

    Returns dict: thread_count -> list[(run_number, filepath)]
    """
    pattern = re.compile(r"oltp_(\d+)t_run(\d+)\.log$")
    result = defaultdict(list)
    for fname in os.listdir(directory):
        m = pattern.match(fname)
        if m:
            threads = int(m.group(1))
            run_n = int(m.group(2))
            result[threads].append((run_n, os.path.join(directory, fname)))
    for v in result.values():
        v.sort()
    return dict(result)


def parse_monitoring_csv(path):
    """Parse monitor_*.csv into dict of column_name -> list[float]."""
    data = defaultdict(list)
    with open(path, "r") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            for key, val in row.items():
                try:
                    data[key].append(float(val))
                except (ValueError, TypeError):
                    data[key].append(val)
    return dict(data)


def find_monitoring_csv(directory):
    """Return first monitor_*.csv found in directory, or None."""
    candidates = sorted(glob.glob(os.path.join(directory, "monitor_*.csv")))
    return candidates[0] if candidates else None


def aggregate_runs(logs_by_thread):
    """From thread->[(run, path)] produce per-thread aggregated stats.

    Returns dict: thread_count -> {
        'tps_median', 'tps_min', 'tps_max',
        'p50_median', 'p95_median', 'p99_median',
        'p50_min', 'p50_max', 'p95_min', 'p95_max', 'p99_min', 'p99_max',
        'errors_total', 'transactions_total',
    }
    """
    agg = {}
    for threads, runs in sorted(logs_by_thread.items()):
        tps_vals = []
        p95_vals = []
        p99_vals = []
        p50_vals = []  # use avg_lat as proxy for p50
        err_vals = []
        for _run_n, fpath in runs:
            intervals_list, summary = parse_sysbench_log(fpath)
            if intervals_list:
                tps_vals.append(float(np.median([r.tps for r in intervals_list])))
            elif summary.transactions > 0:
                tps_vals.append(float(summary.transactions))
            else:
                continue
            p95_vals.append(summary.p95)
            p99_vals.append(summary.p99)
            p50_vals.append(summary.avg_lat)
            err_vals.append(summary.errors)

        tps_arr = np.array(tps_vals) if tps_vals else np.array([0.0])
        p95_arr = np.array(p95_vals) if p95_vals else np.array([0.0])
        p99_arr = np.array(p99_vals) if p99_vals else np.array([0.0])
        p50_arr = np.array(p50_vals) if p50_vals else np.array([0.0])

        agg[threads] = {
            "tps_median": float(np.median(tps_arr)),
            "tps_min": float(np.min(tps_arr)),
            "tps_max": float(np.max(tps_arr)),
            "p50_median": float(np.median(p50_arr)),
            "p50_min": float(np.min(p50_arr)),
            "p50_max": float(np.max(p50_arr)),
            "p95_median": float(np.median(p95_arr)),
            "p95_min": float(np.min(p95_arr)),
            "p95_max": float(np.max(p95_arr)),
            "p99_median": float(np.median(p99_arr)),
            "p99_min": float(np.min(p99_arr)),
            "p99_max": float(np.max(p99_arr)),
            "errors_total": int(np.sum(err_vals)),
            "error_rate_per_run": float(np.mean(err_vals)) if err_vals else 0.0,
        }
    return agg


AURORA_COLOR = "#d62728"
OCI_COLOR = "#1f77b4"
CHART_STYLE = {
    "figure.facecolor": "white",
    "axes.facecolor": "#f8f8f8",
    "axes.grid": True,
    "grid.alpha": 0.3,
    "font.size": 11,
}


def _apply_style():
    plt.rcParams.update(CHART_STYLE)


def chart_tps_vs_threads(aurora_agg, oci_agg, output_dir):
    """Chart 1: TPS vs Thread Count (log-scale X). THE key chart."""
    _apply_style()
    fig, ax = plt.subplots(figsize=(10, 6))

    for label, agg, color, marker in [
        ("Aurora", aurora_agg, AURORA_COLOR, "o"),
        ("OCI MySQL", oci_agg, OCI_COLOR, "s"),
    ]:
        if not agg:
            continue
        threads = sorted(agg.keys())
        medians = [agg[t]["tps_median"] for t in threads]
        lo = [agg[t]["tps_median"] - agg[t]["tps_min"] for t in threads]
        hi = [agg[t]["tps_max"] - agg[t]["tps_median"] for t in threads]
        ax.errorbar(
            threads,
            medians,
            yerr=[lo, hi],
            label=label,
            color=color,
            marker=marker,
            linewidth=2,
            capsize=4,
            markersize=7,
        )

    ax.set_xscale("log", base=2)
    ax.set_xlabel("Thread Count")
    ax.set_ylabel("Transactions per Second (TPS)")
    ax.set_title("TPS vs Thread Count — Aurora vs OCI MySQL HeatWave")
    ax.legend(loc="best")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(output_dir, "tps_vs_threads.png"), dpi=300)
    plt.close(fig)
    print("  -> tps_vs_threads.png")


def chart_latency_percentiles(aurora_agg, oci_agg, output_dir):
    """Chart 2: Latency percentiles (p50, p95, p99) vs thread count."""
    _apply_style()
    fig, axes = plt.subplots(1, 3, figsize=(16, 5), sharey=False)
    percentiles = [
        ("p50", "P50 (avg) Latency"),
        ("p95", "P95 Latency"),
        ("p99", "P99 Latency"),
    ]

    for ax, (pkey, ptitle) in zip(axes, percentiles):
        for label, agg, color, marker in [
            ("Aurora", aurora_agg, AURORA_COLOR, "o"),
            ("OCI MySQL", oci_agg, OCI_COLOR, "s"),
        ]:
            if not agg:
                continue
            threads = sorted(agg.keys())
            medians = [agg[t][f"{pkey}_median"] for t in threads]
            lo = [agg[t][f"{pkey}_median"] - agg[t][f"{pkey}_min"] for t in threads]
            hi = [agg[t][f"{pkey}_max"] - agg[t][f"{pkey}_median"] for t in threads]
            ax.errorbar(
                threads,
                medians,
                yerr=[lo, hi],
                label=label,
                color=color,
                marker=marker,
                linewidth=1.5,
                capsize=3,
                markersize=5,
            )
        ax.set_xscale("log", base=2)
        ax.set_xlabel("Thread Count")
        ax.set_ylabel("Latency (ms)")
        ax.set_title(ptitle)
        ax.legend(loc="best", fontsize=9)
        ax.grid(True, alpha=0.3)

    fig.suptitle("Latency Percentiles — Aurora vs OCI MySQL HeatWave", fontsize=13)
    fig.tight_layout()
    fig.savefig(os.path.join(output_dir, "latency_percentiles.png"), dpi=300)
    plt.close(fig)
    print("  -> latency_percentiles.png")


def chart_tps_timeseries_spike(aurora_dir, oci_dir, output_dir, spike_threads=4096):
    """Chart 3: TPS time series for high-thread run (default 4096 threads)."""
    _apply_style()
    fig, ax = plt.subplots(figsize=(12, 5))

    for label, directory, color in [
        ("Aurora", aurora_dir, AURORA_COLOR),
        ("OCI MySQL", oci_dir, OCI_COLOR),
    ]:
        candidates = [
            os.path.join(directory, f"oltp_{spike_threads}t_run1.log"),
            os.path.join(directory, f"oltp_{spike_threads}t_run2.log"),
            os.path.join(directory, f"oltp_{spike_threads}t_run3.log"),
        ]
        chosen = None
        for c in candidates:
            if os.path.isfile(c):
                chosen = c
                break
        if not chosen:
            continue
        intervals, _ = parse_sysbench_log(chosen)
        if not intervals:
            continue
        times = [r.time_s for r in intervals]
        tps = [r.tps for r in intervals]
        ax.plot(times, tps, label=label, color=color, linewidth=1.2, alpha=0.85)

    ax.set_xlabel("Elapsed Time (s)")
    ax.set_ylabel("TPS")
    ax.set_title(f"TPS Time Series at {spike_threads} Threads — Aurora vs OCI MySQL")
    ax.legend(loc="best")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(output_dir, "tps_timeseries_spike.png"), dpi=300)
    plt.close(fig)
    print("  -> tps_timeseries_spike.png")


def chart_error_rate(aurora_agg, oci_agg, output_dir):
    """Chart 4: Error count/rate vs thread count."""
    _apply_style()
    fig, ax = plt.subplots(figsize=(10, 6))

    for label, agg, color, marker in [
        ("Aurora", aurora_agg, AURORA_COLOR, "o"),
        ("OCI MySQL", oci_agg, OCI_COLOR, "s"),
    ]:
        if not agg:
            continue
        threads = sorted(agg.keys())
        errors = [agg[t]["error_rate_per_run"] for t in threads]
        ax.plot(
            threads,
            errors,
            label=label,
            color=color,
            marker=marker,
            linewidth=2,
            markersize=7,
        )

    ax.set_xscale("log", base=2)
    ax.set_xlabel("Thread Count")
    ax.set_ylabel("Errors (avg per run)")
    ax.set_title("Error Rate vs Thread Count — Aurora vs OCI MySQL HeatWave")
    ax.legend(loc="best")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(output_dir, "error_rate.png"), dpi=300)
    plt.close(fig)
    print("  -> error_rate.png")


def discover_ticketing_logs(directory):
    """Find ticketing_{threads}t.log files.

    Returns dict: thread_count -> filepath
    """
    pattern = re.compile(r"ticketing_(\d+)t\.log$")
    result = {}
    for fname in os.listdir(directory):
        m = pattern.match(fname)
        if m:
            threads = int(m.group(1))
            result[threads] = os.path.join(directory, fname)
    return result


def parse_ticketing_summary(logs_by_thread):
    """Extract TPS and p95 from ticketing logs.

    Returns dict: thread_count -> {'tps': float, 'p95': float, 'p99': float}
    """
    agg = {}
    for threads in sorted(logs_by_thread.keys()):
        fpath = logs_by_thread[threads]
        _, summary = parse_sysbench_log(fpath)
        intervals, _ = parse_sysbench_log(fpath)
        tps = float(np.median([r.tps for r in intervals])) if intervals else 0.0
        agg[threads] = {
            "tps": tps,
            "p95": summary.p95,
            "p99": summary.p99,
            "errors": summary.errors,
        }
    return agg


RE_HAMMERDB_NOPM = re.compile(
    r"System achieved\s+(\d+)\s+NOPM\s+from\s+(\d+)\s+MySQL TPM"
)


def parse_hammerdb_results(directory):
    """Parse HammerDB tpcc_{vu}vu.log files.

    Returns dict: vu_count -> {'nopm': int, 'tpm': int}
    """
    pattern = re.compile(r"tpcc_(\d+)vu\.log$")
    results = {}
    if not os.path.isdir(directory):
        return results
    for fname in os.listdir(directory):
        m = pattern.match(fname)
        if not m:
            continue
        vu = int(m.group(1))
        fpath = os.path.join(directory, fname)
        with open(fpath, "r") as fh:
            for line in fh:
                hm = RE_HAMMERDB_NOPM.search(line)
                if hm:
                    results[vu] = {
                        "nopm": int(hm.group(1)),
                        "tpm": int(hm.group(2)),
                    }
                    break
    return results


def chart_ticketing_tps(aurora_tick, oci_tick, output_dir):
    """Chart 5: Ticketing workload TPS vs thread count."""
    _apply_style()
    fig, ax = plt.subplots(figsize=(10, 6))

    for label, agg, color, marker in [
        ("Aurora", aurora_tick, AURORA_COLOR, "o"),
        ("OCI MySQL", oci_tick, OCI_COLOR, "s"),
    ]:
        if not agg:
            continue
        threads = sorted(agg.keys())
        tps = [agg[t]["tps"] for t in threads]
        ax.plot(
            threads,
            tps,
            label=label,
            color=color,
            marker=marker,
            linewidth=2,
            markersize=7,
        )

    ax.set_xscale("log", base=2)
    ax.set_xlabel("Thread Count")
    ax.set_ylabel("Transactions per Second (TPS)")
    ax.set_title("Ticketing Workload TPS — Aurora vs OCI MySQL MDS")
    ax.legend(loc="best")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(output_dir, "ticketing_tps.png"), dpi=300)
    plt.close(fig)
    print("  -> ticketing_tps.png")


def chart_ticketing_latency(aurora_tick, oci_tick, output_dir):
    """Chart 6: Ticketing workload P95 latency vs thread count."""
    _apply_style()
    fig, ax = plt.subplots(figsize=(10, 6))

    for label, agg, color, marker in [
        ("Aurora", aurora_tick, AURORA_COLOR, "o"),
        ("OCI MySQL", oci_tick, OCI_COLOR, "s"),
    ]:
        if not agg:
            continue
        threads = sorted(agg.keys())
        p95 = [agg[t]["p95"] for t in threads]
        ax.plot(
            threads,
            p95,
            label=label,
            color=color,
            marker=marker,
            linewidth=2,
            markersize=7,
        )

    ax.set_xscale("log", base=2)
    ax.set_yscale("log")
    ax.set_xlabel("Thread Count")
    ax.set_ylabel("P95 Latency (ms)")
    ax.set_title("Ticketing Workload P95 Latency — Aurora vs OCI MySQL MDS")
    ax.legend(loc="best")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(output_dir, "ticketing_latency.png"), dpi=300)
    plt.close(fig)
    print("  -> ticketing_latency.png")


def chart_hammerdb_nopm(aurora_hdb, oci_hdb, output_dir):
    """Chart 7: HammerDB TPC-C NOPM vs Virtual Users."""
    _apply_style()
    fig, ax = plt.subplots(figsize=(10, 6))

    for label, data, color, marker in [
        ("Aurora", aurora_hdb, AURORA_COLOR, "o"),
        ("OCI MySQL", oci_hdb, OCI_COLOR, "s"),
    ]:
        if not data:
            continue
        vus = sorted(data.keys())
        nopm = [data[v]["nopm"] for v in vus]
        ax.plot(
            vus,
            nopm,
            label=label,
            color=color,
            marker=marker,
            linewidth=2,
            markersize=7,
        )

    ax.set_xscale("log", base=2)
    ax.set_xlabel("Virtual Users (VU)")
    ax.set_ylabel("New Orders Per Minute (NOPM)")
    ax.set_title("HammerDB TPC-C NOPM — Aurora vs OCI MySQL MDS")
    ax.legend(loc="best")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(output_dir, "hammerdb_nopm.png"), dpi=300)
    plt.close(fig)
    print("  -> hammerdb_nopm.png")


def chart_combined_summary(
    aurora_agg, oci_agg, aurora_tick, oci_tick, aurora_hdb, oci_hdb, output_dir
):
    """Chart 8: Combined 2x2 summary dashboard."""
    _apply_style()
    fig, axes = plt.subplots(2, 2, figsize=(14, 10))

    # Panel 1: OLTP TPS
    ax = axes[0, 0]
    for label, agg, color, marker in [
        ("Aurora", aurora_agg, AURORA_COLOR, "o"),
        ("OCI MySQL", oci_agg, OCI_COLOR, "s"),
    ]:
        if not agg:
            continue
        threads = sorted(agg.keys())
        medians = [agg[t]["tps_median"] for t in threads]
        ax.plot(
            threads,
            medians,
            label=label,
            color=color,
            marker=marker,
            linewidth=2,
            markersize=6,
        )
    ax.set_xscale("log", base=2)
    ax.set_xlabel("Threads")
    ax.set_ylabel("TPS")
    ax.set_title("OLTP Read/Write TPS")
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)

    # Panel 2: OLTP P95 Latency
    ax = axes[0, 1]
    for label, agg, color, marker in [
        ("Aurora", aurora_agg, AURORA_COLOR, "o"),
        ("OCI MySQL", oci_agg, OCI_COLOR, "s"),
    ]:
        if not agg:
            continue
        threads = sorted(agg.keys())
        p95 = [agg[t]["p95_median"] for t in threads]
        ax.plot(
            threads,
            p95,
            label=label,
            color=color,
            marker=marker,
            linewidth=2,
            markersize=6,
        )
    ax.set_xscale("log", base=2)
    ax.set_yscale("log")
    ax.set_xlabel("Threads")
    ax.set_ylabel("P95 Latency (ms)")
    ax.set_title("OLTP P95 Latency")
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)

    # Panel 3: Ticketing TPS
    ax = axes[1, 0]
    for label, agg, color, marker in [
        ("Aurora", aurora_tick, AURORA_COLOR, "o"),
        ("OCI MySQL", oci_tick, OCI_COLOR, "s"),
    ]:
        if not agg:
            continue
        threads = sorted(agg.keys())
        tps = [agg[t]["tps"] for t in threads]
        ax.plot(
            threads,
            tps,
            label=label,
            color=color,
            marker=marker,
            linewidth=2,
            markersize=6,
        )
    ax.set_xscale("log", base=2)
    ax.set_xlabel("Threads")
    ax.set_ylabel("TPS")
    ax.set_title("Ticketing Workload TPS")
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)

    # Panel 4: HammerDB NOPM
    ax = axes[1, 1]
    for label, data, color, marker in [
        ("Aurora", aurora_hdb, AURORA_COLOR, "o"),
        ("OCI MySQL", oci_hdb, OCI_COLOR, "s"),
    ]:
        if not data:
            continue
        vus = sorted(data.keys())
        nopm = [data[v]["nopm"] for v in vus]
        ax.plot(
            vus,
            nopm,
            label=label,
            color=color,
            marker=marker,
            linewidth=2,
            markersize=6,
        )
    ax.set_xscale("log", base=2)
    ax.set_xlabel("Virtual Users")
    ax.set_ylabel("NOPM")
    ax.set_title("HammerDB TPC-C NOPM")
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)

    fig.suptitle(
        "Aurora MySQL vs OCI MySQL MDS — Benchmark Summary",
        fontsize=14,
        fontweight="bold",
    )
    fig.tight_layout()
    fig.savefig(os.path.join(output_dir, "summary_dashboard.png"), dpi=300)
    plt.close(fig)
    print("  -> summary_dashboard.png")


def main():
    parser = argparse.ArgumentParser(
        description="Generate benchmark comparison charts from sysbench logs "
        "and monitoring CSVs (Aurora vs OCI MySQL HeatWave).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
Expected input file naming:
  oltp_{threads}t_run{N}.log   — sysbench OLTP benchmark logs (N=1,2,3)
  pareto_4096t.log             — Pareto distribution test log
  ticketing_{threads}t.log     — ticketing workload logs
  monitor_*.csv                — monitoring CSV from monitor.py

Output charts (PNG, 300 dpi):
  tps_vs_threads.png           — TPS vs thread count (log scale, error bars)
  latency_percentiles.png      — P50/P95/P99 latency vs thread count
  tps_timeseries_spike.png     — TPS time series at 4096 threads
  error_rate.png               — Error rate vs thread count
  monitoring_overlay.png       — Threads_running & InnoDB row lock waits
""",
    )
    parser.add_argument(
        "--aurora-dir",
        required=True,
        help="Directory containing Aurora benchmark results",
    )
    parser.add_argument(
        "--oci-dir",
        required=True,
        help="Directory containing OCI MySQL benchmark results",
    )
    parser.add_argument(
        "--output-dir",
        required=True,
        help="Directory for output chart PNGs",
    )
    parser.add_argument(
        "--spike-threads",
        type=int,
        default=4096,
        help="Thread count for TPS time-series spike chart (default: 4096)",
    )
    parser.add_argument(
        "--aurora-hammerdb-dir",
        default=None,
        help="Directory containing Aurora HammerDB results",
    )
    parser.add_argument(
        "--oci-hammerdb-dir",
        default=None,
        help="Directory containing OCI HammerDB results",
    )
    args = parser.parse_args()

    for d, name in [(args.aurora_dir, "aurora-dir"), (args.oci_dir, "oci-dir")]:
        if not os.path.isdir(d):
            print(f"Error: {name} directory not found: {d}", file=sys.stderr)
            sys.exit(1)

    os.makedirs(args.output_dir, exist_ok=True)

    print("Discovering sysbench logs...")
    aurora_logs = discover_oltp_logs(args.aurora_dir)
    oci_logs = discover_oltp_logs(args.oci_dir)
    print(
        f"  Aurora: {sum(len(v) for v in aurora_logs.values())} log files "
        f"across {len(aurora_logs)} thread counts"
    )
    print(
        f"  OCI:    {sum(len(v) for v in oci_logs.values())} log files "
        f"across {len(oci_logs)} thread counts"
    )

    print("Aggregating run statistics...")
    aurora_agg = aggregate_runs(aurora_logs)
    oci_agg = aggregate_runs(oci_logs)

    aurora_tick_logs = discover_ticketing_logs(args.aurora_dir)
    oci_tick_logs = discover_ticketing_logs(args.oci_dir)
    aurora_tick = parse_ticketing_summary(aurora_tick_logs)
    oci_tick = parse_ticketing_summary(oci_tick_logs)
    print(f"  Ticketing: Aurora {len(aurora_tick)} / OCI {len(oci_tick)} thread counts")

    aurora_hdb = {}
    oci_hdb = {}
    if args.aurora_hammerdb_dir:
        aurora_hdb = parse_hammerdb_results(args.aurora_hammerdb_dir)
        print(f"  HammerDB Aurora: {len(aurora_hdb)} VU counts")
    if args.oci_hammerdb_dir:
        oci_hdb = parse_hammerdb_results(args.oci_hammerdb_dir)
        print(f"  HammerDB OCI: {len(oci_hdb)} VU counts")

    print("Generating charts...")
    chart_tps_vs_threads(aurora_agg, oci_agg, args.output_dir)
    chart_latency_percentiles(aurora_agg, oci_agg, args.output_dir)
    chart_tps_timeseries_spike(
        args.aurora_dir,
        args.oci_dir,
        args.output_dir,
        spike_threads=args.spike_threads,
    )
    chart_error_rate(aurora_agg, oci_agg, args.output_dir)
    chart_ticketing_tps(aurora_tick, oci_tick, args.output_dir)
    chart_ticketing_latency(aurora_tick, oci_tick, args.output_dir)

    if aurora_hdb or oci_hdb:
        chart_hammerdb_nopm(aurora_hdb, oci_hdb, args.output_dir)

    chart_combined_summary(
        aurora_agg,
        oci_agg,
        aurora_tick,
        oci_tick,
        aurora_hdb,
        oci_hdb,
        args.output_dir,
    )

    print(f"\nAll charts saved to: {args.output_dir}")


if __name__ == "__main__":
    main()
