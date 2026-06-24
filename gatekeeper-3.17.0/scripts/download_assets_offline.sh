#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Run this script with sudo or as root."
    exit 1
fi

set -euo pipefail

BASE_DIR=$(cd "$(dirname "$0")/.." && pwd)
CHART_DIR="${BASE_DIR}/charts"
IMAGE_DIR="${BASE_DIR}/images"
VERSION="3.17.0"
APP_VERSION="v3.17.0"

mkdir -p "$CHART_DIR" "$IMAGE_DIR"

select_download_scope() {
    echo "다운로드 범위를 선택하십시오."
    echo "  1) 전체 (Helm 차트 + 컨테이너 이미지)"
    echo "  2) Helm 차트만"
    echo "  3) 컨테이너 이미지만"
    read -r -p "선택 [1/2/3, 기본값 1]: " DOWNLOAD_SCOPE
    DOWNLOAD_SCOPE="${DOWNLOAD_SCOPE:-1}"

    case "$DOWNLOAD_SCOPE" in
        1|all|ALL) DOWNLOAD_HELM=true; DOWNLOAD_IMAGES=true ;;
        2|helm|HELM) DOWNLOAD_HELM=true; DOWNLOAD_IMAGES=false ;;
        3|image|images|IMAGE|IMAGES) DOWNLOAD_HELM=false; DOWNLOAD_IMAGES=true ;;
        *) echo "[ERROR] 1, 2, 또는 3을 선택하십시오."; exit 1 ;;
    esac
}

select_download_scope

if [ "$DOWNLOAD_HELM" = true ]; then
    echo "[1/2] Gatekeeper Helm 차트 다운로드 중..."
    helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts --force-update
    helm repo update
    rm -rf "${CHART_DIR}/gatekeeper"
    helm pull gatekeeper/gatekeeper --version "$VERSION" --untar -d "$CHART_DIR"
fi

IMAGES=(
    "openpolicyagent/gatekeeper:${APP_VERSION}"
    "openpolicyagent/gatekeeper-crds:${APP_VERSION}"
)

if [ "$DOWNLOAD_IMAGES" = true ]; then
    echo "컨테이너 런타임 환경 감지 중..."
    RUNTIME=""
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        RUNTIME="docker"
    elif command -v ctr >/dev/null 2>&1; then
        RUNTIME="ctr"
    fi

    if [ -z "$RUNTIME" ]; then
        echo "[ERROR] docker 또는 ctr 명령어를 찾을 수 없거나 실행 중이 아닙니다."
        exit 1
    fi
    echo "사용할 컨테이너 런타임: $RUNTIME"

    echo "[2/2] 컨테이너 이미지 다운로드 및 저장 중..."
    for IMG in "${IMAGES[@]}"; do
        FILENAME=$(echo "$IMG" | tr ':/' '-')
        echo "-> Pull: $IMG"
        if [ "$RUNTIME" = "docker" ]; then
            docker pull "$IMG"
            echo "-> Save: ${IMAGE_DIR}/${FILENAME}.tar"
            docker save -o "${IMAGE_DIR}/${FILENAME}.tar" "$IMG"
        else
            ctr images pull "$IMG"
            echo "-> Export: ${IMAGE_DIR}/${FILENAME}.tar"
            ctr images export "${IMAGE_DIR}/${FILENAME}.tar" "$IMG"
        fi
    done
fi

echo "[DONE] Gatekeeper ${APP_VERSION} 오프라인 자산 준비가 완료되었습니다."

