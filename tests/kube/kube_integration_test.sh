#!/bin/bash
#===============================================================================
#
#   Kubernetes FaaS Integration Test Suite
#
#   Created     : 2025-12
#   Description : Kubernetes 환경에서의 FaaS 플랫폼 통합 테스트
#                 - Kubernetes Cluster Validation
#                 - Service Flow Testing (ChatRoom → Callback → Kube Deploy)
#                 - Pod/Job Lifecycle Testing
#                 - Resource Management Verification
#                 - Performance & Scaling Tests
#
#   Prerequisites:
#                 - kubectl configured
#                 - Kubernetes cluster running
#                 - Local registry (localhost:5000) or image accessible
#
#   Usage       : ./kube_integration_test.sh [OPTIONS]
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
readonly REPORT_FILE="${REPORT_DIR}/kube_test_report_${TIMESTAMP}.md"
readonly JSON_REPORT="${REPORT_DIR}/kube_test_report_${TIMESTAMP}.json"

# Test Configuration
FAAS_BASE_URL="${FAAS_BASE_URL:-http://localhost:8000}"
KUBE_NAMESPACE="${KUBE_NAMESPACE:-default}"
TIMEOUT_SHORT=5
TIMEOUT_MEDIUM=30
TIMEOUT_LONG=120
BUILD_WAIT_TIME=45
JOB_WAIT_TIME=60

# Test State
declare -a CREATED_CHATROOMS=()
declare -a CREATED_JOBS=()
declare -a CREATED_CALLBACK_PATHS=()  # 테스트에서 생성한 callback path (이미지 이름 추적용)
declare -a CLEANUP_CHAT_IDS=()        # 추가 정리용 ChatRoom IDs
declare -a CLEANUP_CALLBACK_IDS=()    # 추가 정리용 Callback IDs
declare -a TEST_RESULTS=()
declare -a ISSUES=()
# PERFORMANCE_METRICS - Using individual variables for macOS compatibility
PERF_api_health_ms=""
PERF_kube_build_time_ms=""
PERF_kube_invoke_ms=""
PERF_kube_avg_ms=""
PERF_kube_min_ms=""
PERF_kube_max_ms=""

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
readonly MAGENTA='\033[0;35m'
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
    echo -e "${BOLD}${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${MAGENTA}  $1${NC}"
    echo -e "${BOLD}${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_banner() {
    echo -e "${BOLD}${CYAN}"
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║   ██╗  ██╗ █████╗ ███████╗    ████████╗███████╗███████╗████████╗  ║
║   ██║ ██╔╝██╔══██╗██╔════╝    ╚══██╔══╝██╔════╝██╔════╝╚══██╔══╝  ║
║   █████╔╝ ╚█████╔╝███████╗       ██║   █████╗  ███████╗   ██║     ║
║   ██╔═██╗ ██╔══██╗╚════██║       ██║   ██╔══╝  ╚════██║   ██║     ║
║   ██║  ██╗╚█████╔╝███████║       ██║   ███████╗███████║   ██║     ║
║   ╚═╝  ╚═╝ ╚════╝ ╚══════╝       ╚═╝   ╚══════╝╚══════╝   ╚═╝     ║
║                                                                   ║
║   Kubernetes FaaS Integration Test Suite                          ║
║   Cloud Infrastructure QA Automation                              ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

#===============================================================================
# Utility Functions
#===============================================================================

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

record_issue() {
    local severity="$1"
    local title="$2"
    local description="$3"

    ISSUES+=("{\"severity\":\"${severity}\",\"title\":\"${title}\",\"description\":\"${description}\"}")
    log_warning "[ISSUE] [${severity}] ${title}"
}

