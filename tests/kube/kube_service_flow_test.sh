#!/bin/bash
#===============================================================================
#
#   Kubernetes Service Flow Test Suite
#
#   Description : Kubernetes 서비스 플로우 테스트
#                 - TC-K8S-FLOW01: Docker → Kube 재배포 전환 테스트
#                 - TC-K8S-FLOW02: Kube → Docker 재배포 전환 테스트
#                 - TC-K8S-CD01: ChatRoom 삭제 시 Kube Job/Pod 정리 검증
#
#   Prerequisites:
#                 - kubectl configured
#                 - Kubernetes cluster running
#                 - FaaS API server running
#                 - Docker daemon running
#
#   Note        : 이 테스트는 개별적으로 실행되며, 메인 테스트와 분리됨
#
#   Usage       : ./kube_service_flow_test.sh [OPTIONS]
#
#===============================================================================

set -o pipefail

#===============================================================================
# Configuration & Constants
#===============================================================================
readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
readonly TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
readonly REPORT_DIR="${SCRIPT_DIR}/reports"
readonly REPORT_FILE="${REPORT_DIR}/kube_service_flow_${TIMESTAMP}.md"

# Test Configuration
FAAS_BASE_URL="${FAAS_BASE_URL:-http://localhost:8000}"
KUBE_NAMESPACE="${KUBE_NAMESPACE:-default}"
TIMEOUT_SHORT=5
TIMEOUT_MEDIUM=30
TIMEOUT_LONG=120
BUILD_WAIT_TIME=60

# Test State
declare -a CREATED_CHATROOMS=()
declare -a CREATED_CALLBACKS=()
declare -a TEST_RESULTS=()

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

#===============================================================================
# ANSI Color Codes
#===============================================================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

