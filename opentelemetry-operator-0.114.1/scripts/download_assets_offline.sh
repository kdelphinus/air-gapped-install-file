#!/bin/bash

# OpenTelemetry Operator v0.114.1 (App v0.152.0) 에셋 다운로드 스크립트

set -e

BASE_DIR=$(cd "$(dirname "$0")/.." && pwd)
CHART_DIR="${BASE_DIR}/charts"
IMAGE_DIR="${BASE_DIR}/images"

mkdir -p "$CHART_DIR" "$IMAGE_DIR"

select_download_scope() {
    echo "다운로드 범위를 선택하세요:"
    echo "  1) 전체 (Helm 차트 + 컨테이너 이미지)"
    echo "  2) Helm 차트만"
    echo "  3) 컨테이너 이미지만"
    read -p "선택 [1/2/3, 기본값: 1]: " DOWNLOAD_SCOPE
    DOWNLOAD_SCOPE="${DOWNLOAD_SCOPE:-1}"

    case "$DOWNLOAD_SCOPE" in
        1|all|ALL) DOWNLOAD_HELM=true; DOWNLOAD_IMAGES=true ;;
        2|helm|HELM) DOWNLOAD_HELM=true; DOWNLOAD_IMAGES=false ;;
        3|image|images|IMAGE|IMAGES) DOWNLOAD_HELM=false; DOWNLOAD_IMAGES=true ;;
        *) echo "[오류] 1, 2, 또는 3을 선택하세요."; exit 1 ;;
    esac
}

select_download_scope

if [ "$DOWNLOAD_HELM" = true ]; then
    echo "[1/2] Helm 차트 다운로드 중..."
    helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
    helm repo update
    helm pull open-telemetry/opentelemetry-operator --version 0.114.1 -d "$CHART_DIR"
fi

IMAGES=(
    "ghcr.io/open-telemetry/opentelemetry-operator/opentelemetry-operator:v0.152.0"
)

if [ "$DOWNLOAD_IMAGES" = true ]; then
    echo "[2/2] 컨테이너 이미지 다운로드 및 저장 중..."

    # containerd 소켓 감지 로직
    CTR_SOCKET="/run/containerd/containerd.sock"
    CTR_OPTS=""
    USE_SUDO=false

    # Rootless containerd 소켓 확인
    ROOTLESS_SOCKET="/run/user/$(id -u)/containerd/containerd.sock"
    if [ -S "$ROOTLESS_SOCKET" ]; then
        echo "ℹ️  루트리스 containerd 소켓이 감지되었습니다: $ROOTLESS_SOCKET"
        CTR_OPTS="--address $ROOTLESS_SOCKET"
    else
        # 일반 containerd 소켓에 접근 가능한지 체크
        if [ ! -w "$CTR_SOCKET" ]; then
            echo "ℹ️  일반 containerd 소켓에 권한이 없습니다. sudo를 사용합니다."
            USE_SUDO=true
        fi
    fi

    for IMG in "${IMAGES[@]}"; do
        FILENAME=$(echo $IMG | tr ':/' '-')
        echo "-> 다운로드: $IMG"

        # 이미지 pull
        if [ "$USE_SUDO" = true ]; then
            sudo ctr images pull "$IMG"
        else
            ctr $CTR_OPTS images pull "$IMG"
        fi

        # 이미지 export
        echo "-> 저장: ${IMAGE_DIR}/${FILENAME}.tar"
        if [ "$USE_SUDO" = true ]; then
            sudo ctr images export "${IMAGE_DIR}/${FILENAME}.tar" "$IMG"
        else
            ctr $CTR_OPTS images export "${IMAGE_DIR}/${FILENAME}.tar" "$IMG"
        fi
    done
fi

echo "[완료] 모든 에셋이 저장되었습니다."
