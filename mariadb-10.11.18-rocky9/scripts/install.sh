#!/usr/bin/env bash
set -Eeuo pipefail

COMPONENT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly COMPONENT_ROOT
readonly CONF_FILE="${COMPONENT_ROOT}/install.conf"
readonly DB_RPM_DIR="${COMPONENT_ROOT}/db/rpms"
readonly COMMON_RPM_DIR="${COMPONENT_ROOT}/common/rpms"
readonly MANAGED_CNF="/etc/my.cnf.d/90-airgap-mariadb.cnf"
readonly DATA_DIR="/var/lib/mysql"
readonly LOCK_FILE="/run/lock/mariadb-10.11.18-install.lock"
readonly STATE_DIR="/var/lib/mariadb-airgap"
readonly STATE_FILE="${STATE_DIR}/install.state"
readonly TARGET_VERSION="10.11.18"
readonly TARGET_GALERA_VERSION="26.4.27"

ACTION=""
ASSUME_YES=false
DELETE_DATA=false

log() {
  printf '[%s] %s\n' "$1" "$2"
}

die() {
  log "ERROR" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
사용법:
  sudo ./scripts/install.sh [--install|--upgrade|--reinstall|--reset|--status]
                            [--yes] [--delete-data]

동작:
  --install       신규 설치합니다. 기존 MariaDB가 있으면 중단합니다.
  --upgrade       기존 10.11 계열을 10.11.18로 업그레이드합니다.
  --reinstall     패키지와 관리 설정을 다시 적용하며 DB 데이터는 보존합니다.
  --reset         설치 설정과 패키지를 제거합니다.
  --status        설치 버전과 서비스 상태를 확인합니다.

보호 옵션:
  --yes           변경 작업을 비대화형으로 승인합니다.
  --delete-data   --reset과 함께 지정할 때만 /var/lib/mysql을 삭제합니다.

옵션을 생략하면 현재 상태에 맞는 대화형 메뉴를 표시합니다.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) ACTION="install" ;;
    --upgrade) ACTION="upgrade" ;;
    --reinstall) ACTION="reinstall" ;;
    --reset) ACTION="reset" ;;
    --status) ACTION="status" ;;
    --yes) ASSUME_YES=true ;;
    --delete-data) DELETE_DATA=true ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "알 수 없는 옵션입니다: $1"
      ;;
  esac
  shift
done

[[ "${EUID}" -eq 0 ]] || die "root 권한이 필요합니다. sudo로 실행하십시오."
[[ -r "${CONF_FILE}" ]] || die "설정 파일을 읽을 수 없습니다: ${CONF_FILE}"

# shellcheck disable=SC1090
source "${CONF_FILE}"

: "${MARIADB_VERSION:=10.11.18}"
: "${BIND_ADDRESS:=0.0.0.0}"
: "${PORT:=3306}"
: "${MAX_CONNECTIONS:=1000}"
: "${CHARACTER_SET_SERVER:=utf8mb4}"
: "${COLLATION_SERVER:=utf8mb4_unicode_ci}"
: "${LOWER_CASE_TABLE_NAMES:=1}"
: "${SECURE_FILE_PRIV:=/var/lib/mysql-files}"
: "${LOCAL_INFILE:=OFF}"
: "${OPEN_FIREWALL:=false}"
: "${INSTALLED_VERSION:=}"

on_error() {
  local rc=$?
  local line=${BASH_LINENO[0]:-unknown}
  trap - ERR
  log "ERROR" "작업 실패: line=${line}, rc=${rc}, command=${BASH_COMMAND:-unknown}"
  systemctl status mariadb --no-pager -l 2>/dev/null || true
  exit "${rc}"
}
trap on_error ERR

exec 9>"${LOCK_FILE}"
flock -n 9 || die "다른 MariaDB 설치 작업이 실행 중입니다."

