#!/bin/bash
#===============================================================================
#
#   FaaS Control Plane Integration Test Suite
#
#   Created     : 2025-12
#   Description : 클라우드 인프라 QA 관점의 FaaS 플랫폼 통합 테스트
#                 - Environment Validation
#                 - Service Flow Testing (ChatRoom → Callback → Deploy)
#                 - API Contract Testing (CRUD)
#                 - Docker Integration Testing
#                 - Performance & Cold Start Analysis
#                 - Error Handling Verification
#
#   Service Flow:
#                 1. ChatRoom 생성
#                 2. Callback 생성 (chat_id 연결)
#                 3. Deploy (Docker/Kube)
#                 4. API 호출
#                 5. ChatRoom 삭제 시 연결된 Callback도 삭제
#
#   Usage       : ./faas_integration_test.sh [OPTIONS]
#
#===============================================================================

set -o pipefail

#===============================================================================
# Configuration & Constants
#===============================================================================
readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
readonly REPORT_DIR="${SCRIPT_DIR}/reports"
readonly REPORT_FILE="${REPORT_DIR}/test_report_${TIMESTAMP}.md"
readonly JSON_REPORT="${REPORT_DIR}/test_report_${TIMESTAMP}.json"

# Test Configuration
FAAS_BASE_URL="${FAAS_BASE_URL:-http://localhost:8000}"
TIMEOUT_SHORT=5
TIMEOUT_MEDIUM=15
TIMEOUT_LONG=60
BUILD_WAIT_TIME=30
COLD_START_ITERATIONS=3

# Test State - Service Flow 기반 리소스 관리
declare -a CREATED_CHATROOMS=()      # 생성된 ChatRoom IDs (cleanup 시 사용)
declare -a STANDALONE_CALLBACKS=()    # ChatRoom 없이 생성된 Callback IDs
declare -a CREATED_DOCKER_IMAGES=()   # 테스트에서 생성한 Docker 이미지 이름
declare -a CREATED_CALLBACK_PATHS=()  # 테스트에서 생성한 callback path (이미지 이름 추적용)
declare -a TEST_RESULTS=()
declare -a ISSUES=()
# PERFORMANCE_METRICS - Using individual variables for macOS compatibility
PERF_health_response_ms=""
PERF_build_time_ms=""
PERF_cold_start_ms=""
PERF_warm_call_ms=""
PERF_avg_response_ms=""

# 현재 테스트에서 사용 중인 리소스 (플로우 테스트용)
CURRENT_CHATROOM_ID=""
CURRENT_CALLBACK_ID=""
CURRENT_DEPLOY_PATH=""

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0
TEST_START_TIME=0

#===============================================================================
# ANSI Color Codes
#===============================================================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

#===============================================================================
# Logging Functions
#===============================================================================
log_info() {
    echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠${NC} $1"
}

log_section() {
    echo ""
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_banner() {
    echo -e "${BOLD}${CYAN}"
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║   ███████╗ █████╗  █████╗ ███████╗    ████████╗███████╗███████╗  ║
║   ██╔════╝██╔══██╗██╔══██╗██╔════╝    ╚══██╔══╝██╔════╝██╔════╝  ║
║   █████╗  ███████║███████║███████╗       ██║   █████╗  ███████╗  ║
║   ██╔══╝  ██╔══██║██╔══██║╚════██║       ██║   ██╔══╝  ╚════██║  ║
║   ██║     ██║  ██║██║  ██║███████║       ██║   ███████╗███████║  ║
║   ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝       ╚═╝   ╚══════╝╚══════╝  ║
║                                                                   ║
║   FaaS Control Plane Integration Test Suite                       ║
║   Cloud Infrastructure QA Automation                              ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

#===============================================================================
# Utility Functions
#===============================================================================

# JSON 파싱 (jq 없이도 동작)
json_extract() {
    local json="$1"
    local key="$2"
    echo "$json" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*[^,}]*" | \
        sed 's/.*:[[:space:]]*//' | tr -d '"' | tr -d ' '
}

# 숫자 추출
json_extract_number() {
    local json="$1"
    local key="$2"
    echo "$json" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*[0-9]*" | \
        grep -o '[0-9]*$'
}

# 밀리초 단위 시간 측정
get_time_ms() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v gdate &> /dev/null; then
            echo $(($(gdate +%s%N)/1000000))
        else
            python3 -c 'import time; print(int(time.time() * 1000))'
        fi
    else
        echo $(($(date +%s%N)/1000000))
    fi
}

# 응답 시간 측정하며 curl 실행
timed_curl() {
    local start=$(get_time_ms)
    local response
    response=$(curl -s -w "\n%{http_code}" "$@" 2>/dev/null)
    local end=$(get_time_ms)
    local duration=$((end - start))

    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')

    echo "$body|$http_code|$duration"
}

# 포트 사용 여부 확인
is_port_in_use() {
    local port=$1
    if command -v lsof &> /dev/null; then
        lsof -i :"$port" &> /dev/null
    elif command -v netstat &> /dev/null; then
        netstat -tuln | grep -q ":$port "
    else
        nc -z localhost "$port" 2>/dev/null
    fi
}

# 테스트 결과 기록
record_result() {
    local test_id="$1"
    local test_name="$2"
    local category="$3"
    local status="$4"
    local duration="$5"
    local expected="$6"
    local actual="$7"
    local message="${8:-}"

    ((TOTAL_TESTS++))

    case "$status" in
        PASS)
            ((PASSED_TESTS++))
            log_success "[${test_id}] ${test_name} (${duration}ms)"
            ;;
        FAIL)
            ((FAILED_TESTS++))
            log_error "[${test_id}] ${test_name} - ${message}"
            ;;
        SKIP)
            ((SKIPPED_TESTS++))
            log_warning "[${test_id}] ${test_name} - SKIPPED: ${message}"
            ;;
    esac

    TEST_RESULTS+=("{\"test_id\":\"${test_id}\",\"name\":\"${test_name}\",\"category\":\"${category}\",\"status\":\"${status}\",\"duration_ms\":${duration},\"expected\":\"${expected}\",\"actual\":\"${actual}\",\"message\":\"${message}\"}")
}

# 이슈 기록
record_issue() {
    local severity="$1"
    local title="$2"
    local description="$3"

    ISSUES+=("{\"severity\":\"${severity}\",\"title\":\"${title}\",\"description\":\"${description}\"}")
    log_warning "[ISSUE] [${severity}] ${title}"
}

# Cleanup 함수 - 서비스 플로우 기반
cleanup() {
    log_info "Cleaning up test resources (following service flow)..."

    # 1. ChatRoom 삭제 (연결된 Callback도 함께 삭제됨)
    for chat_id in "${CREATED_CHATROOMS[@]}"; do
        if [[ -n "$chat_id" ]]; then
            curl -s -X DELETE "${FAAS_BASE_URL}/chatroom/${chat_id}" \
                --connect-timeout 3 &> /dev/null || true
            log_info "  Deleted ChatRoom: ${chat_id}"
        fi
    done

    # 2. ChatRoom 없이 생성된 단독 Callback 삭제
    for callback_id in "${STANDALONE_CALLBACKS[@]}"; do
        if [[ -n "$callback_id" ]]; then
            curl -s -X DELETE "${FAAS_BASE_URL}/callbacks/${callback_id}" \
                --connect-timeout 3 &> /dev/null || true
            log_info "  Deleted standalone Callback: ${callback_id}"
        fi
    done

    # 3. 테스트에서 생성한 Docker 이미지만 삭제
    if command -v docker &> /dev/null && docker info &> /dev/null; then
        for callback_path in "${CREATED_CALLBACK_PATHS[@]}"; do
            if [[ -n "$callback_path" ]]; then
                # Remove leading slash for image name
                local clean_path="${callback_path#/}"
                local image_name="callback_${clean_path}"
                # 이미지 존재 여부 확인 후 삭제
                if docker images -q "$image_name" 2>/dev/null | grep -q .; then
                    docker rmi "$image_name" --force &>/dev/null || true
                    log_info "  Deleted Docker image: ${image_name}"
                fi
            fi
        done

        # Clean up test-related containers that might be stopped
        local test_containers
        test_containers=$(docker ps -a --filter "name=callback_" --format "{{.Names}}" 2>/dev/null || echo "")
        for container in $test_containers; do
            if [[ -n "$container" ]]; then
                docker rm -f "$container" &>/dev/null || true
                log_info "  Deleted Docker container: ${container}"
            fi
        done
    fi

    CREATED_CHATROOMS=()
    STANDALONE_CALLBACKS=()
    CREATED_CALLBACK_PATHS=()
}

# 시그널 핸들러
trap cleanup EXIT
trap 'echo ""; log_warning "Test interrupted by user"; exit 130' INT TERM

