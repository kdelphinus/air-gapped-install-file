#!/bin/bash
set -e
BASE_DIR=$(cd "$(dirname "$0")/.." && pwd)
CHART_DIR="${BASE_DIR}/charts"
IMAGE_DIR="${BASE_DIR}/images"
mkdir -p "$CHART_DIR" "$IMAGE_DIR"

echo "[1/2] Helm 차트 다운로드 중..."
helm pull prometheus-community/kube-prometheus-stack --version 62.0.0 -d "$CHART_DIR" || true

echo "[2/2] 컨테이너 이미지 다운로드 및 저장 중..."
IMAGES=(
    "quay.io/prometheus/prometheus:v2.54.1"
    "quay.io/prometheus/alertmanager:v0.27.0"
    "quay.io/prometheus/node-exporter:v1.8.2"
    "docker.io/grafana/grafana:12.4.1"
    "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.13.0"
    "quay.io/prometheus-operator/prometheus-config-reloader:v0.76.1"
    "registry.k8s.io/prometheus-adapter/prometheus-adapter:v0.12.0"
    "quay.io/prometheus-operator/prometheus-operator:v0.76.1"
    # Grafana 보조 이미지 (sidecar, init)
    "quay.io/kiwigrid/k8s-sidecar:1.27.4"
    "docker.io/library/busybox:1.31.1"
    # Prometheus Operator admission webhook certgen
    "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v20221220-controller-v1.5.1-58-g787ea74b6"
)

for IMG in "${IMAGES[@]}"; do
    SAFE_NAME=$(echo $IMG | sed 's/docker.io\///' | tr ':/' '-')
    echo "-> 처리 중: $IMG"
    if [ ! -f "${IMAGE_DIR}/${SAFE_NAME}.tar" ]; then
        sudo ctr images pull "$IMG" || continue
        sudo ctr images export "${IMAGE_DIR}/${SAFE_NAME}.tar" "$IMG"
    else
        echo "   이미 존재함: ${SAFE_NAME}.tar"
    fi
done
echo "[완료] Monitoring 에셋 저장 완료."
