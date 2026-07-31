#!/usr/bin/env bash
set -Eeuo pipefail

COMPONENT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly COMPONENT_ROOT
readonly STATE_FILE="${COMPONENT_ROOT}/galera.conf"
readonly GALERA_CNF="/etc/mysql/mariadb.conf.d/60-galera.cnf"
readonly LOCK_FILE="/run/lock/mariadb-galera-config.lock"
readonly TARGET_MARIADB_VERSION="1:10.11.18+maria~ubu2404"
readonly TARGET_GALERA_VERSION="26.4.27-ubu2404"
readonly SYNC_TIMEOUT="${SYNC_TIMEOUT:-600}"

ACTION=""
ASSUME_YES=false
NEW_CLUSTER=false

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
  sudo ./scripts/configure_galera.sh --configure \
    --node-name db1 \
    --node-address 10.10.10.11 \
    --cluster-nodes 10.10.10.11,10.10.10.12,10.10.10.13

  sudo ./scripts/configure_galera.sh --bootstrap-new-cluster \
    --new-cluster --yes

  sudo ./scripts/configure_galera.sh --join [--yes]
  sudo ./scripts/configure_galera.sh --status

동작:
  --configure
      현재 노드의 Galera 설정을 생성합니다. 서비스는 재시작하지 않습니다.

  --bootstrap-new-cluster
      현재 노드를 신규 클러스터의 최초 노드로 부트스트랩합니다.
      --new-cluster와 --yes를 함께 지정해야 합니다.

  --join
      MariaDB를 재시작하여 설정된 Galera 클러스터에 조인합니다.

  --status
      현재 노드와 클러스터 상태를 출력합니다.

설정 옵션:
  --node-name NAME
  --node-address IP
  --cluster-nodes IP1,IP2,IP3
  --cluster-name NAME

주의:
  부트스트랩은 신규 클러스터의 첫 번째 노드 한 대에서만 실행하십시오.
  전체 장애 복구에는 신규 부트스트랩을 사용하지 말고
  galera-cluster-guide.md의 복구 절차를 따르십시오.
EOF
}

set_action() {
  local requested=$1
  [[ -z "${ACTION}" ]] || die "동작 옵션은 하나만 지정할 수 있습니다."
  ACTION="${requested}"
}

[[ -r "${STATE_FILE}" ]] || die "Galera 설정 파일이 없습니다: ${STATE_FILE}"
# shellcheck disable=SC1090
source "${STATE_FILE}"

