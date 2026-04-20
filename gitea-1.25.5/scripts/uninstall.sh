#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="gitea"
RELEASE_NAME="gitea"

echo "==========================================="
echo " Uninstalling Gitea 1.25.5"
echo "==========================================="
read -p "❓ 정말 삭제하시겠습니까? (y/n): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "취소되었습니다."; exit 0; }

echo ""
read -p "⚠️  PV/PVC 도 함께 삭제하시겠습니까? (데이터 영구 삭제, y/n): " DELETE_PV

# Helm 제거
if helm status "${RELEASE_NAME}" -n "${NAMESPACE}" > /dev/null 2>&1; then
    echo "🗑️  Helm Release '${RELEASE_NAME}' 삭제 중..."
    helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}"
else
    echo "  - 삭제할 Helm Release 가 없습니다."
fi

# HTTPRoute 제거
echo "🗑️  HTTPRoute 삭제 중..."
kubectl delete httproute gitea-route -n "${NAMESPACE}" --ignore-not-found=true

# PVC 먼저 삭제 (PV Retain 정책이므로 PVC 먼저)
if [[ "${DELETE_PV}" =~ ^[Yy]$ ]]; then
    echo "🗑️  PVC 삭제 중..."
    kubectl delete pvc gitea-data-pvc -n "${NAMESPACE}" --ignore-not-found=true
fi

# 네임스페이스 삭제
echo "🗑️  Namespace '${NAMESPACE}' 삭제 중..."
kubectl delete ns "${NAMESPACE}" --ignore-not-found=true --timeout=30s

# PV 삭제 (네임스페이스 삭제 후)
if [[ "${DELETE_PV}" =~ ^[Yy]$ ]]; then
    echo "🗑️  PV 삭제 중..."
    kubectl delete pv gitea-data-pv --ignore-not-found=true
    echo "  ⚠️  호스트 데이터 (/data/gitea) 는 수동으로 삭제하세요."
fi

echo ""
echo "✅ Gitea 삭제 완료."