#===============================================================================
# Environment Validation Tests
#===============================================================================
run_environment_tests() {
    log_section "1. Environment Validation Tests"

    # TC-ENV01: Python Version Check
    local start=$(get_time_ms)
    local py_version
    py_version=$(python3 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+')
    local duration=$(($(get_time_ms) - start))

    if [[ -n "$py_version" ]]; then
        local major=$(echo "$py_version" | cut -d. -f1)
        local minor=$(echo "$py_version" | cut -d. -f2)

        if [[ "$major" -ge 3 && "$minor" -ge 8 ]]; then
            record_result "TC-ENV01" "Python Version Check" "Environment" "PASS" "$duration" ">=3.8" "$py_version"
        else
            record_result "TC-ENV01" "Python Version Check" "Environment" "FAIL" "$duration" ">=3.8" "$py_version" "Python 3.8+ required"
        fi
    else
        record_result "TC-ENV01" "Python Version Check" "Environment" "FAIL" "$duration" ">=3.8" "Not found" "Python not installed"
    fi

    # TC-ENV02: Docker Availability
    start=$(get_time_ms)
    if command -v docker &> /dev/null && docker ps &> /dev/null; then
        local docker_version
        docker_version=$(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        duration=$(($(get_time_ms) - start))
        record_result "TC-ENV02" "Docker Availability" "Environment" "PASS" "$duration" "Docker running" "v${docker_version}"
    else
        duration=$(($(get_time_ms) - start))
        record_result "TC-ENV02" "Docker Availability" "Environment" "FAIL" "$duration" "Docker running" "Not available"
        record_issue "Critical" "Docker Not Running" "Docker daemon is not accessible"
    fi

    # TC-ENV03: Port 8000 Check (Server Running)
    start=$(get_time_ms)
    if is_port_in_use 8000; then
        duration=$(($(get_time_ms) - start))
        record_result "TC-ENV03" "Port 8000 Check" "Environment" "PASS" "$duration" "Server running" "Port in use"
    else
        duration=$(($(get_time_ms) - start))
        record_result "TC-ENV03" "Port 8000 Check" "Environment" "SKIP" "$duration" "Server running" "Port available" "Server not running"
    fi

    # TC-ENV04: curl availability
    start=$(get_time_ms)
    if command -v curl &> /dev/null; then
        local curl_version
        curl_version=$(curl --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        duration=$(($(get_time_ms) - start))
        record_result "TC-ENV04" "curl Availability" "Environment" "PASS" "$duration" "curl installed" "v${curl_version}"
    else
        duration=$(($(get_time_ms) - start))
        record_result "TC-ENV04" "curl Availability" "Environment" "FAIL" "$duration" "curl installed" "Not found"
    fi

    # TC-ENV05: Git Info
    start=$(get_time_ms)
    local git_branch git_commit
    git_branch=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo "N/A")
    git_commit=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "N/A")
    duration=$(($(get_time_ms) - start))
    record_result "TC-ENV05" "Git Repository Check" "Environment" "PASS" "$duration" "Git info" "branch:${git_branch}, commit:${git_commit}"
}

#===============================================================================
# Health Check Tests
#===============================================================================
run_health_tests() {
    log_section "2. Health Check Tests"

    # TC-L01: Health Endpoint
    local result
    result=$(timed_curl -X GET "${FAAS_BASE_URL}/health" --connect-timeout "$TIMEOUT_SHORT")

    local body=$(echo "$result" | cut -d'|' -f1)
    local http_code=$(echo "$result" | cut -d'|' -f2)
    local duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "200" ]] && echo "$body" | grep -q "healthy"; then
        record_result "TC-L01" "Health Check Endpoint" "Health" "PASS" "$duration" "200 + healthy" "HTTP ${http_code}"
    else
        record_result "TC-L01" "Health Check Endpoint" "Health" "FAIL" "$duration" "200 + healthy" "HTTP ${http_code}" "Health check failed"
        record_issue "Critical" "Server Unreachable" "Health endpoint not responding correctly"
        return 1
    fi

    # TC-L01b: Health Response Time SLA (< 500ms)
    local sla_threshold=500
    if [[ "$duration" -lt "$sla_threshold" ]]; then
        record_result "TC-L01b" "Health Response Time SLA" "Health" "PASS" "$duration" "<${sla_threshold}ms" "${duration}ms"
    else
        record_result "TC-L01b" "Health Response Time SLA" "Health" "FAIL" "$duration" "<${sla_threshold}ms" "${duration}ms" "SLA breach"
        record_issue "Medium" "Health Check Slow" "Response time ${duration}ms exceeds SLA"
    fi

    PERF_health_response_ms="$duration"
}

#===============================================================================
# ChatRoom CRUD Tests (서비스 플로우의 시작점)
#===============================================================================
run_chatroom_tests() {
    log_section "3. ChatRoom CRUD Tests"

    local test_chatroom_id=""

    # TC-CR01: Create ChatRoom
    local payload="{\"title\": \"Test ChatRoom ${TIMESTAMP}\"}"

    local result
    result=$(timed_curl -X POST "${FAAS_BASE_URL}/chatroom/" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --connect-timeout "$TIMEOUT_SHORT")

    local body=$(echo "$result" | cut -d'|' -f1)
    local http_code=$(echo "$result" | cut -d'|' -f2)
    local duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "200" ]]; then
        test_chatroom_id=$(json_extract_number "$body" "chat_id")
        local title=$(json_extract "$body" "title")

        if [[ -n "$test_chatroom_id" ]]; then
            CREATED_CHATROOMS+=("$test_chatroom_id")
            record_result "TC-CR01" "Create ChatRoom" "ChatRoom" "PASS" "$duration" "chat_id created" "id=${test_chatroom_id}, title=${title}"
        else
            record_result "TC-CR01" "Create ChatRoom" "ChatRoom" "FAIL" "$duration" "chat_id created" "No ID returned" "Invalid response"
        fi
    else
        record_result "TC-CR01" "Create ChatRoom" "ChatRoom" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}" "Create failed"
    fi

    # TC-CR02: Get Single ChatRoom
    if [[ -n "$test_chatroom_id" ]]; then
        result=$(timed_curl -X GET "${FAAS_BASE_URL}/chatroom/${test_chatroom_id}" \
            --connect-timeout "$TIMEOUT_SHORT")

        http_code=$(echo "$result" | cut -d'|' -f2)
        duration=$(echo "$result" | cut -d'|' -f3)

        if [[ "$http_code" == "200" ]]; then
            record_result "TC-CR02" "Get Single ChatRoom" "ChatRoom" "PASS" "$duration" "HTTP 200" "HTTP ${http_code}"
        else
            record_result "TC-CR02" "Get Single ChatRoom" "ChatRoom" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
        fi
    else
        record_result "TC-CR02" "Get Single ChatRoom" "ChatRoom" "SKIP" "0" "N/A" "N/A" "No chatroom created"
    fi

    # TC-CR03: Get All ChatRooms
    result=$(timed_curl -X GET "${FAAS_BASE_URL}/chatroom/" \
        --connect-timeout "$TIMEOUT_SHORT")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "200" ]] && echo "$body" | grep -q "^\["; then
        record_result "TC-CR03" "Get All ChatRooms" "ChatRoom" "PASS" "$duration" "Array response" "HTTP ${http_code}"
    else
        record_result "TC-CR03" "Get All ChatRooms" "ChatRoom" "FAIL" "$duration" "Array response" "HTTP ${http_code}"
    fi

    # TC-CR04: Get Nonexistent ChatRoom
    result=$(timed_curl -X GET "${FAAS_BASE_URL}/chatroom/99999" \
        --connect-timeout "$TIMEOUT_SHORT")

    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "404" ]]; then
        record_result "TC-CR04" "Get Nonexistent ChatRoom" "ChatRoom" "PASS" "$duration" "HTTP 404" "HTTP ${http_code}"
    else
        record_result "TC-CR04" "Get Nonexistent ChatRoom" "ChatRoom" "FAIL" "$duration" "HTTP 404" "HTTP ${http_code}"
    fi

    # TC-CR05: Update ChatRoom
    if [[ -n "$test_chatroom_id" ]]; then
        local update_payload="{\"title\": \"Updated ChatRoom ${TIMESTAMP}\"}"

        result=$(timed_curl -X PUT "${FAAS_BASE_URL}/chatroom/${test_chatroom_id}" \
            -H "Content-Type: application/json" \
            -d "$update_payload" \
            --connect-timeout "$TIMEOUT_SHORT")

        http_code=$(echo "$result" | cut -d'|' -f2)
        duration=$(echo "$result" | cut -d'|' -f3)

        if [[ "$http_code" == "200" ]]; then
            record_result "TC-CR05" "Update ChatRoom" "ChatRoom" "PASS" "$duration" "HTTP 200" "HTTP ${http_code}"
        else
            record_result "TC-CR05" "Update ChatRoom" "ChatRoom" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
        fi
    fi
}