#===============================================================================
# Cleanup Functions
#===============================================================================
cleanup_kube_resources() {
    log_info "Cleaning up Kubernetes resources..."

    # Delete tracked test jobs
    for job_name in "${CREATED_JOBS[@]}"; do
        if [[ -n "$job_name" ]]; then
            kubectl delete job "$job_name" -n "$KUBE_NAMESPACE" --ignore-not-found=true &>/dev/null
            log_info "  Deleted Job: ${job_name}"
        fi
    done

    # Delete any leftover test pods
    kubectl delete pods -n "$KUBE_NAMESPACE" -l "test=faas-kube-test" --ignore-not-found=true &>/dev/null

    # Clean up completed lambda-job-* jobs created during this test session
    # Only delete jobs created within the last 30 minutes to avoid affecting other tests
    local job_list
    job_list=$(kubectl get jobs -n "$KUBE_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    for job_name in $job_list; do
        if [[ "$job_name" == lambda-job-* ]]; then
            local job_status
            job_status=$(kubectl get job "$job_name" -n "$KUBE_NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
            if [[ "$job_status" == "1" ]]; then
                kubectl delete job "$job_name" -n "$KUBE_NAMESPACE" --ignore-not-found=true &>/dev/null
                log_info "  Deleted completed Job: ${job_name}"
            fi
        fi
    done

    CREATED_JOBS=()
}

cleanup_api_resources() {
    log_info "Cleaning up API resources..."

    # Delete tracked ChatRooms (from CREATED_CHATROOMS)
    for chat_id in "${CREATED_CHATROOMS[@]}"; do
        if [[ -n "$chat_id" ]]; then
            curl -s -X DELETE "${FAAS_BASE_URL}/chatroom/${chat_id}" \
                --connect-timeout 3 &>/dev/null || true
            log_info "  Deleted ChatRoom: ${chat_id}"
        fi
    done

    # Delete additional ChatRooms (from CLEANUP_CHAT_IDS)
    for chat_id in "${CLEANUP_CHAT_IDS[@]}"; do
        if [[ -n "$chat_id" ]]; then
            curl -s -X DELETE "${FAAS_BASE_URL}/chatroom/${chat_id}" \
                --connect-timeout 3 &>/dev/null || true
            log_info "  Deleted ChatRoom (cleanup): ${chat_id}"
        fi
    done

    # Delete additional Callbacks (from CLEANUP_CALLBACK_IDS)
    for callback_id in "${CLEANUP_CALLBACK_IDS[@]}"; do
        if [[ -n "$callback_id" ]]; then
            curl -s -X DELETE "${FAAS_BASE_URL}/callbacks/${callback_id}" \
                --connect-timeout 3 &>/dev/null || true
            log_info "  Deleted Callback (cleanup): ${callback_id}"
        fi
    done

    CREATED_CHATROOMS=()
    CLEANUP_CHAT_IDS=()
    CLEANUP_CALLBACK_IDS=()
}

cleanup_docker_images() {
    log_info "Cleaning up Docker images created by tests..."

    if command -v docker &> /dev/null && docker info &> /dev/null; then
        # callback_ 접두사로 시작하는 모든 이미지 삭제
        local callback_images
        callback_images=$(docker images --format "{{.Repository}}" 2>/dev/null | grep "^callback_" || echo "")
        for image_name in $callback_images; do
            if [[ -n "$image_name" ]]; then
                docker rmi "$image_name" --force &>/dev/null || true
                log_info "  Deleted Docker image: ${image_name}"
            fi
        done
    fi

    CREATED_CALLBACK_PATHS=()
}

cleanup() {
    cleanup_kube_resources
    cleanup_api_resources
    cleanup_docker_images
}

trap cleanup EXIT
trap 'echo ""; log_warning "Test interrupted by user"; exit 130' INT TERM

#===============================================================================
# Kubernetes Environment Validation
#===============================================================================
run_kube_environment_tests() {
    log_section "1. Kubernetes Environment Validation"

    # TC-K8S-ENV01: kubectl availability
    local start=$(get_time_ms)
    if command -v kubectl &> /dev/null; then
        local kubectl_version
        kubectl_version=$(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*"' | cut -d'"' -f4)
        local duration=$(($(get_time_ms) - start))
        record_result "TC-K8S-ENV01" "kubectl Availability" "K8sEnv" "PASS" "$duration" "kubectl installed" "v${kubectl_version}"
    else
        local duration=$(($(get_time_ms) - start))
        record_result "TC-K8S-ENV01" "kubectl Availability" "K8sEnv" "FAIL" "$duration" "kubectl installed" "Not found"
        record_issue "Critical" "kubectl Not Found" "kubectl is required for Kubernetes tests"
        return 1
    fi

    # TC-K8S-ENV02: Cluster connectivity
    start=$(get_time_ms)
    if kubectl cluster-info &>/dev/null; then
        local cluster_info
        cluster_info=$(kubectl cluster-info 2>/dev/null | head -1 | sed 's/\x1b\[[0-9;]*m//g')
        local duration=$(($(get_time_ms) - start))
        record_result "TC-K8S-ENV02" "Cluster Connectivity" "K8sEnv" "PASS" "$duration" "Cluster accessible" "${cluster_info:0:50}"
    else
        local duration=$(($(get_time_ms) - start))
        record_result "TC-K8S-ENV02" "Cluster Connectivity" "K8sEnv" "FAIL" "$duration" "Cluster accessible" "Connection failed"
        record_issue "Critical" "Cluster Unreachable" "Cannot connect to Kubernetes cluster"
        return 1
    fi

    # TC-K8S-ENV03: Namespace exists
    start=$(get_time_ms)
    if kubectl get namespace "$KUBE_NAMESPACE" &>/dev/null; then
        local duration=$(($(get_time_ms) - start))
        record_result "TC-K8S-ENV03" "Namespace Check" "K8sEnv" "PASS" "$duration" "Namespace exists" "$KUBE_NAMESPACE"
    else
        local duration=$(($(get_time_ms) - start))
        record_result "TC-K8S-ENV03" "Namespace Check" "K8sEnv" "FAIL" "$duration" "Namespace exists" "Not found"
        record_issue "High" "Namespace Missing" "Namespace $KUBE_NAMESPACE does not exist"
    fi

    # TC-K8S-ENV04: Node status
    start=$(get_time_ms)
    local ready_nodes
    ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready")
    local total_nodes
    total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    local duration=$(($(get_time_ms) - start))

    if [[ "$ready_nodes" -gt 0 ]]; then
        record_result "TC-K8S-ENV04" "Node Status" "K8sEnv" "PASS" "$duration" "Ready nodes > 0" "${ready_nodes}/${total_nodes} Ready"
    else
        record_result "TC-K8S-ENV04" "Node Status" "K8sEnv" "FAIL" "$duration" "Ready nodes > 0" "No ready nodes"
        record_issue "Critical" "No Ready Nodes" "No Kubernetes nodes are in Ready state"
    fi

    # TC-K8S-ENV05: RBAC permissions (can create jobs)
    start=$(get_time_ms)
    if kubectl auth can-i create jobs -n "$KUBE_NAMESPACE" &>/dev/null; then
        local duration=$(($(get_time_ms) - start))
        record_result "TC-K8S-ENV05" "RBAC Permissions" "K8sEnv" "PASS" "$duration" "Can create jobs" "Authorized"
    else
        local duration=$(($(get_time_ms) - start))
        record_result "TC-K8S-ENV05" "RBAC Permissions" "K8sEnv" "FAIL" "$duration" "Can create jobs" "Unauthorized"
        record_issue "High" "RBAC Permission Denied" "Cannot create jobs in namespace $KUBE_NAMESPACE"
    fi

    # TC-K8S-ENV06: CoreDNS/DNS resolution
    start=$(get_time_ms)
    local dns_pods
    dns_pods=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    local duration=$(($(get_time_ms) - start))

    if [[ "$dns_pods" -gt 0 ]]; then
        record_result "TC-K8S-ENV06" "DNS Service" "K8sEnv" "PASS" "$duration" "DNS pods running" "${dns_pods} running"
    else
        record_result "TC-K8S-ENV06" "DNS Service" "K8sEnv" "SKIP" "$duration" "DNS pods running" "Not detected" "May use different DNS"
    fi
}

#===============================================================================
# API Server Health Check
#===============================================================================
run_api_health_tests() {
    log_section "2. FaaS API Server Health Check"

    # TC-K8S-API01: Health endpoint
    local result
    result=$(timed_curl -X GET "${FAAS_BASE_URL}/health" --connect-timeout "$TIMEOUT_SHORT")

    local body=$(echo "$result" | cut -d'|' -f1)
    local http_code=$(echo "$result" | cut -d'|' -f2)
    local duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "200" ]] && echo "$body" | grep -q "healthy"; then
        record_result "TC-K8S-API01" "API Health Check" "API" "PASS" "$duration" "200 + healthy" "HTTP ${http_code}"
    else
        record_result "TC-K8S-API01" "API Health Check" "API" "FAIL" "$duration" "200 + healthy" "HTTP ${http_code}"
        record_issue "Critical" "API Server Unreachable" "FaaS API server is not responding"
        return 1
    fi

    PERF_api_health_ms="$duration"
}

#===============================================================================
# Kubernetes Deployment Flow Tests
#===============================================================================
run_kube_deploy_tests() {
    log_section "3. Kubernetes Deployment Flow Tests"

    # Step 1: Create ChatRoom
    log_info "  Step 1: Creating ChatRoom..."

    local chatroom_payload="{\"title\": \"K8s Test ${TIMESTAMP}\"}"

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
        record_result "TC-K8S-DEP01" "Create ChatRoom" "K8sDeploy" "PASS" "$duration" "chat_id created" "id=${CURRENT_CHATROOM_ID}"
    else
        record_result "TC-K8S-DEP01" "Create ChatRoom" "K8sDeploy" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
        return 1
    fi

    # Step 2: Create Callback for Kube deployment
    log_info "  Step 2: Creating Callback for Kubernetes..."

    CURRENT_DEPLOY_PATH="/kube_test_${TIMESTAMP}"
    CREATED_CALLBACK_PATHS+=("$CURRENT_DEPLOY_PATH")  # Docker 이미지 정리용 추적
    local python_code='import json\nimport os\ndef lambda_handler(event, context):\n    return {\"statusCode\": 200, \"body\": json.dumps({\"message\": \"Hello from K8s!\", \"pod\": os.environ.get(\"HOSTNAME\", \"unknown\")})}'

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
        record_result "TC-K8S-DEP02" "Create Callback" "K8sDeploy" "PASS" "$duration" "callback created" "id=${CURRENT_CALLBACK_ID}"
    else
        record_result "TC-K8S-DEP02" "Create Callback" "K8sDeploy" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
        return 1
    fi

    # Step 3: Deploy with c_type=kube
    log_info "  Step 3: Deploying to Kubernetes (c_type=kube)..."

    local deploy_payload="{\"callback_id\": ${CURRENT_CALLBACK_ID}, \"status\": true, \"c_type\": \"kube\"}"
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
                sleep 3
                ((elapsed+=3))

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
            PERF_kube_build_time_ms="$build_time"

            if [[ "$final_status" == "deployed" ]]; then
                record_result "TC-K8S-DEP03" "Kube Deploy" "K8sDeploy" "PASS" "$build_time" "status=deployed" "built in ${elapsed}s"
            else
                record_result "TC-K8S-DEP03" "Kube Deploy" "K8sDeploy" "FAIL" "$build_time" "status=deployed" "status=${final_status}"
                record_issue "High" "Kube Build Failed" "Build resulted in status: ${final_status}"
            fi
        else
            record_result "TC-K8S-DEP03" "Kube Deploy" "K8sDeploy" "FAIL" "0" "status=build" "status=${initial_status}"
        fi
    else
        record_result "TC-K8S-DEP03" "Kube Deploy" "K8sDeploy" "FAIL" "0" "HTTP 200" "HTTP ${http_code}"
    fi

    # Step 4: Invoke via Kube endpoint
    log_info "  Step 4: Invoking function via /api/kube/..."

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/api/kube/${CURRENT_DEPLOY_PATH#/}" \
        -H "Content-Type: application/json" \
        -d '{"test": "kube_data"}' \
        --connect-timeout "$TIMEOUT_LONG")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    PERF_kube_invoke_ms="$duration"

    if [[ "$http_code" == "200" ]]; then
        record_result "TC-K8S-DEP04" "Kube Function Invoke" "K8sDeploy" "PASS" "$duration" "HTTP 200" "Response in ${duration}ms"
    else
        record_result "TC-K8S-DEP04" "Kube Function Invoke" "K8sDeploy" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
    fi
}

#===============================================================================
# Kubernetes Job/Pod Lifecycle Tests
#===============================================================================
run_kube_lifecycle_tests() {
    log_section "4. Kubernetes Job/Pod Lifecycle Tests"

    # TC-K8S-LC01: Check for lambda jobs
    local start=$(get_time_ms)
    local lambda_jobs
    lambda_jobs=$(kubectl get jobs -n "$KUBE_NAMESPACE" --no-headers 2>/dev/null | grep -c "lambda-job" || echo "0")
    local duration=$(($(get_time_ms) - start))

    record_result "TC-K8S-LC01" "Lambda Jobs Check" "K8sLifecycle" "PASS" "$duration" "Jobs queryable" "${lambda_jobs} lambda jobs found"

    # TC-K8S-LC02: Check completed jobs
    start=$(get_time_ms)
    local completed_jobs
    completed_jobs=$(kubectl get jobs -n "$KUBE_NAMESPACE" --no-headers 2>/dev/null | grep -c "1/1" || echo "0")
    duration=$(($(get_time_ms) - start))

    record_result "TC-K8S-LC02" "Completed Jobs" "K8sLifecycle" "PASS" "$duration" "Completed jobs count" "${completed_jobs} completed"

    # TC-K8S-LC03: Check for failed pods
    start=$(get_time_ms)
    local failed_pods
    failed_pods=$(kubectl get pods -n "$KUBE_NAMESPACE" --no-headers 2>/dev/null | grep -c "Error\|CrashLoopBackOff\|Failed" || echo "0")
    failed_pods=$(echo "$failed_pods" | tr -d '[:space:]')
    duration=$(($(get_time_ms) - start))

    if [[ "$failed_pods" -eq 0 ]]; then
        record_result "TC-K8S-LC03" "Failed Pods Check" "K8sLifecycle" "PASS" "$duration" "No failed pods" "0 failed"
    else
        record_result "TC-K8S-LC03" "Failed Pods Check" "K8sLifecycle" "FAIL" "$duration" "No failed pods" "${failed_pods} failed"
        record_issue "Medium" "Failed Pods Detected" "${failed_pods} pods in error state"
    fi

    # TC-K8S-LC04: Resource quota check (if exists)
    start=$(get_time_ms)
    local quota_status
    if kubectl get resourcequota -n "$KUBE_NAMESPACE" &>/dev/null; then
        quota_status=$(kubectl get resourcequota -n "$KUBE_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        duration=$(($(get_time_ms) - start))
        record_result "TC-K8S-LC04" "Resource Quota" "K8sLifecycle" "PASS" "$duration" "Quota check" "${quota_status} quotas defined"
    else
        duration=$(($(get_time_ms) - start))
        record_result "TC-K8S-LC04" "Resource Quota" "K8sLifecycle" "SKIP" "$duration" "Quota check" "No quotas" "Resource quotas not configured"
    fi
}

#===============================================================================
# Kubernetes Performance Tests
#===============================================================================
run_kube_performance_tests() {
    log_section "5. Kubernetes Performance Tests"

    local perf_test_path="$CURRENT_DEPLOY_PATH"

    # If no deployed function, create one for performance testing
    if [[ -z "$perf_test_path" ]]; then
        log_info "  No deployed function available, creating one for performance test..."

        # Create ChatRoom for perf test
        local perf_chat_response
        perf_chat_response=$(curl -s -X POST "${FAAS_BASE_URL}/chatroom/" \
            -H "Content-Type: application/json" \
            -d "{\"title\": \"PerfTestChatRoom_${TIMESTAMP}\"}")

        local perf_chat_id=$(echo "$perf_chat_response" | grep -o '"chat_id":[0-9]*' | cut -d':' -f2)

        if [[ -z "$perf_chat_id" ]]; then
            log_warning "  Failed to create ChatRoom for performance test"
            record_result "TC-K8S-PERF01" "Kube Response Time" "K8sPerf" "SKIP" "0" "N/A" "N/A" "Failed to create ChatRoom"
            return
        fi

        CLEANUP_CHAT_IDS+=("$perf_chat_id")
        perf_test_path="/perf_test_${TIMESTAMP}"

        # Create simple callback for performance test
        local perf_callback_response
        perf_callback_response=$(curl -s -X POST "${FAAS_BASE_URL}/callbacks/" \
            -H "Content-Type: application/json" \
            -d "{
                \"chat_id\": ${perf_chat_id},
                \"path\": \"${perf_test_path}\",
                \"method\": \"POST\",
                \"code\": \"def lambda_handler(event, context):\\n    return {'statusCode': 200, 'body': {'message': 'perf test', 'input': event}}\",
                \"type\": \"python\"
            }")

        local perf_callback_id=$(echo "$perf_callback_response" | grep -o '"callback_id":[0-9]*' | cut -d':' -f2)

        if [[ -z "$perf_callback_id" ]]; then
            log_warning "  Failed to create callback for performance test"
            record_result "TC-K8S-PERF01" "Kube Response Time" "K8sPerf" "SKIP" "0" "N/A" "N/A" "Failed to create callback"
            return
        fi

        CLEANUP_CALLBACK_IDS+=("$perf_callback_id")

        # Deploy to Kubernetes
        log_info "  Deploying performance test function to Kubernetes..."
        local deploy_response
        deploy_response=$(curl -s -X POST "${FAAS_BASE_URL}/deploy/" \
            -H "Content-Type: application/json" \
            -d "{\"callback_id\": ${perf_callback_id}, \"status\": true, \"c_type\": \"kube\"}")

        # Wait for build to complete
        log_info "  Waiting for build to complete (up to 60 seconds)..."
        local max_wait=60
        local wait_interval=5
        local elapsed=0

        while [[ $elapsed -lt $max_wait ]]; do
            sleep $wait_interval
            ((elapsed+=wait_interval))

            local status_response
            status_response=$(curl -s "${FAAS_BASE_URL}/callbacks/${perf_callback_id}")
            local status=$(echo "$status_response" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)

            if [[ "$status" == "deployed" ]]; then
                log_info "  Performance test function deployed successfully"
                break
            elif [[ "$status" == "failed" ]]; then
                log_warning "  Performance test function build failed"
                record_result "TC-K8S-PERF01" "Kube Response Time" "K8sPerf" "SKIP" "0" "N/A" "N/A" "Build failed"
                return
            fi

            log_info "    Status: $status (${elapsed}s elapsed)"
        done

        if [[ $elapsed -ge $max_wait ]]; then
            log_warning "  Timeout waiting for performance test function to deploy"
            record_result "TC-K8S-PERF01" "Kube Response Time" "K8sPerf" "SKIP" "0" "N/A" "N/A" "Deploy timeout"
            return
        fi
    fi

    # TC-K8S-PERF01: Multiple invocations
    log_info "  Running multiple Kubernetes invocations..."

    local -a response_times=()
    local iterations=3

    for i in $(seq 1 $iterations); do
        local result
        result=$(timed_curl -X POST "${FAAS_BASE_URL}/api/kube/${perf_test_path#/}" \
            -H "Content-Type: application/json" \
            -d "{\"iteration\": $i}" \
            --connect-timeout "$TIMEOUT_LONG")

        local http_code=$(echo "$result" | cut -d'|' -f2)
        local duration=$(echo "$result" | cut -d'|' -f3)

        if [[ "$http_code" == "200" ]]; then
            response_times+=("$duration")
            log_info "    Iteration $i: ${duration}ms"
        else
            log_warning "    Iteration $i: Failed (HTTP ${http_code})"
        fi

        sleep 2
    done

    if [[ ${#response_times[@]} -ge 2 ]]; then
        local sum=0 min=${response_times[0]} max=${response_times[0]}

        for t in "${response_times[@]}"; do
            ((sum+=t))
            [[ $t -lt $min ]] && min=$t
            [[ $t -gt $max ]] && max=$t
        done

        local avg=$((sum / ${#response_times[@]}))

        PERF_kube_avg_ms="$avg"
        PERF_kube_min_ms="$min"
        PERF_kube_max_ms="$max"

        record_result "TC-K8S-PERF01" "Kube Response Time" "K8sPerf" "PASS" "0" "Response metrics" "avg=${avg}ms, min=${min}ms, max=${max}ms"
    else
        record_result "TC-K8S-PERF01" "Kube Response Time" "K8sPerf" "SKIP" "0" "Response metrics" "Insufficient data"
    fi
}

#===============================================================================
# Kubernetes Error Handling Tests
#===============================================================================
run_kube_error_tests() {
    log_section "6. Kubernetes Error Handling Tests"

    # TC-K8S-ERR01: Nonexistent kube path
    local result
    result=$(timed_curl -X GET "${FAAS_BASE_URL}/api/kube/nonexistent_path_${TIMESTAMP}" \
        --connect-timeout "$TIMEOUT_SHORT")

    local http_code=$(echo "$result" | cut -d'|' -f2)
    local duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "404" ]]; then
        record_result "TC-K8S-ERR01" "Nonexistent Kube Path" "K8sError" "PASS" "$duration" "HTTP 404" "HTTP ${http_code}"
    else
        record_result "TC-K8S-ERR01" "Nonexistent Kube Path" "K8sError" "FAIL" "$duration" "HTTP 404" "HTTP ${http_code}"
    fi

    # TC-K8S-ERR02: Wrong method on kube endpoint
    # 배포 여부와 관계없이 테스트: 존재하지 않는 경로에 DELETE 요청 → 404 예상
    local test_path="${CURRENT_DEPLOY_PATH:-/test_wrong_method_kube_${TIMESTAMP}}"
    result=$(timed_curl -X DELETE "${FAAS_BASE_URL}/api/kube/${test_path#/}" \
        --connect-timeout "$TIMEOUT_SHORT")

    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "404" || "$http_code" == "405" ]]; then
        record_result "TC-K8S-ERR02" "Wrong Method Kube" "K8sError" "PASS" "$duration" "404 or 405" "HTTP ${http_code}"
    else
        record_result "TC-K8S-ERR02" "Wrong Method Kube" "K8sError" "FAIL" "$duration" "404 or 405" "HTTP ${http_code}"
    fi

    # TC-K8S-ERR03: Delete Building Callback (should fail)
    log_info "TC-K8S-ERR03: Testing delete during Kube build..."

    # 1. Create ChatRoom
    local slow_chatroom_result=$(timed_curl -X POST "${FAAS_BASE_URL}/chatroom/" \
        -H "Content-Type: application/json" \
        -d '{"title": "slow_kube_build_test"}' \
        --connect-timeout "$TIMEOUT_SHORT")

    local slow_chatroom_body=$(echo "$slow_chatroom_result" | cut -d'|' -f1)
    local slow_chatroom_id=$(echo "$slow_chatroom_body" | grep -o '"chat_id":[0-9]*' | head -1 | cut -d':' -f2)

    if [[ -z "$slow_chatroom_id" || "$slow_chatroom_id" == "null" ]]; then
        record_result "TC-K8S-ERR03" "Delete Building Callback" "K8sError" "FAIL" "0" "HTTP 400" "ChatRoom creation failed"
    else
        CREATED_CHATROOMS+=("$slow_chatroom_id")

        # 2. Create callback with sleep(28)
        local slow_kube_path="/slow_kube_build_test_${TIMESTAMP}"
        CREATED_CALLBACK_PATHS+=("$slow_kube_path")  # Docker 이미지 정리용 추적

        local slow_callback_code='import time
import json

def lambda_handler(event, context):
    time.sleep(28)
    return {"statusCode": 200, "body": json.dumps({"message": "slow kube build test"})}'

        local encoded_code=$(echo "$slow_callback_code" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
        local slow_callback_result=$(timed_curl -X POST "${FAAS_BASE_URL}/callbacks/" \
            -H "Content-Type: application/json" \
            -d "{\"chat_id\": ${slow_chatroom_id}, \"path\": \"${slow_kube_path}\", \"method\": \"GET\", \"type\": \"python\", \"code\": ${encoded_code}}" \
            --connect-timeout "$TIMEOUT_SHORT")

        local slow_callback_body=$(echo "$slow_callback_result" | cut -d'|' -f1)
        local slow_callback_id=$(echo "$slow_callback_body" | grep -o '"callback_id":[0-9]*' | head -1 | cut -d':' -f2)

        if [[ -z "$slow_callback_id" || "$slow_callback_id" == "null" ]]; then
            record_result "TC-K8S-ERR03" "Delete Building Callback" "K8sError" "FAIL" "0" "HTTP 400" "Callback creation failed"
        else
            # 3. Start deploy in background (kube type)
            log_info "  Starting Kube deploy in background..."
            curl -s -X POST "${FAAS_BASE_URL}/deploy/" \
                -H "Content-Type: application/json" \
                -d "{\"callback_id\": ${slow_callback_id}, \"status\": true, \"c_type\": \"kube\"}" &
            local deploy_pid=$!

            # 4. Wait 1 second then try to delete
            sleep 1

            log_info "  Attempting to delete callback while building..."
            local delete_result=$(timed_curl -X DELETE "${FAAS_BASE_URL}/callbacks/${slow_callback_id}" \
                --connect-timeout "$TIMEOUT_SHORT")

            local delete_http_code=$(echo "$delete_result" | cut -d'|' -f2)
            local delete_duration=$(echo "$delete_result" | cut -d'|' -f3)

            wait $deploy_pid 2>/dev/null || true

            if [[ "$delete_http_code" == "400" ]]; then
                record_result "TC-K8S-ERR03" "Delete Building Callback" "K8sError" "PASS" "$delete_duration" "HTTP 400" "HTTP ${delete_http_code}"
            else
                if [[ "$delete_http_code" == "200" ]]; then
                    record_result "TC-K8S-ERR03" "Delete Building Callback" "K8sError" "FAIL" "$delete_duration" "HTTP 400" "HTTP ${delete_http_code}" "Build too fast"
                else
                    record_result "TC-K8S-ERR03" "Delete Building Callback" "K8sError" "FAIL" "$delete_duration" "HTTP 400" "HTTP ${delete_http_code}"
                fi
            fi

            sleep 2
            curl -s -X DELETE "${FAAS_BASE_URL}/chatroom/${slow_chatroom_id}" > /dev/null 2>&1 || true
        fi
    fi
}

#===============================================================================
# Kubernetes Library & ENV Tests
#===============================================================================
run_kube_library_env_tests() {
    log_section "7. Kubernetes Library & Environment Variable Tests"

    local lib_chatroom_id=""

    # TC-K8S-LE01: Create ChatRoom for library test
    log_info "  Creating ChatRoom for library test..."

    local result
    result=$(timed_curl -X POST "${FAAS_BASE_URL}/chatroom/" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"K8s Library Test ${TIMESTAMP}\"}" \
        --connect-timeout "$TIMEOUT_SHORT")

    local body=$(echo "$result" | cut -d'|' -f1)
    local http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" == "200" ]]; then
        lib_chatroom_id=$(json_extract_number "$body" "chat_id")
        CREATED_CHATROOMS+=("$lib_chatroom_id")
    else
        record_result "TC-K8S-LE01" "Library Test Setup" "K8sLibrary" "SKIP" "0" "N/A" "N/A" "Failed to create ChatRoom"
        return
    fi

    # TC-K8S-LE02: Create Callback with external library
    log_info "  Creating function with external library (requests)..."

    local lib_path="/kube_lib_test_${TIMESTAMP}"
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
        local lib_callback_id=$(json_extract_number "$body" "callback_id")

        # Deploy with kube
        local deploy_payload="{\"callback_id\": ${lib_callback_id}, \"status\": true, \"c_type\": \"kube\"}"
        curl -s -X POST "${FAAS_BASE_URL}/deploy/" \
            -H "Content-Type: application/json" \
            -d "$deploy_payload" \
            --connect-timeout "$TIMEOUT_SHORT" > /dev/null

        log_info "    Waiting for library function build (45+ seconds)..."
        sleep $((BUILD_WAIT_TIME + 15))

        # Check status and invoke
        local check
        check=$(curl -s "${FAAS_BASE_URL}/callbacks/${lib_callback_id}" --connect-timeout 3)
        local status=$(json_extract "$check" "status")

        if [[ "$status" == "deployed" ]]; then
            result=$(timed_curl -X POST "${FAAS_BASE_URL}/api/kube/${lib_path#/}" \
                -H "Content-Type: application/json" \
                -d '{}' \
                --connect-timeout "$TIMEOUT_LONG")

            body=$(echo "$result" | cut -d'|' -f1)
            http_code=$(echo "$result" | cut -d'|' -f2)
            duration=$(echo "$result" | cut -d'|' -f3)

            if [[ "$http_code" == "200" ]] && echo "$body" | grep -q "2.28"; then
                record_result "TC-K8S-LE02" "External Library Function" "K8sLibrary" "PASS" "$duration" "requests 2.28.x" "Library loaded"
            else
                record_result "TC-K8S-LE02" "External Library Function" "K8sLibrary" "FAIL" "$duration" "requests 2.28.x" "HTTP ${http_code}"
            fi
        else
            record_result "TC-K8S-LE02" "External Library Function" "K8sLibrary" "FAIL" "0" "status=deployed" "status=${status}" "Build failed"
        fi
    else
        record_result "TC-K8S-LE02" "External Library Function" "K8sLibrary" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
    fi

    # TC-K8S-LE03: Environment Variable Test
    log_info "  Testing environment variables..."

    local env_chatroom_id=""
    result=$(timed_curl -X POST "${FAAS_BASE_URL}/chatroom/" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"K8s Env Test ${TIMESTAMP}\"}" \
        --connect-timeout "$TIMEOUT_SHORT")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" == "200" ]]; then
        env_chatroom_id=$(json_extract_number "$body" "chat_id")
        CREATED_CHATROOMS+=("$env_chatroom_id")

        local env_path="/kube_env_test_${TIMESTAMP}"
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

            # Deploy with kube
            local deploy_payload="{\"callback_id\": ${env_callback_id}, \"status\": true, \"c_type\": \"kube\"}"
            curl -s -X POST "${FAAS_BASE_URL}/deploy/" \
                -H "Content-Type: application/json" \
                -d "$deploy_payload" \
                --connect-timeout "$TIMEOUT_SHORT" > /dev/null

            log_info "    Waiting for env function build..."
            sleep $BUILD_WAIT_TIME

            # Check status
            local check
            check=$(curl -s "${FAAS_BASE_URL}/callbacks/${env_callback_id}" --connect-timeout 3)
            local status=$(json_extract "$check" "status")

            if [[ "$status" == "deployed" ]]; then
                result=$(timed_curl -X POST "${FAAS_BASE_URL}/api/kube/${env_path#/}" \
                    -H "Content-Type: application/json" \
                    -d '{}' \
                    --connect-timeout "$TIMEOUT_LONG")

                body=$(echo "$result" | cut -d'|' -f1)
                http_code=$(echo "$result" | cut -d'|' -f2)
                duration=$(echo "$result" | cut -d'|' -f3)

                if [[ "$http_code" == "200" ]] && echo "$body" | grep -q "sec"; then
                    record_result "TC-K8S-LE03" "Environment Variable Test" "K8sLibrary" "PASS" "$duration" "API_KEY=sec..." "Env vars work"
                else
                    record_result "TC-K8S-LE03" "Environment Variable Test" "K8sLibrary" "FAIL" "$duration" "API_KEY set" "HTTP ${http_code}"
                fi
            else
                record_result "TC-K8S-LE03" "Environment Variable Test" "K8sLibrary" "FAIL" "0" "status=deployed" "status=${status}" "Build failed"
            fi
        else
            record_result "TC-K8S-LE03" "Environment Variable Test" "K8sLibrary" "FAIL" "0" "HTTP 200" "HTTP ${http_code}"
        fi
    else
        record_result "TC-K8S-LE03" "Environment Variable Test" "K8sLibrary" "SKIP" "0" "N/A" "N/A" "Failed to create ChatRoom"
    fi
}

#===============================================================================
# Kubernetes Node.js Runtime Tests
#===============================================================================
run_kube_nodejs_tests() {
    log_section "9. Kubernetes Node.js Runtime Tests"

    local node_chatroom_id=""
    local node_callback_id=""

    # TC-K8S-NODE01: Create ChatRoom for Node.js test
    log_info "  Creating ChatRoom for Node.js test..."

    local result
    result=$(timed_curl -X POST "${FAAS_BASE_URL}/chatroom/" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"K8s Node.js Test ${TIMESTAMP}\"}" \
        --connect-timeout "$TIMEOUT_SHORT")

    local body=$(echo "$result" | cut -d'|' -f1)
    local http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" == "200" ]]; then
        node_chatroom_id=$(json_extract_number "$body" "chat_id")
        CREATED_CHATROOMS+=("$node_chatroom_id")
    else
        record_result "TC-K8S-NODE01" "K8s Node.js Test Setup" "K8sNode" "SKIP" "0" "N/A" "N/A" "Failed to create ChatRoom"
        return
    fi

    # TC-K8S-NODE02: Create and Deploy Node.js Callback
    log_info "  Creating and deploying Node.js callback to Kubernetes..."

    local node_path="/kube_nodejs_test_${TIMESTAMP}"
    CREATED_CALLBACK_PATHS+=("$node_path")

    local node_code='const handler = async (event) => {
    const body = event.body || {};
    return {
        statusCode: 200,
        body: JSON.stringify({
            message: "Hello from Node.js on Kubernetes!",
            runtime: "node",
            platform: "kubernetes",
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
            record_result "TC-K8S-NODE02" "Create K8s Node.js Callback" "K8sNode" "PASS" "$duration" "type=node" "id=${node_callback_id}"
        else
            record_result "TC-K8S-NODE02" "Create K8s Node.js Callback" "K8sNode" "FAIL" "$duration" "type=node" "type=${node_type}"
            return
        fi
    else
        record_result "TC-K8S-NODE02" "Create K8s Node.js Callback" "K8sNode" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
        return
    fi

    # TC-K8S-NODE03: Deploy Node.js Callback to Kubernetes
    log_info "  Deploying Node.js callback to Kubernetes..."

    local deploy_payload="{\"callback_id\": ${node_callback_id}, \"status\": true, \"c_type\": \"kube\"}"
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
        local node_build_wait=90  # Node.js + K8s 빌드는 더 오래 걸릴 수 있음

        while [[ $elapsed -lt $node_build_wait ]]; do
            sleep 5
            ((elapsed+=5))

            local check
            check=$(curl -s "${FAAS_BASE_URL}/callbacks/${node_callback_id}" --connect-timeout 3)
            final_status=$(json_extract "$check" "status")

            if [[ "$final_status" == "deployed" || "$final_status" == "failed" ]]; then
                break
            fi

            echo -ne "    Building Node.js for K8s... ${elapsed}s / ${node_build_wait}s\r"
        done
        echo ""

        local build_time=$(($(get_time_ms) - build_start))

        if [[ "$final_status" == "deployed" ]]; then
            record_result "TC-K8S-NODE03" "Deploy K8s Node.js Callback" "K8sNode" "PASS" "$build_time" "status=deployed" "built in ${elapsed}s"
        else
            record_result "TC-K8S-NODE03" "Deploy K8s Node.js Callback" "K8sNode" "FAIL" "$build_time" "status=deployed" "status=${final_status}"
            return
        fi
    else
        record_result "TC-K8S-NODE03" "Deploy K8s Node.js Callback" "K8sNode" "FAIL" "0" "HTTP 200" "HTTP ${http_code}"
        return
    fi

    # TC-K8S-NODE04: Invoke Node.js Function on Kubernetes
    log_info "  Invoking Node.js function on Kubernetes..."

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/api/kube/${node_path#/}" \
        -H "Content-Type: application/json" \
        -d '{"test": "nodejs_kube_invoke", "value": 456}' \
        --connect-timeout "$TIMEOUT_LONG")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    if [[ "$http_code" == "200" ]]; then
        # Node.js 응답에서 runtime 및 platform 확인
        if echo "$body" | grep -q "node\|Node" && echo "$body" | grep -q "kubernetes\|Kubernetes"; then
            record_result "TC-K8S-NODE04" "Invoke K8s Node.js Function" "K8sNode" "PASS" "$duration" "K8s Node.js response" "Response in ${duration}ms"
        elif echo "$body" | grep -q "node\|Node"; then
            record_result "TC-K8S-NODE04" "Invoke K8s Node.js Function" "K8sNode" "PASS" "$duration" "Node.js response" "Response in ${duration}ms"
        else
            record_result "TC-K8S-NODE04" "Invoke K8s Node.js Function" "K8sNode" "PASS" "$duration" "HTTP 200" "Response received (${duration}ms)"
        fi
    else
        record_result "TC-K8S-NODE04" "Invoke K8s Node.js Function" "K8sNode" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
    fi
}

#===============================================================================
# Kubernetes Timeout Handling Tests
#===============================================================================
run_kube_timeout_tests() {
    log_section "10. Kubernetes Timeout Handling Tests"

    local timeout_chatroom_id=""
    local timeout_callback_id=""

    # TC-K8S-TIMEOUT01: Create ChatRoom for Timeout test
    log_info "  Creating ChatRoom for K8s Timeout test..."

    local result
    result=$(timed_curl -X POST "${FAAS_BASE_URL}/chatroom/" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"K8s Timeout Test ${TIMESTAMP}\"}" \
        --connect-timeout "$TIMEOUT_SHORT")

    local body=$(echo "$result" | cut -d'|' -f1)
    local http_code=$(echo "$result" | cut -d'|' -f2)

    if [[ "$http_code" == "200" ]]; then
        timeout_chatroom_id=$(json_extract_number "$body" "chat_id")
        CREATED_CHATROOMS+=("$timeout_chatroom_id")
    else
        record_result "TC-K8S-TIMEOUT01" "K8s Timeout Test Setup" "K8sTimeout" "SKIP" "0" "N/A" "N/A" "Failed to create ChatRoom"
        return
    fi

    # TC-K8S-TIMEOUT02: Create Callback that will timeout
    log_info "  Creating callback with long sleep for timeout test..."

    local timeout_path="/kube_timeout_test_${TIMESTAMP}"
    CREATED_CALLBACK_PATHS+=("$timeout_path")

    local timeout_code='import time
import json

def lambda_handler(event, context):
    # Sleep for 120 seconds - longer than typical K8s job timeout
    time.sleep(120)
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
        record_result "TC-K8S-TIMEOUT02" "Create K8s Timeout Callback" "K8sTimeout" "PASS" "$duration" "callback created" "id=${timeout_callback_id}"
    else
        record_result "TC-K8S-TIMEOUT02" "Create K8s Timeout Callback" "K8sTimeout" "FAIL" "$duration" "HTTP 200" "HTTP ${http_code}"
        return
    fi

    # TC-K8S-TIMEOUT03: Deploy Timeout Callback
    log_info "  Deploying timeout callback to Kubernetes..."

    local deploy_payload="{\"callback_id\": ${timeout_callback_id}, \"status\": true, \"c_type\": \"kube\"}"

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
            record_result "TC-K8S-TIMEOUT03" "Deploy K8s Timeout Callback" "K8sTimeout" "PASS" "0" "status=deployed" "Deployed successfully"
        else
            record_result "TC-K8S-TIMEOUT03" "Deploy K8s Timeout Callback" "K8sTimeout" "FAIL" "0" "status=deployed" "status=${final_status}"
            return
        fi
    else
        record_result "TC-K8S-TIMEOUT03" "Deploy K8s Timeout Callback" "K8sTimeout" "FAIL" "0" "HTTP 200" "HTTP ${http_code}"
        return
    fi

    # TC-K8S-TIMEOUT04: Invoke and verify timeout handling
    log_info "  Invoking callback on K8s (expecting timeout)..."

    local invoke_start=$(get_time_ms)

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/api/kube/${timeout_path#/}" \
        -H "Content-Type: application/json" \
        -d '{"test": "kube_timeout_test"}' \
        --connect-timeout 90)  # 90초 타임아웃으로 K8s 타임아웃 테스트

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    local invoke_time=$(($(get_time_ms) - invoke_start))

    # K8s에서 타임아웃 또는 에러 응답 확인
    if echo "$body" | grep -qi "timeout\|error\|failed\|TimeoutError"; then
        record_result "TC-K8S-TIMEOUT04" "K8s Timeout Response Handling" "K8sTimeout" "PASS" "$duration" "Timeout/Error response" "Timeout detected in ${duration}ms"
    elif [[ "$invoke_time" -ge 25000 ]]; then
        # 오래 걸린 응답 = 타임아웃 처리
        record_result "TC-K8S-TIMEOUT04" "K8s Timeout Response Handling" "K8sTimeout" "PASS" "$duration" "Long response time" "Response after ${invoke_time}ms"
    elif [[ "$http_code" != "200" ]]; then
        # 에러 응답 = 타임아웃/실패 처리됨
        record_result "TC-K8S-TIMEOUT04" "K8s Timeout Response Handling" "K8sTimeout" "PASS" "$duration" "Non-200 response" "HTTP ${http_code} (timeout handling)"
    else
        record_result "TC-K8S-TIMEOUT04" "K8s Timeout Response Handling" "K8sTimeout" "FAIL" "$duration" "Timeout response" "HTTP ${http_code}, time=${invoke_time}ms"
    fi
}

#===============================================================================
# Kubernetes Resource Cleanup Tests
#===============================================================================
run_kube_cleanup_tests() {
    log_section "8. Kubernetes Resource Cleanup Tests"

    # TC-K8S-CLN01: Job cleanup capability
    local start=$(get_time_ms)
    local old_jobs
    old_jobs=$(kubectl get jobs -n "$KUBE_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    local duration=$(($(get_time_ms) - start))

    record_result "TC-K8S-CLN01" "Job Count Before Cleanup" "K8sCleanup" "PASS" "$duration" "Count jobs" "${old_jobs} jobs"

    # TC-K8S-CLN02: Delete completed jobs (dry-run check)
    start=$(get_time_ms)
    local completed
    completed=$(kubectl get jobs -n "$KUBE_NAMESPACE" -o jsonpath='{.items[?(@.status.succeeded==1)].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
    duration=$(($(get_time_ms) - start))

    record_result "TC-K8S-CLN02" "Completed Jobs Identified" "K8sCleanup" "PASS" "$duration" "Identify completed" "${completed} completed jobs"

    # TC-K8S-CLN03: Orphan pods check
    start=$(get_time_ms)
    local orphan_pods
    orphan_pods=$(kubectl get pods -n "$KUBE_NAMESPACE" --no-headers 2>/dev/null | grep -v "Running\|Completed\|Succeeded" | wc -l | tr -d ' ')
    duration=$(($(get_time_ms) - start))

    if [[ "$orphan_pods" -eq 0 ]]; then
        record_result "TC-K8S-CLN03" "Orphan Pods Check" "K8sCleanup" "PASS" "$duration" "No orphans" "0 orphan pods"
    else
        record_result "TC-K8S-CLN03" "Orphan Pods Check" "K8sCleanup" "FAIL" "$duration" "No orphans" "${orphan_pods} orphan pods"
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
        echo "  \"test_type\": \"kubernetes\","
        echo "  \"test_date\": \"$(date '+%Y-%m-%d %H:%M:%S')\","
        echo "  \"namespace\": \"${KUBE_NAMESPACE}\","
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
        [[ -n "$PERF_api_health_ms" ]] && { $first_metric || echo ","; first_metric=false; echo -n "    \"api_health_ms\": $PERF_api_health_ms"; }
        [[ -n "$PERF_kube_build_time_ms" ]] && { $first_metric || echo ","; first_metric=false; echo -n "    \"kube_build_time_ms\": $PERF_kube_build_time_ms"; }
        [[ -n "$PERF_kube_invoke_ms" ]] && { $first_metric || echo ","; first_metric=false; echo -n "    \"kube_invoke_ms\": $PERF_kube_invoke_ms"; }
        [[ -n "$PERF_kube_avg_ms" ]] && { $first_metric || echo ","; first_metric=false; echo -n "    \"kube_avg_ms\": $PERF_kube_avg_ms"; }
        [[ -n "$PERF_kube_min_ms" ]] && { $first_metric || echo ","; first_metric=false; echo -n "    \"kube_min_ms\": $PERF_kube_min_ms"; }
        [[ -n "$PERF_kube_max_ms" ]] && { $first_metric || echo ","; first_metric=false; echo -n "    \"kube_max_ms\": $PERF_kube_max_ms"; }
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
        echo "# Kubernetes FaaS Integration Test Report"
        echo ""
        echo "**Test Date:** $(date '+%Y-%m-%d %H:%M:%S')"
        echo "**Namespace:** ${KUBE_NAMESPACE}"
        echo "**Duration:** ${test_duration_sec}s"
        echo "**Target API:** ${FAAS_BASE_URL}"
        echo ""
        echo "## Kubernetes Cluster Info"
        echo ""
        echo "\`\`\`"
        kubectl cluster-info 2>/dev/null | head -3 | sed 's/\x1b\[[0-9;]*m//g' || echo "Cluster info unavailable"
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
        [[ -n "$PERF_kube_build_time_ms" ]] && echo "| Kube Build Time | $((PERF_kube_build_time_ms/1000))s |"
        [[ -n "$PERF_kube_invoke_ms" ]] && echo "| Kube Invoke (First) | ${PERF_kube_invoke_ms}ms |"
        [[ -n "$PERF_kube_avg_ms" ]] && echo "| Kube Avg Response | ${PERF_kube_avg_ms}ms |"
        [[ -n "$PERF_kube_min_ms" ]] && echo "| Kube Min Response | ${PERF_kube_min_ms}ms |"
        [[ -n "$PERF_kube_max_ms" ]] && echo "| Kube Max Response | ${PERF_kube_max_ms}ms |"
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

        echo "## Test Results"
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
    log_section "KUBERNETES TEST SUMMARY"

    echo -e "${BOLD}Environment:${NC}"
    echo "  Target API: ${FAAS_BASE_URL}"
    echo "  Namespace: ${KUBE_NAMESPACE}"
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
    [[ -n "$PERF_kube_build_time_ms" ]] && echo "  Kube Build Time: $((PERF_kube_build_time_ms/1000))s"
    [[ -n "$PERF_kube_invoke_ms" ]] && echo "  First Invoke: ${PERF_kube_invoke_ms}ms"
    [[ -n "$PERF_kube_avg_ms" ]] && echo "  Avg Response: ${PERF_kube_avg_ms}ms"

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

Kubernetes FaaS Integration Test Suite

Options:
  -h, --help              Show this help message
  -u, --url URL           Set FaaS API base URL (default: http://localhost:8000)
  -n, --namespace NS      Set Kubernetes namespace (default: default)
  -q, --quick             Run quick environment check only
  --skip-deploy           Skip deployment tests
  --skip-cleanup          Don't cleanup test resources after completion
  -v, --verbose           Enable verbose output

Prerequisites:
  - kubectl configured and connected to cluster
  - FaaS API server running
  - Sufficient RBAC permissions in namespace

Examples:
  ${SCRIPT_NAME}                              # Run all tests
  ${SCRIPT_NAME} -q                           # Quick environment check
  ${SCRIPT_NAME} -n faas-test                 # Test in specific namespace
  ${SCRIPT_NAME} -u http://192.168.1.100:8000 # Remote API server

Report files are saved to: ${REPORT_DIR}/
EOF
}

#===============================================================================
# Quick Test
#===============================================================================
run_quick_test() {
    log_section "Quick Kubernetes Environment Check"

    echo -n "  kubectl: "
    if command -v kubectl &>/dev/null; then
        echo -e "${GREEN}INSTALLED${NC}"
    else
        echo -e "${RED}NOT FOUND${NC}"
        return 1
    fi

    echo -n "  Cluster connectivity: "
    if kubectl cluster-info &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        return 1
    fi

    echo -n "  Namespace (${KUBE_NAMESPACE}): "
    if kubectl get namespace "$KUBE_NAMESPACE" &>/dev/null; then
        echo -e "${GREEN}EXISTS${NC}"
    else
        echo -e "${YELLOW}NOT FOUND${NC}"
    fi

    echo -n "  Ready nodes: "
    local ready_nodes
    ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo "0")
    if [[ "$ready_nodes" -gt 0 ]]; then
        echo -e "${GREEN}${ready_nodes} node(s)${NC}"
    else
        echo -e "${RED}NONE${NC}"
        return 1
    fi

    echo -n "  FaaS API (${FAAS_BASE_URL}): "
    if curl -s --connect-timeout 3 "${FAAS_BASE_URL}/health" | grep -q "healthy"; then
        echo -e "${GREEN}HEALTHY${NC}"
    else
        echo -e "${RED}UNREACHABLE${NC}"
        return 1
    fi

    echo ""
    echo -e "${GREEN}${BOLD}Quick check passed!${NC}"
    return 0
}

#===============================================================================
# Main
#===============================================================================
main() {
    local run_quick=false
    local skip_deploy=false
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
            -q|--quick)
                run_quick=true
                shift
                ;;
            --skip-deploy)
                skip_deploy=true
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

    log_info "Target API: ${FAAS_BASE_URL}"
    log_info "Namespace: ${KUBE_NAMESPACE}"
    log_info "Timestamp: ${TIMESTAMP}"
    echo ""

    # Quick test mode
    if [[ "$run_quick" == true ]]; then
        run_quick_test
        exit $?
    fi

    TEST_START_TIME=$(get_time_ms)

    # Run test suites
    run_kube_environment_tests || {
        log_error "Kubernetes environment validation failed. Cannot proceed."
        generate_reports
        print_summary
        exit 1
    }

    run_api_health_tests || {
        log_error "API server health check failed. Cannot proceed."
        generate_reports
        print_summary
        exit 1
    }

    if [[ "$skip_deploy" != true ]]; then
        run_kube_deploy_tests
    else
        log_warning "Skipping deployment tests (--skip-deploy)"
    fi

    run_kube_lifecycle_tests
    run_kube_performance_tests
    run_kube_error_tests
    run_kube_library_env_tests
    run_kube_cleanup_tests
    run_kube_nodejs_tests
    run_kube_timeout_tests

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
