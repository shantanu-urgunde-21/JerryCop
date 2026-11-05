#!/usr/bin/env bash
#
# JerryCop WSL2 / Linux Benchmark Suite
# Compares JerryCop against Go stdlib ReverseProxy, Caddy v2, and NGINX.
#
# Usage:
#   chmod +x bench/run_bench.sh
#   ./bench/run_bench.sh
#

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_FILE="$SCRIPT_DIR/results_linux.txt"
DURATION="${1:-10s}"
RUNS="${2:-3}"

# Output redirection helper
exec > >(tee -a "$RESULTS_FILE") 2>&1
echo "========================================================"
echo " JerryCop Linux / WSL2 Benchmark Suite"
echo " Date: $(date)"
echo " CPU Cores: $(nproc)"
echo " Test 1 Duration: $DURATION | Runs: $RUNS"
echo "========================================================"

# Try to bump file limits
ulimit -n 65535 2>/dev/null || true

# Check prerequisites
command -v go >/dev/null 2>&1 || { echo "ERROR: 'go' is not installed or not in PATH." >&2; exit 1; }

if ! command -v hey >/dev/null 2>&1; then
    if [ -f "$HOME/go/bin/hey" ]; then
        export PATH="$HOME/go/bin:$PATH"
    else
        echo "Installing 'hey'..."
        go install github.com/rakyll/hey@latest
        export PATH="$HOME/go/bin:$PATH"
    fi
fi

HAS_CADDY=false
if command -v caddy >/dev/null 2>&1; then
    HAS_CADDY=true
fi

HAS_NGINX=false
if command -v nginx >/dev/null 2>&1; then
    HAS_NGINX=true
else
    echo "NOTE: 'nginx' not found. To include NGINX in the benchmark, run:"
    echo "      sudo apt update && sudo apt install -y nginx"
fi

# Cleanup helper
cleanup() {
    echo "Cleaning up background processes..."
    killall -q backend baseline jerrycop caddy nginx 2>/dev/null || true
    pkill -f "jerrycop" 2>/dev/null || true
    pkill -f "baseline" 2>/dev/null || true
    pkill -f "backend" 2>/dev/null || true
    pkill -9 -f "nginx" 2>/dev/null || true
    rm -f /tmp/nginx_*.pid /tmp/nginx_*.conf 2>/dev/null || true
    sleep 0.5
}
trap cleanup EXIT
cleanup

# Stop NGINX gracefully and wait for port 9092 to be completely free
stop_nginx() {
    local pidfile="$1"
    if [ -n "$pidfile" ] && [ -f "$pidfile" ]; then
        local pid=$(cat "$pidfile" 2>/dev/null || true)
        if [ -n "$pid" ]; then
            kill -QUIT "$pid" 2>/dev/null || true
            local retries=20
            while kill -0 "$pid" 2>/dev/null && [ "$retries" -gt 0 ]; do
                sleep 0.1
                retries=$((retries - 1))
            done
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$pidfile" 2>/dev/null || true
    fi
    pkill -9 -f "nginx" 2>/dev/null || true
    local retries=30
    while nc -z 127.0.0.1 9092 2>/dev/null && [ "$retries" -gt 0 ]; do
        sleep 0.1
        retries=$((retries - 1))
    done
    sleep 0.2
}

# Wait for a TCP port to start listening
wait_port() {
    local port=$1
    local retries=50
    while ! nc -z 127.0.0.1 "$port" 2>/dev/null; do
        sleep 0.1
        retries=$((retries - 1))
        if [ "$retries" -le 0 ]; then
            echo "ERROR: Port $port did not open within 5s" >&2
            return 1
        fi
    done
}

