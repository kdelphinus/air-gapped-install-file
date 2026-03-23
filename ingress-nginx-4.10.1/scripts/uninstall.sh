#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="ingress-nginx"
RELEASE_NAME="ingress-nginx"

echo "==========================================="
echo " Uninstalling NGINX Ingress Controller 4.10.1"
echo "==========================================="
read -p "❓ 정말 삭제하시겠습니까? (y/n): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "취소되었습니다."; exit 0; }

# Helm 제거
if helm status $RELEASE_NAME -n $NAMESPACE > /dev/null 2>&1; then
    echo "🗑️  Helm Release '$RELEASE_NAME' 삭제 중..."
    helm uninstall $RELEASE_NAME -n $NAMESPACE
else
    echo "  - 삭제할 Helm Release가 없습니다."
fi

# 네임스페이스 삭제
echo "🗑️  Namespace '$NAMESPACE' 삭제 중..."
kubectl delete ns $NAMESPACE --ignore-not-found=true

echo ""
echo "✅ NGINX Ingress Controller 삭제 완료."
