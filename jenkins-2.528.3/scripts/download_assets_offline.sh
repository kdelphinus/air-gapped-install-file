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

echo "[1/2] Helm 차트 다운로드 중..."
helm repo add jenkins https://charts.jenkins.io
helm repo update
helm pull jenkins/jenkins --version 6.1.0 -d "$CHART_DIR" # Chart version corresponding to Jenkins 2.x

echo "[2/2] 컨테이너 이미지 다운로드 및 저장 중..."
IMAGES=(
    "jenkins/jenkins:2.528.3-jdk21"
    "jenkins/inbound-agent:3355.v388858a_47b_33-3"
    "kiwigrid/k8s-sidecar:1.30.7"
)

for IMG in "${IMAGES[@]}"; do
    FILENAME=$(echo $IMG | tr ':/' '-')
    echo "-> 다운로드: $IMG"
    sudo ctr images pull "$IMG"
    echo "-> 저장: ${IMAGE_DIR}/${FILENAME}.tar"
    sudo ctr images export "${IMAGE_DIR}/${FILENAME}.tar" "$IMG"
done

echo "[완료] 모든 에셋이 저장되었습니다."
