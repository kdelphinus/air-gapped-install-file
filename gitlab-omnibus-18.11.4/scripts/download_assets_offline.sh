#!/bin/bash

# Root 권한 체크
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

# GitLab Omnibus v18.11.4 에셋 다운로드 스크립트

set -e

BASE_DIR=$(cd "$(dirname "$0")/.." && pwd)
IMAGE_DIR="${BASE_DIR}/images"

mkdir -p "$IMAGE_DIR"

echo "[1/1] 컨테이너 이미지 다운로드 및 저장 중..."
IMAGES=(
    "gitlab/gitlab-ee:18.11.4-ee.0"
)

for IMG in "${IMAGES[@]}"; do
    FILENAME=$(echo $IMG | tr ':/' '-')
    CTR_IMG="${IMG}"
    if [[ "${CTR_IMG}" != *.*/* && "${CTR_IMG}" != localhost/* ]]; then
        CTR_IMG="docker.io/${CTR_IMG}"
    fi
    echo "-> 다운로드: $IMG"
    sudo ctr images pull "$CTR_IMG"
    echo "-> 저장: ${IMAGE_DIR}/${FILENAME}.tar"
    sudo ctr images export "${IMAGE_DIR}/${FILENAME}.tar" "$CTR_IMG"
done

echo "[완료] 모든 에셋이 저장되었습니다."
