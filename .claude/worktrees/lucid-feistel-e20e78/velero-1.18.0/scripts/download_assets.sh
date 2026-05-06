#!/bin/bash

# Root 권한 체크
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

set -e
BASE_DIR=$(cd "$(dirname "$0")/.." && pwd)
CHART_DIR="${BASE_DIR}/charts"
IMAGE_DIR="${BASE_DIR}/images"
SCRIPT_DIR="${BASE_DIR}/scripts"
mkdir -p "$CHART_DIR" "$IMAGE_DIR" "$SCRIPT_DIR"

echo "[1/3] Helm 차트 다운로드..."
helm pull vmware-tanzu/velero --version 12.0.0 -d "$CHART_DIR" || true

echo "[2/3] 이미지 다운로드 (Velero & MinIO)..."
IMAGES=(
    "docker.io/velero/velero:v1.18.0"
    "docker.io/velero/velero-plugin-for-aws:v1.14.0"
    "quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z"
    "quay.io/minio/mc:RELEASE.2024-11-21T17-21-54Z"
)
for IMG in "${IMAGES[@]}"; do
    # registry 명칭(docker.io/, quay.io/) 제거 후 파일명 생성
    SAFE_NAME=$(echo $IMG | sed -E 's/(docker.io\/|quay.io\/)//' | tr ':/' '-')
    if [ ! -f "${IMAGE_DIR}/${SAFE_NAME}.tar" ]; then
        echo "🚀 Pulling $IMG..."
        sudo ctr -n k8s.io images pull "$IMG" || continue
        echo "📦 Exporting to ${IMAGE_DIR}/${SAFE_NAME}.tar..."
        sudo ctr -n k8s.io images export "${IMAGE_DIR}/${SAFE_NAME}.tar" "$IMG"
    fi
done

echo "[3/3] CLI 다운로드..."
VELERO_VER="v1.18.0"
if [ ! -f "${BASE_DIR}/velero-${VELERO_VER}-linux-amd64.tar.gz" ]; then
    wget -q https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VER}/velero-${VELERO_VER}-linux-amd64.tar.gz -O "${BASE_DIR}/velero-${VELERO_VER}-linux-amd64.tar.gz"
fi
echo "[완료] Velero 및 MinIO 에셋 저장 완료."
