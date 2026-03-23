#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="jenkins"
RELEASE_NAME="jenkins"
NODE_LABEL_KEY="jenkins-node"

echo "==========================================="
echo " Uninstalling Jenkins 2.528.3"
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

# 노드 라벨 제거
echo "🗑️  노드 라벨 '$NODE_LABEL_KEY' 제거 중..."
kubectl label nodes --all ${NODE_LABEL_KEY}- > /dev/null 2>&1 || true

# PV/PVC 삭제 여부 (Retain policy — 삭제 시 데이터 유실)
echo ""
read -p "⚠️  PV/PVC도 삭제하시겠습니까? (데이터 유실 주의) (y/n): " DELETE_PV
if [[ "$DELETE_PV" =~ ^[Yy]$ ]]; then
    echo "🗑️  PVC 삭제 중..."
    kubectl delete pvc -n $NAMESPACE --all --ignore-not-found=true

    echo "🗑️  PV 삭제 중..."
    if [ -f "./manifests/pv-volume.yaml" ]; then
        kubectl delete -f ./manifests/pv-volume.yaml --ignore-not-found=true
    fi
    if [ -f "./manifests/gradle-cache-pv-pvc.yaml" ]; then
        kubectl delete -f ./manifests/gradle-cache-pv-pvc.yaml --ignore-not-found=true
    fi
fi

# 네임스페이스 삭제
echo "🗑️  Namespace '$NAMESPACE' 삭제 중..."
kubectl delete ns $NAMESPACE --ignore-not-found=true

echo ""
echo "✅ Jenkins 삭제 완료."
