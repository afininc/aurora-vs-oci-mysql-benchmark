#!/usr/bin/env bash
set -euo pipefail
ulimit -s unlimited
ulimit -n 65535 2>/dev/null || true

# ---------------------------------------------------------------------------
# run_spike_benchmark.sh — Multi-phase sysbench benchmark with staged thread
# escalation, warmup, Pareto distribution, and custom Lua ticketing tests.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
HOST=""
PORT=3306
USER="admin"
PASSWORD=""
DB="benchmark"
THREADS_LIST="32,64,128,256,512,1024,2048,4096"
DURATION=60
REPORT_INTERVAL=5
RUNS=3
WARMUP=60
OUTPUT_DIR=""
TABLES=10
TABLE_SIZE=10000000

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

Multi-phase sysbench benchmark with staged thread escalation.

Required:
  --host HOST           MySQL host
  --password PASS       MySQL password
  --output-dir DIR      Directory for result logs

Optional:
  --port PORT           MySQL port              (default: 3306)
  --user USER           MySQL user              (default: admin)
  --db DB               Database name           (default: benchmark)
  --threads-list LIST   Comma-separated threads (default: 32,64,128,256,512,1024,2048,4096)
  --duration SECS       Seconds per measurement  (default: 60)
  --report-interval SEC Report interval seconds  (default: 5)
  --runs N              Repetitions per thread   (default: 3)
  --warmup SECS         Warmup seconds (discarded) (default: 60)
  --tables N            Number of tables         (default: 10)
  --table-size N        Rows per table           (default: 10000000)
  --help                Show this help message

Phases:
  1. Prepare   — sysbench oltp_read_write prepare
  2. OLTP Spike — warmup + measurement for each thread count × runs
  3. Pareto    — oltp_read_write with pareto distribution at 4096 threads
  4. Ticketing — custom Lua workload for each thread count
  5. Cleanup   — sysbench oltp_read_write cleanup
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)        HOST="$2";            shift 2 ;;
        --port)        PORT="$2";            shift 2 ;;
        --user)        USER="$2";            shift 2 ;;
        --password)    PASSWORD="$2";        shift 2 ;;
        --db)          DB="$2";              shift 2 ;;
        --threads-list) THREADS_LIST="$2";   shift 2 ;;
        --duration)    DURATION="$2";        shift 2 ;;
        --report-interval) REPORT_INTERVAL="$2"; shift 2 ;;
        --runs)        RUNS="$2";            shift 2 ;;
        --warmup)      WARMUP="$2";          shift 2 ;;
        --output-dir)  OUTPUT_DIR="$2";      shift 2 ;;
        --tables)      TABLES="$2";          shift 2 ;;
        --table-size)  TABLE_SIZE="$2";      shift 2 ;;
        --help)        usage ;;
        *)             die "Unknown option: $1. Use --help for usage." ;;
    esac
done

# Validate required args
[[ -z "$HOST" ]]       && die "--host is required"
[[ -z "$PASSWORD" ]]   && die "--password is required"
[[ -z "$OUTPUT_DIR" ]] && die "--output-dir is required"

mkdir -p "$OUTPUT_DIR"

# Split threads list into array
IFS=',' read -ra THREADS_ARRAY <<< "$THREADS_LIST"

# Common sysbench connection flags
COMMON_ARGS=(
    --mysql-host="$HOST"
    --mysql-port="$PORT"
    --mysql-user="$USER"
    --mysql-password="$PASSWORD"
    --mysql-db="$DB"
    --tables="$TABLES"
    --table-size="$TABLE_SIZE"
    --db-ps-mode=disable
)

START_TIME="$(date +%s)"
FILE_COUNT=0

# ---------------------------------------------------------------------------
# Phase 1 — Prepare
# ---------------------------------------------------------------------------
log "===== Phase 1: Prepare ====="
log "Creating $TABLES tables with $TABLE_SIZE rows each"
sysbench oltp_read_write "${COMMON_ARGS[@]}" prepare
log "Phase 1 complete"

