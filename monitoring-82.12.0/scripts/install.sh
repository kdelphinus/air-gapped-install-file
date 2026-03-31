#!/bin/bash

cd "$(dirname "$0")/.." || exit 1
NAMESPACE="monitoring"
RELEASE_NAME="prometheus"
CHART_PATH="./charts/kube-prometheus-stack"
VALUES_FILE="./values.yaml"

# ── 이미지 소스 선택 ──────────────────────────────────────────
echo ""
echo "이미지 소스를 선택하세요:"
echo "  1) Harbor 레지스트리 사용 (사전에 upload_images_to_harbor_v3-lite.sh 실행 필요)"
echo "  2) 로컬 tar 직접 import (Harbor 없음)"
read -p "선택 [1/2, 기본값: 1]: " IMAGE_SOURCE
IMAGE_SOURCE="${IMAGE_SOURCE:-1}"

if [ "${IMAGE_SOURCE}" = "1" ]; then
    read -p "Harbor 레지스트리 주소 (예: 192.168.1.10:30002 또는 harbor.example.com): " IMAGE_REGISTRY
    if [ -z "${IMAGE_REGISTRY}" ]; then
        echo "[오류] Harbor 레지스트리 주소가 필요합니다."; exit 1
    fi
    read -p "Harbor 프로젝트 (예: library, oss): " HARBOR_PROJECT
    if [ -z "${HARBOR_PROJECT}" ]; then
        echo "[오류] Harbor 프로젝트가 필요합니다."; exit 1
    fi
elif [ "${IMAGE_SOURCE}" = "2" ]; then
    echo "로컬 tar 파일을 containerd(k8s.io)에 import 중..."
    IMPORT_COUNT=0
    for tar_file in ./images/*.tar; do
        [ -e "${tar_file}" ] || continue
        echo "  → $(basename "${tar_file}")"
        sudo ctr -n k8s.io images import "${tar_file}"
        IMPORT_COUNT=$((IMPORT_COUNT + 1))
    done
    [ "${IMPORT_COUNT}" -eq 0 ] && echo "[경고] ./images/ 에 tar 파일이 없습니다."
    echo "  ${IMPORT_COUNT}개 이미지 import 완료"
    IMAGE_REGISTRY=""
    HARBOR_PROJECT=""
else
    echo "[오류] 1 또는 2를 선택하세요."; exit 1
fi

echo "🚀 Installing Monitoring (kube-prometheus-stack)..."
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Harbor 사용 시에만 이미지 레지스트리/프로젝트 오버라이드
HELM_IMAGE_ARGS=()
if [ "${IMAGE_SOURCE}" = "1" ]; then
    HELM_IMAGE_ARGS=(
        "--set" "global.imageRegistry=${IMAGE_REGISTRY}"
        "--set" "global.imageNamePrefix=${HARBOR_PROJECT}/"
    )
fi

helm upgrade --install $RELEASE_NAME "$CHART_PATH" \
  --namespace $NAMESPACE \
  -f "$VALUES_FILE" \
  "${HELM_IMAGE_ARGS[@]}" \
  --wait

# ServiceMonitor / PodMonitor 적용 (Prometheus 스크레이프 대상 등록)
for f in ./manifests/servicemonitors-*.yaml ./manifests/podmonitors-*.yaml; do
    [ -f "$f" ] && echo "📊 $f 적용 중..." && kubectl apply -f "$f"
done

# 커스텀 알림 룰 적용
for f in ./manifests/alertrules-*.yaml; do
    [ -f "$f" ] && echo "🔔 $f 적용 중..." && kubectl apply -f "$f"
done

# Grafana 커스텀 대시보드 적용
for f in ./manifests/grafana-dashboard-*.yaml; do
    [ -f "$f" ] && echo "📈 $f 적용 중..." && kubectl apply -f "$f"
done

# HTTPRoute 적용 (Envoy Gateway 사용 시)
if [ -f "./manifests/httproute.yaml" ]; then
    echo "📡 HTTPRoute 적용 중..."
    kubectl apply -f ./manifests/httproute.yaml
fi
