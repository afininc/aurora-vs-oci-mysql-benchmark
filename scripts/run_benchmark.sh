#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# run_benchmark.sh — Master orchestration for Aurora vs OCI MySQL benchmarks.
# Sequences: env check → monitoring → sysbench → hammerdb → cleanup.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
TARGET=""
HOST=""
PORT=3306
USER="admin"
PASSWORD=""
DB="benchmark"
OUTPUT_DIR=""
SKIP_PREPARE=false
SKIP_HAMMERDB=false
SKIP_CLEANUP=false
THREAD_POOL=false
MONITOR_PID=""
RESULTS_DIR=""
START_TIME=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Master orchestration script for Aurora vs OCI MySQL benchmarks.

Required:
  --target TARGET       Benchmark target: "aurora" or "oci"
  --host HOST           MySQL host address
  --password PASS       MySQL password
  --output-dir DIR      Base directory for results

Optional:
  --port PORT           MySQL port (default: 3306)
  --user USER           MySQL user (default: admin)
  --db DB               Database name (default: benchmark)
  --skip-prepare        Skip sysbench prepare (data already loaded)
  --skip-hammerdb       Skip HammerDB TPC-C benchmark
  --skip-cleanup        Skip sysbench cleanup at end
  --thread-pool         Enable thread pool monitoring (OCI only)
  --help                Show this help message

Execution sequence:
  1. Environment check (sysbench, mysql, python3, hammerdbcli)
  2. Create timestamped results directory
  3. Start background monitoring (monitor.py)
  4. Sysbench prepare (unless --skip-prepare)
  5. Sysbench spike benchmark
  6. HammerDB TPC-C (unless --skip-hammerdb)
  7. Stop monitoring
  8. Sysbench cleanup (unless --skip-cleanup)
  9. Print summary
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    if [[ -n "$MONITOR_PID" ]] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        log "Stopping monitoring process (PID $MONITOR_PID)..."
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
    fi
    if [[ $exit_code -ne 0 && -n "$RESULTS_DIR" ]]; then
        log "Benchmark aborted. Partial results in: $RESULTS_DIR"
    fi
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)        TARGET="$2";      shift 2 ;;
        --host)          HOST="$2";        shift 2 ;;
        --port)          PORT="$2";        shift 2 ;;
        --user)          USER="$2";        shift 2 ;;
        --password)      PASSWORD="$2";    shift 2 ;;
        --db)            DB="$2";          shift 2 ;;
        --output-dir)    OUTPUT_DIR="$2";  shift 2 ;;
        --skip-prepare)  SKIP_PREPARE=true; shift ;;
        --skip-hammerdb) SKIP_HAMMERDB=true; shift ;;
        --skip-cleanup)  SKIP_CLEANUP=true; shift ;;
        --thread-pool)   THREAD_POOL=true; shift ;;
        --help)          usage ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate required arguments
# ---------------------------------------------------------------------------
[[ -z "$TARGET" ]]     && die "--target is required (aurora or oci)"
[[ -z "$HOST" ]]       && die "--host is required"
[[ -z "$PASSWORD" ]]   && die "--password is required"
[[ -z "$OUTPUT_DIR" ]] && die "--output-dir is required"

if [[ "$TARGET" != "aurora" && "$TARGET" != "oci" ]]; then
    die "--target must be 'aurora' or 'oci', got: $TARGET"
fi

if [[ "$THREAD_POOL" == true && "$TARGET" != "oci" ]]; then
    die "--thread-pool is only supported with --target oci"
fi

# ---------------------------------------------------------------------------
# Step 1: Environment check
# ---------------------------------------------------------------------------
log "=== Step 1: Environment check ==="

for cmd in sysbench mysql python3; do
    if ! command -v "$cmd" &>/dev/null; then
        die "Required command not found: $cmd"
    fi
    log "  Found: $cmd ($(command -v "$cmd"))"
done

if [[ "$SKIP_HAMMERDB" == false ]]; then
    if ! command -v hammerdbcli &>/dev/null; then
        die "Required command not found: hammerdbcli (use --skip-hammerdb to skip)"
    fi
    log "  Found: hammerdbcli ($(command -v hammerdbcli))"
fi

# ---------------------------------------------------------------------------
# Step 2: Create results directory
# ---------------------------------------------------------------------------
log "=== Step 2: Create results directory ==="

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
RESULTS_DIR="${OUTPUT_DIR}/${TARGET}_${TIMESTAMP}"
mkdir -p "$RESULTS_DIR"
log "Results directory: $RESULTS_DIR"

START_TIME="$(date +%s)"

# ---------------------------------------------------------------------------
# Step 3: Start monitoring
# ---------------------------------------------------------------------------
log "=== Step 3: Start background monitoring ==="

