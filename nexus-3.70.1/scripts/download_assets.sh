#!/bin/bash
# Nexus Repository Manager v3.70.1 에셋 다운로드 스크립트 (ctr 보정 버전)

set -e

BASE_DIR=$(cd "$(dirname "$0")/.." && pwd)
CHART_DIR="${BASE_DIR}/charts"
IMAGE_DIR="${BASE_DIR}/images"

mkdir -p "$CHART_DIR" "$IMAGE_DIR"

echo "[1/2] Helm 차트 다운로드 중..."
# Sonatype 공식 Helm 저장소 사용 (chart version 64.2.0 = appVersion 3.64.0)
# 더 높은 Nexus 버전이 필요한 경우: helm search repo sonatype/nexus-repository-manager --versions
helm repo add sonatype https://sonatype.github.io/helm3-charts/
helm repo update
helm pull sonatype/nexus-repository-manager --version 64.2.0 --untar -d "$CHART_DIR" || true

echo "[2/2] 컨테이너 이미지 다운로드 및 저장 중..."
IMAGES=(
    "docker.io/sonatype/nexus3:3.70.1"
)

for IMG in "${IMAGES[@]}"; do
    SAFE_NAME=$(echo $IMG | sed 's/docker.io\///' | tr ':/' '-')
    echo "-> 다운로드: $IMG"
    sudo ctr images pull "$IMG"
    echo "-> 저장: ${IMAGE_DIR}/${SAFE_NAME}.tar"
    sudo ctr images export "${IMAGE_DIR}/${SAFE_NAME}.tar" "$IMG"
done

echo "[완료] 모든 에셋이 저장되었습니다."
