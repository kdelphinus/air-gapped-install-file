#!/bin/bash
set -Eeuo pipefail

# ==============================================================================
# MariaDB Galera Cluster 10.11.14 -> 10.11.18 Rolling Upgrade Script
#
# Target OS: Rocky Linux / RHEL 9 x86_64
# Target MariaDB: 10.11.18-1.el9
# Target Galera: 26.4.27-1.el9
# Reference:
#   docs/upgrade/galera-10.11.14-to-10.11.18-upgrade-guide.md
# ==============================================================================

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  NC=""
fi

log_info() {
  printf '%s[INFO]%s %s\n' "${BLUE}" "${NC}" "$*"
}

log_success() {
  printf '%s[OK]%s %s\n' "${GREEN}" "${NC}" "$*"
}

log_warn() {
  printf '%s[WARN]%s %s\n' "${YELLOW}" "${NC}" "$*"
}

log_error() {
  printf '%s[ERROR]%s %s\n' "${RED}" "${NC}" "$*" >&2
}

die() {
  log_error "$*"
  exit 1
}

usage() {
  cat <<'EOF'
사용법:
  upgrade_galera_10.11.18.sh --check-only
  upgrade_galera_10.11.18.sh --backup-dump --node-role db1
  upgrade_galera_10.11.18.sh --upgrade-node --node-role <db1|db2|db3> --yes
  upgrade_galera_10.11.18.sh --verify-backup --node-role db1
  upgrade_galera_10.11.18.sh --all --node-role <db1|db2|db3> --yes

옵션:
  --check-only
      현재 RPM과 Galera 상태만 점검합니다. 시스템을 변경하지 않습니다.

  --backup-dump
      DB1의 최신 논리 Dump를 업그레이드 전 보존 경로에 복사하고
      SHA256 및 gzip 무결성을 검증합니다.

  --upgrade-node
      현재 노드만 MariaDB 10.11.18과 Galera 26.4.27로 업그레이드합니다.

  --verify-backup
      DB1의 백업 서비스를 실행하고 결과와 타이머를 검증합니다.

  --all
      엄격한 사전 점검 후 현재 노드를 업그레이드합니다.
      db1에서는 업그레이드 전 Dump 보존도 함께 수행합니다.

  --node-role <db1|db2|db3>
      현재 작업 노드의 역할입니다. 변경 작업에서는 필수입니다.

  --yes
      업그레이드 실행을 명시적으로 승인합니다.
      --upgrade-node 또는 --all에서 필수입니다.

  -h, --help
      도움말을 표시합니다.

환경 변수:
  EXPECTED_CLUSTER_SIZE
      정상 클러스터 크기입니다. 기본값은 3입니다.

  SYNC_TIMEOUT
      업그레이드 후 Synced 상태 대기 시간(초)입니다. 기본값은 1800입니다.

  UPGRADE_TIMEOUT
      각 mariadb-upgrade 단계의 제한 시간(초)입니다. 기본값은 1800입니다.

권장 롤링 순서:
  db3 -> db2 -> db1
EOF
}

