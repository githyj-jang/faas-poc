#!/bin/bash
#===============================================================================
#
#   Docker & Container Health Check Script
#
#   Description : Docker 환경 및 FaaS 컨테이너 상태 점검
#                 - Docker Daemon Status
#                 - Container Resource Usage
#                 - Image Management
#                 - Network Diagnostics
#
#===============================================================================

set -o pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }

section() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

#===============================================================================
# Docker Daemon Check
#===============================================================================
check_docker_daemon() {
    section "Docker Daemon Status"

    # Docker 설치 확인
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        return 1
    fi

    # Docker 버전
    local docker_version
    docker_version=$(docker --version 2>/dev/null)
    log_info "Version: ${docker_version}"

    # Docker daemon 상태
    if docker info &> /dev/null; then
        log_success "Docker daemon is running"

        # 시스템 정보
        local containers=$(docker info --format '{{.Containers}}')
        local running=$(docker info --format '{{.ContainersRunning}}')
        local images=$(docker info --format '{{.Images}}')

        echo ""
        echo "  Containers: ${containers} (Running: ${running})"
        echo "  Images: ${images}"

        # 디스크 사용량
        local disk_usage
        disk_usage=$(docker system df --format "table {{.Type}}\t{{.Size}}\t{{.Reclaimable}}" 2>/dev/null)
        if [[ -n "$disk_usage" ]]; then
            echo ""
            echo "  Disk Usage:"
            echo "$disk_usage" | sed 's/^/    /'
        fi
    else
        log_error "Docker daemon is not running"
        return 1
    fi
}

#===============================================================================
# FaaS Container Check
#===============================================================================
check_faas_containers() {
    section "FaaS Callback Containers"

    # callback_ 이미지 확인
    local callback_images
    callback_images=$(docker images --format "{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}" | grep "callback_" 2>/dev/null)

    if [[ -n "$callback_images" ]]; then
        log_success "Found FaaS callback images:"
        echo ""
        echo "  IMAGE                          SIZE        CREATED"
        echo "  ─────────────────────────────  ──────────  ────────────"
        echo "$callback_images" | while read -r line; do
            echo "  $line"
        done
    else
        log_warning "No FaaS callback images found"
    fi

    echo ""

    # 실행 중인 callback 컨테이너
    local running_containers
    running_containers=$(docker ps --format "{{.Names}}\t{{.Status}}\t{{.Ports}}" --filter "name=callback" 2>/dev/null)

    if [[ -n "$running_containers" ]]; then
        log_info "Running callback containers:"
        echo ""
        echo "  NAME                   STATUS              PORTS"
        echo "  ─────────────────────  ──────────────────  ─────────────"
        echo "$running_containers" | while read -r line; do
            echo "  $line"
        done
    else
        log_info "No callback containers currently running"
    fi
}

#===============================================================================
# Resource Usage Check
#===============================================================================
check_resource_usage() {
    section "Resource Usage"

    # 컨테이너 리소스 사용량
    local stats
    stats=$(docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" 2>/dev/null | head -20)

    if [[ $(echo "$stats" | wc -l) -gt 1 ]]; then
        log_info "Container Resource Usage:"
        echo ""
        echo "$stats" | sed 's/^/  /'
    else
        log_info "No running containers to show stats"
    fi

    echo ""

    # 호스트 시스템 리소스
    log_info "Host System Resources:"
    echo ""

    # CPU
    if command -v top &> /dev/null; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            local cpu_usage
            cpu_usage=$(top -l 1 | grep "CPU usage" | awk '{print $3}')
            echo "  CPU Usage: ${cpu_usage}"
        else
            local cpu_usage
            cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}')
            echo "  CPU Usage: ${cpu_usage}%"
        fi
    fi

    # Memory
    if [[ "$OSTYPE" == "darwin"* ]]; then
        local mem_info
        mem_info=$(vm_stat | head -5)
        echo "  Memory: (see vm_stat for details)"
    else
        local mem_info
        mem_info=$(free -h 2>/dev/null | grep Mem | awk '{print "Total: "$2", Used: "$3", Available: "$7}')
        echo "  Memory: ${mem_info}"
    fi

    # Disk
    local disk_info
    disk_info=$(df -h / | tail -1 | awk '{print "Total: "$2", Used: "$3" ("$5"), Available: "$4}')
    echo "  Disk: ${disk_info}"
}