# Parse hey output: extract reported rps, 200 responses, total duration, errors, p50, p99
# Returns: "success_rps reported_rps errors error_pct p50 p99"
parse_hey() {
    local out="$1"
    local total_sec
    local rep_rps
    local s200
    local p50
    local p99
    local errs=0

    local re_total="Total:[[:space:]]+([0-9.]+)[[:space:]]+secs"
    local re_rps="Requests/sec:[[:space:]]+([0-9.]+)"
    local re_200='\[200\][[:space:]]+([0-9]+)[[:space:]]+responses'
    local re_p50='50%+[[:space:]]+in[[:space:]]+([0-9.]+)'
    local re_p99='99%+[[:space:]]+in[[:space:]]+([0-9.]+)'

    if [[ "$out" =~ $re_total ]]; then
        total_sec="${BASH_REMATCH[1]}"
    fi
    if [[ "$out" =~ $re_rps ]]; then
        rep_rps="${BASH_REMATCH[1]}"
    fi
    if [[ "$out" =~ $re_200 ]]; then
        s200="${BASH_REMATCH[1]}"
    fi
    if [[ "$out" =~ $re_p50 ]]; then
        p50=$(awk -v v="${BASH_REMATCH[1]}" 'BEGIN { printf "%.2f", v * 1000 }')
    fi
    if [[ "$out" =~ $re_p99 ]]; then
        p99=$(awk -v v="${BASH_REMATCH[1]}" 'BEGIN { printf "%.2f", v * 1000 }')
    fi

    # Sum any error counts in Error distribution block
    local in_err=false
    while IFS= read -r line; do
        if [[ "$line" =~ "Error distribution:" ]]; then
            in_err=true
            continue
        fi
        if [ "$in_err" = true ]; then
            if [[ "$line" =~ \[([0-9]+)\] ]]; then
                local cnt="${BASH_REMATCH[1]}"
                errs=$((errs + cnt))
            elif [ -z "$line" ]; then
                in_err=false
            fi
        fi
    done <<< "$out"

    [ -z "$s200" ] && s200=0
    [ -z "$total_sec" ] && total_sec=1
    [ -z "$rep_rps" ] && rep_rps=0
    [ -z "$p50" ] && p50=0
    [ -z "$p99" ] && p99=0

    local succ_rps
    succ_rps=$(awk -v s="$s200" -v t="$total_sec" 'BEGIN { if (t>0) printf "%.1f", s/t; else print 0 }')

    local total_reqs=$((s200 + errs))
    local err_pct=0.0
    if [ "$total_reqs" -gt 0 ]; then
        err_pct=$(awk -v e="$errs" -v tot="$total_reqs" 'BEGIN { printf "%.1f", (e/tot)*100 }')
    fi

    echo "$succ_rps $rep_rps $errs $err_pct $p50 $p99"
}

