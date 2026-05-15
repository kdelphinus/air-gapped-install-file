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
# 82.12.0 버전으로 다운로드
helm pull prometheus-community/kube-prometheus-stack --version 82.12.0 -d "$CHART_DIR" || true

echo "[2/2] 컨테이너 이미지 다운로드 및 저장 중..."
IMAGES=(
    "quay.io/prometheus/prometheus:v3.10.0"
    "quay.io/prometheus/alertmanager:v0.31.1"
    "quay.io/prometheus/node-exporter:v1.10.2"
    "docker.io/grafana/grafana:11.3.3"
    "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.18.0"
    "quay.io/prometheus-operator/prometheus-config-reloader:v0.89.0"
    "quay.io/prometheus-operator/prometheus-operator:v0.89.0"
    "quay.io/kiwigrid/k8s-sidecar:2.5.0"
    "docker.io/library/busybox:1.37.0"
    "ghcr.io/jkroepke/kube-webhook-certgen:v1.7.8"
)

for IMG in "${IMAGES[@]}"; do
    # SAFE_NAME logic matching the actual files in images/ directory
    SAFE_NAME=$(echo $IMG | tr ':/' '-')
    echo "-> 처리 중: $IMG (File: ${SAFE_NAME}.tar)"
    if [ ! -f "${IMAGE_DIR}/${SAFE_NAME}.tar" ]; then
        sudo ctr images pull "$IMG" || continue
        sudo ctr images export "${IMAGE_DIR}/${SAFE_NAME}.tar" "$IMG"
    else
        echo "   이미 존재함: ${SAFE_NAME}.tar"
    fi
done
echo "[완료] Monitoring 에셋 저장 완료."