ACTION=""
NODE_ROLE=""
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only)
      [[ -z "${ACTION}" ]] || die "작업 옵션은 하나만 지정할 수 있습니다."
      ACTION="check"
      shift
      ;;
    --backup-dump)
      [[ -z "${ACTION}" ]] || die "작업 옵션은 하나만 지정할 수 있습니다."
      ACTION="backup"
      shift
      ;;
    --upgrade-node)
      [[ -z "${ACTION}" ]] || die "작업 옵션은 하나만 지정할 수 있습니다."
      ACTION="upgrade"
      shift
      ;;
    --verify-backup)
      [[ -z "${ACTION}" ]] || die "작업 옵션은 하나만 지정할 수 있습니다."
      ACTION="verify_backup"
      shift
      ;;
    --all)
      [[ -z "${ACTION}" ]] || die "작업 옵션은 하나만 지정할 수 있습니다."
      ACTION="all"
      shift
      ;;
    --node-role)
      [[ $# -ge 2 ]] || die "--node-role 뒤에 db1, db2 또는 db3를 지정해야 합니다."
      NODE_ROLE="${2,,}"
      shift 2
      ;;
    --yes)
      ASSUME_YES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_error "알 수 없는 옵션: $1"
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${ACTION}" ]]; then
  usage
  exit 2
fi

if [[ "${EUID}" -ne 0 ]]; then
  die "이 작업은 root 권한이 필요합니다. sudo로 실행하십시오."
fi

readonly SOURCE_MARIADB_VERSION="10.11.14"
readonly TARGET_MARIADB_VERSION="10.11.18"
readonly TARGET_MARIADB_RPM="10.11.18-1.el9.x86_64"
readonly TARGET_GALERA_RPM="26.4.27-1.el9.x86_64"
readonly PRE_UPGRADE_BACKUP_DIR="/backup/pre-upgrade-10.11.14"
readonly DAILY_DUMP_DIR="/backup/dump"
readonly UPGRADE_INFO_FILE="/var/lib/mysql/mysql_upgrade_info"
readonly LOCK_FILE="/run/lock/mariadb-galera-10.11.18-upgrade.lock"

readonly EXPECTED_CLUSTER_SIZE="${EXPECTED_CLUSTER_SIZE:-3}"
readonly SYNC_TIMEOUT="${SYNC_TIMEOUT:-1800}"
readonly UPGRADE_TIMEOUT="${UPGRADE_TIMEOUT:-1800}"

readonly -a TARGET_PACKAGES=(
  "MariaDB-server-10.11.18-1.el9.x86_64"
  "MariaDB-client-10.11.18-1.el9.x86_64"
  "MariaDB-common-10.11.18-1.el9.x86_64"
  "MariaDB-shared-10.11.18-1.el9.x86_64"
  "MariaDB-backup-10.11.18-1.el9.x86_64"
  "galera-4-26.4.27-1.el9.x86_64"
)

on_error() {
  local rc=$?
  local line=${BASH_LINENO[0]:-unknown}
  local command=${BASH_COMMAND:-unknown}

  trap - ERR
  log_error "작업이 실패했습니다. 종료 코드=${rc}, 줄=${line}, 명령=${command}"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl status mariadb --no-pager -l || true
  fi

  if command -v journalctl >/dev/null 2>&1; then
    journalctl -u mariadb -n 50 --no-pager || true
  fi

  exit "${rc}"
}

trap on_error ERR

validate_positive_integer() {
  local name=$1
  local value=$2

  [[ "${value}" =~ ^[1-9][0-9]*$ ]] ||
    die "${name} 값은 1 이상의 정수여야 합니다: ${value}"
}

validate_positive_integer "EXPECTED_CLUSTER_SIZE" "${EXPECTED_CLUSTER_SIZE}"
validate_positive_integer "SYNC_TIMEOUT" "${SYNC_TIMEOUT}"
validate_positive_integer "UPGRADE_TIMEOUT" "${UPGRADE_TIMEOUT}"

require_node_role() {
  case "${NODE_ROLE}" in
    db1|db2|db3)
      ;;
    *)
      die "--node-role db1, db2 또는 db3를 지정해야 합니다."
      ;;
  esac
}

require_upgrade_confirmation() {
  if [[ "${ASSUME_YES}" != true ]]; then
    die "업그레이드 실행에는 --yes 옵션이 필요합니다."
  fi
}

acquire_lock() {
  exec 9>"${LOCK_FILE}"
  flock -n 9 ||
    die "이 노드에서 다른 업그레이드 또는 백업 검증 작업이 실행 중입니다."
}

check_os() {
  [[ -r /etc/os-release ]] ||
    die "/etc/os-release 파일을 읽을 수 없습니다."

  # shellcheck disable=SC1091
  . /etc/os-release

  local os_id=${ID:-unknown}
  local os_like=${ID_LIKE:-}
  local version_id=${VERSION_ID:-}
  local major_version=${version_id%%.*}

  if [[ ! "${os_id}" =~ ^(rocky|rhel|centos|almalinux)$ ]] &&
    [[ " ${os_like} " != *" rhel "* ]]; then
    die "지원하지 않는 OS입니다: ID=${os_id}, ID_LIKE=${os_like:-none}"
  fi

  [[ "${major_version}" == "9" ]] ||
    die "Rocky Linux/RHEL 9 계열만 지원합니다: VERSION_ID=${version_id:-unknown}"

  [[ "$(uname -m)" == "x86_64" ]] ||
    die "x86_64 아키텍처만 지원합니다: $(uname -m)"

  log_success "OS 사전 점검 완료: ${PRETTY_NAME:-${os_id}}"
}