#===============================================================================
# Service Flow Test: ChatRoom → Callback → Deploy → Invoke
#===============================================================================
run_service_flow_tests() {
    log_section "4. Service Flow Tests (ChatRoom → Callback → Deploy)"

    # Step 1: Create ChatRoom for service flow
    log_info "  Step 1: Creating ChatRoom..."

    local chatroom_payload="{\"title\": \"Service Flow Test ${TIMESTAMP}\"}"

    local result
    result=$(timed_curl -X POST "${FAAS_BASE_URL}/chatroom/" \
        -H "Content-Type: application/json" \
        -d "$chatroom_payload" \
        --connect-timeout "$TIMEOUT_SHORT")

    local body=$(echo "$result" | cut -d'|' -f1)
    local http_code=$(echo "$result" | cut -d'|' -f2)
    local duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "200" ]]; then
        CURRENT_CHATROOM_ID=$(json_extract_number "$body" "chat_id")
        CREATED_CHATROOMS+=("$CURRENT_CHATROOM_ID")
        record_result "TC-SF01" "Create ChatRoom for Flow" "ServiceFlow" "PASS" "$duration" "chat_id created" "id=${CURRENT_CHATROOM_ID}"
    else
        record_result "TC-SF01" "Create ChatRoom for Flow" "ServiceFlow" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
        return 1
    fi

    # Step 2: Create Callback with chat_id
    log_info "  Step 2: Creating Callback linked to ChatRoom..."

    CURRENT_DEPLOY_PATH="/flow_test_${TIMESTAMP}"
    CREATED_CALLBACK_PATHS+=("$CURRENT_DEPLOY_PATH")  # Docker 이미지 정리용 추적
    local python_code='import json\ndef lambda_handler(event, context):\n    body = event.get(\"body\", {})\n    return {\"statusCode\": 200, \"body\": json.dumps({\"message\": \"Service flow works!\", \"received\": body})}'

    local callback_payload="{\"path\": \"${CURRENT_DEPLOY_PATH}\", \"method\": \"POST\", \"type\": \"python\", \"code\": \"${python_code}\", \"chat_id\": ${CURRENT_CHATROOM_ID}}"

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/callbacks/" \
        -H "Content-Type: application/json" \
        -d "$callback_payload" \
        --connect-timeout "$TIMEOUT_SHORT")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "200" ]]; then
        CURRENT_CALLBACK_ID=$(json_extract_number "$body" "callback_id")
        local status=$(json_extract "$body" "status")
        record_result "TC-SF02" "Create Callback with chat_id" "ServiceFlow" "PASS" "$duration" "callback linked" "callback_id=${CURRENT_CALLBACK_ID}, chat_id=${CURRENT_CHATROOM_ID}"
    else
        record_result "TC-SF02" "Create Callback with chat_id" "ServiceFlow" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}" "Failed to create callback"
        return 1
    fi

    # Step 3: Verify ChatRoom-Callback Link
    log_info "  Step 3: Verifying ChatRoom-Callback link..."

    result=$(timed_curl -X GET "${FAAS_BASE_URL}/chatroom/${CURRENT_CHATROOM_ID}" \
        --connect-timeout "$TIMEOUT_SHORT")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "200" ]]; then
        local linked_callback_id=$(json_extract_number "$body" "callback_id")
        if [[ "$linked_callback_id" == "$CURRENT_CALLBACK_ID" ]]; then
            record_result "TC-SF03" "Verify ChatRoom-Callback Link" "ServiceFlow" "PASS" "$duration" "callback_id=${CURRENT_CALLBACK_ID}" "linked_id=${linked_callback_id}"
        else
            record_result "TC-SF03" "Verify ChatRoom-Callback Link" "ServiceFlow" "FAIL" "$duration" "callback_id=${CURRENT_CALLBACK_ID}" "linked_id=${linked_callback_id}" "Link mismatch"
        fi
    else
        record_result "TC-SF03" "Verify ChatRoom-Callback Link" "ServiceFlow" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
    fi

    # Step 4: Deploy Callback
    log_info "  Step 4: Deploying Callback..."

    local deploy_payload="{\"callback_id\": ${CURRENT_CALLBACK_ID}, \"status\": true, \"c_type\": \"docker\"}"
    local build_start=$(get_time_ms)

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/deploy/" \
        -H "Content-Type: application/json" \
        -d "$deploy_payload" \
        --connect-timeout "$TIMEOUT_SHORT")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" == "200" ]]; then
        local initial_status=$(json_extract "$body" "status")

        if [[ "$initial_status" == "build" ]]; then
            log_info "    Build started, waiting for completion..."

            local elapsed=0
            local final_status="build"

            while [[ $elapsed -lt $BUILD_WAIT_TIME ]]; do
                sleep 2
                ((elapsed+=2))

                local check
                check=$(curl -s "${FAAS_BASE_URL}/callbacks/${CURRENT_CALLBACK_ID}" --connect-timeout 3)
                final_status=$(json_extract "$check" "status")

                if [[ "$final_status" == "deployed" || "$final_status" == "failed" ]]; then
                    break
                fi

                echo -ne "    Building... ${elapsed}s / ${BUILD_WAIT_TIME}s\r"
            done
            echo ""

            local build_time=$(($(get_time_ms) - build_start))
            PERF_build_time_ms="$build_time"

            if [[ "$final_status" == "deployed" ]]; then
                record_result "TC-SF04" "Deploy Callback" "ServiceFlow" "PASS" "$((build_time))" "status=deployed" "built in ${elapsed}s"
            else
                record_result "TC-SF04" "Deploy Callback" "ServiceFlow" "FAIL" "$((build_time))" "status=deployed" "status=${final_status}" "Build failed"
                record_issue "High" "Docker Build Failed" "Build resulted in status: ${final_status}"
            fi
        else
            record_result "TC-SF04" "Deploy Callback" "ServiceFlow" "FAIL" "0" "status=build" "status=${initial_status}" "Build not started"
        fi
    else
        record_result "TC-SF04" "Deploy Callback" "ServiceFlow" "FAIL" "0" "HTTP 200" "HTTP ${http_code}" "Deploy request failed"
    fi

    # Step 5: Invoke Deployed Function
    log_info "  Step 5: Invoking deployed function..."

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/api/${CURRENT_DEPLOY_PATH#/}" \
        -H "Content-Type: application/json" \
        -d '{"test": "service_flow_data"}' \
        --connect-timeout "$TIMEOUT_MEDIUM")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    PERF_cold_start_ms="$duration"

    if [[ "$http_code" == "200" ]]; then
        record_result "TC-SF05" "Invoke Deployed Function" "ServiceFlow" "PASS" "$duration" "HTTP 200" "Response in ${duration}ms"
    else
        record_result "TC-SF05" "Invoke Deployed Function" "ServiceFlow" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
    fi

    # Step 6: Cold Start Analysis
    log_info "  Step 6: Cold Start analysis..."

    local -a response_times=()

    for i in $(seq 1 $COLD_START_ITERATIONS); do
        result=$(timed_curl -X POST "${FAAS_BASE_URL}/api/${CURRENT_DEPLOY_PATH#/}" \
            -H "Content-Type: application/json" \
            -d "{\"iteration\": $i}" \
            --connect-timeout "$TIMEOUT_MEDIUM")

        http_code=$(echo "$result" | cut -d'|' -f2)
        duration=$(echo "$result" | cut -d'|' -f3)

        if [[ "$http_code" == "200" ]]; then
            response_times+=("$duration")
        fi
    done

    if [[ ${#response_times[@]} -ge 2 ]]; then
        local sum=0 min=${response_times[0]} max=${response_times[0]}

        for t in "${response_times[@]}"; do
            ((sum+=t))
            [[ $t -lt $min ]] && min=$t
            [[ $t -gt $max ]] && max=$t
        done

        local avg=$((sum / ${#response_times[@]}))

        PERF_warm_call_ms="$min"
        PERF_avg_response_ms="$avg"

        record_result "TC-SF06" "Cold Start Analysis" "ServiceFlow" "PASS" "0" "Response metrics" "avg=${avg}ms, min=${min}ms, max=${max}ms"
    else
        record_result "TC-SF06" "Cold Start Analysis" "ServiceFlow" "SKIP" "0" "Multiple responses" "Insufficient data"
    fi
}

#===============================================================================
# Callback CRUD Tests (ChatRoom 연결 포함)
#===============================================================================
run_callback_crud_tests() {
    log_section "5. Callback CRUD Tests"

    local test_callback_id=""

    # TC-CB01: Create Callback without chat_id (standalone)
    log_info "  Testing standalone callback (without chat_id)..."

    local standalone_path="/standalone_${TIMESTAMP}"
    local python_code='import json\ndef lambda_handler(event, context):\n    return {\"statusCode\": 200, \"body\": json.dumps({\"message\": \"Standalone callback\"})}'
    local payload="{\"path\": \"${standalone_path}\", \"method\": \"POST\", \"type\": \"python\", \"code\": \"${python_code}\"}"

    local result
    result=$(timed_curl -X POST "${FAAS_BASE_URL}/callbacks/" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --connect-timeout "$TIMEOUT_SHORT")

    local body=$(echo "$result" | cut -d'|' -f1)
    local http_code=$(echo "$result" | cut -d'|' -f2)
    local duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "200" ]]; then
        test_callback_id=$(json_extract_number "$body" "callback_id")
        STANDALONE_CALLBACKS+=("$test_callback_id")
        CREATED_CALLBACK_PATHS+=("$standalone_path")  # Docker 이미지 정리용 추적
        record_result "TC-CB01" "Create Standalone Callback" "Callback" "PASS" "$duration" "callback_id created" "id=${test_callback_id}"
    else
        record_result "TC-CB01" "Create Standalone Callback" "Callback" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
    fi

    # TC-L03: Create Node.js Callback (test.txt 요구사항)
    log_info "  Testing Node.js callback creation..."

    local test_node_callback_id=""
    local node_path="/test_node_${TIMESTAMP}"
    local node_code='exports.handler = async (event) => { return { statusCode: 200, body: JSON.stringify({message: \"Hello from Node\"}) }; };'
    payload="{\"path\": \"${node_path}\", \"method\": \"POST\", \"type\": \"node\", \"code\": \"${node_code}\"}"

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/callbacks/" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --connect-timeout "$TIMEOUT_SHORT")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "200" ]]; then
        test_node_callback_id=$(json_extract_number "$body" "callback_id")
        local node_type=$(json_extract "$body" "type")

        if [[ "$node_type" == "node" ]]; then
            STANDALONE_CALLBACKS+=("$test_node_callback_id")
            CREATED_CALLBACK_PATHS+=("$node_path")  # Docker 이미지 정리용 추적
            record_result "TC-L03" "Create Node.js Callback" "Callback" "PASS" "$duration" "type=node" "id=${test_node_callback_id}, type=${node_type}"
        else
            record_result "TC-L03" "Create Node.js Callback" "Callback" "FAIL" "$duration" "type=node" "type=${node_type}" "Wrong type returned"
        fi
    else
        record_result "TC-L03" "Create Node.js Callback" "Callback" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}" "Failed to create Node.js callback"
    fi

    # TC-CB02: Create Callback with invalid chat_id
    log_info "  Testing callback creation with invalid chat_id..."

    payload="{\"path\": \"invalid_chat_${TIMESTAMP}\", \"method\": \"POST\", \"type\": \"python\", \"code\": \"def lambda_handler(e, c): pass\", \"chat_id\": 99999}"

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/callbacks/" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --connect-timeout "$TIMEOUT_SHORT")

    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "409" || "$http_code" == "400" || "$http_code" == "404" ]]; then
        record_result "TC-CB02" "Create Callback with Invalid chat_id" "Callback" "PASS" "$duration" "Error response" "HTTP ${http_code}"
    else
        record_result "TC-CB02" "Create Callback with Invalid chat_id" "Callback" "FAIL" "$duration" "Error response" "HTTP ${http_code}" "Should reject invalid chat_id"
    fi

    # TC-CB03: Get Single Callback
    if [[ -n "$test_callback_id" ]]; then
        result=$(timed_curl -X GET "${FAAS_BASE_URL}/callbacks/${test_callback_id}" \
            --connect-timeout "$TIMEOUT_SHORT")

        http_code=$(echo "$result" | cut -d'|' -f2)
        duration=$(echo "$result" | cut -d'|' -f3)

        if [[ "$http_code" == "200" ]]; then
            record_result "TC-CB03" "Get Single Callback" "Callback" "PASS" "$duration" "HTTP 200" "HTTP ${http_code}"
        else
            record_result "TC-CB03" "Get Single Callback" "Callback" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
        fi
    fi

    # TC-CB04: Get All Callbacks
    result=$(timed_curl -X GET "${FAAS_BASE_URL}/callbacks/" \
        --connect-timeout "$TIMEOUT_SHORT")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "200" ]] && echo "$body" | grep -q "^\["; then
        record_result "TC-CB04" "Get All Callbacks" "Callback" "PASS" "$duration" "Array response" "HTTP ${http_code}"
    else
        record_result "TC-CB04" "Get All Callbacks" "Callback" "FAIL" "$duration" "Array response" "HTTP ${http_code}"
    fi

    # TC-CB05: Get Nonexistent Callback
    result=$(timed_curl -X GET "${FAAS_BASE_URL}/callbacks/99999" \
        --connect-timeout "$TIMEOUT_SHORT")

    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "404" ]]; then
        record_result "TC-CB05" "Get Nonexistent Callback" "Callback" "PASS" "$duration" "HTTP 404" "HTTP ${http_code}"
    else
        record_result "TC-CB05" "Get Nonexistent Callback" "Callback" "FAIL" "$duration" "HTTP 404" "HTTP ${http_code}"
    fi

    # TC-CB06: Update Callback
    if [[ -n "$test_callback_id" ]]; then
        sleep 1

        local update_payload="{\"code\": \"import json\\ndef lambda_handler(event, context):\\n    return {\\\"statusCode\\\": 200, \\\"body\\\": json.dumps({\\\"message\\\": \\\"Updated!\\\"})}\"}"

        result=$(timed_curl -X PUT "${FAAS_BASE_URL}/callbacks/${test_callback_id}" \
            -H "Content-Type: application/json" \
            -d "$update_payload" \
            --connect-timeout "$TIMEOUT_SHORT")

        http_code=$(echo "$result" | cut -d'|' -f2)
        duration=$(echo "$result" | cut -d'|' -f3)

        if [[ "$http_code" == "200" ]]; then
            record_result "TC-CB06" "Update Callback" "Callback" "PASS" "$duration" "HTTP 200" "HTTP ${http_code}"
        else
            record_result "TC-CB06" "Update Callback" "Callback" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
        fi
    fi

    # TC-CB07: Duplicate Path Creation (같은 path로 다시 생성 시도)
    if [[ -n "$test_callback_id" ]]; then
        # standalone_path는 /standalone_${TIMESTAMP}로 생성됨 - 동일한 path 사용
        payload="{\"path\": \"${standalone_path}\", \"method\": \"POST\", \"type\": \"python\", \"code\": \"def lambda_handler(e, c): pass\"}"

        result=$(timed_curl -X POST "${FAAS_BASE_URL}/callbacks/" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            --connect-timeout "$TIMEOUT_SHORT")

        http_code=$(echo "$result" | cut -d'|' -f2)
        duration=$(echo "$result" | cut -d'|' -f3)

        if [[ "$http_code" == "400" || "$http_code" == "409" ]]; then
            record_result "TC-CB07" "Duplicate Path Creation" "Callback" "PASS" "$duration" "400 or 409" "HTTP ${http_code}"
        else
            record_result "TC-CB07" "Duplicate Path Creation" "Callback" "FAIL" "$duration" "400 or 409" "HTTP ${http_code}" "Duplicate not rejected"
            record_issue "Medium" "Duplicate Path Allowed" "Server accepted duplicate path creation"
        fi
    fi

    # TC-CB08: Delete Standalone Callback
    if [[ -n "$test_callback_id" ]]; then
        result=$(timed_curl -X DELETE "${FAAS_BASE_URL}/callbacks/${test_callback_id}" \
            --connect-timeout "$TIMEOUT_SHORT")

        http_code=$(echo "$result" | cut -d'|' -f2)
        duration=$(echo "$result" | cut -d'|' -f3)

        if [[ "$http_code" == "200" ]]; then
            # Remove from cleanup list
            STANDALONE_CALLBACKS=("${STANDALONE_CALLBACKS[@]/$test_callback_id}")
            record_result "TC-CB08" "Delete Standalone Callback" "Callback" "PASS" "$duration" "HTTP 200" "HTTP ${http_code}"
        else
            record_result "TC-CB08" "Delete Standalone Callback" "Callback" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
        fi
    fi
}