: "${CLUSTER_NAME:=mariadb-prod}"
: "${CLUSTER_NODES:=}"
: "${NODE_NAME:=}"
: "${NODE_ADDRESS:=}"
: "${SST_METHOD:=rsync}"
: "${OPEN_GALERA_FIREWALL:=true}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configure)
      set_action "configure"
      ;;
    --bootstrap-new-cluster)
      set_action "bootstrap"
      ;;
    --join)
      set_action "join"
      ;;
    --status)
      set_action "status"
      ;;
    --node-name)
      shift
      [[ $# -gt 0 ]] || die "--node-name 값이 필요합니다."
      NODE_NAME=$1
      ;;
    --node-address)
      shift
      [[ $# -gt 0 ]] || die "--node-address 값이 필요합니다."
      NODE_ADDRESS=$1
      ;;
    --cluster-nodes)
      shift
      [[ $# -gt 0 ]] || die "--cluster-nodes 값이 필요합니다."
      CLUSTER_NODES=$1
      ;;
    --cluster-name)
      shift
      [[ $# -gt 0 ]] || die "--cluster-name 값이 필요합니다."
      CLUSTER_NAME=$1
      ;;
    --new-cluster)
      NEW_CLUSTER=true
      ;;
    --yes)
      ASSUME_YES=true
      ;;
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
[[ -n "${ACTION}" ]] || {
  usage
  exit 2
}

exec 9>"${LOCK_FILE}"
flock -n 9 || die "다른 Galera 구성 작업이 실행 중입니다."

check_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release를 읽을 수 없습니다."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] ||
    die "Ubuntu 24.04만 지원합니다."
}

check_installed_versions() {
  local mariadb_version
  local galera_version

  mariadb_version=$(
    dpkg-query -W -f='${Version}' mariadb-server 2>/dev/null || true
  )
  galera_version=$(
    dpkg-query -W -f='${Version}' galera-4 2>/dev/null || true
  )

  [[ "${mariadb_version}" == "${TARGET_MARIADB_VERSION}" ]] ||
    die "mariadb-server ${TARGET_MARIADB_VERSION}이 필요합니다: ${mariadb_version:-미설치}"
  [[ "${galera_version}" == "${TARGET_GALERA_VERSION}" ]] ||
    die "galera-4 ${TARGET_GALERA_VERSION}이 필요합니다: ${galera_version:-미설치}"
}

validate_config() {
  local cluster_node
  local node_count=0
  local node_found=false
  local -A unique_nodes=()
  local -a cluster_nodes=()

  [[ "${CLUSTER_NAME}" =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "CLUSTER_NAME 형식이 올바르지 않습니다."
  [[ "${NODE_NAME}" =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "NODE_NAME 형식이 올바르지 않습니다."
  [[ "${NODE_ADDRESS}" =~ ^[A-Fa-f0-9:.]+$ ]] ||
    die "NODE_ADDRESS는 IPv4 또는 IPv6 주소여야 합니다."
  [[ "${SST_METHOD}" == "rsync" ]] ||
    die "현재 자동 구성은 SST_METHOD=rsync만 지원합니다."
  [[ "${OPEN_GALERA_FIREWALL}" == "true" ||
    "${OPEN_GALERA_FIREWALL}" == "false" ]] ||
    die "OPEN_GALERA_FIREWALL은 true 또는 false여야 합니다."

  IFS=',' read -r -a cluster_nodes <<< "${CLUSTER_NODES}"
  for cluster_node in "${cluster_nodes[@]}"; do
    [[ "${cluster_node}" =~ ^[A-Fa-f0-9:.]+$ ]] ||
      die "클러스터 주소 형식이 올바르지 않습니다: ${cluster_node}"
    [[ -z "${unique_nodes[${cluster_node}]+set}" ]] ||
      die "중복된 클러스터 주소입니다: ${cluster_node}"
    unique_nodes["${cluster_node}"]=1
    node_count=$((node_count + 1))
    [[ "${cluster_node}" == "${NODE_ADDRESS}" ]] && node_found=true
  done

  ((node_count >= 3)) || die "Galera 클러스터 노드는 최소 3대여야 합니다."
  [[ "${node_found}" == true ]] ||
    die "NODE_ADDRESS가 CLUSTER_NODES 목록에 포함되어야 합니다."
}

save_state() {
  local state_gid
  local state_uid
  local tmp

  state_uid=$(stat -c '%u' "${STATE_FILE}")
  state_gid=$(stat -c '%g' "${STATE_FILE}")
  tmp=$(mktemp "${STATE_FILE}.tmp.XXXXXX")
  cat > "${tmp}" <<EOF
# MariaDB Galera 노드 설정
# scripts/configure_galera.sh가 읽고 --configure 실행 시 갱신합니다.

CLUSTER_NAME="${CLUSTER_NAME}"
CLUSTER_NODES="${CLUSTER_NODES}"
NODE_NAME="${NODE_NAME}"
NODE_ADDRESS="${NODE_ADDRESS}"
SST_METHOD="${SST_METHOD}"
OPEN_GALERA_FIREWALL="${OPEN_GALERA_FIREWALL}"
EOF
  chown "${state_uid}:${state_gid}" "${tmp}"
  chmod 644 "${tmp}"
  mv -f "${tmp}" "${STATE_FILE}"
}

configure_network() {
  local port

  [[ "${OPEN_GALERA_FIREWALL}" == "true" ]] || return 0
  if ! command -v ufw >/dev/null 2>&1; then
    log "WARN" "ufw 명령이 없어 방화벽 설정을 건너뜁니다."
    return 0
  fi
  if ! ufw status | grep -Fxq "Status: active"; then
    log "WARN" "UFW가 비활성 상태라 방화벽 설정을 건너뜁니다."
    return 0
  fi

  for port in 3306/tcp 4444/tcp 4567/tcp 4567/udp 4568/tcp; do
    ufw allow "${port}"
  done
  log "OK" "Galera UFW 포트 개방 완료"
}

render_config() {
  local provider
  local tmp

  provider=$(
    dpkg-query -L galera-4 |
      grep '/libgalera_smm\.so$' |
      head -1
  )
  [[ -n "${provider}" && -f "${provider}" ]] ||
    die "Galera provider 라이브러리를 찾을 수 없습니다."

  install -d -o root -g root -m 755 "$(dirname "${GALERA_CNF}")"
  tmp=$(mktemp)
  cat > "${tmp}" <<EOF
# scripts/configure_galera.sh가 galera.conf를 기준으로 생성한 파일입니다.
[mariadb]
wsrep_on=ON
wsrep_provider=${provider}
wsrep_cluster_name=${CLUSTER_NAME}
wsrep_cluster_address=gcomm://${CLUSTER_NODES}
wsrep_node_name=${NODE_NAME}
wsrep_node_address=${NODE_ADDRESS}
wsrep_sst_method=${SST_METHOD}
binlog_format=ROW
default_storage_engine=InnoDB
innodb_autoinc_lock_mode=2
EOF

  if [[ -f "${GALERA_CNF}" ]] && ! cmp -s "${tmp}" "${GALERA_CNF}"; then
    cp -a "${GALERA_CNF}" "${GALERA_CNF}.bak.$(date +%Y%m%d_%H%M%S)"
  fi
  install -o root -g root -m 644 "${tmp}" "${GALERA_CNF}"
  rm -f "${tmp}"
  mariadbd --verbose --help >/dev/null
}

query_status() {
  local variable_name=$1
  mariadb --batch --skip-column-names \
    -e "SHOW GLOBAL STATUS LIKE '${variable_name}';" 2>/dev/null |
    awk 'NR == 1 {print $2}'
}

show_status() {
  local variable_name

  systemctl status mariadb --no-pager -l 2>/dev/null || true
  if ! systemctl is-active --quiet mariadb ||
    ! mariadb -NBe "SELECT 1;" >/dev/null 2>&1; then
    log "WARN" "MariaDB가 실행 중이 아니거나 로컬 접속이 불가능합니다."
    return 0
  fi

  for variable_name in \
    wsrep_cluster_size \
    wsrep_cluster_status \
    wsrep_local_state_comment \
    wsrep_connected \
    wsrep_ready; do
    printf '%s=%s\n' \
      "${variable_name}" \
      "$(query_status "${variable_name}")"
  done
}

wait_for_state() {
  local expected_min_size=$1
  local elapsed=0
  local cluster_size=""
  local cluster_status=""
  local local_state=""
  local connected=""
  local ready=""

  while ((elapsed < SYNC_TIMEOUT)); do
    if systemctl is-active --quiet mariadb &&
      mariadb -NBe "SELECT 1;" >/dev/null 2>&1; then
      cluster_size=$(query_status "wsrep_cluster_size")
      cluster_status=$(query_status "wsrep_cluster_status")
      local_state=$(query_status "wsrep_local_state_comment")
      connected=$(query_status "wsrep_connected")
      ready=$(query_status "wsrep_ready")

      if [[ "${cluster_size}" =~ ^[0-9]+$ ]] &&
        ((cluster_size >= expected_min_size)) &&
        [[ "${cluster_status}" == "Primary" ]] &&
        [[ "${local_state}" == "Synced" ]] &&
        [[ "${connected}" == "ON" ]] &&
        [[ "${ready}" == "ON" ]]; then
        log "OK" "Galera 정상 상태 확인: size=${cluster_size}, state=${local_state}"
        return 0
      fi
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  journalctl -u mariadb -n 100 --no-pager || true
  die "${SYNC_TIMEOUT}초 내에 Galera 정상 상태가 되지 않았습니다."
}

confirm_restart() {
  [[ "${ASSUME_YES}" == true ]] && return 0
  read -r -p "MariaDB 서비스를 재시작하여 클러스터에 조인할까요? [y/N]: " answer
  [[ "${answer}" =~ ^[Yy]$ ]] || die "작업을 취소했습니다."
}

configure_node() {
  validate_config
  configure_network
  render_config
  save_state
  log "OK" "현재 노드의 Galera 설정 완료"
  log "INFO" "설정만 기록했으며 MariaDB 서비스는 재시작하지 않았습니다."
}

bootstrap_new_cluster() {
  [[ "${NEW_CLUSTER}" == true && "${ASSUME_YES}" == true ]] ||
    die "신규 부트스트랩에는 --new-cluster와 --yes가 모두 필요합니다."
  validate_config
  [[ -f "${GALERA_CNF}" ]] || die "먼저 --configure를 실행하십시오."

  if systemctl is-active --quiet mariadb &&
    [[ "$(query_status "wsrep_cluster_status")" == "Primary" ]]; then
    die "이미 Primary Galera 클러스터가 실행 중입니다."
  fi

  log "WARN" "신규 클러스터의 첫 번째 노드로 부트스트랩합니다."
  systemctl stop mariadb 2>/dev/null || true
  galera_new_cluster
  wait_for_state 1
}

join_cluster() {
  validate_config
  [[ -f "${GALERA_CNF}" ]] || die "먼저 --configure를 실행하십시오."
  confirm_restart
  systemctl restart mariadb
  wait_for_state 2
}

if [[ "${ACTION}" == "bootstrap" ]] &&
  { [[ "${NEW_CLUSTER}" != true ]] || [[ "${ASSUME_YES}" != true ]]; }; then
  die "신규 부트스트랩에는 --new-cluster와 --yes가 모두 필요합니다."
fi

check_os
check_installed_versions
for command_name in awk cmp cp dpkg-query flock galera_new_cluster grep head install journalctl mariadb mariadbd mktemp sleep stat systemctl; do
  command -v "${command_name}" >/dev/null 2>&1 ||
    die "필수 명령을 찾을 수 없습니다: ${command_name}"
done

case "${ACTION}" in
  configure) configure_node ;;
  bootstrap) bootstrap_new_cluster ;;
  join) join_cluster ;;
  status) show_status ;;
  *) die "지원하지 않는 동작입니다: ${ACTION}" ;;
esac