MONITOR_CSV="${RESULTS_DIR}/monitor.csv"
MONITOR_CMD=(
    python3 "${SCRIPT_DIR}/monitoring/monitor.py"
    --host "$HOST"
    --port "$PORT"
    --user "$USER"
    --password "$PASSWORD"
    --output "$MONITOR_CSV"
    --daemon
)

if [[ "$THREAD_POOL" == true ]]; then
    MONITOR_CMD+=(--thread-pool)
fi

"${MONITOR_CMD[@]}"

MONITOR_PID_FILE="${MONITOR_CSV}.pid"
if [[ -f "$MONITOR_PID_FILE" ]]; then
    MONITOR_PID="$(cat "$MONITOR_PID_FILE")"
    log "Monitoring started (PID $MONITOR_PID)"
else
    die "Monitor PID file not found: $MONITOR_PID_FILE"
fi

# ---------------------------------------------------------------------------
# Step 4: Sysbench prepare (unless --skip-prepare)
# ---------------------------------------------------------------------------
if [[ "$SKIP_PREPARE" == true ]]; then
    log "=== Step 4: Sysbench prepare — SKIPPED ==="
else
    log "=== Step 4: Sysbench prepare ==="
    sysbench oltp_read_write \
        --mysql-host="$HOST" \
        --mysql-port="$PORT" \
        --mysql-user="$USER" \
        --mysql-password="$PASSWORD" \
        --mysql-db="$DB" \
        --tables=10 \
        --table-size=10000000 \
        prepare
    log "Sysbench prepare complete"
fi

# ---------------------------------------------------------------------------
# Step 5: Sysbench spike benchmark
# ---------------------------------------------------------------------------
log "=== Step 5: Sysbench spike benchmark ==="

SYSBENCH_DIR="${RESULTS_DIR}/sysbench"
mkdir -p "$SYSBENCH_DIR"

bash "${SCRIPT_DIR}/sysbench/run_spike_benchmark.sh" \
    --host "$HOST" \
    --port "$PORT" \
    --user "$USER" \
    --password "$PASSWORD" \
    --db "$DB" \
    --output-dir "$SYSBENCH_DIR"

log "Sysbench spike benchmark complete"

# ---------------------------------------------------------------------------
# Step 6: HammerDB TPC-C (unless --skip-hammerdb)
# ---------------------------------------------------------------------------
if [[ "$SKIP_HAMMERDB" == true ]]; then
    log "=== Step 6: HammerDB TPC-C — SKIPPED ==="
else
    log "=== Step 6: HammerDB TPC-C ==="

    HAMMERDB_DIR="${RESULTS_DIR}/hammerdb"
    mkdir -p "$HAMMERDB_DIR"

    bash "${SCRIPT_DIR}/hammerdb/run_hammerdb.sh" \
        --host "$HOST" \
        --port "$PORT" \
        --user "$USER" \
        --password "$PASSWORD" \
        --output-dir "$HAMMERDB_DIR"

    log "HammerDB TPC-C complete"
fi

# ---------------------------------------------------------------------------
# Step 7: Stop monitoring
# ---------------------------------------------------------------------------
log "=== Step 7: Stop monitoring ==="

if [[ -n "$MONITOR_PID" ]] && kill -0 "$MONITOR_PID" 2>/dev/null; then
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
    log "Monitoring stopped (PID $MONITOR_PID)"
else
    log "Monitoring process already stopped"
fi
MONITOR_PID=""

# ---------------------------------------------------------------------------
# Step 8: Sysbench cleanup (unless --skip-cleanup)
# ---------------------------------------------------------------------------
if [[ "$SKIP_CLEANUP" == true ]]; then
    log "=== Step 8: Sysbench cleanup — SKIPPED ==="
else
    log "=== Step 8: Sysbench cleanup ==="
    sysbench oltp_read_write \
        --mysql-host="$HOST" \
        --mysql-port="$PORT" \
        --mysql-user="$USER" \
        --mysql-password="$PASSWORD" \
        --mysql-db="$DB" \
        --tables=10 \
        cleanup
    log "Sysbench cleanup complete"
fi

# ---------------------------------------------------------------------------
# Step 9: Summary
# ---------------------------------------------------------------------------
log "=== Step 9: Summary ==="

END_TIME="$(date +%s)"
ELAPSED=$(( END_TIME - START_TIME ))
ELAPSED_MIN=$(( ELAPSED / 60 ))
ELAPSED_SEC=$(( ELAPSED % 60 ))
FILE_COUNT="$(find "$RESULTS_DIR" -type f | wc -l | tr -d ' ')"

log "Target:           $TARGET"
log "Results directory: $RESULTS_DIR"
log "Total duration:   ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
log "Files generated:  $FILE_COUNT"
log "=== Benchmark complete ==="
