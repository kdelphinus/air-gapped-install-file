#!/bin/bash
set -e
BASE_DIR=$(cd "$(dirname "$0")/.." && pwd)
CHART_DIR="${BASE_DIR}/charts"
IMAGE_DIR="${BASE_DIR}/images"
SCRIPT_DIR="${BASE_DIR}/scripts"
mkdir -p "$CHART_DIR" "$IMAGE_DIR" "$SCRIPT_DIR"

echo "[1/3] Helm 차트 다운로드..."
helm pull vmware-tanzu/velero --version 7.2.1 -d "$CHART_DIR" || true

echo "[2/3] 이미지 다운로드..."
IMAGES=(
    "docker.io/velero/velero:v1.14.1"
    "docker.io/velero/velero-plugin-for-aws:v1.10.1"
    "docker.io/velero/velero-node-agent:v1.14.1"
)
for IMG in "${IMAGES[@]}"; do
    SAFE_NAME=$(echo $IMG | sed 's/docker.io\///' | tr ':/' '-')
    if [ ! -f "${IMAGE_DIR}/${SAFE_NAME}.tar" ]; then
        sudo ctr images pull "$IMG" || continue
        sudo ctr images export "${IMAGE_DIR}/${SAFE_NAME}.tar" "$IMG"
    fi
done

echo "[3/3] CLI 다운로드..."
VELERO_VER="v1.14.1"
if [ ! -f "${SCRIPT_DIR}/velero-${VELERO_VER}-linux-amd64.tar.gz" ]; then
    wget -q https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VER}/velero-${VELERO_VER}-linux-amd64.tar.gz -O "${SCRIPT_DIR}/velero-${VELERO_VER}-linux-amd64.tar.gz"
fi
echo "[완료] Velero 에셋 저장 완료."
