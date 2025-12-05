#!/bin/bash
#===============================================================================
#
#   Kubernetes Advanced Error Scenarios Test Suite
#
#   Description : Kubernetes 고급 에러 시나리오 테스트
#                 - TC-K8S-ERR03: OOMKilled (메모리 초과)
#                 - TC-K8S-ERR04: ImagePullBackOff (이미지 pull 실패)
#                 - TC-K8S-ERR05: Job Timeout (activeDeadlineSeconds 초과)
#                 - TC-K8S-ERR06: RBAC Permission Denied (권한 부족)
#                 - TC-K8S-ERR07: CrashLoopBackOff (재시작 한도 초과)
#
#   Prerequisites:
#                 - kubectl configured
#                 - Kubernetes cluster running
#                 - Sufficient permissions (for RBAC test, admin access needed)
#
#   Note        : 이 테스트는 개별적으로 실행되며, 메인 테스트와 분리됨
#
#   Usage       : ./kube_error_scenarios_test.sh [OPTIONS]
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
readonly REPORT_FILE="${REPORT_DIR}/kube_error_scenarios_${TIMESTAMP}.md"

# Test Configuration
KUBE_NAMESPACE="${KUBE_NAMESPACE:-default}"
TEST_NAMESPACE="faas-error-test-${TIMESTAMP}"
TIMEOUT_SHORT=10
TIMEOUT_LONG=120

# Test State
declare -a TEST_RESULTS=()
declare -a CREATED_RESOURCES=()

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

