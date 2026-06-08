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

mkdir -p "$CHART_DIR" "$IMAGE_DIR"

echo "[1/2] Helm 차트 다운로드 중..."
helm pull oci://docker.io/envoyproxy/gateway-helm \
  --version v1.7.2 \
  -d "$CHART_DIR"

echo "[2/2] 컨테이너 이미지 다운로드 및 저장 중..."
IMAGES=(
    "docker.io/envoyproxy/gateway:v1.7.2"
    "docker.io/envoyproxy/envoy:distroless-v1.37.2"
)

for IMG in "${IMAGES[@]}"; do
    FILENAME=$(echo "$IMG" | tr ':/' '-')
    TAR_PATH="${IMAGE_DIR}/${FILENAME}.tar"

    echo "-> 저장: ${TAR_PATH}"
    rm -f "$TAR_PATH"

    skopeo copy \
      --override-os linux \
      --override-arch amd64 \
      "docker://${IMG}" \
      "docker-archive:${TAR_PATH}:${IMG}"
done

echo "[완료] 모든 에셋이 저장되었습니다."