#===============================================================================
# ChatRoom Cascade Delete Test (서비스 플로우 핵심)
#===============================================================================
run_cascade_delete_test() {
    log_section "6. Cascade Delete Test (ChatRoom → Callback)"

    # Step 1: Create ChatRoom
    local cascade_chatroom_id=""
    local cascade_callback_id=""

    log_info "  Creating ChatRoom for cascade delete test..."

    local result
    result=$(timed_curl -X POST "${FAAS_BASE_URL}/chatroom/" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"Cascade Test ${TIMESTAMP}\"}" \
        --connect-timeout "$TIMEOUT_SHORT")

    local body=$(echo "$result" | cut -d'|' -f1)
    local http_code=$(echo "$result" | cut -d'|' -f2)
    local duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "200" ]]; then
        cascade_chatroom_id=$(json_extract_number "$body" "chat_id")
        record_result "TC-CD01" "Create ChatRoom for Cascade" "CascadeDelete" "PASS" "$duration" "chat_id created" "id=${cascade_chatroom_id}"
    else
        record_result "TC-CD01" "Create ChatRoom for Cascade" "CascadeDelete" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
        return 1
    fi

    # Step 2: Create Callback linked to ChatRoom
    log_info "  Creating Callback linked to ChatRoom..."

    local cascade_path="/cascade_${TIMESTAMP}"
    local python_code='def lambda_handler(e, c): return {\"statusCode\": 200}'
    local payload="{\"path\": \"${cascade_path}\", \"method\": \"POST\", \"type\": \"python\", \"code\": \"${python_code}\", \"chat_id\": ${cascade_chatroom_id}}"

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/callbacks/" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --connect-timeout "$TIMEOUT_SHORT")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "200" ]]; then
        cascade_callback_id=$(json_extract_number "$body" "callback_id")
        CREATED_CALLBACK_PATHS+=("$cascade_path")  # Docker 이미지 정리용 추적
        record_result "TC-CD02" "Create Linked Callback" "CascadeDelete" "PASS" "$duration" "callback created" "id=${cascade_callback_id}"
    else
        record_result "TC-CD02" "Create Linked Callback" "CascadeDelete" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
        # Cleanup chatroom
        curl -s -X DELETE "${FAAS_BASE_URL}/chatroom/${cascade_chatroom_id}" &>/dev/null
        return 1
    fi

    # Step 3: Delete ChatRoom (should cascade delete Callback)
    log_info "  Deleting ChatRoom (expecting cascade delete)..."

    result=$(timed_curl -X DELETE "${FAAS_BASE_URL}/chatroom/${cascade_chatroom_id}" \
        --connect-timeout "$TIMEOUT_SHORT")

    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "200" ]]; then
        record_result "TC-CD03" "Delete ChatRoom" "CascadeDelete" "PASS" "$duration" "HTTP 200" "HTTP ${http_code}"
    else
        record_result "TC-CD03" "Delete ChatRoom" "CascadeDelete" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
    fi

    # Step 4: Verify Callback was also deleted
    log_info "  Verifying Callback was cascade deleted..."

    result=$(timed_curl -X GET "${FAAS_BASE_URL}/callbacks/${cascade_callback_id}" \
        --connect-timeout "$TIMEOUT_SHORT")

    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "404" ]]; then
        record_result "TC-CD04" "Verify Cascade Delete" "CascadeDelete" "PASS" "$duration" "HTTP 404 (deleted)" "HTTP ${http_code}"
    else
        record_result "TC-CD04" "Verify Cascade Delete" "CascadeDelete" "FAIL" "$duration" "HTTP 404 (deleted)" "HTTP ${http_code}" "Callback still exists!"
        record_issue "High" "Cascade Delete Failed" "Callback was not deleted when ChatRoom was deleted"
        # Manual cleanup
        curl -s -X DELETE "${FAAS_BASE_URL}/callbacks/${cascade_callback_id}" &>/dev/null
    fi
}

#===============================================================================
# Library & Environment Variable Tests
#===============================================================================
run_library_env_tests() {
    log_section "7. Library & Environment Variable Tests"

    # 이 테스트들도 서비스 플로우를 따름
    local lib_chatroom_id=""
    local lib_callback_id=""

    # TC-LE01: Create ChatRoom for library test
    log_info "  Creating ChatRoom for library test..."

    local result
    result=$(timed_curl -X POST "${FAAS_BASE_URL}/chatroom/" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"Library Test ${TIMESTAMP}\"}" \
        --connect-timeout "$TIMEOUT_SHORT")

    local body=$(echo "$result" | cut -d'|' -f1)
    local http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" == "200" ]]; then
        lib_chatroom_id=$(json_extract_number "$body" "chat_id")
        CREATED_CHATROOMS+=("$lib_chatroom_id")
    else
        record_result "TC-LE01" "Library Test Setup" "Library" "SKIP" "0" "N/A" "N/A" "Failed to create ChatRoom"
        return
    fi

    # TC-LE02: Create Callback with external library
    log_info "  Creating function with external library (this may take a while)..."

    local lib_path="/lib_test_${TIMESTAMP}"
    CREATED_CALLBACK_PATHS+=("$lib_path")  # Docker 이미지 정리용 추적
    local lib_code='import json\nimport requests\ndef lambda_handler(event, context):\n    return {\"statusCode\": 200, \"body\": json.dumps({\"requests_version\": requests.__version__})}'
    local lib_payload="{\"path\": \"${lib_path}\", \"method\": \"POST\", \"type\": \"python\", \"code\": \"${lib_code}\", \"library\": \"requests==2.28.0\", \"chat_id\": ${lib_chatroom_id}}"

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/callbacks/" \
        -H "Content-Type: application/json" \
        -d "$lib_payload" \
        --connect-timeout "$TIMEOUT_SHORT")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)
    local duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "200" ]]; then
        lib_callback_id=$(json_extract_number "$body" "callback_id")

        # Deploy
        local deploy_payload="{\"callback_id\": ${lib_callback_id}, \"status\": true, \"c_type\": \"docker\"}"
        curl -s -X POST "${FAAS_BASE_URL}/deploy/" \
            -H "Content-Type: application/json" \
            -d "$deploy_payload" \
            --connect-timeout "$TIMEOUT_SHORT" > /dev/null

        log_info "    Waiting for library function build (${BUILD_WAIT_TIME}+ seconds)..."
        sleep $((BUILD_WAIT_TIME + 15))

        # Check status and invoke
        local check
        check=$(curl -s "${FAAS_BASE_URL}/callbacks/${lib_callback_id}" --connect-timeout 3)
        local status=$(json_extract "$check" "status")

        if [[ "$status" == "deployed" ]]; then
            result=$(timed_curl -X POST "${FAAS_BASE_URL}/api/${lib_path#/}" \
                -H "Content-Type: application/json" \
                -d '{}' \
                --connect-timeout "$TIMEOUT_MEDIUM")

            body=$(echo "$result" | cut -d'|' -f1)
            http_code=$(echo "$result" | cut -d'|' -f2)
            duration=$(echo "$result" | cut -d'|' -f3)

            if [[ "$http_code" == "200" ]] && echo "$body" | grep -q "2.28"; then
                record_result "TC-LE02" "External Library Function" "Library" "PASS" "$duration" "requests 2.28.x" "Library loaded"
            else
                record_result "TC-LE02" "External Library Function" "Library" "FAIL" "$duration" "requests 2.28.x" "HTTP ${http_code}"
            fi
        else
            record_result "TC-LE02" "External Library Function" "Library" "FAIL" "0" "status=deployed" "status=${status}" "Build failed"
        fi
    else
        record_result "TC-LE02" "External Library Function" "Library" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
    fi

    # TC-LE03: Environment Variable Test
    local env_chatroom_id=""

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/chatroom/" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"Env Test ${TIMESTAMP}\"}" \
        --connect-timeout "$TIMEOUT_SHORT")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" == "200" ]]; then
        env_chatroom_id=$(json_extract_number "$body" "chat_id")
        CREATED_CHATROOMS+=("$env_chatroom_id")

        local env_path="/env_test_${TIMESTAMP}"
        CREATED_CALLBACK_PATHS+=("$env_path")  # Docker 이미지 정리용 추적
        local env_code='import os\nimport json\ndef lambda_handler(event, context):\n    api_key = os.environ.get(\"API_KEY\", \"NOTSET\")\n    return {\"statusCode\": 200, \"body\": json.dumps({\"api_key_prefix\": api_key[:3] if len(api_key) >= 3 else api_key})}'
        local env_payload="{\"path\": \"${env_path}\", \"method\": \"POST\", \"type\": \"python\", \"code\": \"${env_code}\", \"env\": {\"API_KEY\": \"secret123\", \"DB_HOST\": \"localhost\"}, \"chat_id\": ${env_chatroom_id}}"

        result=$(timed_curl -X POST "${FAAS_BASE_URL}/callbacks/" \
            -H "Content-Type: application/json" \
            -d "$env_payload" \
            --connect-timeout "$TIMEOUT_SHORT")

        body=$(echo "$result" | cut -d'|' -f1)
        http_code=$(echo "$result" | cut -d'|' -f2)

        if [[ "$http_code" == "200" ]]; then
            local env_callback_id=$(json_extract_number "$body" "callback_id")

            # Deploy
            local deploy_payload="{\"callback_id\": ${env_callback_id}, \"status\": true, \"c_type\": \"docker\"}"
            curl -s -X POST "${FAAS_BASE_URL}/deploy/" \
                -H "Content-Type: application/json" \
                -d "$deploy_payload" \
                --connect-timeout "$TIMEOUT_SHORT" > /dev/null

            log_info "    Waiting for env function build..."
            sleep $BUILD_WAIT_TIME

            result=$(timed_curl -X POST "${FAAS_BASE_URL}/api/${env_path#/}" \
                -H "Content-Type: application/json" \
                -d '{}' \
                --connect-timeout "$TIMEOUT_MEDIUM")

            body=$(echo "$result" | cut -d'|' -f1)
            http_code=$(echo "$result" | cut -d'|' -f2)
            duration=$(echo "$result" | cut -d'|' -f3)

            if [[ "$http_code" == "200" ]] && echo "$body" | grep -q "sec"; then
                record_result "TC-LE03" "Environment Variable Test" "Library" "PASS" "$duration" "api_key_prefix=sec" "Env vars work"
            else
                record_result "TC-LE03" "Environment Variable Test" "Library" "FAIL" "$duration" "api_key_prefix=sec" "HTTP ${http_code}"
            fi
        fi
    fi
}

