#!/usr/bin/env bash
set -Eeuo pipefail

COMPONENT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly COMPONENT_ROOT
readonly CONF_FILE="${COMPONENT_ROOT}/install.conf"
readonly DB_DEB_DIR="${COMPONENT_ROOT}/db/debs"
readonly COMMON_DEB_DIR="${COMPONENT_ROOT}/common/debs"
readonly MANAGED_CNF="/etc/mysql/mariadb.conf.d/90-airgap-mariadb.cnf"
readonly GALERA_CNF="/etc/mysql/mariadb.conf.d/60-galera.cnf"
readonly DATA_DIR="/var/lib/mysql"
readonly LOCK_FILE="/run/lock/mariadb-10.11.18-install.lock"
readonly STATE_DIR="/var/lib/mariadb-airgap"
readonly STATE_FILE="${STATE_DIR}/install.state"
readonly TARGET_VERSION="10.11.18"
readonly TARGET_DEB_VERSION="1:10.11.18+maria~ubu2404"
readonly TARGET_GALERA_VERSION="26.4.27-ubu2404"

ACTION=""
ASSUME_YES=false
DELETE_DATA=false
LOCAL_APT_REPO=""

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
  --reset         설치 설정과 MariaDB/Galera 패키지를 제거합니다.
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
  cleanup_local_repo
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
  [[ "${PORT}" =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) ||
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
  [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] ||
    die "Ubuntu 24.04만 지원합니다: ID=${ID:-unknown}, VERSION_ID=${VERSION_ID:-unknown}"
  [[ "$(uname -m)" == "x86_64" ]] || die "x86_64 아키텍처만 지원합니다."
}

installed_version() {
  local package_status
  package_status=$(
    dpkg-query -W -f='${db:Status-Status}' mariadb-server 2>/dev/null || true
  )
  if [[ "${package_status}" == "installed" ]]; then
    dpkg-query -W -f='${Version}' mariadb-server
  fi
}