require_common_commands() {
  local command_name
  local -a commands=(
    awk
    chmod
    cp
    cut
    find
    flock
    grep
    gzip
    head
    hostname
    install
    journalctl
    mariadb
    mariadb-upgrade
    rpm
    sha256sum
    sort
    systemctl
    timeout
  )

  for command_name in "${commands[@]}"; do
    command -v "${command_name}" >/dev/null 2>&1 ||
      die "필수 명령을 찾을 수 없습니다: ${command_name}"
  done
}

query_status() {
  local variable_name=$1

  mariadb --batch --skip-column-names \
    -e "SHOW GLOBAL STATUS LIKE '${variable_name}';" |
    awk 'NR == 1 {print $2}'
}

query_variable() {
  local variable_name=$1

  mariadb --batch --skip-column-names \
    -e "SHOW GLOBAL VARIABLES LIKE '${variable_name}';" |
    awk 'NR == 1 {print $2}'
}

print_installed_packages() {
  rpm -qa --qf \
    '%{NAME} %{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n' |
    grep -Ei '^(MariaDB|galera-4)' |
    sort || true
}

check_cluster_status() {
  local cluster_size
  local cluster_status
  local local_state
  local ready
  local connected
  local desync

  log_info "현재 MariaDB 및 Galera 상태를 확인합니다."

  systemctl is-active --quiet mariadb ||
    die "MariaDB 서비스가 active 상태가 아닙니다."

  mariadb -NBe "SELECT 1;" >/dev/null ||
    die "로컬 MariaDB 소켓으로 접속할 수 없습니다."

  cluster_size=$(query_status "wsrep_cluster_size")
  cluster_status=$(query_status "wsrep_cluster_status")
  local_state=$(query_status "wsrep_local_state_comment")
  ready=$(query_status "wsrep_ready")
  connected=$(query_status "wsrep_connected")
  desync=$(query_variable "wsrep_desync")

  printf '%s\n' \
    "  - wsrep_cluster_size: ${cluster_size} (기대값: ${EXPECTED_CLUSTER_SIZE})" \
    "  - wsrep_cluster_status: ${cluster_status} (기대값: Primary)" \
    "  - wsrep_local_state_comment: ${local_state} (기대값: Synced)" \
    "  - wsrep_ready: ${ready} (기대값: ON)" \
    "  - wsrep_connected: ${connected} (기대값: ON)" \
    "  - wsrep_desync: ${desync} (기대값: OFF)"

  [[ "${cluster_size}" == "${EXPECTED_CLUSTER_SIZE}" ]] ||
    die "클러스터 크기가 ${EXPECTED_CLUSTER_SIZE}이 아닙니다."
  [[ "${cluster_status}" == "Primary" ]] ||
    die "클러스터가 Primary 상태가 아닙니다."
  [[ "${local_state}" == "Synced" ]] ||
    die "현재 노드가 Synced 상태가 아닙니다."
  [[ "${ready}" == "ON" ]] ||
    die "현재 노드의 wsrep_ready가 ON이 아닙니다."
  [[ "${connected}" == "ON" ]] ||
    die "현재 노드의 wsrep_connected가 ON이 아닙니다."
  [[ "${desync}" == "OFF" ]] ||
    die "현재 노드의 wsrep_desync가 OFF가 아닙니다."

  log_success "Galera 사전 조건이 모두 정상입니다."
}

check_source_version() {
  local current_version

  current_version=$(mariadb -NBe "SELECT VERSION();" | cut -d- -f1)

  [[ "${current_version}" == "${SOURCE_MARIADB_VERSION}" ]] ||
    die "현재 MariaDB 버전이 ${SOURCE_MARIADB_VERSION}이 아닙니다: ${current_version}"

  log_success "업그레이드 시작 버전 확인: ${current_version}"
}

selinux_port_is_mysqld() {
  local protocol=$1
  local port=$2

  semanage port -l |
    awk -v protocol="${protocol}" \
      '$1 == "mysqld_port_t" && $2 == protocol {print $0}' |
    grep -Eq "(^|[ ,])${port}([, ]|$)"
}