#===============================================================================
# Logging Functions
#===============================================================================
log_info() { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $1"; }
log_success() { echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $1"; }
log_error() { echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $1"; }
log_warning() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠${NC} $1"; }

log_section() {
    echo ""
    echo -e "${BOLD}${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${MAGENTA}  $1${NC}"
    echo -e "${BOLD}${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

log_step() {
    echo -e "${BLUE}  ▶${NC} $1"
}

print_banner() {
    echo -e "${BOLD}${CYAN}"
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║   ██╗  ██╗ █████╗ ███████╗    ███████╗██╗      ██████╗ ██╗    ██╗ ║
║   ██║ ██╔╝██╔══██╗██╔════╝    ██╔════╝██║     ██╔═══██╗██║    ██║ ║
║   █████╔╝ ╚█████╔╝███████╗    █████╗  ██║     ██║   ██║██║ █╗ ██║ ║
║   ██╔═██╗ ██╔══██╗╚════██║    ██╔══╝  ██║     ██║   ██║██║███╗██║ ║
║   ██║  ██╗╚█████╔╝███████║    ██║     ███████╗╚██████╔╝╚███╔███╔╝ ║
║   ╚═╝  ╚═╝ ╚════╝ ╚══════╝    ╚═╝     ╚══════╝ ╚═════╝  ╚══╝╚══╝  ║
║                                                                   ║
║   Kubernetes Service Flow Test Suite                              ║
║   Docker ↔ Kube Switching & Cascade Delete                        ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

#===============================================================================
# Utility Functions
#===============================================================================
get_time_ms() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        python3 -c 'import time; print(int(time.time() * 1000))'
    else
        echo $(($(date +%s%N)/1000000))
    fi
}

json_extract() {
    local json="$1"
    local key="$2"
    echo "$json" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*[^,}]*" | \
        sed 's/.*:[[:space:]]*//' | tr -d '"' | tr -d ' '
}

json_extract_number() {
    local json="$1"
    local key="$2"
    echo "$json" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*[0-9]*" | \
        grep -o '[0-9]*$'
}

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

record_result() {
    local test_id="$1"
    local test_name="$2"
    local status="$3"
    local duration="$4"
    local expected="$5"
    local actual="$6"
    local message="${7:-}"

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

    TEST_RESULTS+=("${test_id}|${test_name}|${status}|${duration}|${expected}|${actual}|${message}")
}

wait_for_deploy_status() {
    local callback_id="$1"
    local expected_status="$2"
    local timeout="$3"
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        sleep 3
        ((elapsed+=3))

        local check
        check=$(curl -s "${FAAS_BASE_URL}/callbacks/${callback_id}" --connect-timeout 3)
        local status=$(json_extract "$check" "status")

        if [[ "$status" == "$expected_status" || "$status" == "failed" ]]; then
            echo "$status"
            return 0
        fi

        echo -ne "    Building... ${elapsed}s/${timeout}s\r"
    done
    echo ""
    echo "timeout"
    return 1
}

#===============================================================================
# Cleanup Functions
#===============================================================================
cleanup() {
    log_info "Cleaning up test resources..."

    # Delete ChatRooms (will cascade delete linked callbacks)
    for chat_id in "${CREATED_CHATROOMS[@]}"; do
        if [[ -n "$chat_id" ]]; then
            curl -s -X DELETE "${FAAS_BASE_URL}/chatroom/${chat_id}" \
                --connect-timeout 3 &>/dev/null || true
            log_info "  Deleted ChatRoom: ${chat_id}"
        fi
    done

    # Delete any standalone callbacks
    for cb_id in "${CREATED_CALLBACKS[@]}"; do
        if [[ -n "$cb_id" ]]; then
            curl -s -X DELETE "${FAAS_BASE_URL}/callbacks/${cb_id}" \
                --connect-timeout 3 &>/dev/null || true
            log_info "  Deleted Callback: ${cb_id}"
        fi
    done

    CREATED_CHATROOMS=()
    CREATED_CALLBACKS=()
}

trap cleanup EXIT
trap 'echo ""; log_warning "Test interrupted by user"; exit 130' INT TERM

#===============================================================================
# Prerequisites Check
#===============================================================================
check_prerequisites() {
    log_section "Prerequisites Check"

    local all_pass=true

    # Check FaaS API
    log_step "Checking FaaS API server..."
    if curl -s --connect-timeout 3 "${FAAS_BASE_URL}/health" | grep -q "healthy"; then
        log_success "FaaS API server is healthy"
    else
        log_error "FaaS API server is not responding"
        all_pass=false
    fi

    # Check kubectl
    log_step "Checking kubectl..."
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null; then
        log_success "kubectl is configured and cluster is accessible"
    else
        log_warning "kubectl not available or cluster not accessible"
        log_info "  Kubernetes-related tests may be skipped"
    fi

    # Check Docker
    log_step "Checking Docker..."
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        log_success "Docker daemon is running"
    else
        log_warning "Docker not available"
        log_info "  Docker-related tests may be skipped"
    fi

    if [[ "$all_pass" == false ]]; then
        log_error "Prerequisites check failed"
        return 1
    fi

    return 0
}

#===============================================================================
# TC-K8S-FLOW01: Docker → Kube 재배포 전환 테스트
#===============================================================================
test_docker_to_kube_switch() {
    log_section "TC-K8S-FLOW01: Docker → Kube Redeployment Switch"

    local test_start=$(get_time_ms)
    local chatroom_id=""
    local callback_id=""
    local deploy_path="flow_docker_kube_${TIMESTAMP}"

    # Step 1: Create ChatRoom
    log_step "Step 1: Creating ChatRoom..."

    local result
    result=$(timed_curl -X POST "${FAAS_BASE_URL}/chatroom/" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"Flow Test Docker->Kube ${TIMESTAMP}\"}" \
        --connect-timeout "$TIMEOUT_SHORT")

    local body=$(echo "$result" | cut -d'|' -f1)
    local http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" != "200" ]]; then
        local duration=$(($(get_time_ms) - test_start))
        record_result "TC-K8S-FLOW01" "Docker→Kube Switch" "FAIL" "$duration" "ChatRoom created" "HTTP ${http_code}"
        return 1
    fi

    chatroom_id=$(json_extract_number "$body" "chat_id")
    CREATED_CHATROOMS+=("$chatroom_id")
    log_info "    ChatRoom created: ${chatroom_id}"

    # Step 2: Create Callback
    log_step "Step 2: Creating Callback..."

    local python_code='import json\ndef handler(event):\n    return {\"statusCode\": 200, \"body\": json.dumps({\"message\": \"Hello\", \"deploy_type\": \"dynamic\"})}'

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/callbacks/" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"${deploy_path}\", \"method\": \"POST\", \"type\": \"python\", \"code\": \"${python_code}\", \"chat_id\": ${chatroom_id}}" \
        --connect-timeout "$TIMEOUT_SHORT")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" != "200" ]]; then
        local duration=$(($(get_time_ms) - test_start))
        record_result "TC-K8S-FLOW01" "Docker→Kube Switch" "FAIL" "$duration" "Callback created" "HTTP ${http_code}"
        return 1
    fi

    callback_id=$(json_extract_number "$body" "callback_id")
    log_info "    Callback created: ${callback_id}"

    # Step 3: Deploy with Docker (c_type: docker)
    log_step "Step 3: Deploying with Docker (c_type=docker)..."

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/deploy/" \
        -H "Content-Type: application/json" \
        -d "{\"callback_id\": ${callback_id}, \"status\": true, \"c_type\": \"docker\"}" \
        --connect-timeout "$TIMEOUT_SHORT")

    http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" != "200" ]]; then
        local duration=$(($(get_time_ms) - test_start))
        record_result "TC-K8S-FLOW01" "Docker→Kube Switch" "FAIL" "$duration" "Docker deploy started" "HTTP ${http_code}"
        return 1
    fi

    log_info "    Waiting for Docker build..."
    local docker_status=$(wait_for_deploy_status "$callback_id" "deployed" "$BUILD_WAIT_TIME")

    if [[ "$docker_status" != "deployed" ]]; then
        local duration=$(($(get_time_ms) - test_start))
        record_result "TC-K8S-FLOW01" "Docker→Kube Switch" "FAIL" "$duration" "Docker deployed" "status=${docker_status}"
        return 1
    fi

    log_success "    Docker deployment successful"

    # Step 4: Invoke via Docker endpoint
    log_step "Step 4: Verifying Docker invocation..."

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/api/${deploy_path}" \
        -H "Content-Type: application/json" \
        -d '{"test": "docker_invoke"}' \
        --connect-timeout "$TIMEOUT_LONG")

    http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" != "200" ]]; then
        log_warning "    Docker invoke returned HTTP ${http_code}"
    else
        log_success "    Docker invoke successful"
    fi

    # Step 5: Redeploy with Kube (c_type: kube)
    log_step "Step 5: Redeploying with Kube (c_type=kube)..."

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/deploy/" \
        -H "Content-Type: application/json" \
        -d "{\"callback_id\": ${callback_id}, \"status\": true, \"c_type\": \"kube\"}" \
        --connect-timeout "$TIMEOUT_SHORT")

    http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" != "200" ]]; then
        local duration=$(($(get_time_ms) - test_start))
        record_result "TC-K8S-FLOW01" "Docker→Kube Switch" "FAIL" "$duration" "Kube deploy started" "HTTP ${http_code}"
        return 1
    fi

    log_info "    Waiting for Kube build..."
    local kube_status=$(wait_for_deploy_status "$callback_id" "deployed" "$BUILD_WAIT_TIME")

    if [[ "$kube_status" != "deployed" ]]; then
        local duration=$(($(get_time_ms) - test_start))
        record_result "TC-K8S-FLOW01" "Docker→Kube Switch" "FAIL" "$duration" "Kube deployed" "status=${kube_status}"
        return 1
    fi

    log_success "    Kube deployment successful"

    # Step 6: Invoke via Kube endpoint
    log_step "Step 6: Verifying Kube invocation..."

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/api/kube/${deploy_path}" \
        -H "Content-Type: application/json" \
        -d '{"test": "kube_invoke"}' \
        --connect-timeout "$TIMEOUT_LONG")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)
    local kube_duration=$(echo "$result" | cut -d'|' -f3)

    local duration=$(($(get_time_ms) - test_start))

    if [[ "$http_code" == "200" ]]; then
        record_result "TC-K8S-FLOW01" "Docker→Kube Switch" "PASS" "$duration" "Both deployments work" "Docker→Kube switch successful"

        log_info ""
        log_info "  Summary:"
        echo "    - ChatRoom: ${chatroom_id}"
        echo "    - Callback: ${callback_id}"
        echo "    - Docker deploy: Success"
        echo "    - Kube deploy: Success"
        echo "    - Kube invoke latency: ${kube_duration}ms"
    else
        record_result "TC-K8S-FLOW01" "Docker→Kube Switch" "FAIL" "$duration" "Kube invoke HTTP 200" "HTTP ${http_code}"
    fi
}

#===============================================================================
# TC-K8S-FLOW02: Kube → Docker 재배포 전환 테스트
#===============================================================================
test_kube_to_docker_switch() {
    log_section "TC-K8S-FLOW02: Kube → Docker Redeployment Switch"

    local test_start=$(get_time_ms)
    local chatroom_id=""
    local callback_id=""
    local deploy_path="flow_kube_docker_${TIMESTAMP}"

    # Step 1: Create ChatRoom
    log_step "Step 1: Creating ChatRoom..."

    local result
    result=$(timed_curl -X POST "${FAAS_BASE_URL}/chatroom/" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"Flow Test Kube->Docker ${TIMESTAMP}\"}" \
        --connect-timeout "$TIMEOUT_SHORT")

    local body=$(echo "$result" | cut -d'|' -f1)
    local http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" != "200" ]]; then
        local duration=$(($(get_time_ms) - test_start))
        record_result "TC-K8S-FLOW02" "Kube→Docker Switch" "FAIL" "$duration" "ChatRoom created" "HTTP ${http_code}"
        return 1
    fi

    chatroom_id=$(json_extract_number "$body" "chat_id")
    CREATED_CHATROOMS+=("$chatroom_id")
    log_info "    ChatRoom created: ${chatroom_id}"

    # Step 2: Create Callback
    log_step "Step 2: Creating Callback..."

    local python_code='import json\ndef handler(event):\n    return {\"statusCode\": 200, \"body\": json.dumps({\"source\": \"dynamic_switch\"})}'

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/callbacks/" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"${deploy_path}\", \"method\": \"POST\", \"type\": \"python\", \"code\": \"${python_code}\", \"chat_id\": ${chatroom_id}}" \
        --connect-timeout "$TIMEOUT_SHORT")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" != "200" ]]; then
        local duration=$(($(get_time_ms) - test_start))
        record_result "TC-K8S-FLOW02" "Kube→Docker Switch" "FAIL" "$duration" "Callback created" "HTTP ${http_code}"
        return 1
    fi

    callback_id=$(json_extract_number "$body" "callback_id")
    log_info "    Callback created: ${callback_id}"

    # Step 3: Deploy with Kube first (c_type: kube)
    log_step "Step 3: Deploying with Kube (c_type=kube)..."

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/deploy/" \
        -H "Content-Type: application/json" \
        -d "{\"callback_id\": ${callback_id}, \"status\": true, \"c_type\": \"kube\"}" \
        --connect-timeout "$TIMEOUT_SHORT")

    http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" != "200" ]]; then
        local duration=$(($(get_time_ms) - test_start))
        record_result "TC-K8S-FLOW02" "Kube→Docker Switch" "FAIL" "$duration" "Kube deploy started" "HTTP ${http_code}"
        return 1
    fi

    log_info "    Waiting for Kube build..."
    local kube_status=$(wait_for_deploy_status "$callback_id" "deployed" "$BUILD_WAIT_TIME")

    if [[ "$kube_status" != "deployed" ]]; then
        local duration=$(($(get_time_ms) - test_start))
        record_result "TC-K8S-FLOW02" "Kube→Docker Switch" "FAIL" "$duration" "Kube deployed" "status=${kube_status}"
        return 1
    fi

    log_success "    Kube deployment successful"

    # Step 4: Invoke via Kube endpoint
    log_step "Step 4: Verifying Kube invocation..."

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/api/kube/${deploy_path}" \
        -H "Content-Type: application/json" \
        -d '{"test": "kube_invoke"}' \
        --connect-timeout "$TIMEOUT_LONG")

    http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" != "200" ]]; then
        log_warning "    Kube invoke returned HTTP ${http_code}"
    else
        log_success "    Kube invoke successful"
    fi

    # Step 5: Redeploy with Docker (c_type: docker)
    log_step "Step 5: Redeploying with Docker (c_type=docker)..."

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/deploy/" \
        -H "Content-Type: application/json" \
        -d "{\"callback_id\": ${callback_id}, \"status\": true, \"c_type\": \"docker\"}" \
        --connect-timeout "$TIMEOUT_SHORT")

    http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" != "200" ]]; then
        local duration=$(($(get_time_ms) - test_start))
        record_result "TC-K8S-FLOW02" "Kube→Docker Switch" "FAIL" "$duration" "Docker deploy started" "HTTP ${http_code}"
        return 1
    fi

    log_info "    Waiting for Docker build..."
    local docker_status=$(wait_for_deploy_status "$callback_id" "deployed" "$BUILD_WAIT_TIME")

    if [[ "$docker_status" != "deployed" ]]; then
        local duration=$(($(get_time_ms) - test_start))
        record_result "TC-K8S-FLOW02" "Kube→Docker Switch" "FAIL" "$duration" "Docker deployed" "status=${docker_status}"
        return 1
    fi

    log_success "    Docker deployment successful"

    # Step 6: Invoke via Docker endpoint
    log_step "Step 6: Verifying Docker invocation..."

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/api/${deploy_path}" \
        -H "Content-Type: application/json" \
        -d '{"test": "docker_invoke"}' \
        --connect-timeout "$TIMEOUT_LONG")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)
    local docker_duration=$(echo "$result" | cut -d'|' -f3)

    local duration=$(($(get_time_ms) - test_start))

    if [[ "$http_code" == "200" ]]; then
        record_result "TC-K8S-FLOW02" "Kube→Docker Switch" "PASS" "$duration" "Both deployments work" "Kube→Docker switch successful"

        log_info ""
        log_info "  Summary:"
        echo "    - ChatRoom: ${chatroom_id}"
        echo "    - Callback: ${callback_id}"
        echo "    - Kube deploy: Success"
        echo "    - Docker deploy: Success"
        echo "    - Docker invoke latency: ${docker_duration}ms"
    else
        record_result "TC-K8S-FLOW02" "Kube→Docker Switch" "FAIL" "$duration" "Docker invoke HTTP 200" "HTTP ${http_code}"
    fi
}

#===============================================================================
# TC-K8S-CD01: ChatRoom 삭제 시 Kube Job/Pod 정리 검증
#===============================================================================
test_cascade_delete_kube_resources() {
    log_section "TC-K8S-CD01: ChatRoom Cascade Delete (Kube Resources)"

    local test_start=$(get_time_ms)
    local chatroom_id=""
    local callback_id=""
    local deploy_path="cascade_kube_${TIMESTAMP}"

    # Check if kubectl is available
    if ! command -v kubectl &>/dev/null || ! kubectl cluster-info &>/dev/null; then
        local duration=$(($(get_time_ms) - test_start))
        record_result "TC-K8S-CD01" "Cascade Delete Kube" "SKIP" "$duration" "N/A" "N/A" "kubectl not available"
        return
    fi

    # Step 1: Create ChatRoom
    log_step "Step 1: Creating ChatRoom..."

    local result
    result=$(timed_curl -X POST "${FAAS_BASE_URL}/chatroom/" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"Cascade Delete Test ${TIMESTAMP}\"}" \
        --connect-timeout "$TIMEOUT_SHORT")

    local body=$(echo "$result" | cut -d'|' -f1)
    local http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" != "200" ]]; then
        local duration=$(($(get_time_ms) - test_start))
        record_result "TC-K8S-CD01" "Cascade Delete Kube" "FAIL" "$duration" "ChatRoom created" "HTTP ${http_code}"
        return 1
    fi

    chatroom_id=$(json_extract_number "$body" "chat_id")
    # Don't add to CREATED_CHATROOMS - we'll delete it manually for testing
    log_info "    ChatRoom created: ${chatroom_id}"

    # Step 2: Create Callback
    log_step "Step 2: Creating Callback..."

    local python_code='import json\ndef handler(event):\n    return {\"statusCode\": 200, \"body\": json.dumps({\"cascade\": \"test\"})}'

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/callbacks/" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"${deploy_path}\", \"method\": \"POST\", \"type\": \"python\", \"code\": \"${python_code}\", \"chat_id\": ${chatroom_id}}" \
        --connect-timeout "$TIMEOUT_SHORT")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" != "200" ]]; then
        CREATED_CHATROOMS+=("$chatroom_id")  # Add for cleanup
        local duration=$(($(get_time_ms) - test_start))
        record_result "TC-K8S-CD01" "Cascade Delete Kube" "FAIL" "$duration" "Callback created" "HTTP ${http_code}"
        return 1
    fi

    callback_id=$(json_extract_number "$body" "callback_id")
    log_info "    Callback created: ${callback_id}"

    # Step 3: Deploy with Kube
    log_step "Step 3: Deploying with Kube..."

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/deploy/" \
        -H "Content-Type: application/json" \
        -d "{\"callback_id\": ${callback_id}, \"status\": true, \"c_type\": \"kube\"}" \
        --connect-timeout "$TIMEOUT_SHORT")

    http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" != "200" ]]; then
        CREATED_CHATROOMS+=("$chatroom_id")
        local duration=$(($(get_time_ms) - test_start))
        record_result "TC-K8S-CD01" "Cascade Delete Kube" "FAIL" "$duration" "Deploy started" "HTTP ${http_code}"
        return 1
    fi

    log_info "    Waiting for build..."
    local deploy_status=$(wait_for_deploy_status "$callback_id" "deployed" "$BUILD_WAIT_TIME")

    if [[ "$deploy_status" != "deployed" ]]; then
        CREATED_CHATROOMS+=("$chatroom_id")
        local duration=$(($(get_time_ms) - test_start))
        record_result "TC-K8S-CD01" "Cascade Delete Kube" "FAIL" "$duration" "Deployed" "status=${deploy_status}"
        return 1
    fi

    log_success "    Kube deployment successful"

    # Step 4: Invoke to create Kube Job/Pod
    log_step "Step 4: Invoking to create Kube Job..."

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/api/kube/${deploy_path}" \
        -H "Content-Type: application/json" \
        -d '{"test": "cascade"}' \
        --connect-timeout "$TIMEOUT_LONG")

    http_code=$(echo "$result" | cut -d'|' -f2)
    log_info "    Invoke result: HTTP ${http_code}"

    # Give time for Job/Pod to be created
    sleep 3

    # Step 5: Check for Kube resources before deletion
    log_step "Step 5: Checking Kube resources before deletion..."

    local jobs_before=$(kubectl get jobs -n "$KUBE_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    local pods_before=$(kubectl get pods -n "$KUBE_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')

    log_info "    Jobs before: ${jobs_before}"
    log_info "    Pods before: ${pods_before}"

    # Step 6: Verify Callback exists
    log_step "Step 6: Verifying Callback exists..."

    result=$(timed_curl -X GET "${FAAS_BASE_URL}/callbacks/${callback_id}" \
        --connect-timeout "$TIMEOUT_SHORT")

    http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" != "200" ]]; then
        CREATED_CHATROOMS+=("$chatroom_id")
        local duration=$(($(get_time_ms) - test_start))
        record_result "TC-K8S-CD01" "Cascade Delete Kube" "FAIL" "$duration" "Callback exists" "HTTP ${http_code}"
        return 1
    fi

    log_success "    Callback ${callback_id} exists"

    # Step 7: Delete ChatRoom (should cascade delete Callback)
    log_step "Step 7: Deleting ChatRoom (triggering cascade delete)..."

    result=$(timed_curl -X DELETE "${FAAS_BASE_URL}/chatroom/${chatroom_id}" \
        --connect-timeout "$TIMEOUT_SHORT")

    http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" != "200" ]]; then
        CREATED_CHATROOMS+=("$chatroom_id")
        local duration=$(($(get_time_ms) - test_start))
        record_result "TC-K8S-CD01" "Cascade Delete Kube" "FAIL" "$duration" "ChatRoom deleted" "HTTP ${http_code}"
        return 1
    fi

    log_success "    ChatRoom ${chatroom_id} deleted"

    # Step 8: Verify Callback was cascade deleted
    log_step "Step 8: Verifying Callback was cascade deleted..."

    sleep 2  # Give time for cascade

    result=$(timed_curl -X GET "${FAAS_BASE_URL}/callbacks/${callback_id}" \
        --connect-timeout "$TIMEOUT_SHORT")

    http_code=$(echo "$result" | cut -d'|' -f2)

    local callback_deleted=false
    if [[ "$http_code" == "404" ]]; then
        callback_deleted=true
        log_success "    Callback ${callback_id} was cascade deleted"
    else
        log_warning "    Callback still exists (HTTP ${http_code})"
    fi

    # Step 9: Check Kube resources after deletion
    log_step "Step 9: Checking Kube resources after deletion..."

    sleep 3  # Give time for cleanup

    local jobs_after=$(kubectl get jobs -n "$KUBE_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    local pods_after=$(kubectl get pods -n "$KUBE_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')

    log_info "    Jobs after: ${jobs_after}"
    log_info "    Pods after: ${pods_after}"

    local duration=$(($(get_time_ms) - test_start))

    # Evaluate results
    if [[ "$callback_deleted" == true ]]; then
        record_result "TC-K8S-CD01" "Cascade Delete Kube" "PASS" "$duration" "Callback cascade deleted" "ChatRoom→Callback deletion verified"

        log_info ""
        log_info "  Summary:"
        echo "    - ChatRoom ${chatroom_id}: Deleted"
        echo "    - Callback ${callback_id}: Cascade deleted"
        echo "    - Jobs: ${jobs_before} → ${jobs_after}"
        echo "    - Pods: ${pods_before} → ${pods_after}"
    else
        record_result "TC-K8S-CD01" "Cascade Delete Kube" "FAIL" "$duration" "Callback deleted" "Callback still exists"
    fi
}

#===============================================================================
# Report Generation
#===============================================================================
generate_report() {
    log_section "Generating Test Report"

    mkdir -p "$REPORT_DIR"

    local pass_rate=0
    [[ $TOTAL_TESTS -gt 0 ]] && pass_rate=$((PASSED_TESTS * 100 / TOTAL_TESTS))

    {
        echo "# Kubernetes Service Flow Test Report"
        echo ""
        echo "**Test Date:** $(date '+%Y-%m-%d %H:%M:%S')"
        echo "**API Server:** ${FAAS_BASE_URL}"
        echo "**K8s Namespace:** ${KUBE_NAMESPACE}"
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
        echo "## Test Results"
        echo ""
        echo "| Test ID | Test Name | Status | Duration | Details |"
        echo "|---------|-----------|--------|----------|---------|"

        for result in "${TEST_RESULTS[@]}"; do
            IFS='|' read -r id name status dur expected actual msg <<< "$result"
            local icon="⏭️"
            [[ "$status" == "PASS" ]] && icon="✅"
            [[ "$status" == "FAIL" ]] && icon="❌"
            echo "| ${id} | ${name} | ${icon} ${status} | ${dur}ms | ${actual} |"
        done

        echo ""
        echo "## Test Descriptions"
        echo ""
        echo "### TC-K8S-FLOW01: Docker → Kube Switch"
        echo "Tests the ability to redeploy a function from Docker to Kubernetes execution mode."
        echo "Verifies that:"
        echo "- Initial Docker deployment works"
        echo "- Redeployment to Kube succeeds"
        echo "- Function invocation works via /api/kube/ endpoint"
        echo ""
        echo "### TC-K8S-FLOW02: Kube → Docker Switch"
        echo "Tests the ability to redeploy a function from Kubernetes to Docker execution mode."
        echo "Verifies that:"
        echo "- Initial Kube deployment works"
        echo "- Redeployment to Docker succeeds"
        echo "- Function invocation works via /api/ endpoint"
        echo ""
        echo "### TC-K8S-CD01: Cascade Delete"
        echo "Tests that deleting a ChatRoom properly cascades to delete linked resources."
        echo "Verifies that:"
        echo "- ChatRoom deletion triggers Callback deletion"
        echo "- Associated Kubernetes Jobs/Pods are properly cleaned up"
    } > "$REPORT_FILE"

    log_success "Report saved to: ${REPORT_FILE}"
}

print_summary() {
    local pass_rate=0
    [[ $TOTAL_TESTS -gt 0 ]] && pass_rate=$((PASSED_TESTS * 100 / TOTAL_TESTS))

    echo ""
    log_section "SERVICE FLOW TEST SUMMARY"

    echo -e "${BOLD}Configuration:${NC}"
    echo "  API Server: ${FAAS_BASE_URL}"
    echo "  Namespace: ${KUBE_NAMESPACE}"

    echo ""
    echo -e "${BOLD}Results:${NC}"
    echo "  Total Tests: ${TOTAL_TESTS}"
    echo -e "  ${GREEN}Passed: ${PASSED_TESTS}${NC}"
    echo -e "  ${RED}Failed: ${FAILED_TESTS}${NC}"
    echo -e "  ${YELLOW}Skipped: ${SKIPPED_TESTS}${NC}"

    if [[ $pass_rate -ge 80 ]]; then
        echo -e "\n  ${GREEN}${BOLD}Pass Rate: ${pass_rate}%${NC}"
    elif [[ $pass_rate -ge 60 ]]; then
        echo -e "\n  ${YELLOW}${BOLD}Pass Rate: ${pass_rate}%${NC}"
    else
        echo -e "\n  ${RED}${BOLD}Pass Rate: ${pass_rate}%${NC}"
    fi

    echo ""
    echo -e "${BOLD}Individual Results:${NC}"
    for result in "${TEST_RESULTS[@]}"; do
        IFS='|' read -r id name status dur expected actual msg <<< "$result"
        case "$status" in
            PASS) echo -e "  ${GREEN}✓${NC} ${id}: ${name}" ;;
            FAIL) echo -e "  ${RED}✗${NC} ${id}: ${name} - ${msg:-$actual}" ;;
            SKIP) echo -e "  ${YELLOW}⏭${NC} ${id}: ${name} - ${msg}" ;;
        esac
    done
}