#===============================================================================
# Network Check
#===============================================================================
check_network() {
    section "Network Diagnostics"

    # Docker 네트워크
    log_info "Docker Networks:"
    echo ""
    docker network ls --format "  {{.Name}}\t{{.Driver}}\t{{.Scope}}" 2>/dev/null

    echo ""

    # 포트 확인
    log_info "Port Status:"
    echo ""

    local ports_to_check=(8000 5432 6379 80 443)
    for port in "${ports_to_check[@]}"; do
        if command -v lsof &> /dev/null; then
            local pid
            pid=$(lsof -ti :"$port" 2>/dev/null | head -1)
            if [[ -n "$pid" ]]; then
                local process
                process=$(ps -p "$pid" -o comm= 2>/dev/null)
                echo -e "  Port ${port}: ${GREEN}IN USE${NC} (PID: ${pid}, Process: ${process})"
            else
                echo -e "  Port ${port}: ${YELLOW}AVAILABLE${NC}"
            fi
        else
            if nc -z localhost "$port" 2>/dev/null; then
                echo -e "  Port ${port}: ${GREEN}IN USE${NC}"
            else
                echo -e "  Port ${port}: ${YELLOW}AVAILABLE${NC}"
            fi
        fi
    done
}

#===============================================================================
# Cleanup Recommendations
#===============================================================================
show_cleanup_recommendations() {
    section "Cleanup Recommendations"

    # 중지된 컨테이너
    local stopped_count
    stopped_count=$(docker ps -aq --filter "status=exited" | wc -l | tr -d ' ')
    if [[ "$stopped_count" -gt 0 ]]; then
        log_warning "Found ${stopped_count} stopped containers"
        echo "  Run: docker container prune"
    fi

    # 미사용 이미지
    local dangling_count
    dangling_count=$(docker images -q --filter "dangling=true" | wc -l | tr -d ' ')
    if [[ "$dangling_count" -gt 0 ]]; then
        log_warning "Found ${dangling_count} dangling images"
        echo "  Run: docker image prune"
    fi

    # 미사용 볼륨
    local unused_volumes
    unused_volumes=$(docker volume ls -q --filter "dangling=true" | wc -l | tr -d ' ')
    if [[ "$unused_volumes" -gt 0 ]]; then
        log_warning "Found ${unused_volumes} unused volumes"
        echo "  Run: docker volume prune"
    fi

    # 전체 정리
    local total_reclaimable
    total_reclaimable=$(docker system df --format '{{.Reclaimable}}' 2>/dev/null | head -1)
    if [[ -n "$total_reclaimable" ]]; then
        echo ""
        log_info "Total reclaimable space: ${total_reclaimable}"
        echo "  Run: docker system prune -a (CAUTION: removes all unused data)"
    fi

    # 정리할 것이 없으면
    if [[ "$stopped_count" -eq 0 && "$dangling_count" -eq 0 && "$unused_volumes" -eq 0 ]]; then
        log_success "System is clean, no cleanup needed"
    fi
}

#===============================================================================
# Quick Actions
#===============================================================================
show_quick_actions() {
    section "Quick Actions"

    echo "  Available commands:"
    echo ""
    echo "  ${BOLD}Cleanup:${NC}"
    echo "    docker container prune -f     # Remove stopped containers"
    echo "    docker image prune -f         # Remove dangling images"
    echo "    docker system prune -f        # Remove all unused data"
    echo ""
    echo "  ${BOLD}FaaS Specific:${NC}"
    echo "    docker images | grep callback_    # List callback images"
    echo "    docker rmi \$(docker images -q 'callback_*')  # Remove all callback images"
    echo ""
    echo "  ${BOLD}Monitoring:${NC}"
    echo "    docker stats                  # Real-time resource usage"
    echo "    docker logs -f <container>    # Follow container logs"
}

#===============================================================================
# Main
#===============================================================================
main() {
    echo ""
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║        Docker & Container Health Check                        ║${NC}"
    echo -e "${BOLD}${CYAN}║        FaaS Infrastructure Diagnostics                        ║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"

    check_docker_daemon || exit 1
    check_faas_containers
    check_resource_usage
    check_network
    show_cleanup_recommendations
    show_quick_actions

    echo ""
    log_success "Health check completed at $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
}

main "$@"
