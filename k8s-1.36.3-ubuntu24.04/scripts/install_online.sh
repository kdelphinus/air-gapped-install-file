#!/usr/bin/env bash

set -Eeuo pipefail

COMPONENT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly COMPONENT_ROOT
readonly DOWNLOAD_SCRIPT="${COMPONENT_ROOT}/scripts/download_assets_offline.sh"
readonly INSTALL_SCRIPT="${COMPONENT_ROOT}/scripts/install.sh"

die() {
    printf '[오류] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
사용법:
  sudo ./scripts/install_online.sh

동작:
  1. Kubernetes v1.36.3 온라인 설치 자산을 로컬 k8s/ 디렉터리에 수집합니다.
  2. SHA-256 및 버전 검증을 사용하는 기존 install.sh를 실행합니다.

주의:
  - Ubuntu 24.04 amd64 온라인 환경 전용입니다.
  - 정확한 DEB와 컨테이너 이미지를 모두 수집하므로 충분한 디스크 공간이 필요합니다.
  - 기존 k8s/ 자산은 새로 수집한 자산으로 교체됩니다.
EOF
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            die "알 수 없는 옵션입니다: $1"
            ;;
    esac
fi

[[ "${EUID}" -eq 0 ]] || die "root 권한이 필요합니다. sudo로 실행하십시오."
[[ -x "${DOWNLOAD_SCRIPT}" ]] || die "다운로드 스크립트를 실행할 수 없습니다: ${DOWNLOAD_SCRIPT}"
[[ -x "${INSTALL_SCRIPT}" ]] || die "설치 스크립트를 실행할 수 없습니다: ${INSTALL_SCRIPT}"

printf '[온라인 1/2] Kubernetes v1.36.3 설치 자산을 수집합니다.\n'
"${DOWNLOAD_SCRIPT}"

printf '[온라인 2/2] 검증된 로컬 자산으로 Kubernetes 설치를 시작합니다.\n'
exec "${INSTALL_SCRIPT}"
