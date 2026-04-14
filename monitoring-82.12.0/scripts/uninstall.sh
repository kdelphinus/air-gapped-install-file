#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="monitoring"
RELEASE_NAME="prometheus"

echo "==========================================="
echo " Uninstalling Monitoring (kube-prometheus-stack)"
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

# manifests 제거
echo "🗑️  Manifests 삭제 중..."
for f in ./manifests/*.yaml; do
    [ -f "$f" ] && kubectl delete -f "$f" --ignore-not-found=true
done

# 네임스페이스 삭제 (PVC 포함) — PV 삭제 전에 먼저 실행
echo "🗑️  Namespace '$NAMESPACE' 삭제 중..."
kubectl delete ns $NAMESPACE --ignore-not-found=true --wait=false

# PV 삭제 여부 (Retain policy — 삭제 시 데이터 유실)
echo ""
read -p "⚠️  PV도 삭제하시겠습니까? (데이터 유실 주의) (y/n): " DELETE_PV
if [[ "$DELETE_PV" =~ ^[Yy]$ ]]; then
    # PVC가 완전히 삭제될 때까지 대기 (최대 60초)
    echo "⏳ PVC 삭제 완료 대기 중..."
    for i in $(seq 1 60); do
        PVC_COUNT=$(kubectl get pvc -n $NAMESPACE --no-headers 2>/dev/null | wc -l)
        [ "$PVC_COUNT" -eq 0 ] && break
        sleep 1
    done
    echo "🗑️  PV 삭제 중..."
    kubectl delete pv -l app.kubernetes.io/instance=$RELEASE_NAME --ignore-not-found=true
    kubectl get pv | grep $NAMESPACE | awk '{print $1}' | xargs -r kubectl delete pv
fi

echo ""
echo "✅ Monitoring 삭제 완료."