#===============================================================================
# Error Handling Tests
#===============================================================================
run_error_handling_tests() {
    log_section "8. Error Handling Tests"

    # TC-ERR01: Nonexistent Path
    local result
    result=$(timed_curl -X GET "${FAAS_BASE_URL}/api/nonexistent_path_xyz_${TIMESTAMP}" \
        --connect-timeout "$TIMEOUT_SHORT")

    local http_code=$(echo "$result" | cut -d'|' -f2)
    local duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "404" ]]; then
        record_result "TC-ERR01" "Nonexistent Path Call" "Error" "PASS" "$duration" "HTTP 404" "HTTP ${http_code}"
    else
        record_result "TC-ERR01" "Nonexistent Path Call" "Error" "FAIL" "$duration" "HTTP 404" "HTTP ${http_code}"
    fi

    # TC-ERR02: Wrong HTTP Method (DELETE on a POST-only path or nonexistent path)
    # 배포 여부와 관계없이 테스트: 존재하지 않는 경로에 DELETE 요청 → 404 예상
    local test_path="${CURRENT_DEPLOY_PATH:-/test_wrong_method_${TIMESTAMP}}"
    result=$(timed_curl -X DELETE "${FAAS_BASE_URL}/api/${test_path#/}" \
        --connect-timeout "$TIMEOUT_SHORT")

    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "404" || "$http_code" == "405" ]]; then
        record_result "TC-ERR02" "Wrong HTTP Method" "Error" "PASS" "$duration" "404 or 405" "HTTP ${http_code}"
    else
        record_result "TC-ERR02" "Wrong HTTP Method" "Error" "FAIL" "$duration" "404 or 405" "HTTP ${http_code}"
    fi

    # TC-ERR03: Invalid JSON Request
    result=$(timed_curl -X POST "${FAAS_BASE_URL}/callbacks/" \
        -H "Content-Type: application/json" \
        -d "invalid json {{{{" \
        --connect-timeout "$TIMEOUT_SHORT")

    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "400" || "$http_code" == "422" ]]; then
        record_result "TC-ERR03" "Invalid JSON Request" "Error" "PASS" "$duration" "400 or 422" "HTTP ${http_code}"
    else
        record_result "TC-ERR03" "Invalid JSON Request" "Error" "FAIL" "$duration" "400 or 422" "HTTP ${http_code}"
    fi

    # TC-ERR04: Invalid Deploy Request (nonexistent callback)
    result=$(timed_curl -X POST "${FAAS_BASE_URL}/deploy/" \
        -H "Content-Type: application/json" \
        -d '{"callback_id": 99999, "status": true, "c_type": "docker"}' \
        --connect-timeout "$TIMEOUT_SHORT")

    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "404" ]]; then
        record_result "TC-ERR04" "Invalid Deploy Request" "Error" "PASS" "$duration" "HTTP 404" "HTTP ${http_code}"
    else
        record_result "TC-ERR04" "Invalid Deploy Request" "Error" "FAIL" "$duration" "HTTP 404" "HTTP ${http_code}"
    fi

    # TC-ERR05: Delete Building Callback (should fail)
    # sleep(28)을 사용하는 콜백을 생성하고 배포 시작 직후 삭제 시도
    log_info "TC-ERR05: Creating slow-building callback for delete test..."

    # 1. ChatRoom 생성
    local slow_chatroom_result=$(timed_curl -X POST "${FAAS_BASE_URL}/chatroom/" \
        -H "Content-Type: application/json" \
        -d '{"title": "slow_build_test_room"}' \
        --connect-timeout "$TIMEOUT_SHORT")

    local slow_chatroom_body=$(echo "$slow_chatroom_result" | cut -d'|' -f1)
    local slow_chatroom_id=$(echo "$slow_chatroom_body" | grep -o '"chat_id":[0-9]*' | head -1 | cut -d':' -f2)

    if [[ -z "$slow_chatroom_id" || "$slow_chatroom_id" == "null" ]]; then
        record_result "TC-ERR05" "Delete Building Callback" "Error" "FAIL" "0" "HTTP 400" "ChatRoom creation failed" "Could not create chatroom"
    else
        CREATED_CHATROOMS+=("$slow_chatroom_id")  # cleanup 추적

        # 2. sleep(28)을 포함하는 콜백 생성 (빌드에 28초 이상 소요)
        local slow_build_path="/slow_build_test_${TIMESTAMP}"
        CREATED_CALLBACK_PATHS+=("$slow_build_path")  # Docker 이미지 정리용 추적

        local slow_callback_code='import time
import json

def lambda_handler(event, context):
    time.sleep(28)
    return {"statusCode": 200, "body": json.dumps({"message": "slow build test"})}'

        local encoded_code=$(echo "$slow_callback_code" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
        local slow_callback_result=$(timed_curl -X POST "${FAAS_BASE_URL}/callbacks/" \
            -H "Content-Type: application/json" \
            -d "{\"chat_id\": ${slow_chatroom_id}, \"path\": \"${slow_build_path}\", \"method\": \"GET\", \"type\": \"python\", \"code\": ${encoded_code}}" \
            --connect-timeout "$TIMEOUT_SHORT")

        local slow_callback_body=$(echo "$slow_callback_result" | cut -d'|' -f1)
        local slow_callback_id=$(echo "$slow_callback_body" | grep -o '"callback_id":[0-9]*' | head -1 | cut -d':' -f2)

        if [[ -z "$slow_callback_id" || "$slow_callback_id" == "null" ]]; then
            record_result "TC-ERR05" "Delete Building Callback" "Error" "FAIL" "0" "HTTP 400" "Callback creation failed" "Could not create callback"
        else
            # 3. 배포 시작 (비동기로 실행 - 백그라운드에서)
            log_info "TC-ERR05: Starting deploy in background..."
            curl -s -X POST "${FAAS_BASE_URL}/deploy/" \
                -H "Content-Type: application/json" \
                -d "{\"callback_id\": ${slow_callback_id}, \"status\": true, \"c_type\": \"docker\"}" &
            local deploy_pid=$!

            # 4. 1초 대기 후 삭제 시도 (빌드 중일 때)
            sleep 1

            log_info "TC-ERR05: Attempting to delete callback while building..."
            local delete_result=$(timed_curl -X DELETE "${FAAS_BASE_URL}/callbacks/${slow_callback_id}" \
                --connect-timeout "$TIMEOUT_SHORT")

            local delete_http_code=$(echo "$delete_result" | cut -d'|' -f2)
            local delete_duration=$(echo "$delete_result" | cut -d'|' -f3)
            local delete_body=$(echo "$delete_result" | cut -d'|' -f1)

            # 배포 프로세스 종료 대기 (타임아웃 설정)
            wait $deploy_pid 2>/dev/null || true

            # 5. 결과 검증: 빌드 중 삭제는 HTTP 400이어야 함
            if [[ "$delete_http_code" == "400" ]]; then
                record_result "TC-ERR05" "Delete Building Callback" "Error" "PASS" "$delete_duration" "HTTP 400" "HTTP ${delete_http_code}"
            else
                # 만약 삭제가 성공했다면 (HTTP 200), 빌드가 너무 빨리 완료된 것
                if [[ "$delete_http_code" == "200" ]]; then
                    record_result "TC-ERR05" "Delete Building Callback" "Error" "FAIL" "$delete_duration" "HTTP 400" "HTTP ${delete_http_code}" "Build completed too fast, delete succeeded"
                else
                    record_result "TC-ERR05" "Delete Building Callback" "Error" "FAIL" "$delete_duration" "HTTP 400" "HTTP ${delete_http_code}" "Response: ${delete_body}"
                fi
            fi

            # 정리는 cleanup() 함수에서 CREATED_CHATROOMS를 통해 처리됨
            sleep 2  # 배포 정리를 위해 잠시 대기
        fi
    fi
}

