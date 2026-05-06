#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="falco"

echo "Falco 8.0.1 제거를 시작합니다..."

helm uninstall falco -n "$NAMESPACE" 2>/dev/null && echo "[OK] Helm 릴리스 제거 완료." || echo "[INFO] 릴리스가 없거나 이미 제거됨."

kubectl delete namespace "$NAMESPACE" 2>/dev/null && echo "[OK] Namespace 제거 완료." || echo "[INFO] Namespace가 없거나 이미 제거됨."

echo "완료."
