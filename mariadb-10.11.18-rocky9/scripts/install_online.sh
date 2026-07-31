#!/usr/bin/env bash
set -Eeuo pipefail

COMPONENT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly COMPONENT_ROOT
readonly DOWNLOAD_SCRIPT="${COMPONENT_ROOT}/scripts/download_assets_offline.sh"
readonly INSTALL_SCRIPT="${COMPONENT_ROOT}/scripts/install.sh"

ACTION=""
ASSUME_YES=false

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
사용법:
  sudo ./scripts/install_online.sh [--install|--upgrade|--reinstall] [--yes]

동작:
  --install       MariaDB 10.11.18을 신규 설치합니다. 기본 동작입니다.
  --upgrade       기존 MariaDB 10.11 계열을 10.11.18로 업그레이드합니다.
  --reinstall     MariaDB 10.11.18 패키지와 설정을 다시 적용합니다.
  --yes           확인 질문 없이 진행합니다.

환경 변수:
  MARIADB_REPO_URL
      MariaDB 10.11.18 RPM 저장소 URL을 재정의합니다.

이 스크립트는 정확한 버전의 RPM과 의존성을 먼저 로컬 폴더에 받은 뒤
오프라인 설치 스크립트를 호출합니다.
EOF
}

set_action() {
  local requested=$1
  [[ -z "${ACTION}" ]] || die "설치 동작은 하나만 지정할 수 있습니다."
  ACTION="${requested}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) set_action "install" ;;
    --upgrade) set_action "upgrade" ;;
    --reinstall) set_action "reinstall" ;;
    --yes) ASSUME_YES=true ;;
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
[[ -x "${DOWNLOAD_SCRIPT}" ]] || die "다운로드 스크립트를 실행할 수 없습니다."
[[ -x "${INSTALL_SCRIPT}" ]] || die "설치 스크립트를 실행할 수 없습니다."

ACTION=${ACTION:-install}

printf '[INFO] MariaDB 10.11.18 온라인 설치용 RPM을 수집합니다.\n'
"${DOWNLOAD_SCRIPT}"

install_args=("--${ACTION}")
if [[ "${ASSUME_YES}" == true ]]; then
  install_args+=("--yes")
fi

printf '[INFO] 검증된 로컬 RPM으로 %s 작업을 시작합니다.\n' "${ACTION}"
exec "${INSTALL_SCRIPT}" "${install_args[@]}"