#===============================================================================
# Node.js Runtime Tests
#===============================================================================
run_nodejs_tests() {
    log_section "9. Node.js Runtime Tests"

    local node_chatroom_id=""
    local node_callback_id=""

    # TC-NODE01: Create ChatRoom for Node.js test
    log_info "  Creating ChatRoom for Node.js test..."

    local result
    result=$(timed_curl -X POST "${FAAS_BASE_URL}/chatroom/" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"Node.js Test ${TIMESTAMP}\"}" \
        --connect-timeout "$TIMEOUT_SHORT")

    local body=$(echo "$result" | cut -d'|' -f1)
    local http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" == "200" ]]; then
        node_chatroom_id=$(json_extract_number "$body" "chat_id")
        CREATED_CHATROOMS+=("$node_chatroom_id")
    else
        record_result "TC-NODE01" "Node.js Test Setup" "Node.js" "SKIP" "0" "N/A" "N/A" "Failed to create ChatRoom"
        return
    fi

    # TC-NODE02: Create and Deploy Node.js Callback
    log_info "  Creating and deploying Node.js callback..."

    local node_path="/nodejs_test_${TIMESTAMP}"
    CREATED_CALLBACK_PATHS+=("$node_path")

    local node_code='const handler = async (event) => {
    const body = event.body || {};
    return {
        statusCode: 200,
        body: JSON.stringify({
            message: "Hello from Node.js!",
            runtime: "node",
            received: body,
            timestamp: new Date().toISOString()
        })
    };
};
exports.lambda_handler = handler;'

    local encoded_code=$(echo "$node_code" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/callbacks/" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"${node_path}\", \"method\": \"POST\", \"type\": \"node\", \"code\": ${encoded_code}, \"chat_id\": ${node_chatroom_id}}" \
        --connect-timeout "$TIMEOUT_SHORT")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)
    local duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "200" ]]; then
        node_callback_id=$(json_extract_number "$body" "callback_id")
        local node_type=$(json_extract "$body" "type")

        if [[ "$node_type" == "node" ]]; then
            record_result "TC-NODE02" "Create Node.js Callback" "Node.js" "PASS" "$duration" "type=node" "id=${node_callback_id}"
        else
            record_result "TC-NODE02" "Create Node.js Callback" "Node.js" "FAIL" "$duration" "type=node" "type=${node_type}"
            return
        fi
    else
        record_result "TC-NODE02" "Create Node.js Callback" "Node.js" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
        return
    fi

    # TC-NODE03: Deploy Node.js Callback
    log_info "  Deploying Node.js callback..."

    local deploy_payload="{\"callback_id\": ${node_callback_id}, \"status\": true, \"c_type\": \"docker\"}"
    local build_start=$(get_time_ms)

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/deploy/" \
        -H "Content-Type: application/json" \
        -d "$deploy_payload" \
        --connect-timeout "$TIMEOUT_SHORT")

    http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" == "200" ]]; then
        log_info "    Build started, waiting for completion..."

        local elapsed=0
        local final_status="build"
        local node_build_wait=60  # Node.js 빌드는 더 오래 걸릴 수 있음

        while [[ $elapsed -lt $node_build_wait ]]; do
            sleep 3
            ((elapsed+=3))

            local check
            check=$(curl -s "${FAAS_BASE_URL}/callbacks/${node_callback_id}" --connect-timeout 3)
            final_status=$(json_extract "$check" "status")

            if [[ "$final_status" == "deployed" || "$final_status" == "failed" ]]; then
                break
            fi

            echo -ne "    Building Node.js... ${elapsed}s / ${node_build_wait}s\r"
        done
        echo ""

        local build_time=$(($(get_time_ms) - build_start))

        if [[ "$final_status" == "deployed" ]]; then
            record_result "TC-NODE03" "Deploy Node.js Callback" "Node.js" "PASS" "$build_time" "status=deployed" "built in ${elapsed}s"
        else
            record_result "TC-NODE03" "Deploy Node.js Callback" "Node.js" "FAIL" "$build_time" "status=deployed" "status=${final_status}"
            return
        fi
    else
        record_result "TC-NODE03" "Deploy Node.js Callback" "Node.js" "FAIL" "0" "HTTP 200" "HTTP ${http_code}"
        return
    fi

    # TC-NODE04: Invoke Node.js Function
    log_info "  Invoking Node.js function..."

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/api/${node_path#/}" \
        -H "Content-Type: application/json" \
        -d '{"test": "nodejs_invoke", "value": 123}' \
        --connect-timeout "$TIMEOUT_LONG")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "200" ]]; then
        # Node.js 응답에서 runtime 확인
        if echo "$body" | grep -q "node\|Node"; then
            record_result "TC-NODE04" "Invoke Node.js Function" "Node.js" "PASS" "$duration" "Node.js response" "Response in ${duration}ms"
        else
            record_result "TC-NODE04" "Invoke Node.js Function" "Node.js" "PASS" "$duration" "HTTP 200" "Response received (${duration}ms)"
        fi
    else
        record_result "TC-NODE04" "Invoke Node.js Function" "Node.js" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
    fi
}

#===============================================================================
# Timeout Handling Tests
#===============================================================================
run_timeout_tests() {
    log_section "10. Timeout Handling Tests"

    local timeout_chatroom_id=""
    local timeout_callback_id=""

    # TC-TIMEOUT01: Create ChatRoom for Timeout test
    log_info "  Creating ChatRoom for Timeout test..."

    local result
    result=$(timed_curl -X POST "${FAAS_BASE_URL}/chatroom/" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"Timeout Test ${TIMESTAMP}\"}" \
        --connect-timeout "$TIMEOUT_SHORT")

    local body=$(echo "$result" | cut -d'|' -f1)
    local http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" == "200" ]]; then
        timeout_chatroom_id=$(json_extract_number "$body" "chat_id")
        CREATED_CHATROOMS+=("$timeout_chatroom_id")
    else
        record_result "TC-TIMEOUT01" "Timeout Test Setup" "Timeout" "SKIP" "0" "N/A" "N/A" "Failed to create ChatRoom"
        return
    fi

    # TC-TIMEOUT02: Create Callback that will timeout (sleep 60 seconds)
    log_info "  Creating callback with 60-second sleep (will timeout at 30s)..."

    local timeout_path="/timeout_test_${TIMESTAMP}"
    CREATED_CALLBACK_PATHS+=("$timeout_path")

    local timeout_code='import time
import json

def lambda_handler(event, context):
    # Sleep for 60 seconds - longer than the 30 second timeout
    time.sleep(60)
    return {"statusCode": 200, "body": json.dumps({"message": "This should never be returned"})}'

    local encoded_code=$(echo "$timeout_code" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/callbacks/" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"${timeout_path}\", \"method\": \"POST\", \"type\": \"python\", \"code\": ${encoded_code}, \"chat_id\": ${timeout_chatroom_id}}" \
        --connect-timeout "$TIMEOUT_SHORT")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)
    local duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "200" ]]; then
        timeout_callback_id=$(json_extract_number "$body" "callback_id")
        record_result "TC-TIMEOUT02" "Create Timeout Callback" "Timeout" "PASS" "$duration" "callback created" "id=${timeout_callback_id}"
    else
        record_result "TC-TIMEOUT02" "Create Timeout Callback" "Timeout" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
        return
    fi

    # TC-TIMEOUT03: Deploy Timeout Callback
    log_info "  Deploying timeout callback..."

    local deploy_payload="{\"callback_id\": ${timeout_callback_id}, \"status\": true, \"c_type\": \"docker\"}"

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/deploy/" \
        -H "Content-Type: application/json" \
        -d "$deploy_payload" \
        --connect-timeout "$TIMEOUT_SHORT")

    http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" == "200" ]]; then
        log_info "    Waiting for build completion..."

        local elapsed=0
        local final_status="build"

        while [[ $elapsed -lt $BUILD_WAIT_TIME ]]; do
            sleep 3
            ((elapsed+=3))

            local check
            check=$(curl -s "${FAAS_BASE_URL}/callbacks/${timeout_callback_id}" --connect-timeout 3)
            final_status=$(json_extract "$check" "status")

            if [[ "$final_status" == "deployed" || "$final_status" == "failed" ]]; then
                break
            fi

            echo -ne "    Building... ${elapsed}s / ${BUILD_WAIT_TIME}s\r"
        done
        echo ""

        if [[ "$final_status" == "deployed" ]]; then
            record_result "TC-TIMEOUT03" "Deploy Timeout Callback" "Timeout" "PASS" "0" "status=deployed" "Deployed successfully"
        else
            record_result "TC-TIMEOUT03" "Deploy Timeout Callback" "Timeout" "FAIL" "0" "status=deployed" "status=${final_status}"
            return
        fi
    else
        record_result "TC-TIMEOUT03" "Deploy Timeout Callback" "Timeout" "FAIL" "0" "HTTP 200" "HTTP ${http_code}"
        return
    fi

    # TC-TIMEOUT04: Invoke and verify timeout handling
    log_info "  Invoking callback (expecting timeout after ~30s)..."

    local invoke_start=$(get_time_ms)

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/api/${timeout_path#/}" \
        -H "Content-Type: application/json" \
        -d '{"test": "timeout_test"}' \
        --connect-timeout 45)  # 45초 타임아웃으로 서버의 30초 타임아웃 테스트

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    local invoke_time=$(($(get_time_ms) - invoke_start))

    # 타임아웃 응답 확인:
    # - 응답 시간이 25-40초 사이 (서버의 30초 타임아웃 근처)
    # - 또는 응답에 "timeout" 또는 에러 코드 포함
    if echo "$body" | grep -qi "timeout\|TIMEOUT\|time.out\|Process Time Out"; then
        record_result "TC-TIMEOUT04" "Timeout Response Handling" "Timeout" "PASS" "$duration" "Timeout response" "Timeout detected in ${duration}ms"
    elif [[ "$invoke_time" -ge 25000 && "$invoke_time" -le 45000 ]]; then
        # 약 30초 후 응답 = 타임아웃 처리됨
        record_result "TC-TIMEOUT04" "Timeout Response Handling" "Timeout" "PASS" "$duration" "~30s timeout" "Response after ${invoke_time}ms"
    elif [[ "$http_code" == "200" ]] && echo "$body" | grep -qi "lambda_status_code"; then
        # lambda_status_code가 있으면 타임아웃 처리된 것
        record_result "TC-TIMEOUT04" "Timeout Response Handling" "Timeout" "PASS" "$duration" "Lambda status code" "Timeout handled"
    else
        record_result "TC-TIMEOUT04" "Timeout Response Handling" "Timeout" "FAIL" "$duration" "Timeout response" "HTTP ${http_code}, time=${invoke_time}ms"
    fi
}

