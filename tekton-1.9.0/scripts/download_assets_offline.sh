#!/bin/bash

# Root 권한 체크
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

# Tekton v1.9.0 LTS 에셋 다운로드 스크립트

set -e

BASE_DIR=$(cd "$(dirname "$0")/.." && pwd)
MANIFEST_DIR="${BASE_DIR}/manifests"
IMAGE_DIR="${BASE_DIR}/images"

mkdir -p "$MANIFEST_DIR" "$IMAGE_DIR"

echo "[1/2] 매니페스트 다운로드 중..."
curl -L https://storage.googleapis.com/tekton-releases/pipeline/previous/v1.9.0/release.yaml -o "${MANIFEST_DIR}/pipelines-v1.9.0-release.yaml"
curl -L https://storage.googleapis.com/tekton-releases/triggers/previous/v0.34.0/release.yaml -o "${MANIFEST_DIR}/triggers-v0.34.0-release.yaml"
curl -L https://storage.googleapis.com/tekton-releases/dashboard/previous/v0.65.0/release.yaml -o "${MANIFEST_DIR}/dashboard-v0.65.0-release.yaml"

echo "[2/2] 컨테이너 이미지 다운로드 및 저장 중..."
# Pipelines v1.9.0
IMAGES=(
    "ghcr.io/tektoncd/pipeline/cmd/controller:v1.9.0"
    "ghcr.io/tektoncd/pipeline/cmd/webhook:v1.9.0"
    "ghcr.io/tektoncd/pipeline/cmd/entrypoint:v1.9.0"
    "ghcr.io/tektoncd/pipeline/cmd/kubeconfigwriter:v1.9.0"
    "ghcr.io/tektoncd/pipeline/cmd/imagedigestexporter:v1.9.0"
    "ghcr.io/tektoncd/pipeline/cmd/pullrequest-init:v1.9.0"
    "ghcr.io/tektoncd/pipeline/cmd/workingdirinit:v1.9.0"
)
# Triggers v0.34.0
IMAGES+=(
    "ghcr.io/tektoncd/triggers/cmd/controller:v0.34.0"
    "ghcr.io/tektoncd/triggers/cmd/webhook:v0.34.0"
    "ghcr.io/tektoncd/triggers/cmd/eventlistenersink:v0.34.0"
)
# Dashboard v0.65.0
IMAGES+=(
    "ghcr.io/tektoncd/dashboard/cmd/dashboard:v0.65.0"
)

for IMG in "${IMAGES[@]}"; do
    FILENAME=$(echo $IMG | tr ':/' '-')
    echo "-> 다운로드: $IMG"
    sudo ctr images pull "$IMG"
    echo "-> 저장: ${IMAGE_DIR}/${FILENAME}.tar"
    sudo ctr images export "${IMAGE_DIR}/${FILENAME}.tar" "$IMG"
done

echo "[완료] 모든 에셋이 저장되었습니다."
