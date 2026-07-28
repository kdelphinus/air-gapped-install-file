#!/bin/bash
set -Eeuo pipefail

# ==============================================================================
# MariaDB Galera Cluster 10.11.14 -> 10.11.18 Rolling Upgrade Script
#
# Target Environment: Rocky Linux 9 (RHEL 9)
# Target Version: MariaDB 10.11.18-1.el9.x86_64 / Galera 26.4.27-1.el9.x86_64
# Reference Document: docs/upgrade/galera-10.11.14-to-10.11.18-upgrade-guide.md
# ==============================================================================

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 0. Root 권한 체크
if [ "$EUID" -ne 0 ]; then
  log_error "이 스크립트는 root 권한(sudo)으로 실행해야 합니다."
  exit 1
fi

BASE_DIR=$(cd "$(dirname "$0")/.." && pwd)
PRE_UPGRADE_BACKUP_DIR="/backup/pre-upgrade-10.11.14"
DAILY_DUMP_DIR="/backup/dump"

# OS 감지 (Rocky Linux / RHEL 9 계열)
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID=${ID:-}
  OS_LIKE=${ID_LIKE:-}
else
  log_error "OS 정보(/etc/os-release)를 확인할 수 없습니다."
  exit 1
fi

is_rhel9_like() {
  [[ "$OS_ID" =~ ^(rocky|rhel|centos|almalinux)$ ]] || [[ " ${OS_LIKE:-} " == *" rhel "* ]]
}

if ! is_rhel9_like; then
  log_warn "경고: 이 업그레이드 스크립트는 Rocky Linux 9 / RHEL 9 환경을 기준으로 검증되었습니다. (감지됨: ${OS_ID:-unknown})"
fi

# 1. 사전 상태 점검
check_cluster_status() {
  log_info "=== 1. 현재 패키지 버전 및 Galera 클러스터 상태 점검 ==="
  
  echo -e "\n[설치된 MariaDB/Galera RPM 패키지]"
  rpm -qa --qf '%{NAME} %{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n' | grep -Ei '^(MariaDB|galera-4)' | sort || true

  if ! command -v mariadb &>/dev/null; then
    log_error "mariadb 클라이언트 명령어를 찾을 수 없습니다."
    return 1
  fi

  echo -e "\n[Galera 클러스터 글로벌 상태]"
  mariadb -NBe "
SELECT @@hostname, VERSION();
SHOW GLOBAL STATUS WHERE Variable_name IN (
  'wsrep_cluster_size',
  'wsrep_cluster_status',
  'wsrep_local_state_comment',
  'wsrep_ready',
  'wsrep_connected'
);
SHOW GLOBAL VARIABLES LIKE 'wsrep_desync';
" || true

  local cluster_size
  local cluster_status
  local local_state
  local ready
  local connected
  local desync

  cluster_size=$(mariadb -NBe "SHOW GLOBAL STATUS LIKE 'wsrep_cluster_size'" 2>/dev/null | awk '{print $2}' || echo "N/A")
  cluster_status=$(mariadb -NBe "SHOW GLOBAL STATUS LIKE 'wsrep_cluster_status'" 2>/dev/null | awk '{print $2}' || echo "N/A")
  local_state=$(mariadb -NBe "SHOW GLOBAL STATUS LIKE 'wsrep_local_state_comment'" 2>/dev/null | awk '{print $2}' || echo "N/A")
  ready=$(mariadb -NBe "SHOW GLOBAL STATUS LIKE 'wsrep_ready'" 2>/dev/null | awk '{print $2}' || echo "N/A")
  connected=$(mariadb -NBe "SHOW GLOBAL STATUS LIKE 'wsrep_connected'" 2>/dev/null | awk '{print $2}' || echo "N/A")
  desync=$(mariadb -NBe "SHOW GLOBAL VARIABLES LIKE 'wsrep_desync'" 2>/dev/null | awk '{print $2}' || echo "N/A")

  log_info "클러스터 상태 점검 요약:"
  echo "  - wsrep_cluster_size: ${cluster_size} (기대값: 3)"
  echo "  - wsrep_cluster_status: ${cluster_status} (기대값: Primary)"
  echo "  - wsrep_local_state_comment: ${local_state} (기대값: Synced)"
  echo "  - wsrep_ready: ${ready} (기대값: ON)"
  echo "  - wsrep_connected: ${connected} (기대값: ON)"
  echo "  - wsrep_desync: ${desync} (기대값: OFF)"

  if [ "${cluster_status}" = "Primary" ] && [ "${local_state}" = "Synced" ] && [ "${ready}" = "ON" ] && [ "${connected}" = "ON" ]; then
    log_success "Galera 클러스터 상태가 정상(Primary/Synced)입니다."
  else
    log_warn "주의: Galera 클러스터 상태가 권장 사전 조건(Primary & Synced)과 다릅니다."
  fi
}

