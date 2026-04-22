#!/bin/bash
# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="nginx-ingress"
RELEASE_NAME="nginx-ingress"

echo "========================================================================"
echo " F5 NGINX Ingress Controller v5.3.1 삭제"
echo "========================================================================"
read -p "정말 삭제하시겠습니까? (y/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "취소되었습니다."; exit 0; }

# Helm 릴리스 삭제
if helm status "$RELEASE_NAME" -n "$NAMESPACE" > /dev/null 2>&1; then
    echo "Helm Release '$RELEASE_NAME' 삭제 중..."
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE"
else
    echo "삭제할 Helm Release가 없습니다."
fi

# CRD 삭제 (선택적 — 재설치 예정이라면 생략)
read -p "CRD(Custom Resource Definitions)도 함께 삭제하시겠습니까? (y/N): " DELETE_CRD
if [[ "$DELETE_CRD" =~ ^[Yy]$ ]]; then
    echo "NIC CRD 삭제 중 (manifests/)..."
    kubectl delete -k ./manifests/ --ignore-not-found=true
fi

# 네임스페이스 삭제
echo "Namespace '$NAMESPACE' 삭제 중..."
kubectl delete ns "$NAMESPACE" --ignore-not-found=true

echo ""
echo "========================================================================"
echo " F5 NGINX Ingress Controller 삭제 완료"
echo "========================================================================"
