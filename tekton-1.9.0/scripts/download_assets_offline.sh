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

# 매니페스트 파일들에서 실제 ghcr.io 및 gcr.io 이미지 주소를 동적으로 파싱
# @sha256: 다이제스트는 pull 단계 이전에 제거하여 순수 이미지명:태그 구조 확보
echo "-> 매니페스트 디렉토리($MANIFEST_DIR)에서 이미지 목록 동적 추출 중..."
mapfile -t IMAGES < <(grep -o -E '(ghcr\.io/tektoncd|gcr\.io/tekton-releases)/[^"'\'' ]*' "$MANIFEST_DIR"/*.yaml 2>/dev/null | sed 's/@sha256.*//' | sort -u)

if [ ${#IMAGES[@]} -eq 0 ]; then
    echo -e "\033[0;31m[오류] 매니페스트에서 이미지 목록을 추출하지 못했습니다.\033[0m"
    exit 1
fi

echo "-> 추출 완료: 총 ${#IMAGES[@]} 개의 고유 이미지 감지됨"

for IMG in "${IMAGES[@]}"; do
    FILENAME=$(echo "$IMG" | tr ':/' '-')
    echo "-> 다운로드: $IMG"
    sudo ctr images pull "$IMG"
    echo "-> 저장: ${IMAGE_DIR}/${FILENAME}.tar"
    sudo ctr images export "${IMAGE_DIR}/${FILENAME}.tar" "$IMG"
done

echo "[완료] 모든 에셋이 저장되었습니다."