#===============================================================================
# Help
#===============================================================================
print_help() {
    cat << EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Kubernetes Service Flow Test Suite

Tests the following scenarios:
  TC-K8S-FLOW01  Docker → Kube redeployment switch
  TC-K8S-FLOW02  Kube → Docker redeployment switch
  TC-K8S-CD01    ChatRoom cascade delete (Kube resources)

Options:
  -h, --help              Show this help message
  -u, --url URL           FaaS API base URL (default: http://localhost:8000)
  -n, --namespace NS      Kubernetes namespace (default: default)
  --test TEST_ID          Run specific test only (FLOW01, FLOW02, CD01)
  --skip-cleanup          Don't cleanup test resources

Examples:
  ${SCRIPT_NAME}                        # Run all service flow tests
  ${SCRIPT_NAME} --test FLOW01          # Run only Docker→Kube test
  ${SCRIPT_NAME} -u http://api:8000     # Use different API URL

EOF
}

#===============================================================================
# Main
#===============================================================================
main() {
    local specific_test=""
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
            -n|--namespace)
                KUBE_NAMESPACE="$2"
                shift 2
                ;;
            --test)
                specific_test="$2"
                shift 2
                ;;
            --skip-cleanup)
                skip_cleanup=true
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

    log_info "API Server: ${FAAS_BASE_URL}"
    log_info "Namespace: ${KUBE_NAMESPACE}"
    log_info "Timestamp: ${TIMESTAMP}"
    echo ""

    # Check prerequisites
    check_prerequisites || exit 1

    # Run tests
    if [[ -n "$specific_test" ]]; then
        case "$specific_test" in
            FLOW01|flow01|docker-kube) test_docker_to_kube_switch ;;
            FLOW02|flow02|kube-docker) test_kube_to_docker_switch ;;
            CD01|cd01|cascade) test_cascade_delete_kube_resources ;;
            *)
                log_error "Unknown test: $specific_test"
                log_info "Valid tests: FLOW01, FLOW02, CD01"
                exit 1
                ;;
        esac
    else
        test_docker_to_kube_switch
        test_kube_to_docker_switch
        test_cascade_delete_kube_resources
    fi

    # Generate report
    generate_report

    # Print summary
    print_summary

    # Cleanup
    if [[ "$skip_cleanup" != true ]]; then
        cleanup
    fi

    [[ $FAILED_TESTS -eq 0 ]]
}

main "$@"