# 2. 업그레이드 전 Dump 보존 및 무결성 검증 (선택 / DB1용)
preserve_pre_upgrade_backup() {
  log_info "=== 2. 업그레이드 전 Dump 보존 및 무결성 검증 ==="

  if [ ! -d "${DAILY_DUMP_DIR}" ]; then
    log_warn "일일 Dump 디렉터리(${DAILY_DUMP_DIR})가 존재하지 않습니다. Dump 보존을 스킵합니다."
    return 0
  fi

  local latest_dump
  latest_dump=$(find "${DAILY_DUMP_DIR}" -maxdepth 1 -type f -name "mariadb_full_*.sql.gz" -printf "%T@ %p\n" 2>/dev/null | sort -nr | head -1 | cut -d" " -f2-)

  if [ -z "${latest_dump}" ]; then
    log_warn "보존 대상 최신 Dump 파일(mariadb_full_*.sql.gz)을 찾을 수 없습니다."
    return 0
  fi

  log_info "보존 대상 Dump 파일: ${latest_dump}"
  install -d -o root -g root -m 700 "${PRE_UPGRADE_BACKUP_DIR}"
  cp -a -- "${latest_dump}" "${PRE_UPGRADE_BACKUP_DIR}/"

  log_info "Dump 무결성 검증 (SHA256 및 gzip) 진행 중..."
  (
    cd "${PRE_UPGRADE_BACKUP_DIR}"
    sha256sum -- *.sql.gz > SHA256SUMS
    sha256sum -c SHA256SUMS
    gzip -t -- *.sql.gz
    chmod 600 -- *.sql.gz SHA256SUMS
  )
  log_success "업그레이드 전 Dump 보존 및 무결성 검증 완료: ${PRE_UPGRADE_BACKUP_DIR}"
}

# 3. 노드 롤링 업그레이드 수행
perform_node_upgrade() {
  log_info "=== 3. 노드 MariaDB 10.11.18 업그레이드 시작 ==="

  # 3.1 MariaDB 서비스 중지
  log_info "3.1 MariaDB 서비스 중지..."
  systemctl stop mariadb

  # 3.2 패키지 업그레이드 (DNF versionlock / exclude 우회)
  log_info "3.2 MariaDB 10.11.18 및 Galera 패키지 업그레이드 설치..."
  dnf --disableexcludes=all --disableplugin=versionlock install -y \
    MariaDB-server-10.11.18-1.el9.x86_64 \
    MariaDB-client-10.11.18-1.el9.x86_64 \
    MariaDB-common-10.11.18-1.el9.x86_64 \
    MariaDB-shared-10.11.18-1.el9.x86_64 \
    MariaDB-backup-10.11.18-1.el9.x86_64 \
    galera-4-26.4.27-1.el9.x86_64

  log_success "패키지 업그레이드 설치 완료."

  # 3.3 MariaDB 시작 및 Synced 대기
  log_info "3.3 MariaDB 서비스 비동기 시작 및 Synced 동기화 대기..."
  systemctl start --no-block mariadb

  local timeout=300
  local elapsed=0
  local synced=false

  log_info "클러스터 동기화(Synced 상태) 복구 대기 중 (최대 ${timeout}초)..."
  while [ $elapsed -lt $timeout ]; do
    if systemctl is-active --quiet mariadb; then
      local state
      state=$(mariadb -NBe "SHOW GLOBAL STATUS LIKE 'wsrep_local_state_comment'" 2>/dev/null | awk '{print $2}' || true)
      local ready
      ready=$(mariadb -NBe "SHOW GLOBAL STATUS LIKE 'wsrep_ready'" 2>/dev/null | awk '{print $2}' || true)

      if [ "${state}" = "Synced" ] && [ "${ready}" = "ON" ]; then
        synced=true
        break
      fi
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  if [ "${synced}" = true ]; then
    log_success "MariaDB 정상 기동 및 Galera Synced 동기화 완료! (${elapsed}초 소요)"
  else
    log_error "타임아웃(${timeout}초) 내에 MariaDB가 Synced 상태에 도달하지 못했습니다."
    systemctl status mariadb --no-pager || true
    return 1
  fi

  # 3.4 시스템 테이블 및 전체 DB 스키마 업그레이드
  log_info "3.4 mariadb-upgrade 실행 (1단계: --upgrade-system-tables)..."
  mariadb-upgrade --force --skip-write-binlog --upgrade-system-tables

  log_info "mariadb-upgrade 실행 (2단계: 전체 스키마 검사)..."
  mariadb-upgrade --force --skip-write-binlog

  local upgrade_info_file="/var/lib/mysql/mysql_upgrade_info"
  if [ -f "${upgrade_info_file}" ]; then
    local installed_ver
    installed_ver=$(cat "${upgrade_info_file}")
    log_info "mysql_upgrade_info 버전: ${installed_ver}"
    if [[ "${installed_ver}" == *"10.11.18"* ]]; then
      log_success "mariadb-upgrade 정상 완료 확인 (${installed_ver})."
    else
      log_warn "mysql_upgrade_info 내용이 10.11.18과 다릅니다: ${installed_ver}"
    fi
  fi

  # 3.5 업그레이드 후 상태 검증
  log_info "3.5 업그레이드 결과 및 최종 클러스터 상태 검증..."
  check_cluster_status
}

