#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="nexus"
RELEASE_NAME="nexus"

echo "==========================================="
echo " Uninstalling Nexus Repository Manager"
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

# HTTPRoute 제거
if [ -f "./manifests/httproute.yaml" ]; then
    echo "🗑️  HTTPRoute 삭제 중..."
    kubectl delete -f ./manifests/httproute.yaml --ignore-not-found=true
fi

# PV 삭제 여부 (Retain policy — 삭제 시 데이터 유실)
echo ""
read -p "⚠️  PV도 삭제하시겠습니까? (데이터 유실 주의) (y/n): " DELETE_PV
if [[ "$DELETE_PV" =~ ^[Yy]$ ]]; then
    echo "🗑️  PV 삭제 중..."
    kubectl get pv | grep $NAMESPACE | awk '{print $1}' | xargs -r kubectl delete pv
fi

# 네임스페이스 삭제
echo "🗑️  Namespace '$NAMESPACE' 삭제 중..."
kubectl delete ns $NAMESPACE --ignore-not-found=true

echo ""
echo "✅ Nexus 삭제 완료."
