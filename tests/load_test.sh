#!/bin/bash
#===============================================================================
#
#   FaaS Load Test Script
#
#   Description : 동시성 및 부하 테스트를 위한 스크립트
#                 - Concurrent Request Testing
#                 - Throughput Measurement
#                 - Latency Percentile Analysis
#
#===============================================================================

set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Configuration
FAAS_BASE_URL="${FAAS_BASE_URL:-http://localhost:8000}"
CONCURRENT_USERS="${CONCURRENT_USERS:-10}"
TOTAL_REQUESTS="${TOTAL_REQUESTS:-100}"
TEST_PATH="${TEST_PATH:-}"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

log_info() {
    echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $1"
}

print_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] <endpoint_path>

FaaS Load Test Script

Options:
  -h, --help              Show this help message
  -u, --url URL           Base URL (default: http://localhost:8000)
  -c, --concurrent N      Concurrent users (default: 10)
  -n, --requests N        Total requests (default: 100)
  -m, --method METHOD     HTTP method (default: POST)
  -d, --data DATA         Request body JSON

Examples:
  $(basename "$0") docker_test                    # Test deployed function
  $(basename "$0") -c 20 -n 200 docker_test      # 20 concurrent, 200 total
  $(basename "$0") -m GET health                  # Health check load test

EOF
}

# 단일 요청 실행 및 시간 측정
execute_request() {
    local path="$1"
    local method="$2"
    local data="$3"

    local start_time=$(python3 -c 'import time; print(int(time.time() * 1000))')

    local http_code
    if [[ "$method" == "GET" ]]; then
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X GET "${FAAS_BASE_URL}/${path}" \
            --connect-timeout 10 \
            --max-time 30)
    else
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "${FAAS_BASE_URL}/${path}" \
            -H "Content-Type: application/json" \
            -d "${data:-{}}" \
            --connect-timeout 10 \
            --max-time 30)
    fi

    local end_time=$(python3 -c 'import time; print(int(time.time() * 1000))')
    local duration=$((end_time - start_time))

    echo "${duration}|${http_code}"
}

# 병렬 실행
run_parallel_requests() {
    local path="$1"
    local method="$2"
    local data="$3"
    local temp_file=$(mktemp)

    log_info "Starting load test: ${CONCURRENT_USERS} concurrent users, ${TOTAL_REQUESTS} total requests"
    log_info "Target: ${FAAS_BASE_URL}/${path}"
    echo ""

    local start_time=$(python3 -c 'import time; print(time.time())')

    # 병렬 실행
    seq 1 "$TOTAL_REQUESTS" | xargs -P "$CONCURRENT_USERS" -I {} \
        bash -c "execute_request '$path' '$method' '$data'" >> "$temp_file"

    local end_time=$(python3 -c 'import time; print(time.time())')
    local total_time=$(python3 -c "print(round($end_time - $start_time, 2))")

    # 결과 분석
    analyze_results "$temp_file" "$total_time"

    rm -f "$temp_file"
}

# 결과 분석
analyze_results() {
    local result_file="$1"
    local total_time="$2"

    local -a latencies=()
    local success_count=0
    local fail_count=0

    while IFS='|' read -r latency http_code; do
        if [[ -n "$latency" ]]; then
            latencies+=("$latency")
            if [[ "$http_code" == "200" ]]; then
                ((success_count++))
            else
                ((fail_count++))
            fi
        fi
    done < "$result_file"

    local total_count=${#latencies[@]}

    if [[ $total_count -eq 0 ]]; then
        log_error "No results collected"
        return 1
    fi

    # 정렬
    IFS=$'\n' sorted=($(sort -n <<<"${latencies[*]}")); unset IFS

    # 통계 계산
    local sum=0
    local min=${sorted[0]}
    local max=${sorted[-1]}

    for lat in "${sorted[@]}"; do
        ((sum+=lat))
    done

    local avg=$((sum / total_count))

    # Percentiles
    local p50_idx=$((total_count * 50 / 100))
    local p95_idx=$((total_count * 95 / 100))
    local p99_idx=$((total_count * 99 / 100))

    local p50=${sorted[$p50_idx]}
    local p95=${sorted[$p95_idx]}
    local p99=${sorted[$p99_idx]}

    # Throughput
    local throughput=$(python3 -c "print(round($total_count / $total_time, 2))")

    # 출력
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}                    LOAD TEST RESULTS                           ${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BOLD}Summary:${NC}"
    echo "  Total Requests: ${total_count}"
    echo -e "  ${GREEN}Successful: ${success_count}${NC}"
    echo -e "  ${RED}Failed: ${fail_count}${NC}"
    echo "  Total Time: ${total_time}s"
    echo "  Throughput: ${throughput} req/s"
    echo ""
    echo -e "${BOLD}Latency (ms):${NC}"
    echo "  Min: ${min}ms"
    echo "  Max: ${max}ms"
    echo "  Avg: ${avg}ms"
    echo "  P50: ${p50}ms"
    echo "  P95: ${p95}ms"
    echo "  P99: ${p99}ms"
    echo ""

    # Success rate
    local success_rate=$((success_count * 100 / total_count))
    if [[ $success_rate -ge 99 ]]; then
        echo -e "${GREEN}${BOLD}Success Rate: ${success_rate}%${NC}"
    elif [[ $success_rate -ge 95 ]]; then
        echo -e "${YELLOW}${BOLD}Success Rate: ${success_rate}%${NC}"
    else
        echo -e "${RED}${BOLD}Success Rate: ${success_rate}%${NC}"
    fi
}

export -f execute_request
export FAAS_BASE_URL

main() {
    local method="POST"
    local data="{}"

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                print_help
                exit 0
                ;;
            -u|--url)
                FAAS_BASE_URL="$2"
                export FAAS_BASE_URL
                shift 2
                ;;
            -c|--concurrent)
                CONCURRENT_USERS="$2"
                shift 2
                ;;
            -n|--requests)
                TOTAL_REQUESTS="$2"
                shift 2
                ;;
            -m|--method)
                method="$2"
                shift 2
                ;;
            -d|--data)
                data="$2"
                shift 2
                ;;
            *)
                TEST_PATH="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$TEST_PATH" ]]; then
        log_error "Please specify an endpoint path"
        print_help
        exit 1
    fi

    # Health check 경로 처리
    if [[ "$TEST_PATH" == "health" ]]; then
        TEST_PATH="health"
        method="GET"
    else
        TEST_PATH="api/${TEST_PATH}"
    fi

    run_parallel_requests "$TEST_PATH" "$method" "$data"
}

main "$@"