check_selinux_preflight() {
  local enforce_state

  command -v getenforce >/dev/null 2>&1 ||
    die "getenforce 명령을 찾을 수 없습니다."

  enforce_state=$(getenforce)
  if [[ "${enforce_state}" != "Enforcing" ]]; then
    log_warn "SELinux가 Enforcing 상태가 아닙니다: ${enforce_state}"
    return 0
  fi

  command -v semanage >/dev/null 2>&1 ||
    die "SELinux 포트 확인에 필요한 semanage 명령을 찾을 수 없습니다."
  command -v semodule >/dev/null 2>&1 ||
    die "SELinux 모듈 확인에 필요한 semodule 명령을 찾을 수 없습니다."

  selinux_port_is_mysqld tcp 4444 ||
    die "SELinux mysqld_port_t에 4444/TCP가 등록되지 않았습니다."
  selinux_port_is_mysqld tcp 4567 ||
    die "SELinux mysqld_port_t에 4567/TCP가 등록되지 않았습니다."
  selinux_port_is_mysqld udp 4567 ||
    die "SELinux mysqld_port_t에 4567/UDP가 등록되지 않았습니다."
  selinux_port_is_mysqld tcp 4568 ||
    die "SELinux mysqld_port_t에 4568/TCP가 등록되지 않았습니다."

  semodule -l |
    awk '{print $1}' |
    grep -Fxq "galera_sst_timeout" ||
    die "SELinux 모듈 galera_sst_timeout이 설치되지 않았습니다."

  log_success "Galera SST/IST SELinux 사전 점검 완료"
}

preflight_target_packages() {
  command -v dnf >/dev/null 2>&1 ||
    die "dnf 명령을 찾을 수 없습니다."

  log_info "MariaDB 10.11.18 패키지 존재 여부와 의존성을 확인합니다."
  dnf \
    --disableexcludes=all \
    --disableplugin=versionlock \
    list --available \
    "${TARGET_PACKAGES[@]}"

  log_info "MariaDB 중지 전에 대상 패키지를 미리 다운로드합니다."
  dnf \
    --disableexcludes=all \
    --disableplugin=versionlock \
    --setopt=keepcache=True \
    install -y \
    --downloadonly \
    "${TARGET_PACKAGES[@]}"

  log_success "대상 패키지 사전 확인 및 다운로드 완료"
}

preserve_pre_upgrade_backup() {
  local latest_dump

  [[ "${NODE_ROLE}" == "db1" ]] ||
    die "업그레이드 전 Dump 보존은 --node-role db1에서만 실행할 수 있습니다."

  [[ -d "${DAILY_DUMP_DIR}" ]] ||
    die "일일 Dump 디렉터리가 없습니다: ${DAILY_DUMP_DIR}"

  latest_dump=$(
    find "${DAILY_DUMP_DIR}" \
      -maxdepth 1 \
      -type f \
      -name "mariadb_full_*.sql.gz" \
      -printf "%T@ %p\n" |
      sort -nr |
      head -1 |
      cut -d" " -f2-
  )

  [[ -n "${latest_dump}" ]] ||
    die "보존할 mariadb_full_*.sql.gz 파일을 찾지 못했습니다."

  log_info "원본 Dump의 gzip 무결성을 먼저 확인합니다: ${latest_dump}"
  gzip -t -- "${latest_dump}"

  install -d \
    -o root \
    -g root \
    -m 700 \
    "${PRE_UPGRADE_BACKUP_DIR}"

  cp -a -- "${latest_dump}" "${PRE_UPGRADE_BACKUP_DIR}/"

  (
    cd "${PRE_UPGRADE_BACKUP_DIR}"
    sha256sum -- *.sql.gz > SHA256SUMS
    sha256sum -c SHA256SUMS
    gzip -t -- *.sql.gz
    chmod 600 -- *.sql.gz SHA256SUMS
  )

  log_success "업그레이드 전 Dump 보존과 무결성 검증 완료"
}

assert_installed_rpm() {
  local package_name=$1
  local expected_version=$2
  local installed_version

  installed_version=$(
    rpm -q \
      --qf '%{VERSION}-%{RELEASE}.%{ARCH}' \
      "${package_name}"
  )

  [[ "${installed_version}" == "${expected_version}" ]] ||
    die "${package_name} 버전 불일치: ${installed_version}, 기대값: ${expected_version}"
}

