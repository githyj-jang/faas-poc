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
declare -a TEST_RESULTS=()
declare -a ISSUES=()
declare -A PERFORMANCE_METRICS=()

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

    # Delete test jobs
    for job_name in "${CREATED_JOBS[@]}"; do
        if [[ -n "$job_name" ]]; then
            kubectl delete job "$job_name" -n "$KUBE_NAMESPACE" --ignore-not-found=true &>/dev/null
            log_info "  Deleted Job: ${job_name}"
        fi
    done

    # Delete any leftover test pods
    kubectl delete pods -n "$KUBE_NAMESPACE" -l "test=faas-kube-test" --ignore-not-found=true &>/dev/null

    CREATED_JOBS=()
}

cleanup_api_resources() {
    log_info "Cleaning up API resources..."

    for chat_id in "${CREATED_CHATROOMS[@]}"; do
        if [[ -n "$chat_id" ]]; then
            curl -s -X DELETE "${FAAS_BASE_URL}/chatroom/${chat_id}" \
                --connect-timeout 3 &>/dev/null || true
            log_info "  Deleted ChatRoom: ${chat_id}"
        fi
    done

    CREATED_CHATROOMS=()
}

cleanup() {
    cleanup_kube_resources
    cleanup_api_resources
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

    PERFORMANCE_METRICS["api_health_ms"]="$duration"
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

    CURRENT_DEPLOY_PATH="kube_test_${TIMESTAMP}"
    local python_code='import json\nimport os\ndef handler(event):\n    return {\"statusCode\": 200, \"body\": json.dumps({\"message\": \"Hello from K8s!\", \"pod\": os.environ.get(\"HOSTNAME\", \"unknown\")})}'

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
            PERFORMANCE_METRICS["kube_build_time_ms"]="$build_time"

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

    result=$(timed_curl -X POST "${FAAS_BASE_URL}/api/kube/${CURRENT_DEPLOY_PATH}" \
        -H "Content-Type: application/json" \
        -d '{"test": "kube_data"}' \
        --connect-timeout "$TIMEOUT_LONG")

    body=$(echo "$result" | cut -d'|' -f1)
    http_code=$(echo "$result" | cut -d'|' -f2)
    duration=$(echo "$result" | cut -d'|' -f3)

    PERFORMANCE_METRICS["kube_invoke_ms"]="$duration"

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

    if [[ -z "$CURRENT_DEPLOY_PATH" ]]; then
        log_warning "  No deployed function available for performance tests"
        record_result "TC-K8S-PERF01" "Kube Response Time" "K8sPerf" "SKIP" "0" "N/A" "N/A" "No deployed function"
        return
    fi

    # TC-K8S-PERF01: Multiple invocations
    log_info "  Running multiple Kubernetes invocations..."

    local -a response_times=()
    local iterations=3

    for i in $(seq 1 $iterations); do
        local result
        result=$(timed_curl -X POST "${FAAS_BASE_URL}/api/kube/${CURRENT_DEPLOY_PATH}" \
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

        PERFORMANCE_METRICS["kube_avg_ms"]="$avg"
        PERFORMANCE_METRICS["kube_min_ms"]="$min"
        PERFORMANCE_METRICS["kube_max_ms"]="$max"

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
    if [[ -n "$CURRENT_DEPLOY_PATH" ]]; then
        result=$(timed_curl -X DELETE "${FAAS_BASE_URL}/api/kube/${CURRENT_DEPLOY_PATH}" \
            --connect-timeout "$TIMEOUT_SHORT")

        http_code=$(echo "$result" | cut -d'|' -f2)
        duration=$(echo "$result" | cut -d'|' -f3)

        if [[ "$http_code" == "404" || "$http_code" == "405" ]]; then
            record_result "TC-K8S-ERR02" "Wrong Method Kube" "K8sError" "PASS" "$duration" "404 or 405" "HTTP ${http_code}"
        else
            record_result "TC-K8S-ERR02" "Wrong Method Kube" "K8sError" "FAIL" "$duration" "404 or 405" "HTTP ${http_code}"
        fi
    else
        record_result "TC-K8S-ERR02" "Wrong Method Kube" "K8sError" "SKIP" "0" "N/A" "N/A" "No deployed path"
    fi
}

#===============================================================================
# Kubernetes Resource Cleanup Tests
#===============================================================================
run_kube_cleanup_tests() {
    log_section "7. Kubernetes Resource Cleanup Tests"

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
        for key in "${!PERFORMANCE_METRICS[@]}"; do
            echo "    \"${key}\": ${PERFORMANCE_METRICS[$key]},"
        done | sed '$ s/,$//'
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
        [[ -n "${PERFORMANCE_METRICS[kube_build_time_ms]}" ]] && echo "| Kube Build Time | $((${PERFORMANCE_METRICS[kube_build_time_ms]}/1000))s |"
        [[ -n "${PERFORMANCE_METRICS[kube_invoke_ms]}" ]] && echo "| Kube Invoke (First) | ${PERFORMANCE_METRICS[kube_invoke_ms]}ms |"
        [[ -n "${PERFORMANCE_METRICS[kube_avg_ms]}" ]] && echo "| Kube Avg Response | ${PERFORMANCE_METRICS[kube_avg_ms]}ms |"
        [[ -n "${PERFORMANCE_METRICS[kube_min_ms]}" ]] && echo "| Kube Min Response | ${PERFORMANCE_METRICS[kube_min_ms]}ms |"
        [[ -n "${PERFORMANCE_METRICS[kube_max_ms]}" ]] && echo "| Kube Max Response | ${PERFORMANCE_METRICS[kube_max_ms]}ms |"
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
    [[ -n "${PERFORMANCE_METRICS[kube_build_time_ms]}" ]] && echo "  Kube Build Time: $((${PERFORMANCE_METRICS[kube_build_time_ms]}/1000))s"
    [[ -n "${PERFORMANCE_METRICS[kube_invoke_ms]}" ]] && echo "  First Invoke: ${PERFORMANCE_METRICS[kube_invoke_ms]}ms"
    [[ -n "${PERFORMANCE_METRICS[kube_avg_ms]}" ]] && echo "  Avg Response: ${PERFORMANCE_METRICS[kube_avg_ms]}ms"

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
    run_kube_cleanup_tests

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