validate_config() {
  [[ "${MARIADB_VERSION}" == "${TARGET_VERSION}" ]] ||
    die "MARIADB_VERSION은 ${TARGET_VERSION}이어야 합니다."
  [[ "${PORT}" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) ||
    die "PORT는 1~65535 범위의 숫자여야 합니다."
  [[ "${MAX_CONNECTIONS}" =~ ^[1-9][0-9]*$ ]] ||
    die "MAX_CONNECTIONS는 1 이상의 정수여야 합니다."
  [[ "${LOWER_CASE_TABLE_NAMES}" =~ ^[012]$ ]] ||
    die "LOWER_CASE_TABLE_NAMES는 0, 1, 2 중 하나여야 합니다."
  [[ "${LOCAL_INFILE}" == "ON" || "${LOCAL_INFILE}" == "OFF" ]] ||
    die "LOCAL_INFILE은 ON 또는 OFF여야 합니다."
  [[ "${OPEN_FIREWALL}" == "true" || "${OPEN_FIREWALL}" == "false" ]] ||
    die "OPEN_FIREWALL은 true 또는 false여야 합니다."

  [[ "${SECURE_FILE_PRIV}" == /* && "${SECURE_FILE_PRIV}" != "/" ]] ||
    die "SECURE_FILE_PRIV는 루트가 아닌 절대 경로여야 합니다."
  [[ "${BIND_ADDRESS}" =~ ^[A-Fa-f0-9:.]+$ ]] ||
    die "BIND_ADDRESS는 IPv4 또는 IPv6 주소여야 합니다."
  [[ "${SECURE_FILE_PRIV}" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    die "SECURE_FILE_PRIV 경로에 허용되지 않는 문자가 있습니다."
  [[ "${CHARACTER_SET_SERVER}" =~ ^[A-Za-z0-9_]+$ ]] ||
    die "CHARACTER_SET_SERVER 형식이 올바르지 않습니다."
  [[ "${COLLATION_SERVER}" =~ ^[A-Za-z0-9_]+$ ]] ||
    die "COLLATION_SERVER 형식이 올바르지 않습니다."
}

check_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release를 읽을 수 없습니다."
  # shellcheck disable=SC1091
  source /etc/os-release
  local os_id=${ID:-unknown}
  local os_like=${ID_LIKE:-}
  local major=${VERSION_ID%%.*}

  if [[ ! "${os_id}" =~ ^(rocky|rhel|almalinux)$ ]] &&
    [[ " ${os_like} " != *" rhel "* ]]; then
    die "Rocky Linux/RHEL 계열만 지원합니다: ID=${os_id}"
  fi
  [[ "${major}" == "9" ]] ||
    die "Rocky Linux/RHEL 9 계열만 지원합니다: VERSION_ID=${VERSION_ID:-unknown}"
  [[ "$(uname -m)" == "x86_64" ]] || die "x86_64 아키텍처만 지원합니다."
}

installed_version() {
  if rpm -q MariaDB-server >/dev/null 2>&1; then
    rpm -q --qf '%{VERSION}' MariaDB-server
  fi
}

save_runtime_state() {
  install -d -o root -g root -m 700 "${STATE_DIR}"
  cat > "${STATE_FILE}" <<EOF
MYSQL_USER_CREATED_BY_INSTALL=${MYSQL_USER_CREATED_BY_INSTALL}
SECURE_DIR_CREATED_BY_INSTALL=${SECURE_DIR_CREATED_BY_INSTALL}
EOF
  chown root:root "${STATE_FILE}"
  chmod 600 "${STATE_FILE}"
}

load_runtime_state() {
  local key
  local value

  MYSQL_USER_CREATED_BY_INSTALL=false
  SECURE_DIR_CREATED_BY_INSTALL=false
  [[ -f "${STATE_FILE}" ]] || return 0

  while IFS='=' read -r key value; do
    case "${key}" in
      MYSQL_USER_CREATED_BY_INSTALL)
        MYSQL_USER_CREATED_BY_INSTALL=${value}
        ;;
      SECURE_DIR_CREATED_BY_INSTALL)
        SECURE_DIR_CREATED_BY_INSTALL=${value}
        ;;
    esac
  done < "${STATE_FILE}"

  [[ "${MYSQL_USER_CREATED_BY_INSTALL}" == "true" ||
    "${MYSQL_USER_CREATED_BY_INSTALL}" == "false" ]] ||
    die "런타임 상태의 MYSQL_USER_CREATED_BY_INSTALL 값이 올바르지 않습니다."
  [[ "${SECURE_DIR_CREATED_BY_INSTALL}" == "true" ||
    "${SECURE_DIR_CREATED_BY_INSTALL}" == "false" ]] ||
    die "런타임 상태의 SECURE_DIR_CREATED_BY_INSTALL 값이 올바르지 않습니다."
}
verify_bundle() {
  local rpm_file
  local package_name
  local package_version
  local found_server=false
  local found_galera=false
  local -a rpm_files=()

  mapfile -d '' rpm_files < <(
    find "${DB_RPM_DIR}" "${COMMON_RPM_DIR}" -maxdepth 1 -type f -name '*.rpm' -print0
  )
  (( ${#rpm_files[@]} > 0 )) || die "오프라인 RPM 파일이 없습니다."

  for rpm_file in "${rpm_files[@]}"; do
    package_name=$(rpm -qp --qf '%{NAME}' "${rpm_file}")
    package_version=$(rpm -qp --qf '%{VERSION}' "${rpm_file}")
    if [[ "${package_name}" =~ ^MariaDB- ]] && [[ "${package_version}" != "${TARGET_VERSION}" ]]; then
      die "대상 버전이 아닌 MariaDB RPM이 있습니다: $(basename "${rpm_file}")"
    fi
    if [[ "${package_name}" == "MariaDB-server" && "${package_version}" == "${TARGET_VERSION}" ]]; then
      found_server=true
    fi
    if [[ "${package_name}" == "galera-4" && "${package_version}" == "${TARGET_GALERA_VERSION}" ]]; then
      found_galera=true
    fi
  done

  [[ "${found_server}" == true ]] || die "MariaDB-server ${TARGET_VERSION} RPM이 없습니다."
  [[ "${found_galera}" == true ]] || die "galera-4 ${TARGET_GALERA_VERSION} RPM이 없습니다."
  log "OK" "오프라인 RPM 번들 검증 완료"
}

save_conf() {
  local installed=$1
  local conf_gid
  local conf_uid
  local tmp

  conf_uid=$(stat -c '%u' "${CONF_FILE}")
  conf_gid=$(stat -c '%g' "${CONF_FILE}")
  tmp=$(mktemp "${CONF_FILE}.tmp.XXXXXX")
  cat > "${tmp}" <<EOF
# MariaDB 10.11.18 설치 설정
# scripts/install.sh가 읽고 설치 완료 시 동일한 형식으로 갱신합니다.
# 비밀번호와 같은 비밀값은 이 파일에 저장하지 않습니다.

MARIADB_VERSION="${MARIADB_VERSION}"
BIND_ADDRESS="${BIND_ADDRESS}"
PORT="${PORT}"
MAX_CONNECTIONS="${MAX_CONNECTIONS}"
CHARACTER_SET_SERVER="${CHARACTER_SET_SERVER}"
COLLATION_SERVER="${COLLATION_SERVER}"
LOWER_CASE_TABLE_NAMES="${LOWER_CASE_TABLE_NAMES}"
SECURE_FILE_PRIV="${SECURE_FILE_PRIV}"
LOCAL_INFILE="${LOCAL_INFILE}"
OPEN_FIREWALL="${OPEN_FIREWALL}"
INSTALLED_VERSION="${installed}"
EOF
  chown "${conf_uid}:${conf_gid}" "${tmp}"
  chmod 644 "${tmp}"
  mv -f "${tmp}" "${CONF_FILE}"
}

render_config() {
  local tmp
  tmp=$(mktemp)
  cat > "${tmp}" <<EOF
# scripts/install.sh가 install.conf를 기준으로 생성한 파일입니다.
[mariadb]
bind-address=${BIND_ADDRESS}
port=${PORT}
character-set-server=${CHARACTER_SET_SERVER}
collation-server=${COLLATION_SERVER}
default-storage-engine=InnoDB
binlog-format=ROW
innodb-autoinc-lock-mode=2
lower-case-table-names=${LOWER_CASE_TABLE_NAMES}
max-connections=${MAX_CONNECTIONS}
secure-file-priv=${SECURE_FILE_PRIV}
local-infile=${LOCAL_INFILE}
EOF

  if [[ -f "${MANAGED_CNF}" ]] && ! cmp -s "${tmp}" "${MANAGED_CNF}"; then
    cp -a "${MANAGED_CNF}" "${MANAGED_CNF}.bak.$(date +%Y%m%d_%H%M%S)"
  fi
  install -o root -g root -m 644 "${tmp}" "${MANAGED_CNF}"
  rm -f "${tmp}"

  install -d -o mysql -g mysql -m 750 "${SECURE_FILE_PRIV}"
  command -v restorecon >/dev/null 2>&1 && restorecon -RF "${SECURE_FILE_PRIV}" || true
}

install_rpms() {
  local dnf_action=$1
  local rpm_file package_name package_nevra
  local -a target_rpms=()
  local -a missing_dependency_rpms=()
  local -A seen_nevra=()

  local -a required_dependency_names=(
    boost-program-options
    libaio
    liburing
    libxcrypt-compat
    perl-DBI
    perl-File-Copy
    perl-Math-BigInt
    perl-Math-Complex
    perl-Sys-Hostname
    socat
  )

  while IFS= read -r -d '' rpm_file; do
    package_name=$(rpm -qp --qf '%{NAME}' "${rpm_file}")
    package_nevra=$(rpm -qp --qf '%{NEVRA}' "${rpm_file}")

    if [[ -n "${seen_nevra[${package_nevra}]:-}" ]]; then
      continue
    fi
    seen_nevra["${package_nevra}"]=1

    if [[ "${package_name}" == MariaDB-* ||
      "${package_name}" == "galera-4" ||
      "${package_name}" == "mysql-selinux" ]]; then
      target_rpms+=("${rpm_file}")
    elif ! printf '%s\n' "${required_dependency_names[@]}" |
      grep -Fxq "${package_name}"; then
      continue
    elif ! rpm -q "${package_name}" >/dev/null 2>&1; then
      missing_dependency_rpms+=("${rpm_file}")
    fi
  done < <(
    find "${COMMON_RPM_DIR}" "${DB_RPM_DIR}" -maxdepth 1 -type f -name '*.rpm' -print0
  )

  ((${#target_rpms[@]} > 0)) ||
    die "MariaDB/Galera target RPMs were not found."

  log "INFO" \
    "Applying ${#target_rpms[@]} target RPMs and ${#missing_dependency_rpms[@]} missing dependency RPMs."

  dnf module disable -y mariadb >/dev/null 2>&1 || true
  if [[ "${dnf_action}" == "reinstall" ]]; then
    if ((${#missing_dependency_rpms[@]} > 0)); then
      dnf localinstall -y --disablerepo='*' "${missing_dependency_rpms[@]}"
    fi
    dnf reinstall -y --disablerepo='*' "${target_rpms[@]}"
  else
    dnf localinstall -y --disablerepo='*' \
      "${missing_dependency_rpms[@]}" \
      "${target_rpms[@]}"
  fi
}

configure_firewall() {
  [[ "${OPEN_FIREWALL}" == "true" ]] || return 0
  command -v firewall-cmd >/dev/null 2>&1 ||
    die "OPEN_FIREWALL=true이지만 firewall-cmd가 없습니다."
  firewall-cmd --permanent --add-port="${PORT}/tcp"
  firewall-cmd --reload
}

verify_installation() {
  local running_version
  systemctl is-active --quiet mariadb || die "MariaDB 서비스가 active 상태가 아닙니다."
  running_version=$(mariadb --batch --skip-column-names -e 'SELECT VERSION();')
  [[ "${running_version}" == "${TARGET_VERSION}"-* ]] ||
    die "실행 중인 버전이 ${TARGET_VERSION}이 아닙니다: ${running_version}"
  rpm -q galera-4 --qf '%{VERSION}' | grep -Fxq "${TARGET_GALERA_VERSION}" ||
    die "Galera 버전이 ${TARGET_GALERA_VERSION}이 아닙니다."
  log "OK" "MariaDB ${running_version} 설치 및 서비스 검증 완료"
}

check_existing_compatibility() {
  local current_lower_case

  systemctl is-active --quiet mariadb || return 0
  command -v mariadb >/dev/null 2>&1 || return 0

  current_lower_case=$(
    mariadb --batch --skip-column-names \
      -e "SELECT @@GLOBAL.lower_case_table_names;" 2>/dev/null || true
  )
  if [[ -n "${current_lower_case}" ]] &&
    [[ "${current_lower_case}" != "${LOWER_CASE_TABLE_NAMES}" ]]; then
    die "기존 lower_case_table_names=${current_lower_case}와 install.conf의 ${LOWER_CASE_TABLE_NAMES}가 다릅니다. 기존 데이터 설정과 동일하게 맞추십시오."
  fi
}
confirm_action() {
  local message=$1
  [[ "${ASSUME_YES}" == true ]] && return 0
  read -r -p "${message} [y/N]: " answer
  [[ "${answer}" =~ ^[Yy]$ ]] || die "작업을 취소했습니다."
}

select_action() {
  local current
  current=$(installed_version)
  if [[ -z "${current}" ]]; then
    ACTION="install"
    return
  fi

  printf '기존 MariaDB가 감지되었습니다: %s\n' "${current}"
  printf '%s\n' \
    '1) 업그레이드' \
    '2) 재설치(데이터 보존)' \
    '3) 초기화' \
    '4) 상태 확인' \
    '5) 취소'
  read -r -p '선택 [1-5]: ' choice
  case "${choice}" in
    1) ACTION="upgrade" ;;
    2) ACTION="reinstall" ;;
    3) ACTION="reset" ;;
    4) ACTION="status" ;;
    *) exit 0 ;;
  esac
}

perform_install() {
  local mode=$1
  local current
  current=$(installed_version)

  case "${mode}" in
    install)
      [[ -z "${current}" ]] ||
        die "MariaDB ${current}이 이미 설치되어 있습니다. --upgrade 또는 --reinstall을 사용하십시오."
      ;;
    upgrade)
      [[ -n "${current}" ]] || die "업그레이드할 MariaDB가 없습니다."
      [[ "${current}" == 10.11.* ]] ||
        die "자동 업그레이드는 MariaDB 10.11 계열만 지원합니다: ${current}"
      ;;
    reinstall)
      [[ "${current}" == "${TARGET_VERSION}" ]] ||
        die "재설치는 이미 설치된 ${TARGET_VERSION}에서만 지원합니다: ${current:-none}"
      ;;
  esac

  confirm_action "MariaDB ${TARGET_VERSION} ${mode} 작업을 진행하시겠습니까?"
  check_existing_compatibility
  verify_bundle
  MYSQL_USER_CREATED_BY_INSTALL=false
  SECURE_DIR_CREATED_BY_INSTALL=false
  if [[ "${mode}" == "install" ]]; then
    getent passwd mysql >/dev/null 2>&1 || MYSQL_USER_CREATED_BY_INSTALL=true
    [[ -e "${SECURE_FILE_PRIV}" ]] || SECURE_DIR_CREATED_BY_INSTALL=true
  elif [[ -f "${STATE_FILE}" ]]; then
    load_runtime_state
  fi
  save_runtime_state
  systemctl stop mariadb 2>/dev/null || true
  if [[ "${mode}" == "reinstall" ]]; then
    install_rpms "reinstall"
  else
    install_rpms "install"
  fi
  render_config
  systemctl enable --now mariadb
  mariadb-upgrade --force
  configure_firewall
  verify_installation
  save_conf "${TARGET_VERSION}"
}

perform_reset() {
  load_runtime_state
  confirm_action "MariaDB 패키지와 관리 설정을 제거하시겠습니까?"
  if [[ "${DELETE_DATA}" == true ]]; then
    [[ "${ASSUME_YES}" == true ]] ||
      read -r -p '데이터 삭제 확인을 위해 DELETE-MARIADB-DATA를 입력하십시오: ' token
    if [[ "${ASSUME_YES}" != true && "${token:-}" != "DELETE-MARIADB-DATA" ]]; then
      die "데이터 삭제 확인 문자열이 일치하지 않습니다."
    fi
  fi

  systemctl disable --now mariadb 2>/dev/null || true
  dnf remove -y 'MariaDB-*' galera-4 mysql-selinux
  rm -f "${MANAGED_CNF}"
  if [[ "${DELETE_DATA}" == true ]]; then
    [[ "${DATA_DIR}" == "/var/lib/mysql" && ! -L "${DATA_DIR}" ]] ||
      die "안전 검증에 실패하여 데이터 디렉터리를 삭제하지 않습니다."
    if [[ -e "${DATA_DIR}" ]]; then
      rm -rf --one-file-system "${DATA_DIR}"
      log "WARN" "${DATA_DIR} 데이터가 삭제되었습니다."
    else
      log "INFO" "${DATA_DIR} 데이터 디렉터리는 이미 없습니다."
    fi

    if [[ "${SECURE_DIR_CREATED_BY_INSTALL}" == true ]]; then
      [[ "${SECURE_FILE_PRIV}" == /* && "${SECURE_FILE_PRIV}" != "/" &&
        ! -L "${SECURE_FILE_PRIV}" ]] ||
        die "보안 파일 디렉터리 안전 검증에 실패했습니다."
      rm -rf --one-file-system "${SECURE_FILE_PRIV}"
      log "WARN" "설치 과정에서 만든 ${SECURE_FILE_PRIV} 디렉터리가 삭제되었습니다."
    fi

    if [[ "${MYSQL_USER_CREATED_BY_INSTALL}" == true ]]; then
      command -v userdel >/dev/null 2>&1 || die "userdel 명령이 필요합니다."
      if getent passwd mysql >/dev/null 2>&1; then
        userdel mysql
      fi
      if getent group mysql >/dev/null 2>&1; then
        groupdel mysql
      fi
      log "WARN" "설치 과정에서 만든 mysql 시스템 계정이 삭제되었습니다."
    fi
  else
    log "INFO" "${DATA_DIR} 데이터는 보존했습니다."
  fi
  rm -f "${STATE_FILE}"
  rmdir "${STATE_DIR}" 2>/dev/null || true
  save_conf ""
  log "OK" "MariaDB 초기화 완료"
}

show_status() {
  local current
  current=$(installed_version)
  printf '설정 목표 버전: %s\n' "${MARIADB_VERSION}"
  printf '설치된 서버 버전: %s\n' "${current:-미설치}"
  printf '저장된 설치 상태: %s\n' "${INSTALLED_VERSION:-없음}"
  systemctl status mariadb --no-pager -l 2>/dev/null || true
}

validate_config
check_os
command -v dnf >/dev/null 2>&1 || die "dnf 명령을 찾을 수 없습니다."
command -v rpm >/dev/null 2>&1 || die "rpm 명령을 찾을 수 없습니다."
[[ -n "${ACTION}" ]] || select_action
if [[ "${DELETE_DATA}" == true && "${ACTION}" != "reset" ]]; then
  die "--delete-data는 --reset과 함께만 사용할 수 있습니다."
fi

case "${ACTION}" in
  install|upgrade|reinstall) perform_install "${ACTION}" ;;
  reset) perform_reset ;;
  status) show_status ;;
  *) die "지원하지 않는 동작입니다: ${ACTION}" ;;
esac