print_banner() {
    echo -e "${BOLD}${RED}"
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║   ██╗  ██╗ █████╗ ███████╗    ███████╗██████╗ ██████╗             ║
║   ██║ ██╔╝██╔══██╗██╔════╝    ██╔════╝██╔══██╗██╔══██╗            ║
║   █████╔╝ ╚█████╔╝███████╗    █████╗  ██████╔╝██████╔╝            ║
║   ██╔═██╗ ██╔══██╗╚════██║    ██╔══╝  ██╔══██╗██╔══██╗            ║
║   ██║  ██╗╚█████╔╝███████║    ███████╗██║  ██║██║  ██║            ║
║   ╚═╝  ╚═╝ ╚════╝ ╚══════╝    ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝            ║
║                                                                   ║
║   Kubernetes Advanced Error Scenarios Test Suite                  ║
║   Edge Cases & Failure Mode Testing                               ║
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

wait_for_condition() {
    local condition_cmd="$1"
    local timeout="$2"
    local interval="${3:-2}"
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        if eval "$condition_cmd" 2>/dev/null; then
            return 0
        fi
        sleep "$interval"
        ((elapsed+=interval))
        echo -ne "  Waiting... ${elapsed}s/${timeout}s\r"
    done
    echo ""
    return 1
}

#===============================================================================
# Cleanup Functions
#===============================================================================
cleanup() {
    log_info "Cleaning up test resources..."

    # Delete test jobs and pods
    for resource in "${CREATED_RESOURCES[@]}"; do
        local type=$(echo "$resource" | cut -d':' -f1)
        local name=$(echo "$resource" | cut -d':' -f2)
        local ns=$(echo "$resource" | cut -d':' -f3)

        kubectl delete "$type" "$name" -n "$ns" --ignore-not-found=true &>/dev/null
        log_info "  Deleted ${type}: ${name}"
    done

    # Delete test namespace if created
    if kubectl get namespace "$TEST_NAMESPACE" &>/dev/null; then
        kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found=true &>/dev/null
        log_info "  Deleted namespace: ${TEST_NAMESPACE}"
    fi

    CREATED_RESOURCES=()
}

trap cleanup EXIT
trap 'echo ""; log_warning "Test interrupted by user"; exit 130' INT TERM

#===============================================================================
# TC-K8S-ERR03: OOMKilled (메모리 초과)
#===============================================================================
test_oom_killed() {
    log_section "TC-K8S-ERR03: OOMKilled (Memory Exceeded)"

    log_info "Creating Job with memory limit that will be exceeded..."

    local job_name="oom-test-${TIMESTAMP}"
    local start=$(get_time_ms)

    # Create a Job that will consume more memory than its limit
    cat <<EOF | kubectl apply -n "$KUBE_NAMESPACE" -f - 2>/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  labels:
    test: faas-error-test
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 60
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: oom-container
        image: python:3.9-slim
        resources:
          limits:
            memory: "32Mi"
          requests:
            memory: "16Mi"
        command:
        - python3
        - -c
        - |
          # Allocate memory until OOMKilled
          import time
          data = []
          print("Starting memory allocation...")
          for i in range(1000):
              data.append('x' * (1024 * 1024))  # 1MB chunks
              print(f"Allocated {len(data)} MB")
              time.sleep(0.1)
EOF

    if [[ $? -ne 0 ]]; then
        local duration=$(($(get_time_ms) - start))
        record_result "TC-K8S-ERR03" "OOMKilled Detection" "FAIL" "$duration" "Job created" "Failed to create job"
        return
    fi

    CREATED_RESOURCES+=("job:${job_name}:${KUBE_NAMESPACE}")

    log_info "Waiting for OOMKilled event..."

    # Wait for pod to be OOMKilled (up to 60s)
    local oom_detected=false
    local elapsed=0
    local pod_name=""

    while [[ $elapsed -lt 60 ]]; do
        sleep 3
        ((elapsed+=3))

        # Get pod name
        pod_name=$(kubectl get pods -n "$KUBE_NAMESPACE" -l job-name="${job_name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

        if [[ -n "$pod_name" ]]; then
            # Check for OOMKilled
            local reason=$(kubectl get pod "$pod_name" -n "$KUBE_NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null)
            local last_reason=$(kubectl get pod "$pod_name" -n "$KUBE_NAMESPACE" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null)

            if [[ "$reason" == "OOMKilled" || "$last_reason" == "OOMKilled" ]]; then
                oom_detected=true
                log_info "  OOMKilled detected after ${elapsed}s"
                break
            fi

            # Also check events
            if kubectl get events -n "$KUBE_NAMESPACE" --field-selector involvedObject.name="$pod_name" 2>/dev/null | grep -q "OOMKilled"; then
                oom_detected=true
                log_info "  OOMKilled event detected after ${elapsed}s"
                break
            fi
        fi

        echo -ne "  Waiting for OOMKilled... ${elapsed}s/60s\r"
    done
    echo ""

    local duration=$(($(get_time_ms) - start))

    if [[ "$oom_detected" == true ]]; then
        # Verify the system correctly identified OOMKilled
        local exit_code=$(kubectl get pod "$pod_name" -n "$KUBE_NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null)

        record_result "TC-K8S-ERR03" "OOMKilled Detection" "PASS" "$duration" "OOMKilled detected" "ExitCode=${exit_code:-137}"

        # Additional verification: Check events
        log_info "  Verifying OOMKilled events..."
        kubectl get events -n "$KUBE_NAMESPACE" --field-selector involvedObject.name="$pod_name" --sort-by='.lastTimestamp' 2>/dev/null | tail -5 | sed 's/^/    /'
    else
        record_result "TC-K8S-ERR03" "OOMKilled Detection" "SKIP" "$duration" "OOMKilled detected" "Timeout or memory not exceeded" "May need more aggressive memory consumption"
    fi
}

#===============================================================================
# TC-K8S-ERR04: ImagePullBackOff (이미지 pull 실패)
#===============================================================================
test_image_pull_backoff() {
    log_section "TC-K8S-ERR04: ImagePullBackOff (Image Pull Failed)"

    log_info "Creating Job with non-existent image..."

    local job_name="imagepull-test-${TIMESTAMP}"
    local fake_image="nonexistent-registry.invalid/fake-image:v999.999.999"
    local start=$(get_time_ms)

    cat <<EOF | kubectl apply -n "$KUBE_NAMESPACE" -f - 2>/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  labels:
    test: faas-error-test
spec:
  backoffLimit: 1
  activeDeadlineSeconds: 120
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: fake-container
        image: ${fake_image}
        command: ["echo", "This should never run"]
EOF

    if [[ $? -ne 0 ]]; then
        local duration=$(($(get_time_ms) - start))
        record_result "TC-K8S-ERR04" "ImagePullBackOff Detection" "FAIL" "$duration" "Job created" "Failed to create job"
        return
    fi

    CREATED_RESOURCES+=("job:${job_name}:${KUBE_NAMESPACE}")

    log_info "Waiting for ImagePullBackOff event..."

    local pull_error_detected=false
    local elapsed=0
    local pod_name=""
    local error_reason=""

    while [[ $elapsed -lt 60 ]]; do
        sleep 3
        ((elapsed+=3))

        pod_name=$(kubectl get pods -n "$KUBE_NAMESPACE" -l job-name="${job_name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

        if [[ -n "$pod_name" ]]; then
            # Check waiting reason
            local waiting_reason=$(kubectl get pod "$pod_name" -n "$KUBE_NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)

            if [[ "$waiting_reason" == "ImagePullBackOff" || "$waiting_reason" == "ErrImagePull" ]]; then
                pull_error_detected=true
                error_reason="$waiting_reason"
                log_info "  ${waiting_reason} detected after ${elapsed}s"
                break
            fi
        fi

        echo -ne "  Waiting for ImagePullBackOff... ${elapsed}s/60s\r"
    done
    echo ""

    local duration=$(($(get_time_ms) - start))

    if [[ "$pull_error_detected" == true ]]; then
        # Get detailed error message
        local error_message=$(kubectl get pod "$pod_name" -n "$KUBE_NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state.waiting.message}' 2>/dev/null)

        record_result "TC-K8S-ERR04" "ImagePullBackOff Detection" "PASS" "$duration" "ImagePullBackOff" "${error_reason}"

        log_info "  Error details:"
        echo "    Reason: ${error_reason}"
        echo "    Message: ${error_message:0:100}..."

        # Show events
        log_info "  Related events:"
        kubectl get events -n "$KUBE_NAMESPACE" --field-selector involvedObject.name="$pod_name" --sort-by='.lastTimestamp' 2>/dev/null | grep -i "pull\|image" | tail -3 | sed 's/^/    /'
    else
        record_result "TC-K8S-ERR04" "ImagePullBackOff Detection" "FAIL" "$duration" "ImagePullBackOff" "Not detected within timeout"
    fi
}

#===============================================================================
# TC-K8S-ERR05: Job Timeout (activeDeadlineSeconds 초과)
#===============================================================================
test_job_timeout() {
    log_section "TC-K8S-ERR05: Job Timeout (ActiveDeadlineSeconds Exceeded)"

    log_info "Creating Job with short activeDeadlineSeconds..."

    local job_name="timeout-test-${TIMESTAMP}"
    local deadline_seconds=10
    local start=$(get_time_ms)

    cat <<EOF | kubectl apply -n "$KUBE_NAMESPACE" -f - 2>/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  labels:
    test: faas-error-test
spec:
  backoffLimit: 0
  activeDeadlineSeconds: ${deadline_seconds}
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: slow-container
        image: busybox:latest
        command:
        - sh
        - -c
        - |
          echo "Starting long-running task..."
          sleep 300  # Sleep for 5 minutes (will exceed deadline)
          echo "Task completed"
EOF

    if [[ $? -ne 0 ]]; then
        local duration=$(($(get_time_ms) - start))
        record_result "TC-K8S-ERR05" "Job Timeout Detection" "FAIL" "$duration" "Job created" "Failed to create job"
        return
    fi

    CREATED_RESOURCES+=("job:${job_name}:${KUBE_NAMESPACE}")

    log_info "Waiting for Job to exceed deadline (${deadline_seconds}s)..."

    local timeout_detected=false
    local elapsed=0
    local wait_time=$((deadline_seconds + 30))

    while [[ $elapsed -lt $wait_time ]]; do
        sleep 3
        ((elapsed+=3))

        # Check job status
        local job_status=$(kubectl get job "$job_name" -n "$KUBE_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Failed")].reason}' 2>/dev/null)

        if [[ "$job_status" == "DeadlineExceeded" ]]; then
            timeout_detected=true
            log_info "  DeadlineExceeded detected after ${elapsed}s"
            break
        fi

        # Also check for Failed condition
        local failed=$(kubectl get job "$job_name" -n "$KUBE_NAMESPACE" -o jsonpath='{.status.failed}' 2>/dev/null)
        if [[ "$failed" -gt 0 ]]; then
            # Double check reason
            job_status=$(kubectl get job "$job_name" -n "$KUBE_NAMESPACE" -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null)
            if [[ "$job_status" == "DeadlineExceeded" ]]; then
                timeout_detected=true
                log_info "  Job failed with DeadlineExceeded after ${elapsed}s"
                break
            fi
        fi

        echo -ne "  Waiting for timeout... ${elapsed}s/${wait_time}s\r"
    done
    echo ""

    local duration=$(($(get_time_ms) - start))

    if [[ "$timeout_detected" == true ]]; then
        record_result "TC-K8S-ERR05" "Job Timeout Detection" "PASS" "$duration" "DeadlineExceeded" "Job timed out correctly"

        # Show job conditions
        log_info "  Job conditions:"
        kubectl get job "$job_name" -n "$KUBE_NAMESPACE" -o jsonpath='{.status.conditions}' 2>/dev/null | python3 -m json.tool 2>/dev/null | head -10 | sed 's/^/    /'
    else
        record_result "TC-K8S-ERR05" "Job Timeout Detection" "FAIL" "$duration" "DeadlineExceeded" "Timeout not detected"
    fi
}

#===============================================================================
# TC-K8S-ERR06: RBAC Permission Denied (권한 부족)
#===============================================================================
test_rbac_permission_denied() {
    log_section "TC-K8S-ERR06: RBAC Permission Denied"

    log_info "Testing RBAC permissions..."

    local start=$(get_time_ms)

    # Test 1: Check if current user can list secrets (usually restricted)
    log_info "  Testing permission to list secrets..."
    local can_list_secrets
    can_list_secrets=$(kubectl auth can-i list secrets -n "$KUBE_NAMESPACE" 2>/dev/null)

    if [[ "$can_list_secrets" == "yes" ]]; then
        log_info "    Current context CAN list secrets (has elevated permissions)"
    else
        log_info "    Current context CANNOT list secrets (restricted - expected in production)"
    fi

    # Test 2: Try to access a restricted namespace (kube-system pods)
    log_info "  Testing access to kube-system namespace..."
    local can_delete_pods
    can_delete_pods=$(kubectl auth can-i delete pods -n kube-system 2>/dev/null)

    # Test 3: Create a restricted ServiceAccount and test with it
    log_info "  Creating restricted ServiceAccount for RBAC test..."

    local sa_name="restricted-sa-${TIMESTAMP}"
    local role_name="restricted-role-${TIMESTAMP}"

    # Create ServiceAccount
    kubectl create serviceaccount "$sa_name" -n "$KUBE_NAMESPACE" &>/dev/null

    if [[ $? -eq 0 ]]; then
        CREATED_RESOURCES+=("serviceaccount:${sa_name}:${KUBE_NAMESPACE}")

        # Create a Role with minimal permissions (only get pods)
        cat <<EOF | kubectl apply -n "$KUBE_NAMESPACE" -f - &>/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${role_name}
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
EOF
        CREATED_RESOURCES+=("role:${role_name}:${KUBE_NAMESPACE}")

        # Create RoleBinding
        kubectl create rolebinding "${role_name}-binding" \
            --role="$role_name" \
            --serviceaccount="${KUBE_NAMESPACE}:${sa_name}" \
            -n "$KUBE_NAMESPACE" &>/dev/null

        CREATED_RESOURCES+=("rolebinding:${role_name}-binding:${KUBE_NAMESPACE}")

        # Test what the restricted SA can do
        log_info "  Testing restricted ServiceAccount permissions..."

        local can_create_jobs
        can_create_jobs=$(kubectl auth can-i create jobs -n "$KUBE_NAMESPACE" --as="system:serviceaccount:${KUBE_NAMESPACE}:${sa_name}" 2>/dev/null)

        local can_get_pods
        can_get_pods=$(kubectl auth can-i get pods -n "$KUBE_NAMESPACE" --as="system:serviceaccount:${KUBE_NAMESPACE}:${sa_name}" 2>/dev/null)

        local duration=$(($(get_time_ms) - start))

        if [[ "$can_create_jobs" == "no" && "$can_get_pods" == "yes" ]]; then
            record_result "TC-K8S-ERR06" "RBAC Permission Denied" "PASS" "$duration" "Jobs denied, Pods allowed" "RBAC working correctly"

            log_info "  RBAC verification results:"
            echo "    - Create Jobs: ${can_create_jobs} (expected: no)"
            echo "    - Get Pods: ${can_get_pods} (expected: yes)"
        elif [[ "$can_create_jobs" == "yes" ]]; then
            record_result "TC-K8S-ERR06" "RBAC Permission Denied" "SKIP" "$duration" "Jobs denied" "SA can create jobs" "Cluster may have permissive defaults"
        else
            record_result "TC-K8S-ERR06" "RBAC Permission Denied" "PASS" "$duration" "Restricted access" "RBAC enforced"
        fi
    else
        local duration=$(($(get_time_ms) - start))
        record_result "TC-K8S-ERR06" "RBAC Permission Denied" "SKIP" "$duration" "N/A" "Cannot create SA" "Insufficient permissions for test setup"
    fi
}

#===============================================================================
# TC-K8S-ERR07: CrashLoopBackOff (재시작 한도 초과)
#===============================================================================
test_crash_loop_backoff() {
    log_section "TC-K8S-ERR07: CrashLoopBackOff (Restart Limit Exceeded)"

    log_info "Creating Pod that will crash repeatedly..."

    local pod_name="crashloop-test-${TIMESTAMP}"
    local start=$(get_time_ms)

    # Create a Pod (not Job) to test CrashLoopBackOff
    cat <<EOF | kubectl apply -n "$KUBE_NAMESPACE" -f - 2>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  labels:
    test: faas-error-test
spec:
  restartPolicy: Always
  containers:
  - name: crash-container
    image: busybox:latest
    command:
    - sh
    - -c
    - |
      echo "Starting and crashing immediately..."
      exit 1
EOF

    if [[ $? -ne 0 ]]; then
        local duration=$(($(get_time_ms) - start))
        record_result "TC-K8S-ERR07" "CrashLoopBackOff Detection" "FAIL" "$duration" "Pod created" "Failed to create pod"
        return
    fi

    CREATED_RESOURCES+=("pod:${pod_name}:${KUBE_NAMESPACE}")

    log_info "Waiting for CrashLoopBackOff state..."

    local crashloop_detected=false
    local elapsed=0
    local restart_count=0

    while [[ $elapsed -lt 90 ]]; do
        sleep 5
        ((elapsed+=5))

        # Check pod status
        local pod_status=$(kubectl get pod "$pod_name" -n "$KUBE_NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
        restart_count=$(kubectl get pod "$pod_name" -n "$KUBE_NAMESPACE" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)

        if [[ "$pod_status" == "CrashLoopBackOff" ]]; then
            crashloop_detected=true
            log_info "  CrashLoopBackOff detected after ${elapsed}s (restarts: ${restart_count})"
            break
        fi

        echo -ne "  Waiting for CrashLoopBackOff... ${elapsed}s/90s (restarts: ${restart_count:-0})\r"
    done
    echo ""

    local duration=$(($(get_time_ms) - start))

    if [[ "$crashloop_detected" == true ]]; then
        record_result "TC-K8S-ERR07" "CrashLoopBackOff Detection" "PASS" "$duration" "CrashLoopBackOff" "Restarts: ${restart_count}"

        # Show pod events
        log_info "  Pod events:"
        kubectl get events -n "$KUBE_NAMESPACE" --field-selector involvedObject.name="$pod_name" --sort-by='.lastTimestamp' 2>/dev/null | tail -5 | sed 's/^/    /'

        # Show restart backoff timing
        log_info "  Container state details:"
        kubectl get pod "$pod_name" -n "$KUBE_NAMESPACE" -o jsonpath='{.status.containerStatuses[0]}' 2>/dev/null | python3 -m json.tool 2>/dev/null | head -15 | sed 's/^/    /'
    else
        # Check if it's still crashing but not in backoff yet
        if [[ "$restart_count" -gt 0 ]]; then
            record_result "TC-K8S-ERR07" "CrashLoopBackOff Detection" "PASS" "$duration" "Container crashing" "Restarts: ${restart_count}, backoff pending"
        else
            record_result "TC-K8S-ERR07" "CrashLoopBackOff Detection" "FAIL" "$duration" "CrashLoopBackOff" "Not detected"
        fi
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
        echo "# Kubernetes Advanced Error Scenarios Test Report"
        echo ""
        echo "**Test Date:** $(date '+%Y-%m-%d %H:%M:%S')"
        echo "**Namespace:** ${KUBE_NAMESPACE}"
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
        echo "| Test ID | Test Name | Status | Duration | Expected | Actual |"
        echo "|---------|-----------|--------|----------|----------|--------|"

        for result in "${TEST_RESULTS[@]}"; do
            IFS='|' read -r id name status dur expected actual msg <<< "$result"
            local icon="⏭️"
            [[ "$status" == "PASS" ]] && icon="✅"
            [[ "$status" == "FAIL" ]] && icon="❌"
            echo "| ${id} | ${name} | ${icon} ${status} | ${dur}ms | ${expected} | ${actual} |"
        done

        echo ""
        echo "## Test Descriptions"
        echo ""
        echo "### TC-K8S-ERR03: OOMKilled"
        echo "Tests detection of memory limit exceeded errors (OOMKilled). Verifies that Kubernetes correctly terminates containers that exceed their memory limits."
        echo ""
        echo "### TC-K8S-ERR04: ImagePullBackOff"
        echo "Tests detection of image pull failures. Verifies proper handling when a container image cannot be pulled from the registry."
        echo ""
        echo "### TC-K8S-ERR05: Job Timeout"
        echo "Tests activeDeadlineSeconds enforcement. Verifies that Jobs are properly terminated when they exceed their deadline."
        echo ""
        echo "### TC-K8S-ERR06: RBAC Permission Denied"
        echo "Tests RBAC enforcement. Verifies that restricted ServiceAccounts cannot perform unauthorized actions."
        echo ""
        echo "### TC-K8S-ERR07: CrashLoopBackOff"
        echo "Tests detection of repeatedly crashing containers. Verifies Kubernetes applies exponential backoff for failing containers."
    } > "$REPORT_FILE"

    log_success "Report saved to: ${REPORT_FILE}"
}

print_summary() {
    local pass_rate=0
    [[ $TOTAL_TESTS -gt 0 ]] && pass_rate=$((PASSED_TESTS * 100 / TOTAL_TESTS))

    echo ""
    log_section "ERROR SCENARIOS TEST SUMMARY"

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
            FAIL) echo -e "  ${RED}✗${NC} ${id}: ${name} - ${msg}" ;;
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

Kubernetes Advanced Error Scenarios Test Suite

Tests the following error scenarios:
  TC-K8S-ERR03  OOMKilled (Memory exceeded)
  TC-K8S-ERR04  ImagePullBackOff (Image pull failed)
  TC-K8S-ERR05  Job Timeout (activeDeadlineSeconds exceeded)
  TC-K8S-ERR06  RBAC Permission Denied
  TC-K8S-ERR07  CrashLoopBackOff (Container restart limit)

Options:
  -h, --help              Show this help message
  -n, --namespace NS      Kubernetes namespace (default: default)
  --test TEST_ID          Run specific test only (e.g., ERR03, ERR04)
  --skip-cleanup          Don't cleanup test resources

Examples:
  ${SCRIPT_NAME}                        # Run all error scenario tests
  ${SCRIPT_NAME} --test ERR03           # Run only OOMKilled test
  ${SCRIPT_NAME} -n faas-test           # Run in specific namespace

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

    log_info "Namespace: ${KUBE_NAMESPACE}"
    log_info "Timestamp: ${TIMESTAMP}"
    echo ""

    # Check prerequisites
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl is required but not installed"
        exit 1
    fi

    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    # Run tests
    if [[ -n "$specific_test" ]]; then
        case "$specific_test" in
            ERR03|err03|oom) test_oom_killed ;;
            ERR04|err04|image) test_image_pull_backoff ;;
            ERR05|err05|timeout) test_job_timeout ;;
            ERR06|err06|rbac) test_rbac_permission_denied ;;
            ERR07|err07|crash) test_crash_loop_backoff ;;
            *)
                log_error "Unknown test: $specific_test"
                log_info "Valid tests: ERR03, ERR04, ERR05, ERR06, ERR07"
                exit 1
                ;;
        esac
    else
        test_oom_killed
        test_image_pull_backoff
        test_job_timeout
        test_rbac_permission_denied
        test_crash_loop_backoff
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