verify_target_packages() {
  assert_installed_rpm "MariaDB-server" "${TARGET_MARIADB_RPM}"
  assert_installed_rpm "MariaDB-client" "${TARGET_MARIADB_RPM}"
  assert_installed_rpm "MariaDB-common" "${TARGET_MARIADB_RPM}"
  assert_installed_rpm "MariaDB-shared" "${TARGET_MARIADB_RPM}"
  assert_installed_rpm "MariaDB-backup" "${TARGET_MARIADB_RPM}"
  assert_installed_rpm "galera-4" "${TARGET_GALERA_RPM}"

  log_success "MariaDB와 Galera RPM 버전 검증 완료"
}

wait_for_synced_cluster() {
  local elapsed=0
  local cluster_size=""
  local cluster_status=""
  local local_state=""
  local ready=""
  local connected=""
  local desync=""

  log_info "Galera 정상 복귀를 최대 ${SYNC_TIMEOUT}초 동안 기다립니다."

  while (( elapsed < SYNC_TIMEOUT )); do
    if systemctl is-failed --quiet mariadb; then
      journalctl -u mariadb -n 100 --no-pager || true
      die "MariaDB 서비스가 failed 상태가 되었습니다."
    fi

    if systemctl is-active --quiet mariadb &&
      mariadb -NBe "SELECT 1;" >/dev/null 2>&1; then
      cluster_size=$(query_status "wsrep_cluster_size" 2>/dev/null || true)
      cluster_status=$(query_status "wsrep_cluster_status" 2>/dev/null || true)
      local_state=$(query_status "wsrep_local_state_comment" 2>/dev/null || true)
      ready=$(query_status "wsrep_ready" 2>/dev/null || true)
      connected=$(query_status "wsrep_connected" 2>/dev/null || true)
      desync=$(query_variable "wsrep_desync" 2>/dev/null || true)

      if [[ "${cluster_size}" == "${EXPECTED_CLUSTER_SIZE}" ]] &&
        [[ "${cluster_status}" == "Primary" ]] &&
        [[ "${local_state}" == "Synced" ]] &&
        [[ "${ready}" == "ON" ]] &&
        [[ "${connected}" == "ON" ]] &&
        [[ "${desync}" == "OFF" ]]; then
        log_success "Galera 클러스터 정상 복귀 완료 (${elapsed}초)"
        return 0
      fi
    fi

    if (( elapsed % 30 == 0 )); then
      log_info \
        "대기 중: size=${cluster_size:-N/A}, status=${cluster_status:-N/A}, state=${local_state:-N/A}, ready=${ready:-N/A}"
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  journalctl -u mariadb -n 100 --no-pager || true
  die "${SYNC_TIMEOUT}초 내에 Galera 클러스터가 정상 복귀하지 못했습니다."
}

run_mariadb_upgrade_step() {
  local description=$1
  shift

  log_info "${description}"
  if timeout \
    --foreground \
    "${UPGRADE_TIMEOUT}" \
    mariadb-upgrade \
    --force \
    --skip-write-binlog \
    "$@"; then
    return 0
  else
    local rc=$?
    log_error "mariadb-upgrade 실패 또는 제한 시간 초과: ${description}, rc=${rc}"
    mariadb -e "SHOW FULL PROCESSLIST;" || true
    return "${rc}"
  fi
}