# Run multi-pass benchmark and compute the true median
# Usage: run_bench "Label" "http://url" "opts..." "warmup_opts"
run_bench() {
    local label="$1"
    local url="$2"
    local opts="$3"
    local warmup_opts="$4"

    echo ""
    echo "--------------------------------------------------------"
    echo " $label"
    echo " Target: $url"
    echo "--------------------------------------------------------"

    if [ -n "$warmup_opts" ]; then
        echo " [Warmup] Sending warm-up traffic ($warmup_opts)..."
        hey $warmup_opts "$url" >/dev/null 2>&1 || true
        sleep 0.5
    fi

    local lines=()
    for ((i=1; i<=RUNS; i++)); do
        echo " [Run $i/$RUNS] hey $opts $url"
        local raw
        raw=$(hey $opts "$url" 2>&1)
        local parsed
        parsed=$(parse_hey "$raw")
        read -r s_rps r_rps errs err_pct p50 p99 <<< "$parsed"
        printf "   Run %d: Reported: %8.1f req/s | Successful: %8.1f req/s | Errors: %5d (%4.1f%%) | P50: %6.1fms | P99: %6.1fms\n" \
            "$i" "$r_rps" "$s_rps" "$errs" "$err_pct" "$p50" "$p99"
        lines+=("$s_rps $r_rps $errs $err_pct $p50 $p99")
        sleep 0.3
    done

    # Sort lines numerically by successful rps
    IFS=$'\n' sorted=($(sort -k1,1n <<<"${lines[*]}"))
    unset IFS

    local mid=$(( ${#sorted[@]} / 2 ))
    local med="${sorted[$mid]}"
    read -r m_srps m_rrps m_errs m_errpct m_p50 m_p99 <<< "$med"

    echo ""
    echo " >>> MEDIAN for $label:"
    printf "     Successful: %8.1f req/s | Reported: %8.1f req/s | Errors: %5d (%4.1f%%) | P50: %6.1fms | P99: %6.1fms\n" \
        "$m_srps" "$m_rrps" "$m_errs" "$m_errpct" "$m_p50" "$m_p99"

    MEDIAN_RESULT="$med"
}

# --- Compile binaries ---
echo ""
echo "--- Compiling Go binaries for Linux ---"
cd "$REPO_ROOT"
go build -o "$REPO_ROOT/jerrycop" ./cmd/main.go
go build -o "$REPO_ROOT/bench/backends/backend" ./bench/backends/
go build -o "$REPO_ROOT/bench/baseline/baseline" ./bench/baseline/
echo "Build complete."

T1_OPTS="-z $DURATION -c 200 -t 10"
WARMUP_OPTS="-z 3s -c 100 -t 10"

# ========================================================
# TEST 1: Throughput -- stdlib vs NGINX vs Caddy vs JerryCop
# ========================================================
echo ""
echo "========================================================"
echo " TEST 1: Throughput -- stdlib vs NGINX vs Caddy vs JerryCop"
echo "         Single fast backend (0ms latency), c=200, -z $DURATION"
echo "         Includes warm-up pass; reports median of $RUNS runs"
echo "========================================================"

# Start backend on 8001
"$REPO_ROOT/bench/backends/backend" --port=8001 --latency=0 >/dev/null 2>&1 &
B1_PID=$!
wait_port 8001

# 1.1 Go stdlib ReverseProxy (port 9090)
"$REPO_ROOT/bench/baseline/baseline" --listen=127.0.0.1:9090 --upstream=http://127.0.0.1:8001 >/dev/null 2>&1 &
STDLIB_PID=$!
wait_port 9090
run_bench "Go stdlib ReverseProxy -> 8001" "http://127.0.0.1:9090/" "$T1_OPTS" "$WARMUP_OPTS"
STDLIB_MED="$MEDIAN_RESULT"
disown $STDLIB_PID 2>/dev/null; kill -9 $STDLIB_PID 2>/dev/null || true
sleep 0.5

# 1.2 NGINX (port 9092)
NGINX_MED="0 0 0 0 0 0"
if [ "$HAS_NGINX" = true ]; then
    cat << 'EOF' > /tmp/nginx_jerrycop.conf
events {
    worker_connections 10240;
    use epoll;
    multi_accept on;
}
http {
    access_log off;
    error_log /dev/null crit;
    keepalive_timeout 65;
    keepalive_requests 100000;
    upstream backend {
        server 127.0.0.1:8001;
        keepalive 256;
    }
    server {
        listen 127.0.0.1:9092;
        location / {
            proxy_pass http://backend;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
        }
    }
}
EOF
    nginx -c /tmp/nginx_jerrycop.conf -g "pid /tmp/nginx_jerrycop.pid;"
    wait_port 9092
    run_bench "NGINX (epoll) -> 8001" "http://127.0.0.1:9092/" "$T1_OPTS" "$WARMUP_OPTS"
    NGINX_MED="$MEDIAN_RESULT"
    stop_nginx "/tmp/nginx_jerrycop.pid"
    rm -f /tmp/nginx_jerrycop.conf 2>/dev/null || true
fi

# 1.3 Caddy v2 (port 9091)
CADDY_MED="0 0 0 0 0 0"
if [ "$HAS_CADDY" = true ]; then
    caddy reverse-proxy --from http://127.0.0.1:9091 --to 127.0.0.1:8001 &
    CADDY_PID=$!
    wait_port 9091
    run_bench "Caddy v2 -> 8001" "http://127.0.0.1:9091/" "$T1_OPTS" "$WARMUP_OPTS"
    CADDY_MED="$MEDIAN_RESULT"
    disown $CADDY_PID 2>/dev/null; kill -9 $CADDY_PID 2>/dev/null || true
    sleep 0.5
fi

# 1.4 JerryCop (port 8080)
cp "$SCRIPT_DIR/configs/single_fast.yaml" "$REPO_ROOT/config/config.yaml"
"$REPO_ROOT/jerrycop" >/dev/null 2>&1 &
JERRY_PID=$!
wait_port 8080
run_bench "JerryCop (Single Backend) -> 8001" "http://127.0.0.1:8080/" "$T1_OPTS" "$WARMUP_OPTS"
JERRY_MED="$MEDIAN_RESULT"
disown $JERRY_PID 2>/dev/null; kill -9 $JERRY_PID 2>/dev/null || true

# Stop backend 8001
disown $B1_PID 2>/dev/null; kill -9 $B1_PID 2>/dev/null || true
sleep 0.5

echo ""
echo "--- TEST 1 HEAD-TO-HEAD SUMMARY (Median of $RUNS Runs) ---"
read -r s_srps s_rrps s_errs s_pct s_p50 s_p99 <<< "$STDLIB_MED"
printf "  stdlib ReverseProxy: %8.1f Successful req/s | P50: %5.1fms | P99: %6.1fms | Errors: %4.1f%%\n" "$s_srps" "$s_p50" "$s_p99" "$s_pct"

if [ "$HAS_NGINX" = true ]; then
    read -r n_srps n_rrps n_errs n_pct n_p50 n_p99 <<< "$NGINX_MED"
    printf "  NGINX (epoll):       %8.1f Successful req/s | P50: %5.1fms | P99: %6.1fms | Errors: %4.1f%%\n" "$n_srps" "$n_p50" "$n_p99" "$n_pct"
fi

if [ "$HAS_CADDY" = true ]; then
    read -r c_srps c_rrps c_errs c_pct c_p50 c_p99 <<< "$CADDY_MED"
    printf "  Caddy v2:            %8.1f Successful req/s | P50: %5.1fms | P99: %6.1fms | Errors: %4.1f%%\n" "$c_srps" "$c_p50" "$c_p99" "$c_pct"
fi

read -r j_srps j_rrps j_errs j_pct j_p50 j_p99 <<< "$JERRY_MED"
printf "  JerryCop:            %8.1f Successful req/s | P50: %5.1fms | P99: %6.1fms | Errors: %4.1f%%\n" "$j_srps" "$j_p50" "$j_p99" "$j_pct"

# ========================================================
# TEST 2: Multi-Backend Latency Skew (4 Backends: 3 Fast @ 0ms, 1 Outlier @ 200ms)
# ========================================================
echo ""
echo "========================================================"
echo " TEST 2: Multi-Backend Latency Skew (4 Upstreams)"
echo "         Backends: 3 Fast (0ms) on 8001, 8002, 8003"
echo "                   1 Slow (200ms) on 8004"
echo "         Clients: c=100 concurrent for $DURATION"
echo "         Comparing JerryCop vs. NGINX on RR and Least-Conn"
echo "========================================================"

start_4_backends() {
    "$REPO_ROOT/bench/backends/backend" --port=8001 --latency=0 >/dev/null 2>&1 &
    B1_PID=$!
    "$REPO_ROOT/bench/backends/backend" --port=8002 --latency=0 >/dev/null 2>&1 &
    B2_PID=$!
    "$REPO_ROOT/bench/backends/backend" --port=8003 --latency=0 >/dev/null 2>&1 &
    B3_PID=$!
    "$REPO_ROOT/bench/backends/backend" --port=8004 --latency=200ms >/dev/null 2>&1 &
    B4_PID=$!
    wait_port 8001
    wait_port 8002
    wait_port 8003
    wait_port 8004
}

stop_4_backends() {
    disown $B1_PID $B2_PID $B3_PID $B4_PID 2>/dev/null || true
    kill -9 $B1_PID $B2_PID $B3_PID $B4_PID 2>/dev/null || true
    sleep 0.5
}

get_4_stats() {
    local s1=$(curl -s http://127.0.0.1:8001/stats | grep -o '"total_requests":[0-9]*' | cut -d: -f2)
    local s2=$(curl -s http://127.0.0.1:8002/stats | grep -o '"total_requests":[0-9]*' | cut -d: -f2)
    local s3=$(curl -s http://127.0.0.1:8003/stats | grep -o '"total_requests":[0-9]*' | cut -d: -f2)
    local s4=$(curl -s http://127.0.0.1:8004/stats | grep -o '"total_requests":[0-9]*' | cut -d: -f2)
    [ -z "$s1" ] && s1=0
    [ -z "$s2" ] && s2=0
    [ -z "$s3" ] && s3=0
    [ -z "$s4" ] && s4=0
    local fast_tot=$((s1 + s2 + s3))
    local total=$((fast_tot + s4))
    local fast_pct=0.0
    local slow_pct=0.0
    if [ "$total" -gt 0 ]; then
        fast_pct=$(awk -v f="$fast_tot" -v t="$total" 'BEGIN { printf "%.1f", (f/t)*100 }')
        slow_pct=$(awk -v s="$s4" -v t="$total" 'BEGIN { printf "%.1f", (s/t)*100 }')
    fi
    echo "$fast_pct $slow_pct $s1 $s2 $s3 $s4"
}

# --- 2.1 JerryCop ROUND_ROBIN ---
echo ""
echo "--- Testing JerryCop ROUND_ROBIN (4 backends) ---"
start_4_backends
cp "$SCRIPT_DIR/configs/rr_multi.yaml" "$REPO_ROOT/config/config.yaml"
"$REPO_ROOT/jerrycop" >/dev/null 2>&1 &
JERRY_RR_PID=$!
wait_port 8080

raw_j_rr=$(hey -z "$DURATION" -c 100 -t 10 http://127.0.0.1:8080/ 2>&1)
read -r j_rr_srps j_rr_rrps j_rr_errs j_rr_pct j_rr_p50 j_rr_p99 <<< "$(parse_hey "$raw_j_rr")"
read -r j_rr_fpct j_rr_spct j_rr_s1 j_rr_s2 j_rr_s3 j_rr_s4 <<< "$(get_4_stats)"
disown $JERRY_RR_PID 2>/dev/null; kill -9 $JERRY_RR_PID 2>/dev/null || true
stop_4_backends

# --- 2.2 JerryCop LEAST_CONNECTION ---
echo "--- Testing JerryCop LEAST_CONNECTION (4 backends) ---"
start_4_backends
cp "$SCRIPT_DIR/configs/least_conn_multi.yaml" "$REPO_ROOT/config/config.yaml"
"$REPO_ROOT/jerrycop" >/dev/null 2>&1 &
JERRY_LC_PID=$!
wait_port 8080

raw_j_lc=$(hey -z "$DURATION" -c 100 -t 10 http://127.0.0.1:8080/ 2>&1)
read -r j_lc_srps j_lc_rrps j_lc_errs j_lc_pct j_lc_p50 j_lc_p99 <<< "$(parse_hey "$raw_j_lc")"
read -r j_lc_fpct j_lc_spct j_lc_s1 j_lc_s2 j_lc_s3 j_lc_s4 <<< "$(get_4_stats)"
disown $JERRY_LC_PID 2>/dev/null; kill -9 $JERRY_LC_PID 2>/dev/null || true
stop_4_backends

# --- 2.3 NGINX ROUND_ROBIN ---
n_rr_srps="0"; n_rr_p50="0"; n_rr_p99="0"; n_rr_fpct="0"; n_rr_spct="0"
if [ "$HAS_NGINX" = true ]; then
    echo "--- Testing NGINX ROUND_ROBIN (4 backends) ---"
    stop_nginx "/tmp/nginx_rr.pid"
    start_4_backends
    cat << 'EOF' > /tmp/nginx_rr.conf
events { worker_connections 10240; use epoll; multi_accept on; }
http {
    access_log off; error_log /dev/null crit; keepalive_timeout 65; keepalive_requests 100000;
    upstream backend_rr {
        server 127.0.0.1:8001; server 127.0.0.1:8002; server 127.0.0.1:8003; server 127.0.0.1:8004;
        keepalive 256;
    }
    server {
        listen 127.0.0.1:9092;
        location / { proxy_pass http://backend_rr; proxy_http_version 1.1; proxy_set_header Connection ""; }
    }
}
EOF
    nginx -c /tmp/nginx_rr.conf -g "pid /tmp/nginx_rr.pid;"
    wait_port 9092
    raw_n_rr=$(hey -z "$DURATION" -c 100 -t 10 http://127.0.0.1:9092/ 2>&1)
    read -r n_rr_srps n_rr_rrps n_rr_errs n_rr_pct n_rr_p50 n_rr_p99 <<< "$(parse_hey "$raw_n_rr")"
    read -r n_rr_fpct n_rr_spct n_rr_s1 n_rr_s2 n_rr_s3 n_rr_s4 <<< "$(get_4_stats)"
    stop_nginx "/tmp/nginx_rr.pid"
    rm -f /tmp/nginx_rr.conf 2>/dev/null || true
    stop_4_backends
fi

# --- 2.4 NGINX LEAST_CONN ---
n_lc_srps="0"; n_lc_p50="0"; n_lc_p99="0"; n_lc_fpct="0"; n_lc_spct="0"
if [ "$HAS_NGINX" = true ]; then
    echo "--- Testing NGINX LEAST_CONN (4 backends) ---"
    stop_nginx "/tmp/nginx_lc.pid"
    start_4_backends
    cat << 'EOF' > /tmp/nginx_lc.conf
events { worker_connections 10240; use epoll; multi_accept on; }
http {
    access_log off; error_log /dev/null crit; keepalive_timeout 65; keepalive_requests 100000;
    upstream backend_lc {
        least_conn;
        server 127.0.0.1:8001; server 127.0.0.1:8002; server 127.0.0.1:8003; server 127.0.0.1:8004;
        keepalive 256;
    }
    server {
        listen 127.0.0.1:9092;
        location / { proxy_pass http://backend_lc; proxy_http_version 1.1; proxy_set_header Connection ""; }
    }
}
EOF
    nginx -c /tmp/nginx_lc.conf -g "pid /tmp/nginx_lc.pid;"
    wait_port 9092
    raw_n_lc=$(hey -z "$DURATION" -c 100 -t 10 http://127.0.0.1:9092/ 2>&1)
    read -r n_lc_srps n_lc_rrps n_lc_errs n_lc_pct n_lc_p50 n_lc_p99 <<< "$(parse_hey "$raw_n_lc")"
    read -r n_lc_fpct n_lc_spct n_lc_s1 n_lc_s2 n_lc_s3 n_lc_s4 <<< "$(get_4_stats)"
    stop_nginx "/tmp/nginx_lc.pid"
    rm -f /tmp/nginx_lc.conf 2>/dev/null || true
    stop_4_backends
fi

echo ""
echo "--- TEST 2 SUMMARY: 4-BACKEND LATENCY SKEW (3 Fast @ 0ms, 1 Outlier @ 200ms) ---"
printf "  JerryCop ROUND_ROBIN:       %8.1f req/s | P50: %6.1fms | P99: %6.1fms | Traffic Split: %s%% fast / %s%% slow
"     "$j_rr_srps" "$j_rr_p50" "$j_rr_p99" "$j_rr_fpct" "$j_rr_spct"
if [ "$HAS_NGINX" = true ]; then
    printf "  NGINX ROUND_ROBIN:          %8.1f req/s | P50: %6.1fms | P99: %6.1fms | Traffic Split: %s%% fast / %s%% slow
"         "$n_rr_srps" "$n_rr_p50" "$n_rr_p99" "$n_rr_fpct" "$n_rr_spct"
fi
printf "  JerryCop LEAST_CONNECTION:  %8.1f req/s | P50: %6.1fms | P99: %6.1fms | Traffic Split: %s%% fast / %s%% slow
"     "$j_lc_srps" "$j_lc_p50" "$j_lc_p99" "$j_lc_fpct" "$j_lc_spct"
if [ "$HAS_NGINX" = true ]; then
    printf "  NGINX LEAST_CONN:           %8.1f req/s | P50: %6.1fms | P99: %6.1fms | Traffic Split: %s%% fast / %s%% slow
"         "$n_lc_srps" "$n_lc_p50" "$n_lc_p99" "$n_lc_fpct" "$n_lc_spct"
fi

# ========================================================
# TEST 3: Overload / Limiter Verification
# ========================================================
echo ""
echo "========================================================"
echo " TEST 3: Overload / Concurrency Limiter Verification"
echo "         Backend: 100ms latency, Clients: c=300 concurrent"
echo "         Expectation: MaxConcReq=100 limits backend in-flight"
echo "         concurrency to <= 100 and caps throughput near 1,000 req/s"
echo "========================================================"

# 3.1 Limited (MaxConcReq=100)
"$REPO_ROOT/bench/backends/backend" --port=8001 --latency=100ms >/dev/null 2>&1 &
B3_PID=$!
wait_port 8001

cp "$SCRIPT_DIR/configs/overload.yaml" "$REPO_ROOT/config/config.yaml"
"$REPO_ROOT/jerrycop" >/dev/null 2>&1 &
JERRY_OVER_PID=$!
wait_port 8080

raw_over=$(hey -n 2000 -c 300 -t 15 http://127.0.0.1:8080/ 2>&1)
read -r over_srps over_rrps over_errs over_pct over_p50 over_p99 <<< "$(parse_hey "$raw_over")"
over_peak=$(curl -s http://127.0.0.1:8001/stats | grep -o '"peak_inflight":[0-9]*' | cut -d: -f2)
disown $JERRY_OVER_PID $B3_PID 2>/dev/null; kill -9 $JERRY_OVER_PID $B3_PID 2>/dev/null || true
sleep 1

# 3.2 Unconstrained (MaxConcReq=20000)
"$REPO_ROOT/bench/backends/backend" --port=8001 --latency=100ms >/dev/null 2>&1 &
B3_PID=$!
wait_port 8001

cp "$SCRIPT_DIR/configs/single_fast.yaml" "$REPO_ROOT/config/config.yaml"
"$REPO_ROOT/jerrycop" >/dev/null 2>&1 &
JERRY_UNLIM_PID=$!
wait_port 8080

raw_unlim=$(hey -n 2000 -c 300 -t 15 http://127.0.0.1:8080/ 2>&1)
read -r unlim_srps unlim_rrps unlim_errs unlim_pct unlim_p50 unlim_p99 <<< "$(parse_hey "$raw_unlim")"
unlim_peak=$(curl -s http://127.0.0.1:8001/stats | grep -o '"peak_inflight":[0-9]*' | cut -d: -f2)
disown $JERRY_UNLIM_PID $B3_PID 2>/dev/null; kill -9 $JERRY_UNLIM_PID $B3_PID 2>/dev/null || true
sleep 1

echo ""
echo "--- TEST 3 SUMMARY (Limiter Verification on 100ms Backend) ---"
printf "  MaxConcReq=100:   Throughput: %6.1f req/s | Backend Peak In-Flight: %4d | Errors: %d\n" \
    "$over_srps" "$over_peak" "$over_errs"
printf "  Unconstrained:    Throughput: %6.1f req/s | Backend Peak In-Flight: %4d | Errors: %d\n" \
    "$unlim_srps" "$unlim_peak" "$unlim_errs"

# ========================================================
# TEST 4: Concurrency Scaling Sweep
# ========================================================
echo ""
echo "========================================================"
echo " TEST 4: Concurrency Scaling Sweep (Successful req/s)"
echo "         Single fast backend (0ms), JerryCop Single Backend"
echo "         50,000 requests per tier"
echo "========================================================"

"$REPO_ROOT/bench/backends/backend" --port=8001 --latency=0 >/dev/null 2>&1 &
B4_PID=$!
wait_port 8001

cp "$SCRIPT_DIR/configs/single_fast.yaml" "$REPO_ROOT/config/config.yaml"
"$REPO_ROOT/jerrycop" >/dev/null 2>&1 &
JERRY_SWEEP_PID=$!
wait_port 8080

echo ""
echo "  | Concurrency | Reported/s | Successful/s | Errors | Error % |   P50   |   P99   |"
echo "  |-------------|------------|--------------|--------|---------|---------|---------|"

for conc in 50 100 200 500 1000 2000; do
    raw_sw=$(hey -n 50000 -c "$conc" -t 15 http://127.0.0.1:8080/ 2>&1)
    read -r sw_srps sw_rrps sw_errs sw_pct sw_p50 sw_p99 <<< "$(parse_hey "$raw_sw")"
    printf "  | %11d | %8.1f/s | %10.1f/s | %6d | %6.1f%% | %5.1fms | %5.1fms |\n" \
        "$conc" "$sw_rrps" "$sw_srps" "$sw_errs" "$sw_pct" "$sw_p50" "$sw_p99"
    sleep 0.5
done

disown $JERRY_SWEEP_PID $B4_PID 2>/dev/null; kill -9 $JERRY_SWEEP_PID $B4_PID 2>/dev/null || true

echo ""
echo "========================================================"
echo " All Linux / WSL2 tests complete! Results saved to bench/results_linux.txt"
echo "========================================================"

