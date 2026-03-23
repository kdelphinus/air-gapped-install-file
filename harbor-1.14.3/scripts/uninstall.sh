#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="harbor"
RELEASE_NAME="harbor"

echo "==========================================="
echo " Uninstalling Harbor 1.14.3"
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

# PVC 제거
echo "🗑️  PVC 삭제 중..."
kubectl delete pvc -n $NAMESPACE --all --ignore-not-found=true

# PV 삭제 여부 (Retain policy — 삭제 시 이미지/데이터 유실)
echo ""
read -p "⚠️  PV도 삭제하시겠습니까? (Harbor 저장 이미지 전체 유실 주의) (y/n): " DELETE_PV
if [[ "$DELETE_PV" =~ ^[Yy]$ ]]; then
    echo "🗑️  PV 삭제 중..."
    kubectl delete pv harbor-pv --ignore-not-found=true
    kubectl get pv | grep $NAMESPACE | awk '{print $1}' | xargs -r kubectl delete pv
fi

# 임시 파일 제거
echo "🗑️  임시 파일 제거 중..."
rm -f ./harbor-hostpath-persistence.yaml ./harbor-generated-values.yaml 2>/dev/null || true

# 네임스페이스 삭제
echo "🗑️  Namespace '$NAMESPACE' 삭제 중..."
kubectl delete ns $NAMESPACE --ignore-not-found=true

echo ""
echo "✅ Harbor 삭제 완료."
echo "   PV 데이터가 남아있는 경우 호스트 경로에서 직접 삭제하세요."