installed_short_version() {
  local version
  version=$(installed_version)
  version=${version#*:}
  version=${version%%+*}
  version=${version%%-*}
  printf '%s' "${version}"
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
    die "저장된 MYSQL_USER_CREATED_BY_INSTALL 값이 올바르지 않습니다."
  [[ "${SECURE_DIR_CREATED_BY_INSTALL}" == "true" ||
    "${SECURE_DIR_CREATED_BY_INSTALL}" == "false" ]] ||
    die "저장된 SECURE_DIR_CREATED_BY_INSTALL 값이 올바르지 않습니다."
}

verify_checksums() {
  local directory=$1
  [[ -f "${directory}/SHA256SUMS" ]] || return 0
  (
    cd "${directory}"
    sha256sum --quiet -c SHA256SUMS
  )
}

verify_bundle() {
  local deb_file
  local package_name
  local package_version
  local architecture
  local found_server=false
  local found_galera=false
  local -a deb_files=()

  mapfile -d '' deb_files < <(
    find "${DB_DEB_DIR}" "${COMMON_DEB_DIR}" \
      -maxdepth 1 -type f -name '*.deb' -print0
  )
  ((${#deb_files[@]} > 0)) || die "오프라인 DEB 파일이 없습니다."

  verify_checksums "${DB_DEB_DIR}"
  verify_checksums "${COMMON_DEB_DIR}"

  for deb_file in "${deb_files[@]}"; do
    package_name=$(dpkg-deb -f "${deb_file}" Package)
    package_version=$(dpkg-deb -f "${deb_file}" Version)
    architecture=$(dpkg-deb -f "${deb_file}" Architecture)
    [[ "${architecture}" == "amd64" || "${architecture}" == "all" ]] ||
      die "지원하지 않는 DEB 아키텍처입니다: $(basename "${deb_file}")"

    if [[ "${package_name}" =~ ^mariadb-(server|client|backup|common|server-core|client-core)$ ]] &&
      [[ "${package_version}" != "${TARGET_DEB_VERSION}" ]]; then
      die "대상 버전이 아닌 MariaDB DEB가 있습니다: $(basename "${deb_file}")"
    fi
    if [[ "${package_name}" == "mariadb-server" &&
      "${package_version}" == "${TARGET_DEB_VERSION}" ]]; then
      found_server=true
    fi
    if [[ "${package_name}" == "galera-4" &&
      "${package_version}" == "${TARGET_GALERA_VERSION}" ]]; then
      found_galera=true
    fi
  done

  [[ "${found_server}" == true ]] ||
    die "mariadb-server ${TARGET_DEB_VERSION} DEB가 없습니다."
  [[ "${found_galera}" == true ]] ||
    die "galera-4 ${TARGET_GALERA_VERSION} DEB가 없습니다."
  log "OK" "오프라인 DEB 번들 검증 완료"
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
# scripts/install.sh가 읽고 설치 완료 시 같은 형식으로 갱신합니다.
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

  install -d -o root -g root -m 755 "$(dirname "${MANAGED_CNF}")"
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
}

prepare_runtime_directories() {
  if getent passwd mysql >/dev/null 2>&1; then
    install -d -o mysql -g mysql -m 750 "${SECURE_FILE_PRIV}"
  else
    install -d -o root -g root -m 755 "${SECURE_FILE_PRIV}"
  fi
}

ensure_runtime_directories() {
  getent passwd mysql >/dev/null 2>&1 ||
    die "MariaDB 패키지 설치 후 mysql 계정이 생성되지 않았습니다."
  install -d -o mysql -g mysql -m 750 "${SECURE_FILE_PRIV}"
}

cleanup_local_repo() {
  if [[ -n "${LOCAL_APT_REPO}" &&
    "${LOCAL_APT_REPO}" == /tmp/mariadb-local-apt.* &&
    -d "${LOCAL_APT_REPO}" ]]; then
    rm -rf --one-file-system "${LOCAL_APT_REPO}"
  fi
  LOCAL_APT_REPO=""
}

build_local_repository() {
  local deb_file
  local destination
  local filename
  local size
  local checksum

  LOCAL_APT_REPO=$(mktemp -d /tmp/mariadb-local-apt.XXXXXX)
  while IFS= read -r -d '' deb_file; do
    filename=$(basename "${deb_file}")
    destination="${LOCAL_APT_REPO}/${filename}"
    if [[ -e "${destination}" ]]; then
      cmp -s "${deb_file}" "${destination}" ||
        die "이름이 같고 내용이 다른 DEB가 있습니다: ${filename}"
      continue
    fi
    ln -s "${deb_file}" "${destination}"
  done < <(
    find "${COMMON_DEB_DIR}" "${DB_DEB_DIR}" \
      -maxdepth 1 -type f -name '*.deb' -print0
  )

  : > "${LOCAL_APT_REPO}/Packages"
  for deb_file in "${LOCAL_APT_REPO}"/*.deb; do
    filename=$(basename "${deb_file}")
    size=$(stat -Lc '%s' "${deb_file}")
    checksum=$(sha256sum "${deb_file}" | awk '{print $1}')
    dpkg-deb -f "${deb_file}" >> "${LOCAL_APT_REPO}/Packages"
    printf 'Filename: ./%s\nSize: %s\nSHA256: %s\n\n' \
      "${filename}" \
      "${size}" \
      "${checksum}" >> "${LOCAL_APT_REPO}/Packages"
  done

  printf 'deb [trusted=yes] file:%s ./\n' "${LOCAL_APT_REPO}" > \
    "${LOCAL_APT_REPO}/local.list"
}

install_debs() {
  local install_mode=$1
  local -a apt_options=()
  local -a install_options=()
  local -a target_packages=(
    "mysql-common=${TARGET_DEB_VERSION}"
    "mariadb-common=${TARGET_DEB_VERSION}"
    "libmariadb3=${TARGET_DEB_VERSION}"
    "mariadb-client-core=${TARGET_DEB_VERSION}"
    "mariadb-client=${TARGET_DEB_VERSION}"
    "mariadb-server-core=${TARGET_DEB_VERSION}"
    "mariadb-server=${TARGET_DEB_VERSION}"
    "mariadb-backup=${TARGET_DEB_VERSION}"
    "galera-4=${TARGET_GALERA_VERSION}"
  )

  build_local_repository
  apt_options=(
    -o "Dir::Etc::sourcelist=${LOCAL_APT_REPO}/local.list"
    -o "Dir::Etc::sourceparts=-"
    -o "APT::Sandbox::User=root"
  )
  apt-get "${apt_options[@]}" update
  if [[ "${install_mode}" == "reinstall" ]]; then
    install_options+=("--reinstall")
  fi

  log "INFO" "격리된 로컬 APT 저장소에서 MariaDB/Galera DEB를 적용합니다."
  DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" install \
    -y \
    --no-install-recommends \
    --allow-change-held-packages \
    "${install_options[@]}" \
    "${target_packages[@]}"
  cleanup_local_repo
}
configure_firewall() {
  [[ "${OPEN_FIREWALL}" == "true" ]] || return 0
  command -v ufw >/dev/null 2>&1 ||
    die "OPEN_FIREWALL=true이지만 ufw 명령이 없습니다."

  if ufw status | grep -Fxq "Status: active"; then
    ufw allow "${PORT}/tcp"
    log "OK" "UFW MariaDB 포트 개방 완료"
  else
    log "WARN" "UFW가 비활성 상태라 포트 설정을 건너뜁니다."
  fi
}

verify_installation() {
  local galera_version
  local package_version
  local running_version

  systemctl is-active --quiet mariadb ||
    die "MariaDB 서비스가 active 상태가 아닙니다."
  running_version=$(mariadb --batch --skip-column-names -e 'SELECT VERSION();')
  [[ "${running_version}" == "${TARGET_VERSION}"-* ]] ||
    die "실행 중인 버전이 ${TARGET_VERSION}이 아닙니다: ${running_version}"

  package_version=$(installed_version)
  [[ "${package_version}" == "${TARGET_DEB_VERSION}" ]] ||
    die "mariadb-server 패키지 버전이 다릅니다: ${package_version}"
  galera_version=$(dpkg-query -W -f='${Version}' galera-4 2>/dev/null || true)
  [[ "${galera_version}" == "${TARGET_GALERA_VERSION}" ]] ||
    die "Galera 버전이 다릅니다: ${galera_version:-미설치}"
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
  if [[ -n "${current_lower_case}" &&
    "${current_lower_case}" != "${LOWER_CASE_TABLE_NAMES}" ]]; then
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
  current=$(installed_short_version)
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
  local current_deb

  current=$(installed_short_version)
  current_deb=$(installed_version)
  case "${mode}" in
    install)
      [[ -z "${current_deb}" ]] ||
        die "MariaDB ${current}이 이미 설치되어 있습니다. --upgrade 또는 --reinstall을 사용하십시오."
      ;;
    upgrade)
      [[ -n "${current_deb}" ]] || die "업그레이드할 MariaDB가 없습니다."
      [[ "${current}" == 10.11.* ]] ||
        die "자동 업그레이드는 MariaDB 10.11 계열만 지원합니다: ${current}"
      dpkg --compare-versions "${current_deb}" le "${TARGET_DEB_VERSION}" ||
        die "설치된 버전이 대상보다 최신이라 다운그레이드하지 않습니다: ${current_deb}"
      ;;
    reinstall)
      [[ "${current_deb}" == "${TARGET_DEB_VERSION}" ]] ||
        die "재설치는 정확한 ${TARGET_DEB_VERSION}에서만 지원합니다: ${current_deb:-미설치}"
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
  render_config
  prepare_runtime_directories
  install_debs "${mode}"
  ensure_runtime_directories
  systemctl enable --now mariadb
  mariadb-upgrade --force
  configure_firewall
  verify_installation
  save_conf "${TARGET_VERSION}"
}

installed_mariadb_packages() {
  {
    dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' \
      'mariadb-*' \
      galera-4 \
      mysql-common 2>/dev/null || true
  } |
    awk -F '\t' '$2 == "installed" {print $1}' |
    sort -u
}

perform_reset() {
  local token=""
  local -a packages=()

  load_runtime_state
  confirm_action "MariaDB/Galera 패키지와 관리 설정을 제거하시겠습니까?"
  if [[ "${DELETE_DATA}" == true ]]; then
    [[ "${ASSUME_YES}" == true ]] ||
      read -r -p '데이터 삭제 확인을 위해 DELETE-MARIADB-DATA를 입력하십시오: ' token
    if [[ "${ASSUME_YES}" != true &&
      "${token}" != "DELETE-MARIADB-DATA" ]]; then
      die "데이터 삭제 확인 문자열이 일치하지 않습니다."
    fi
  fi

  systemctl disable --now mariadb 2>/dev/null || true
  mapfile -t packages < <(installed_mariadb_packages)
  if ((${#packages[@]} > 0)); then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "${packages[@]}"
  fi
  rm -f "${MANAGED_CNF}" "${GALERA_CNF}"

  if [[ "${DELETE_DATA}" == true ]]; then
    [[ "${DATA_DIR}" == "/var/lib/mysql" && ! -L "${DATA_DIR}" ]] ||
      die "안전 검증에 실패하여 데이터 디렉터리를 삭제하지 않았습니다."
    if [[ -e "${DATA_DIR}" ]]; then
      rm -rf --one-file-system "${DATA_DIR}"
      log "WARN" "${DATA_DIR} 데이터가 삭제되었습니다."
    else
      log "INFO" "${DATA_DIR} 데이터 디렉터리가 이미 없습니다."
    fi

    if [[ "${SECURE_DIR_CREATED_BY_INSTALL}" == true ]]; then
      [[ "${SECURE_FILE_PRIV}" == /* &&
        "${SECURE_FILE_PRIV}" != "/" &&
        ! -L "${SECURE_FILE_PRIV}" ]] ||
        die "보안 파일 디렉터리 안전 검증에 실패했습니다."
      rm -rf --one-file-system "${SECURE_FILE_PRIV}"
      log "WARN" "설치 과정에서 만든 ${SECURE_FILE_PRIV}를 삭제했습니다."
    fi

    if [[ "${MYSQL_USER_CREATED_BY_INSTALL}" == true ]]; then
      if getent passwd mysql >/dev/null 2>&1; then
        userdel mysql
      fi
      if getent group mysql >/dev/null 2>&1; then
        groupdel mysql
      fi
      log "WARN" "설치 과정에서 만든 mysql 시스템 계정을 삭제했습니다."
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
  printf '설치된 패키지 버전: %s\n' "${current:-미설치}"
  printf '저장된 설치 상태: %s\n' "${INSTALLED_VERSION:-없음}"
  systemctl status mariadb --no-pager -l 2>/dev/null || true
}

validate_config
check_os
for command_name in apt-get awk cmp dpkg dpkg-deb dpkg-query find flock getent grep install ln mktemp sha256sum sort stat systemctl; do
  command -v "${command_name}" >/dev/null 2>&1 ||
    die "필수 명령을 찾을 수 없습니다: ${command_name}"
done

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