# 4. DB1 백업 서비스 테스트 (선택 / DB1 전용)
verify_db1_backup() {
  log_info "=== 4. DB1 백업 서비스 수동 실행 및 타이머 활성화 ==="

  if systemctl list-unit-files | grep -q "mariadb-backup-dump.service"; then
    log_info "mariadb-backup-dump.service 실행 중..."
    systemctl start mariadb-backup-dump.service
    systemctl status mariadb-backup-dump.service --no-pager || true

    log_info "mariadb-backup-dump.timer 활성화..."
    systemctl enable --now mariadb-backup-dump.timer
    systemctl list-timers mariadb-backup-dump.timer --all || true
    log_success "DB1 백업 서비스 검증 및 타이머 설정 완료."
  else
    log_warn "mariadb-backup-dump.service 가 존재하지 않습니다. 스킵합니다."
  fi
}

# 사용법 표시
usage() {
  echo "사용법: $0 [옵션]"
  echo "  --check-only      : 클러스터 상태 및 설치된 RPM 패키지 사전 점검만 수행"
  echo "  --backup-dump     : 업그레이드 전 Dump 보존 및 무결성 검증 (DB1 권장)"
  echo "  --upgrade-node    : 현재 노드의 10.11.18 패키지 업그레이드 및 mariadb-upgrade 수행"
  echo "  --verify-backup   : 업그레이드 후 백업 서비스 동작 검증 및 타이머 활성화 (DB1 전용)"
  echo "  --all             : 사전 점검 -> Dump 보존(있을경우) -> 노드 업그레이드 전체 수행"
  echo "  -h, --help        : 도움말 표시"
}

# 메인 실행 로직
ACTION=""

if [ $# -eq 0 ]; then
  ACTION="all"
else
  case "$1" in
    --check-only) ACTION="check" ;;
    --backup-dump) ACTION="backup" ;;
    --upgrade-node) ACTION="upgrade" ;;
    --verify-backup) ACTION="verify_backup" ;;
    --all) ACTION="all" ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "알 수 없는 옵션: $1"; usage; exit 1 ;;
  esac
fi

case "$ACTION" in
  check)
    check_cluster_status
    ;;
  backup)
    preserve_pre_upgrade_backup
    ;;
  upgrade)
    check_cluster_status
    perform_node_upgrade
    ;;
  verify_backup)
    verify_db1_backup
    ;;
  all)
    check_cluster_status
    preserve_pre_upgrade_backup
    perform_node_upgrade
    ;;
esac

log_success "🎉 작업을 완료했습니다."
