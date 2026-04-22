#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="kube-system"

echo "Tetragon 1.6.0 제거를 시작합니다..."

kubectl delete tracingpolicy --all 2>/dev/null && echo "[OK] TracingPolicy 제거 완료." || echo "[INFO] TracingPolicy 없음."

helm uninstall tetragon -n "$NAMESPACE" 2>/dev/null && echo "[OK] Helm 릴리스 제거 완료." || echo "[INFO] 릴리스가 없거나 이미 제거됨."

echo "완료."
