#!/usr/bin/env python3
"""MySQL metrics collector for benchmark monitoring via SHOW GLOBAL STATUS."""

import argparse
import csv
import os
import signal
import sys
import time
from datetime import datetime, timezone

import mysql.connector

GAUGE_METRICS = [
    "Threads_running",
    "Threads_connected",
    "Innodb_row_lock_current_waits",
]

COUNTER_METRICS = [
    "Questions",
    "Queries",
    "Com_select",
    "Com_insert",
    "Com_update",
    "Com_commit",
    "Com_rollback",
    "Innodb_row_lock_waits",
    "Innodb_row_lock_time",
    "Innodb_buffer_pool_reads",
    "Innodb_buffer_pool_read_requests",
    "Slow_queries",
    "Aborted_connects",
    "Aborted_clients",
]

ALL_METRICS = GAUGE_METRICS + COUNTER_METRICS


def parse_args():
    parser = argparse.ArgumentParser(
        description="Collect MySQL metrics during benchmarks via SHOW GLOBAL STATUS."
    )
    parser.add_argument("--host", required=True, help="MySQL host")
    parser.add_argument(
        "--port", type=int, default=3306, help="MySQL port (default: 3306)"
    )
    parser.add_argument("--user", default="admin", help="MySQL user (default: admin)")
    parser.add_argument("--password", required=True, help="MySQL password")
    parser.add_argument(
        "--interval",
        type=float,
        default=1,
        help="Seconds between collections (default: 1)",
    )
    parser.add_argument(
        "--duration",
        type=int,
        default=600,
        help="Total seconds to monitor (default: 600)",
    )
    parser.add_argument("--output", required=True, help="CSV output file path")
    parser.add_argument(
        "--thread-pool",
        action="store_true",
        help="Enable thread pool metric collection (OCI)",
    )
    parser.add_argument(
        "--daemon",
        action="store_true",
        help="Run in background, write PID to {output}.pid",
    )
    return parser.parse_args()


def connect(args):
    return mysql.connector.connect(
        host=args.host,
        port=args.port,
        user=args.user,
        password=args.password,
        connection_timeout=10,
    )


def fetch_status(cursor):
    cursor.execute("SHOW GLOBAL STATUS")
    return {row[0]: row[1] for row in cursor.fetchall()}


def fetch_threadpool_status(cursor):
    cursor.execute("SHOW GLOBAL STATUS LIKE 'Threadpool%'")
    return {row[0]: row[1] for row in cursor.fetchall()}


def daemonize(output_path):
    pid = os.fork()
    if pid > 0:
        sys.exit(0)

    os.setsid()

    pid = os.fork()
    if pid > 0:
        sys.exit(0)

    log_path = f"{output_path}.log"
    log_fd = open(log_path, "a")
    os.dup2(log_fd.fileno(), sys.stdout.fileno())
    os.dup2(log_fd.fileno(), sys.stderr.fileno())

    pid_path = f"{output_path}.pid"
    with open(pid_path, "w") as f:
        f.write(str(os.getpid()))


class MetricsCollector:
    def __init__(self, args):
        self.args = args
        self.running = True
        self.conn = None
        self.csv_file = None
        self.writer = None
        self.prev_counters = None
        self.tp_keys = []

    def shutdown(self, signum=None, frame=None):
        self.running = False

    def run(self):
        signal.signal(signal.SIGTERM, self.shutdown)
        signal.signal(signal.SIGINT, self.shutdown)

        self.conn = connect(self.args)
        cursor = self.conn.cursor()

        if self.args.thread_pool:
            tp_status = fetch_threadpool_status(cursor)
            self.tp_keys = sorted(tp_status.keys())

        delta_cols = [f"{m}_delta" for m in COUNTER_METRICS]
        tp_cols = self.tp_keys if self.args.thread_pool else []
        header = ["timestamp"] + ALL_METRICS + delta_cols + tp_cols

        output_dir = os.path.dirname(self.args.output)
        if output_dir:
            os.makedirs(output_dir, exist_ok=True)
        self.csv_file = open(self.args.output, "w", newline="")
        self.writer = csv.writer(self.csv_file)
        self.writer.writerow(header)

        start_time = time.monotonic()
        try:
            while self.running and (time.monotonic() - start_time) < self.args.duration:
                self._collect(cursor)
                deadline = time.monotonic() + self.args.interval
                while self.running and time.monotonic() < deadline:
                    time.sleep(min(0.1, deadline - time.monotonic()))
        finally:
            self._cleanup()

    def _collect(self, cursor):
        try:
            status = fetch_status(cursor)
        except mysql.connector.Error:
            try:
                self.conn = connect(self.args)
                cursor = self.conn.cursor()
                status = fetch_status(cursor)
            except mysql.connector.Error as e:
                print(f"[monitor] reconnect failed: {e}", file=sys.stderr)
                return

        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        raw = {m: int(status.get(m, 0)) for m in ALL_METRICS}

        current_counters = {m: raw[m] for m in COUNTER_METRICS}
        deltas = {}
        if self.prev_counters is not None:
            for m in COUNTER_METRICS:
                deltas[m] = current_counters[m] - self.prev_counters[m]
        else:
            for m in COUNTER_METRICS:
                deltas[m] = 0
        self.prev_counters = current_counters

        tp_values = []
        if self.args.thread_pool:
            try:
                tp_status = fetch_threadpool_status(cursor)
                tp_values = [tp_status.get(k, "0") for k in self.tp_keys]
            except mysql.connector.Error:
                tp_values = ["0"] * len(self.tp_keys)

        row = [ts]
        row += [raw[m] for m in ALL_METRICS]
        row += [deltas[m] for m in COUNTER_METRICS]
        row += tp_values
        self.writer.writerow(row)
        self.csv_file.flush()

    def _cleanup(self):
        if self.csv_file:
            self.csv_file.flush()
            self.csv_file.close()
        if self.conn:
            try:
                self.conn.close()
            except Exception:
                pass
        if self.args.daemon:
            pid_path = f"{self.args.output}.pid"
            try:
                os.remove(pid_path)
            except OSError:
                pass


def main():
    args = parse_args()

    if args.daemon:
        daemonize(args.output)

    collector = MetricsCollector(args)
    collector.run()


if __name__ == "__main__":
    main()
