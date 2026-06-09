#!/bin/bash

# Root 권한 체크
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

# Jenkins v2.528.3 에셋 다운로드 스크립트

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
    helm repo add jenkins https://charts.jenkins.io
    helm repo update
    helm pull jenkins/jenkins --version 6.1.0 -d "$CHART_DIR" # Chart version corresponding to Jenkins 2.x
fi

IMAGES=(
    "docker.io/jenkins/jenkins:2.528.3-jdk21"
    "docker.io/jenkins/inbound-agent:3355.v388858a_47b_33-3"
    "docker.io/kiwigrid/k8s-sidecar:1.30.7"
)

if [ "$DOWNLOAD_IMAGES" = true ]; then
    echo "[2/2] 컨테이너 이미지 다운로드 및 저장 중..."
    for IMG in "${IMAGES[@]}"; do
        FILENAME=$(echo $IMG | tr ':/' '-')
        echo "-> 다운로드: $IMG"
        sudo ctr images pull "$IMG"
        echo "-> 저장: ${IMAGE_DIR}/${FILENAME}.tar"
        sudo ctr images export "${IMAGE_DIR}/${FILENAME}.tar" "$IMG"
    done
fi

echo "[완료] 모든 에셋이 저장되었습니다."
