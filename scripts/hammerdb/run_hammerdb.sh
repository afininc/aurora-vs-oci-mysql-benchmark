#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
PORT=3306
USER="admin"
VU_LIST="8,16,32,64,128,256,512"
OUTPUT_DIR=""
SKIP_BUILD=false
HOST=""
PASSWORD=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run HammerDB TPC-C benchmark across multiple virtual user counts.

Required:
  --host HOST          Database hostname or IP
  --password PASS      Database password

Optional:
  --port PORT          Database port (default: 3306)
  --user USER          Database user (default: admin)
  --vu-list LIST       Comma-separated VU counts (default: 8,16,32,64,128,256,512)
  --output-dir DIR     Directory for log output (default: ./hammerdb_results_TIMESTAMP)
  --skip-build         Skip schema build step
  --help               Show this help message
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)       HOST="$2"; shift 2 ;;
        --port)       PORT="$2"; shift 2 ;;
        --user)       USER="$2"; shift 2 ;;
        --password)   PASSWORD="$2"; shift 2 ;;
        --vu-list)    VU_LIST="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        --help)       usage ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage
            ;;
    esac
done

if [[ -z "$HOST" ]]; then
    echo "ERROR: --host is required" >&2
    exit 1
fi

if [[ -z "$PASSWORD" ]]; then
    echo "ERROR: --password is required" >&2
    exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="./hammerdb_results_$(date +%Y%m%d_%H%M%S)"
fi

mkdir -p "$OUTPUT_DIR"

export DB_HOST="$HOST"
export DB_PORT="$PORT"
export DB_USER="$USER"
export DB_PASSWORD="$PASSWORD"

echo "============================================"
echo "HammerDB TPC-C Benchmark"
echo "============================================"
echo "Host:       $DB_HOST:$DB_PORT"
echo "User:       $DB_USER"
echo "VU list:    $VU_LIST"
echo "Output dir: $OUTPUT_DIR"
echo "Skip build: $SKIP_BUILD"
echo "============================================"

# --- Schema Build ---
if [[ "$SKIP_BUILD" == "false" ]]; then
    echo ""
    echo ">>> Building TPC-C schema (100 warehouses, 16 build VUs)..."
    hammerdbcli auto "$SCRIPT_DIR/tpcc_build.tcl" 2>&1 | tee "$OUTPUT_DIR/tpcc_build.log"
    echo ">>> Schema build complete."
    echo ""
else
    echo ""
    echo ">>> Skipping schema build (--skip-build)."
    echo ""
fi

# --- Benchmark Runs ---
IFS=',' read -ra VU_ARRAY <<< "$VU_LIST"
TOTAL_RUNS=${#VU_ARRAY[@]}
RUN_NUM=0

for VU in "${VU_ARRAY[@]}"; do
    RUN_NUM=$((RUN_NUM + 1))
    export VU_COUNT="$VU"

    echo ">>> [$RUN_NUM/$TOTAL_RUNS] Running TPC-C with $VU VUs..."
    hammerdbcli auto "$SCRIPT_DIR/tpcc_run.tcl" 2>&1 | tee "$OUTPUT_DIR/tpcc_${VU}vu.log"
    echo ">>> Run complete: $VU VUs"

    if [[ $RUN_NUM -lt $TOTAL_RUNS ]]; then
        echo ">>> Sleeping 60s before next run..."
        sleep 60
    fi
done

# --- Summary ---
echo ""
echo "============================================"
echo "All TPC-C runs complete."
echo "============================================"
echo "Results saved to: $OUTPUT_DIR"
echo ""
echo "Log files:"
for VU in "${VU_ARRAY[@]}"; do
    echo "  $OUTPUT_DIR/tpcc_${VU}vu.log"
done
echo "============================================"
