#!/bin/bash

# Root 권한 체크
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

# Envoy Gateway v1.6.1 (Envoy Proxy v1.36.3) 에셋 다운로드 스크립트

set -e

BASE_DIR=$(cd "$(dirname "$0")/.." && pwd)
CHART_DIR="${BASE_DIR}/charts"
IMAGE_DIR="${BASE_DIR}/images"

mkdir -p "$CHART_DIR" "$IMAGE_DIR"

echo "[1/2] Helm 차트 다운로드 중..."
helm repo add envoygateway https://helm.envoygateway.ai
helm repo update
# Controller 차트
helm pull envoygateway/gateway --version v1.6.1 -d "$CHART_DIR"
# Infra 차트 (gateway-infra는 로컬에 있는 경우가 많으나, 필요한 경우를 위해 명시)
# helm pull envoygateway/gateway-infra --version v1.6.1 -d "$CHART_DIR"

echo "[2/2] 컨테이너 이미지 다운로드 및 저장 중..."
IMAGES=(
    "docker.io/envoyproxy/gateway:v1.6.1"
    "docker.io/envoyproxy/envoy:distroless-v1.36.3"
)

for IMG in "${IMAGES[@]}"; do
    FILENAME=$(echo $IMG | tr ':/' '-')
    echo "-> 다운로드: $IMG"
    sudo ctr images pull "$IMG"
    echo "-> 저장: ${IMAGE_DIR}/${FILENAME}.tar"
    sudo ctr images export "${IMAGE_DIR}/${FILENAME}.tar" "$IMG"
done

echo "[완료] 모든 에셋이 저장되었습니다."