# ---------------------------------------------------------------------------
# Phase 2 — Standard OLTP spike (warmup + measurement per thread count)
# ---------------------------------------------------------------------------
log "===== Phase 2: OLTP Spike ====="
for threads in "${THREADS_ARRAY[@]}"; do
    for run in $(seq 1 "$RUNS"); do
        log "--- threads=$threads  run=$run/$RUNS ---"

        # Warmup (discarded)
        log "Warmup: ${WARMUP}s with $threads threads"
        sysbench oltp_read_write "${COMMON_ARGS[@]}" \
            --threads="$threads" \
            --time="$WARMUP" \
            --report-interval="$REPORT_INTERVAL" \
            run > /dev/null

        # Measurement
        OUTFILE="${OUTPUT_DIR}/oltp_${threads}t_run${run}.log"
        log "Measurement: ${DURATION}s → $OUTFILE"
        sysbench oltp_read_write "${COMMON_ARGS[@]}" \
            --threads="$threads" \
            --time="$DURATION" \
            --report-interval="$REPORT_INTERVAL" \
            run > "$OUTFILE"
        FILE_COUNT=$((FILE_COUNT + 1))

        # Stabilization pause
        log "Sleeping 30s for server stabilization"
        sleep 30
    done
done
log "Phase 2 complete"

# ---------------------------------------------------------------------------
# Phase 3 — Pareto distribution test
# ---------------------------------------------------------------------------
log "===== Phase 3: Pareto Distribution ====="
PARETO_FILE="${OUTPUT_DIR}/pareto_4096t.log"
log "Running pareto test: 4096 threads, 120s → $PARETO_FILE"
sysbench oltp_read_write "${COMMON_ARGS[@]}" \
    --rand-type=pareto \
    --rand-pareto-h=0.1 \
    --threads=4096 \
    --time=120 \
    --report-interval=5 \
    run > "$PARETO_FILE"
FILE_COUNT=$((FILE_COUNT + 1))
log "Phase 3 complete"

# ---------------------------------------------------------------------------
# Phase 4 — Custom Lua ticketing workload
# ---------------------------------------------------------------------------
log "===== Phase 4: Ticketing Workload ====="
TICKETING_LUA="${SCRIPT_DIR}/ticketing_workload.lua"
if [[ ! -f "$TICKETING_LUA" ]]; then
    die "Ticketing Lua script not found: $TICKETING_LUA"
fi

for threads in "${THREADS_ARRAY[@]}"; do
    TICKET_FILE="${OUTPUT_DIR}/ticketing_${threads}t.log"
    log "Ticketing: threads=$threads → $TICKET_FILE"
    sysbench "$TICKETING_LUA" \
        --mysql-host="$HOST" \
        --mysql-port="$PORT" \
        --mysql-user="$USER" \
        --mysql-password="$PASSWORD" \
        --mysql-db="$DB" \
        --threads="$threads" \
        --time=60 \
        --report-interval=5 \
        run > "$TICKET_FILE"
    FILE_COUNT=$((FILE_COUNT + 1))
done
log "Phase 4 complete"

# ---------------------------------------------------------------------------
# Phase 5 — Cleanup
# ---------------------------------------------------------------------------
log "===== Phase 5: Cleanup ====="
sysbench oltp_read_write "${COMMON_ARGS[@]}" cleanup
log "Phase 5 complete"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
END_TIME="$(date +%s)"
ELAPSED=$((END_TIME - START_TIME))
HOURS=$((ELAPSED / 3600))
MINUTES=$(( (ELAPSED % 3600) / 60 ))
SECS=$((ELAPSED % 60))

log "===== Benchmark Complete ====="
log "Total duration: ${HOURS}h ${MINUTES}m ${SECS}s"
log "Test files generated: $FILE_COUNT"
log "Output directory: $OUTPUT_DIR"