#===============================================================================
# Undeploy Tests
#===============================================================================
run_undeploy_tests() {
    log_section "11. Undeploy Tests"

    local undeploy_chatroom_id=""
    local undeploy_callback_id=""
    local undeploy_path="/undeploy_test_${TIMESTAMP}"

    # TC-UNDEPLOY01: Setup - Create and Deploy
    log_info "  Setting up callback for undeploy test..."

    local result
    result=$(timed_curl -X POST "${FAAS_BASE_URL}/chatroom/" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"Undeploy Test ${TIMESTAMP}\"}" \
        --connect-timeout "$TIMEOUT_SHORT")

    local body=$(echo "$result" | cut -d'|' -f1)
    local http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" == "200" ]]; then
        undeploy_chatroom_id=$(json_extract_number "$body" "chat_id")
        CREATED_CHATROOMS+=("$undeploy_chatroom_id")
    else
        record_result "TC-UNDEPLOY01" "Undeploy Test Setup" "Undeploy" "SKIP" "0" "N/A" "N/A" "Failed to create ChatRoom"
        return
    fi

    CREATED_CALLBACK_PATHS+=("$undeploy_path")

    local undeploy_code='import json
def lambda_handler(event, context):
    return {"statusCode": 200, "body": json.dumps({"message": "undeploy test"})}'

    local encoded_code=$(echo "$undeploy_code" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/callbacks/" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"${undeploy_path}\", \"method\": \"POST\", \"type\": \"python\", \"code\": ${encoded_code}, \"chat_id\": ${undeploy_chatroom_id}}" \
        --connect-timeout "$TIMEOUT_SHORT")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" == "200" ]]; then
        undeploy_callback_id=$(json_extract_number "$body" "callback_id")
    else
        record_result "TC-UNDEPLOY01" "Undeploy Test Setup" "Undeploy" "SKIP" "0" "N/A" "N/A" "Failed to create Callback"
        return
    fi

    # Deploy first
    curl -s -X POST "${FAAS_BASE_URL}/deploy/" \
        -H "Content-Type: application/json" \
        -d "{\"callback_id\": ${undeploy_callback_id}, \"status\": true, \"c_type\": \"docker\"}" > /dev/null

    log_info "    Waiting for initial deploy..."
    sleep $BUILD_WAIT_TIME

    # Verify deployed
    local check=$(curl -s "${FAAS_BASE_URL}/callbacks/${undeploy_callback_id}" --connect-timeout 3)
    local status=$(json_extract "$check" "status")

    if [[ "$status" != "deployed" ]]; then
        record_result "TC-UNDEPLOY01" "Undeploy Test Setup" "Undeploy" "SKIP" "0" "status=deployed" "status=${status}" "Initial deploy failed"
        return
    fi

    record_result "TC-UNDEPLOY01" "Undeploy Test Setup" "Undeploy" "PASS" "0" "Deployed" "Ready for undeploy test"

    # TC-UNDEPLOY02: Undeploy (status=false)
    log_info "  Undeploying callback..."

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/deploy/" \
        -H "Content-Type: application/json" \
        -d "{\"callback_id\": ${undeploy_callback_id}, \"status\": false, \"c_type\": \"docker\"}" \
        --connect-timeout "$TIMEOUT_SHORT")

    http_code=$(echo "$result" | cut -d'|' -f2)
    local duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "200" ]]; then
        # Verify status changed to undeployed
        check=$(curl -s "${FAAS_BASE_URL}/callbacks/${undeploy_callback_id}" --connect-timeout 3)
        status=$(json_extract "$check" "status")

        if [[ "$status" == "undeployed" ]]; then
            record_result "TC-UNDEPLOY02" "Undeploy Callback" "Undeploy" "PASS" "$duration" "status=undeployed" "status=${status}"
        else
            record_result "TC-UNDEPLOY02" "Undeploy Callback" "Undeploy" "FAIL" "$duration" "status=undeployed" "status=${status}"
        fi
    else
        record_result "TC-UNDEPLOY02" "Undeploy Callback" "Undeploy" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
    fi

    # TC-UNDEPLOY03: Invoke after undeploy (should fail with 404)
    log_info "  Invoking undeployed callback (expecting 404)..."

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/api/${undeploy_path#/}" \
        -H "Content-Type: application/json" \
        -d '{"test": "after_undeploy"}' \
        --connect-timeout "$TIMEOUT_SHORT")

    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    # Undeploy 후에는 404 또는 405가 반환될 수 있음 (callback_map에서 제거됨)
    if [[ "$http_code" == "404" || "$http_code" == "405" ]]; then
        record_result "TC-UNDEPLOY03" "Invoke After Undeploy" "Undeploy" "PASS" "$duration" "HTTP 404/405" "HTTP ${http_code}"
    else
        record_result "TC-UNDEPLOY03" "Invoke After Undeploy" "Undeploy" "FAIL" "$duration" "HTTP 404/405" "HTTP ${http_code}"
    fi
}

