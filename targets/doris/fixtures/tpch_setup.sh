#!/usr/bin/env bash
set -euo pipefail

# TPC-H Data Generation & Loading Script for Apache Doris
# Downloads dbgen, generates TPC-H data at a configurable scale factor,
# creates the schema, and loads data via Doris STREAM LOAD API.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
SCALE_FACTOR=1
HOST="doris-doris-fe.crucible-benchmarks.svc.cluster.local"
QUERY_PORT=9030
HTTP_PORT=8030
USER="root"
PASSWORD=""
DATABASE="tpch"
WORK_DIR="/tmp/tpch-data"
SKIP_GENERATE=false
SKIP_LOAD=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Generate TPC-H data and load it into Apache Doris.

Options:
  --scale-factor SF   TPC-H scale factor (default: 1). Common values: 1, 10, 100
  --host HOST         Doris FE host (default: doris-doris-fe.crucible-benchmarks.svc.cluster.local)
  --query-port PORT   Doris FE MySQL query port (default: 9030)
  --http-port PORT    Doris FE HTTP port for STREAM LOAD (default: 8030)
  --user USER         Doris username (default: root)
  --password PASS     Doris password (default: empty)
  --database DB       Target database name (default: tpch)
  --work-dir DIR      Directory for generated data (default: /tmp/tpch-data)
  --skip-generate     Skip data generation (use existing files in work-dir)
  --skip-load         Skip data loading (only generate data)
  -h, --help          Show this help message
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scale-factor) SCALE_FACTOR="$2"; shift 2 ;;
        --host)         HOST="$2"; shift 2 ;;
        --query-port)   QUERY_PORT="$2"; shift 2 ;;
        --http-port)    HTTP_PORT="$2"; shift 2 ;;
        --user)         USER="$2"; shift 2 ;;
        --password)     PASSWORD="$2"; shift 2 ;;
        --database)     DATABASE="$2"; shift 2 ;;
        --work-dir)     WORK_DIR="$2"; shift 2 ;;
        --skip-generate) SKIP_GENERATE=true; shift ;;
        --skip-load)    SKIP_LOAD=true; shift ;;
        -h|--help)      usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

MYSQL_CMD="mysql --protocol=tcp -h ${HOST} -P ${QUERY_PORT} -u ${USER}"
if [[ -n "$PASSWORD" ]]; then
    MYSQL_CMD="${MYSQL_CMD} -p${PASSWORD}"
fi

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --- Step 1: Download and compile dbgen ---
build_dbgen() {
    local dbgen_dir="${WORK_DIR}/tpch-dbgen"
    if [[ -x "${dbgen_dir}/dbgen" ]]; then
        log "dbgen already built at ${dbgen_dir}/dbgen, skipping"
        return
    fi

    log "Downloading tpch-dbgen..."
    mkdir -p "${WORK_DIR}"
    if [[ -d "${dbgen_dir}" ]]; then
        rm -rf "${dbgen_dir}"
    fi
    git clone --depth 1 https://github.com/electrum/tpch-dbgen.git "${dbgen_dir}"

    log "Compiling dbgen..."
    cd "${dbgen_dir}"
    make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)"
    cd - > /dev/null

    log "dbgen built successfully"
}

# --- Step 2: Generate TPC-H data ---
generate_data() {
    local dbgen_dir="${WORK_DIR}/tpch-dbgen"
    local data_dir="${WORK_DIR}/sf${SCALE_FACTOR}"

    if [[ -d "${data_dir}" ]] && ls "${data_dir}"/*.tbl &>/dev/null; then
        log "Data already exists at ${data_dir}, skipping generation"
        return
    fi

    log "Generating TPC-H data at SF${SCALE_FACTOR}..."
    mkdir -p "${data_dir}"
    cd "${dbgen_dir}"
    ./dbgen -s "${SCALE_FACTOR}" -f
    mv ./*.tbl "${data_dir}/"
    cd - > /dev/null

    # Remove trailing pipe delimiter that dbgen adds
    log "Cleaning generated data (removing trailing delimiters)..."
    for f in "${data_dir}"/*.tbl; do
        sed -i.bak 's/|$//' "$f" && rm -f "${f}.bak"
    done

    log "Data generated at ${data_dir}"
}

# --- Step 3: Create schema ---
create_schema() {
    log "Creating database and schema..."
    ${MYSQL_CMD} < "${SCRIPT_DIR}/tpch_ddl.sql"
    log "Schema created"
}

# --- Step 4: Load data via STREAM LOAD ---
stream_load_table() {
    local table="$1"
    local file="$2"
    local file_size
    file_size=$(wc -c < "$file" | tr -d ' ')

    log "Loading ${table} ($(numfmt --to=iec "${file_size}" 2>/dev/null || echo "${file_size} bytes"))..."

    local auth
    local auth="${USER}:${PASSWORD}"

    local response
    response=$(curl -s -w "\n%{http_code}" \
        --location-trusted \
        -u "${auth}" \
        -H "Expect: 100-continue" \
        -H "column_separator:|" \
        -H "label:tpch_${table}_$(date +%s)" \
        -T "$file" \
        "http://${HOST}:${HTTP_PORT}/api/${DATABASE}/${table}/_stream_load")

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        log "ERROR: Failed to load ${table} (HTTP ${http_code})"
        echo "$body"
        return 1
    fi

    local status
    status=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Status',''))" 2>/dev/null || echo "")
    if [[ "$status" == "Success" || "$status" == "Publish Timeout" ]]; then
        local rows
        rows=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('NumberLoadedRows',0))" 2>/dev/null || echo "?")
        log "  ${table}: ${rows} rows loaded"
    else
        log "ERROR: STREAM LOAD failed for ${table}"
        echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body"
        return 1
    fi
}

load_data() {
    local data_dir="${WORK_DIR}/sf${SCALE_FACTOR}"
    local tables=(region nation part supplier partsupp customer orders lineitem)

    log "Loading data into Doris (${HOST}:${HTTP_PORT})..."
    for table in "${tables[@]}"; do
        local file="${data_dir}/${table}.tbl"
        if [[ ! -f "$file" ]]; then
            log "ERROR: Missing data file: ${file}"
            return 1
        fi
        stream_load_table "$table" "$file"
    done
    log "All tables loaded successfully"
}

# --- Main ---
main() {
    log "TPC-H Setup for Doris — SF${SCALE_FACTOR}"
    log "Target: ${HOST}:${QUERY_PORT} (HTTP: ${HTTP_PORT})"

    if [[ "$SKIP_GENERATE" == "false" ]]; then
        build_dbgen
        generate_data
    else
        log "Skipping data generation (--skip-generate)"
    fi

    if [[ "$SKIP_LOAD" == "false" ]]; then
        create_schema
        load_data
    else
        log "Skipping data loading (--skip-load)"
    fi

    log "Done!"
}

main