perform_node_upgrade() {
  log_info "현재 작업 노드: role=${NODE_ROLE}, hostname=$(hostname -f)"
  log_warn "권장 순서는 db3 -> db2 -> db1이며 한 노드가 완전히 복귀한 뒤 다음 노드를 작업해야 합니다."

  check_cluster_status
  check_source_version
  check_selinux_preflight
  preflight_target_packages

  log_info "MariaDB 서비스를 중지합니다."
  systemctl stop mariadb
  systemctl is-active --quiet mariadb &&
    die "MariaDB 서비스가 정상적으로 중지되지 않았습니다."

  log_info "사전 다운로드한 MariaDB 10.11.18 패키지를 설치합니다."
  dnf \
    --disableexcludes=all \
    --disableplugin=versionlock \
    --setopt=keepcache=True \
    install -y \
    "${TARGET_PACKAGES[@]}"

  verify_target_packages

  log_info "MariaDB 서비스를 비동기로 시작합니다."
  systemctl start --no-block mariadb
  wait_for_synced_cluster

  run_mariadb_upgrade_step \
    "시스템 테이블 업그레이드를 실행합니다." \
    --upgrade-system-tables

  run_mariadb_upgrade_step \
    "전체 스키마 업그레이드 검사를 실행합니다."

  [[ -f "${UPGRADE_INFO_FILE}" ]] ||
    die "mariadb-upgrade 완료 파일이 없습니다: ${UPGRADE_INFO_FILE}"

  [[ "$(<"${UPGRADE_INFO_FILE}")" == "${TARGET_MARIADB_VERSION}-MariaDB" ]] ||
    die "mysql_upgrade_info 값이 올바르지 않습니다: $(<"${UPGRADE_INFO_FILE}")"

  verify_target_packages
  check_cluster_status

  local running_version
  running_version=$(mariadb -NBe "SELECT VERSION();" | cut -d- -f1)
  [[ "${running_version}" == "${TARGET_MARIADB_VERSION}" ]] ||
    die "실행 중인 MariaDB 버전이 올바르지 않습니다: ${running_version}"

  log_success "현재 노드의 MariaDB 10.11.18 업그레이드 완료"
}

latest_dump_file() {
  find "${DAILY_DUMP_DIR}" \
    -maxdepth 1 \
    -type f \
    -name "mariadb_full_*.sql.gz" \
    -printf "%T@ %p\n" |
    sort -nr |
    head -1 |
    cut -d" " -f2-
}

verify_db1_backup() {
  local latest_dump

  [[ "${NODE_ROLE}" == "db1" ]] ||
    die "백업 검증은 --node-role db1에서만 실행할 수 있습니다."

  check_cluster_status

  systemctl cat mariadb-backup-dump.service >/dev/null ||
    die "mariadb-backup-dump.service가 없습니다."
  systemctl cat mariadb-backup-dump.timer >/dev/null ||
    die "mariadb-backup-dump.timer가 없습니다."

  log_info "DB1 논리 백업 서비스를 실행합니다."
  systemctl start mariadb-backup-dump.service

  latest_dump=$(latest_dump_file)
  [[ -n "${latest_dump}" ]] ||
    die "백업 실행 후 mariadb_full_*.sql.gz 파일을 찾지 못했습니다."

  gzip -t -- "${latest_dump}"
  sha256sum -- "${latest_dump}"

  systemctl enable --now mariadb-backup-dump.timer
  systemctl is-enabled --quiet mariadb-backup-dump.timer ||
    die "백업 타이머가 enabled 상태가 아닙니다."
  systemctl is-active --quiet mariadb-backup-dump.timer ||
    die "백업 타이머가 active 상태가 아닙니다."

  check_cluster_status
  systemctl list-timers mariadb-backup-dump.timer --all

  log_success "DB1 업그레이드 후 백업 및 타이머 검증 완료"
}

check_os
require_common_commands

case "${ACTION}" in
  check)
    log_info "설치된 MariaDB/Galera RPM:"
    print_installed_packages
    check_cluster_status
    ;;
  backup)
    require_node_role
    [[ "${NODE_ROLE}" == "db1" ]] ||
      die "--backup-dump는 --node-role db1에서만 사용할 수 있습니다."
    acquire_lock
    check_cluster_status
    preserve_pre_upgrade_backup
    ;;
  upgrade)
    require_node_role
    require_upgrade_confirmation
    acquire_lock
    perform_node_upgrade
    ;;
  verify_backup)
    require_node_role
    [[ "${NODE_ROLE}" == "db1" ]] ||
      die "--verify-backup은 --node-role db1에서만 사용할 수 있습니다."
    acquire_lock
    verify_db1_backup
    ;;
  all)
    require_node_role
    require_upgrade_confirmation
    acquire_lock
    check_cluster_status

    if [[ "${NODE_ROLE}" == "db1" ]]; then
      preserve_pre_upgrade_backup
    else
      log_info "${NODE_ROLE}에서는 DB1 전용 Dump 보존 단계를 건너뜁니다."
    fi

    perform_node_upgrade
    ;;
  *)
    die "내부 오류: 지원하지 않는 작업입니다."
    ;;
esac

log_success "요청한 작업을 완료했습니다."