#===============================================================================
# Report Generation
#===============================================================================
generate_reports() {
    log_section "Generating Test Reports"

    mkdir -p "$REPORT_DIR"

    local test_duration=$(($(get_time_ms) - TEST_START_TIME))
    local test_duration_sec=$((test_duration / 1000))
    local pass_rate=0
    [[ $TOTAL_TESTS -gt 0 ]] && pass_rate=$((PASSED_TESTS * 100 / TOTAL_TESTS))

    # Generate JSON Report
    {
        echo "{"
        echo "  \"test_date\": \"$(date '+%Y-%m-%d %H:%M:%S')\","
        echo "  \"tester\": \"QA Engineer\","
        echo "  \"duration_sec\": ${test_duration_sec},"
        echo "  \"summary\": {"
        echo "    \"total\": ${TOTAL_TESTS},"
        echo "    \"passed\": ${PASSED_TESTS},"
        echo "    \"failed\": ${FAILED_TESTS},"
        echo "    \"skipped\": ${SKIPPED_TESTS},"
        echo "    \"pass_rate\": ${pass_rate}"
        echo "  },"
        echo "  \"performance\": {"
        local first_metric=true
        [[ -n "$PERF_health_response_ms" ]] && { $first_metric || echo ","; first_metric=false; echo -n "    \"health_response_ms\": $PERF_health_response_ms"; }
        [[ -n "$PERF_build_time_ms" ]] && { $first_metric || echo ","; first_metric=false; echo -n "    \"build_time_ms\": $PERF_build_time_ms"; }
        [[ -n "$PERF_cold_start_ms" ]] && { $first_metric || echo ","; first_metric=false; echo -n "    \"cold_start_ms\": $PERF_cold_start_ms"; }
        [[ -n "$PERF_warm_call_ms" ]] && { $first_metric || echo ","; first_metric=false; echo -n "    \"warm_call_ms\": $PERF_warm_call_ms"; }
        [[ -n "$PERF_avg_response_ms" ]] && { $first_metric || echo ","; first_metric=false; echo -n "    \"avg_response_ms\": $PERF_avg_response_ms"; }
        echo ""
        echo "  },"
        echo "  \"results\": ["
        printf '%s\n' "${TEST_RESULTS[@]}" | sed 's/$/,/' | sed '$ s/,$//'
        echo "  ],"
        echo "  \"issues\": ["
        printf '%s\n' "${ISSUES[@]}" | sed 's/$/,/' | sed '$ s/,$//'
        echo "  ]"
        echo "}"
    } > "$JSON_REPORT"

    # Generate Markdown Report
    {
        echo "# FaaS Control Plane Test Report"
        echo ""
        echo "**Test Date:** $(date '+%Y-%m-%d %H:%M:%S')"
        echo "**Duration:** ${test_duration_sec}s"
        echo "**Target:** ${FAAS_BASE_URL}"
        echo ""
        echo "## Service Flow Tested"
        echo ""
        echo "\`\`\`"
        echo "ChatRoom (생성) → Callback (생성/연결) → Deploy → API 호출 → ChatRoom (삭제) → Callback (연쇄 삭제)"
        echo "\`\`\`"
        echo ""
        echo "## Summary"
        echo ""
        echo "| Metric | Value |"
        echo "|--------|-------|"
        echo "| Total Tests | ${TOTAL_TESTS} |"
        echo "| Passed | ${PASSED_TESTS} |"
        echo "| Failed | ${FAILED_TESTS} |"
        echo "| Skipped | ${SKIPPED_TESTS} |"
        echo "| **Pass Rate** | **${pass_rate}%** |"
        echo ""
        echo "## Performance Metrics"
        echo ""
        echo "| Metric | Value |"
        echo "|--------|-------|"
        [[ -n "$PERF_cold_start_ms" ]] && echo "| Cold Start | ${PERF_cold_start_ms}ms |"
        [[ -n "$PERF_warm_call_ms" ]] && echo "| Warm Call | ${PERF_warm_call_ms}ms |"
        [[ -n "$PERF_avg_response_ms" ]] && echo "| Avg Response | ${PERF_avg_response_ms}ms |"
        [[ -n "$PERF_build_time_ms" ]] && echo "| Build Time | $((PERF_build_time_ms/1000))s |"
        [[ -n "$PERF_health_response_ms" ]] && echo "| Health Check | ${PERF_health_response_ms}ms |"
        echo ""

        if [[ ${#ISSUES[@]} -gt 0 ]]; then
            echo "## Issues Found"
            echo ""
            echo "| Severity | Title | Description |"
            echo "|----------|-------|-------------|"
            for issue in "${ISSUES[@]}"; do
                local severity=$(echo "$issue" | grep -o '"severity":"[^"]*"' | cut -d'"' -f4)
                local title=$(echo "$issue" | grep -o '"title":"[^"]*"' | cut -d'"' -f4)
                local desc=$(echo "$issue" | grep -o '"description":"[^"]*"' | cut -d'"' -f4)
                echo "| ${severity} | ${title} | ${desc} |"
            done
            echo ""
        fi

        echo "## Test Results by Category"
        echo ""
        echo "| ID | Name | Category | Status | Duration |"
        echo "|----|------|----------|--------|----------|"
        for result in "${TEST_RESULTS[@]}"; do
            local id=$(echo "$result" | grep -o '"test_id":"[^"]*"' | cut -d'"' -f4)
            local name=$(echo "$result" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
            local category=$(echo "$result" | grep -o '"category":"[^"]*"' | cut -d'"' -f4)
            local status=$(echo "$result" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
            local dur=$(echo "$result" | grep -o '"duration_ms":[0-9]*' | cut -d':' -f2)

            local status_icon="⏭️"
            [[ "$status" == "PASS" ]] && status_icon="✅"
            [[ "$status" == "FAIL" ]] && status_icon="❌"

            echo "| ${id} | ${name} | ${category} | ${status_icon} | ${dur}ms |"
        done
    } > "$REPORT_FILE"

    log_success "JSON report: ${JSON_REPORT}"
    log_success "Markdown report: ${REPORT_FILE}"
}

print_summary() {
    local test_duration=$(($(get_time_ms) - TEST_START_TIME))
    local test_duration_sec=$((test_duration / 1000))
    local pass_rate=0
    [[ $TOTAL_TESTS -gt 0 ]] && pass_rate=$((PASSED_TESTS * 100 / TOTAL_TESTS))

    echo ""
    log_section "TEST EXECUTION SUMMARY"

    echo -e "${BOLD}Service Flow:${NC}"
    echo "  ChatRoom → Callback → Deploy → Invoke → Cascade Delete"
    echo ""

    echo -e "${BOLD}Environment:${NC}"
    echo "  Target URL: ${FAAS_BASE_URL}"
    echo "  Platform: $(uname -s) $(uname -r)"
    echo "  Test Date: $(date '+%Y-%m-%d %H:%M:%S')"

    echo ""
    echo -e "${BOLD}Results:${NC}"
    echo "  Total Tests: ${TOTAL_TESTS}"
    echo -e "  ${GREEN}Passed: ${PASSED_TESTS}${NC}"
    echo -e "  ${RED}Failed: ${FAILED_TESTS}${NC}"
    echo -e "  ${YELLOW}Skipped: ${SKIPPED_TESTS}${NC}"
    echo "  Duration: ${test_duration_sec}s"

    if [[ $pass_rate -ge 80 ]]; then
        echo -e "\n  ${GREEN}${BOLD}Pass Rate: ${pass_rate}%${NC}"
    elif [[ $pass_rate -ge 60 ]]; then
        echo -e "\n  ${YELLOW}${BOLD}Pass Rate: ${pass_rate}%${NC}"
    else
        echo -e "\n  ${RED}${BOLD}Pass Rate: ${pass_rate}%${NC}"
    fi

    echo ""
    echo -e "${BOLD}Performance Metrics:${NC}"
    [[ -n "$PERF_cold_start_ms" ]] && echo "  Cold Start: ${PERF_cold_start_ms}ms"
    [[ -n "$PERF_warm_call_ms" ]] && echo "  Warm Call: ${PERF_warm_call_ms}ms"
    [[ -n "$PERF_avg_response_ms" ]] && echo "  Avg Response: ${PERF_avg_response_ms}ms"
    [[ -n "$PERF_build_time_ms" ]] && echo "  Build Time: $((PERF_build_time_ms/1000))s"

    if [[ ${#ISSUES[@]} -gt 0 ]]; then
        echo ""
        echo -e "${BOLD}${RED}Issues Found (${#ISSUES[@]}):${NC}"
        for issue in "${ISSUES[@]}"; do
            local severity=$(echo "$issue" | grep -o '"severity":"[^"]*"' | cut -d'"' -f4)
            local title=$(echo "$issue" | grep -o '"title":"[^"]*"' | cut -d'"' -f4)
            echo -e "  ${YELLOW}[${severity}]${NC} ${title}"
        done
    fi
}

#===============================================================================
# Help & Usage
#===============================================================================
print_help() {
    cat << EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

FaaS Control Plane Integration Test Suite
Tests the complete service flow: ChatRoom → Callback → Deploy → Invoke

Options:
  -h, --help              Show this help message
  -u, --url URL           Set base URL (default: http://localhost:8000)
  -q, --quick             Run quick smoke tests only
  -f, --full              Run full tests including library tests (takes longer)
  --skip-docker           Skip Docker deployment tests
  --skip-cleanup          Don't cleanup test resources after completion
  -v, --verbose           Enable verbose output

Service Flow:
  1. ChatRoom 생성
  2. Callback 생성 (chat_id로 ChatRoom에 연결)
  3. Deploy (Docker 이미지 빌드)
  4. API 호출 테스트
  5. ChatRoom 삭제 시 연결된 Callback도 함께 삭제

Examples:
  ${SCRIPT_NAME}                          # Run standard tests
  ${SCRIPT_NAME} -q                       # Quick smoke test
  ${SCRIPT_NAME} -f                       # Full test suite
  ${SCRIPT_NAME} -u http://staging:8000   # Test staging server
  ${SCRIPT_NAME} --skip-docker            # Skip Docker tests

Report files are saved to: ${REPORT_DIR}/
EOF
}

#===============================================================================
# Quick Smoke Test
#===============================================================================
run_quick_test() {
    log_section "Quick Smoke Test"

    echo -n "  Health check: "
    if curl -s --connect-timeout 3 "${FAAS_BASE_URL}/health" | grep -q "healthy"; then
        echo -e "${GREEN}PASS${NC}"
    else
        echo -e "${RED}FAIL${NC}"
        return 1
    fi

    echo -n "  List chatrooms: "
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "${FAAS_BASE_URL}/chatroom/" --connect-timeout 3)
    if [[ "$http_code" == "200" ]]; then
        echo -e "${GREEN}PASS${NC}"
    else
        echo -e "${RED}FAIL (HTTP ${http_code})${NC}"
        return 1
    fi

    echo -n "  List callbacks: "
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "${FAAS_BASE_URL}/callbacks/" --connect-timeout 3)
    if [[ "$http_code" == "200" ]]; then
        echo -e "${GREEN}PASS${NC}"
    else
        echo -e "${RED}FAIL (HTTP ${http_code})${NC}"
        return 1
    fi

    # Service flow quick test
    echo -n "  Service flow (ChatRoom→Callback): "

    # Create chatroom
    local chat_response
    chat_response=$(curl -s -X POST "${FAAS_BASE_URL}/chatroom/" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"Quick Test ${TIMESTAMP}\"}" \
        --connect-timeout 5)

    if echo "$chat_response" | grep -q "chat_id"; then
        local chat_id
        chat_id=$(echo "$chat_response" | grep -o '"chat_id"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*$')

        # Create callback with chat_id
        local cb_response
        cb_response=$(curl -s -X POST "${FAAS_BASE_URL}/callbacks/" \
            -H "Content-Type: application/json" \
            -d "{\"path\": \"quick_${TIMESTAMP}\", \"method\": \"POST\", \"type\": \"python\", \"code\": \"def lambda_handler(e, c): return {\\\"statusCode\\\": 200}\", \"chat_id\": ${chat_id}}" \
            --connect-timeout 5)

        if echo "$cb_response" | grep -q "callback_id"; then
            echo -e "${GREEN}PASS${NC}"
            # Cleanup via ChatRoom (will cascade delete callback)
            curl -s -X DELETE "${FAAS_BASE_URL}/chatroom/${chat_id}" --connect-timeout 3 > /dev/null
        else
            echo -e "${RED}FAIL (Callback creation)${NC}"
            curl -s -X DELETE "${FAAS_BASE_URL}/chatroom/${chat_id}" --connect-timeout 3 > /dev/null
            return 1
        fi
    else
        echo -e "${RED}FAIL (ChatRoom creation)${NC}"
        return 1
    fi

    echo ""
    echo -e "${GREEN}${BOLD}Quick smoke test passed!${NC}"
    return 0
}

#===============================================================================
# Main
#===============================================================================
main() {
    local run_quick=false
    local run_full=false
    local skip_docker=false
    local skip_cleanup=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                print_help
                exit 0
                ;;
            -u|--url)
                FAAS_BASE_URL="$2"
                shift 2
                ;;
            -q|--quick)
                run_quick=true
                shift
                ;;
            -f|--full)
                run_full=true
                shift
                ;;
            --skip-docker)
                skip_docker=true
                shift
                ;;
            --skip-cleanup)
                skip_cleanup=true
                shift
                ;;
            -v|--verbose)
                set -x
                shift
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                print_help
                exit 1
                ;;
        esac
    done

    print_banner

    log_info "Target URL: ${FAAS_BASE_URL}"
    log_info "Timestamp: ${TIMESTAMP}"
    echo ""

    # Quick test mode
    if [[ "$run_quick" == true ]]; then
        run_quick_test
        exit $?
    fi

    TEST_START_TIME=$(get_time_ms)

    # Run test suites
    run_environment_tests
    run_health_tests

    # Check if server is responding
    local server_ok=false
    for result in "${TEST_RESULTS[@]}"; do
        if echo "$result" | grep -q '"test_id":"TC-L01"' && echo "$result" | grep -q '"status":"PASS"'; then
            server_ok=true
            break
        fi
    done

    if [[ "$server_ok" == true ]]; then
        # ChatRoom CRUD (서비스의 시작점)
        run_chatroom_tests

        # Service Flow Test (ChatRoom → Callback → Deploy → Invoke)
        if [[ "$skip_docker" != true ]]; then
            run_service_flow_tests
        else
            log_warning "Skipping Docker/Service flow tests (--skip-docker)"
        fi

        # Callback CRUD Tests
        run_callback_crud_tests

        # Cascade Delete Test (서비스 플로우 핵심)
        run_cascade_delete_test

        # Library & Env Tests (optional, takes time)
        if [[ "$run_full" == true ]]; then
            run_library_env_tests
        else
            log_info "Skipping library tests (use -f for full tests)"
        fi

        # Error Handling Tests
        run_error_handling_tests

        # Node.js Runtime Tests (full mode only)
        if [[ "$run_full" == true ]] && [[ "$skip_docker" != true ]]; then
            run_nodejs_tests
        else
            log_info "Skipping Node.js tests (use -f for full tests)"
        fi

        # Timeout Tests (full mode only - takes ~30s)
        if [[ "$run_full" == true ]] && [[ "$skip_docker" != true ]]; then
            run_timeout_tests
        else
            log_info "Skipping Timeout tests (use -f for full tests)"
        fi

        # Undeploy Tests (full mode only)
        if [[ "$run_full" == true ]] && [[ "$skip_docker" != true ]]; then
            run_undeploy_tests
        else
            log_info "Skipping Undeploy tests (use -f for full tests)"
        fi
    else
        log_error "Server not responding. Skipping remaining tests."
    fi

    # Generate reports
    generate_reports

    # Print summary
    print_summary

    # Cleanup (unless skipped)
    if [[ "$skip_cleanup" != true ]]; then
        cleanup
    fi

    # Exit code
    [[ $FAILED_TESTS -eq 0 ]]
}

main "$@"
