#!/bin/bash
cd "$(dirname "$0")/.." || exit 1
NAMESPACE="monitoring"
RELEASE_NAME="prometheus"
CHART_PATH="./charts/kube-prometheus-stack"
VALUES_FILE="./values.yaml"

echo "🚀 Installing Monitoring (kube-prometheus-stack)..."
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install $RELEASE_NAME "$CHART_PATH" \
  --namespace $NAMESPACE \
  -f "$VALUES_FILE" \
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
