#!/usr/bin/env bash
set -Eeuo pipefail

COMPONENT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly COMPONENT_ROOT
readonly DB_DEB_DIR="${COMPONENT_ROOT}/db/debs"
readonly COMMON_DEB_DIR="${COMPONENT_ROOT}/common/debs"
readonly REPOSITORY_DIR="${COMPONENT_ROOT}/repository"
readonly MARIADB_VERSION="10.11.18"
readonly MARIADB_DEB_VERSION="1:10.11.18+maria~ubu2404"
readonly GALERA_DEB_VERSION="26.4.27-ubu2404"
readonly DEFAULT_REPO_URL="https://archive.mariadb.org/mariadb-10.11.18/repo/ubuntu"
readonly MARIADB_REPO_URL="${MARIADB_REPO_URL:-${DEFAULT_REPO_URL}}"
readonly SIGNING_KEY_URL="https://mariadb.org/mariadb_release_signing_key.pgp"
readonly KEY_ASC="${REPOSITORY_DIR}/mariadb_release_signing_key.pgp"
readonly KEY_GPG="${REPOSITORY_DIR}/mariadb-keyring.gpg"

APT_SOURCE_DIR=""
UBUNTU_SOURCE_FILE=""
SOURCE_FILE=""
declare -a APT_SOURCE_OPTIONS=()

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${APT_SOURCE_DIR}" &&
    "${APT_SOURCE_DIR}" == /tmp/mariadb-apt-sources.* &&
    -d "${APT_SOURCE_DIR}" ]]; then
    rm -rf --one-file-system "${APT_SOURCE_DIR}"
  fi
}
trap cleanup EXIT

check_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release를 읽을 수 없습니다."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] ||
    die "Ubuntu 24.04에서 실행하십시오: ID=${ID:-unknown}, VERSION_ID=${VERSION_ID:-unknown}"
  [[ "$(uname -m)" == "x86_64" ]] || die "x86_64 아키텍처만 지원합니다."
}

configure_isolated_sources() {
  if [[ -r /etc/apt/sources.list.d/ubuntu.sources ]]; then
    UBUNTU_SOURCE_FILE="/etc/apt/sources.list.d/ubuntu.sources"
  elif [[ -r /etc/apt/sources.list ]]; then
    UBUNTU_SOURCE_FILE="/etc/apt/sources.list"
  else
    die "Ubuntu 공식 APT 소스 파일을 찾을 수 없습니다."
  fi

  APT_SOURCE_DIR=$(mktemp -d /tmp/mariadb-apt-sources.XXXXXX)
  SOURCE_FILE="${APT_SOURCE_DIR}/mariadb.list"
  printf 'deb [arch=amd64 signed-by=%s] %s noble main\n' \
    "${KEY_GPG}" \
    "${MARIADB_REPO_URL}" > "${SOURCE_FILE}"

  APT_SOURCE_OPTIONS=(
    -o "Dir::Etc::sourcelist=${UBUNTU_SOURCE_FILE}"
    -o "Dir::Etc::sourceparts=${APT_SOURCE_DIR}"
    -o "APT::Sandbox::User=root"
  )
}

download_dependency_closure() {
  local destination=$1
  shift
  local -a roots=("$@")
  local -a packages=()

  mapfile -t packages < <(
    apt-cache "${APT_SOURCE_OPTIONS[@]}" depends \
      --recurse \
      --no-recommends \
      --no-suggests \
      --no-conflicts \
      --no-breaks \
      --no-replaces \
      --no-enhances \
      "${roots[@]}" |
      sed -nE '/^[a-z0-9][a-z0-9+.-]*(:[a-z0-9]+)?$/p' |
      sort -u
  )
  ((${#packages[@]} > 0)) || die "의존성 패키지 목록을 계산하지 못했습니다."

  (
    cd "${destination}"
    apt-get "${APT_SOURCE_OPTIONS[@]}" download "${packages[@]}"
  )
}

verify_exact_package() {
  local directory=$1
  local package_name=$2
  local expected_version=$3
  local deb_file
  local version

  while IFS= read -r -d '' deb_file; do
    [[ "$(dpkg-deb -f "${deb_file}" Package)" == "${package_name}" ]] || continue
    version=$(dpkg-deb -f "${deb_file}" Version)
    [[ "${version}" == "${expected_version}" ]] &&
      return 0
  done < <(find "${directory}" -maxdepth 1 -type f -name '*.deb' -print0)

  die "${package_name} ${expected_version} DEB를 찾을 수 없습니다."
}

[[ "${EUID}" -eq 0 ]] || die "root 권한이 필요합니다. sudo로 실행하십시오."
check_os
for command_name in apt-cache apt-get curl dpkg-deb gpg sed sha256sum sort; do
  command -v "${command_name}" >/dev/null 2>&1 ||
    die "필수 명령을 찾을 수 없습니다: ${command_name}"
done

install -d -m 755 \
  "${DB_DEB_DIR}" \
  "${COMMON_DEB_DIR}" \
  "${REPOSITORY_DIR}"
find "${DB_DEB_DIR}" "${COMMON_DEB_DIR}" \
  -maxdepth 1 -type f \( -name '*.deb' -o -name 'SHA256SUMS' \) -delete

curl -fsSL "${SIGNING_KEY_URL}" -o "${KEY_ASC}"
gpg --batch --yes --dearmor --output "${KEY_GPG}" "${KEY_ASC}"
chmod 644 "${KEY_ASC}" "${KEY_GPG}"

configure_isolated_sources
apt-get "${APT_SOURCE_OPTIONS[@]}" update

printf '[INFO] MariaDB %s 및 Galera %s DEB를 다운로드합니다.\n' \
  "${MARIADB_VERSION}" \
  "${GALERA_DEB_VERSION}"

download_dependency_closure \
  "${DB_DEB_DIR}" \
  mariadb-server \
  mariadb-client \
  mariadb-backup \
  galera-4

download_dependency_closure \
  "${COMMON_DEB_DIR}" \
  rsync \
  socat \
  lsof \
  psmisc \
  iproute2 \
  libdbi-perl \
  ca-certificates

verify_exact_package "${DB_DEB_DIR}" mariadb-server "${MARIADB_DEB_VERSION}"
verify_exact_package "${DB_DEB_DIR}" mariadb-client "${MARIADB_DEB_VERSION}"
verify_exact_package "${DB_DEB_DIR}" mariadb-backup "${MARIADB_DEB_VERSION}"
verify_exact_package "${DB_DEB_DIR}" galera-4 "${GALERA_DEB_VERSION}"

(
  cd "${DB_DEB_DIR}"
  sha256sum ./*.deb > SHA256SUMS
)
(
  cd "${COMMON_DEB_DIR}"
  sha256sum ./*.deb > SHA256SUMS
)

printf '[OK] 다운로드 및 버전 검증 완료\n'
printf '  DB DEB: %s\n' "${DB_DEB_DIR}"
printf '  공통 DEB: %s\n' "${COMMON_DEB_DIR}"
