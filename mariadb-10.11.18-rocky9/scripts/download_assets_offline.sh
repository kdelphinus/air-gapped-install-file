#!/usr/bin/env bash
set -Eeuo pipefail

COMPONENT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly COMPONENT_ROOT
readonly DB_RPM_DIR="${COMPONENT_ROOT}/db/rpms"
readonly COMMON_RPM_DIR="${COMPONENT_ROOT}/common/rpms"
readonly MARIADB_VERSION="10.11.18"
readonly GALERA_VERSION="26.4.27"
readonly DEFAULT_REPO_URL="https://dlm.mariadb.com/repo/mariadb-server/10.11.18/yum/rhel/9/x86_64"
readonly MARIADB_REPO_URL="${MARIADB_REPO_URL:-${DEFAULT_REPO_URL}}"

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

[[ "${EUID}" -eq 0 ]] || die "root 권한이 필요합니다. sudo로 실행하십시오."
[[ -r /etc/os-release ]] || die "/etc/os-release를 읽을 수 없습니다."

# shellcheck disable=SC1091
source /etc/os-release
os_id=${ID:-unknown}
os_like=${ID_LIKE:-}
major=${VERSION_ID%%.*}

if [[ ! "${os_id}" =~ ^(rocky|rhel|almalinux)$ ]] &&
  [[ " ${os_like} " != *" rhel "* ]]; then
  die "Rocky Linux/RHEL 계열에서 실행하십시오: ID=${os_id}"
fi
[[ "${major}" == "9" ]] || die "Rocky Linux/RHEL 9 계열만 지원합니다."
[[ "$(uname -m)" == "x86_64" ]] || die "x86_64 아키텍처만 지원합니다."

dnf install -y dnf-plugins-core
mkdir -p "${DB_RPM_DIR}" "${COMMON_RPM_DIR}"
rm -f "${DB_RPM_DIR}"/*.rpm "${COMMON_RPM_DIR}"/*.rpm

printf '[INFO] MariaDB %s 및 Galera %s RPM을 다운로드합니다.\n' \
  "${MARIADB_VERSION}" "${GALERA_VERSION}"

dnf download \
  --resolve \
  --alldeps \
  --destdir="${DB_RPM_DIR}" \
  --repofrompath="mariadb-airgap,${MARIADB_REPO_URL}" \
  --enablerepo=mariadb-airgap \
  "MariaDB-server-${MARIADB_VERSION}" \
  "MariaDB-client-${MARIADB_VERSION}" \
  "MariaDB-common-${MARIADB_VERSION}" \
  "MariaDB-shared-${MARIADB_VERSION}" \
  "MariaDB-backup-${MARIADB_VERSION}" \
  "galera-4-${GALERA_VERSION}" \
  mysql-selinux

dnf download \
  --resolve \
  --alldeps \
  --destdir="${COMMON_RPM_DIR}" \
  socat rsync tar lsof policycoreutils-python-utils

printf '[OK] 다운로드 완료\n'
printf '  DB RPM: %s\n' "${DB_RPM_DIR}"
printf '  공통 RPM: %s\n' "${COMMON_RPM_DIR}"
