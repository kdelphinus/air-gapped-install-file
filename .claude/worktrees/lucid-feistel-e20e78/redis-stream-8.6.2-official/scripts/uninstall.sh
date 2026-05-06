#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="redis-stream-official"
RELEASE_NAME="redis-stream-official"

echo "======================================================"
echo " Redis Stream (공식 이미지 - Helm) 삭제"
echo " Namespace: ${NAMESPACE}"
echo " Release:   ${RELEASE_NAME}"
echo "======================================================"
echo ""
echo "[경고] StatefulSet, Service, ConfigMap, Secret이 삭제됩니다."
echo "       PV는 Retain policy로 보존됩니다."
echo ""
read -p "계속하려면 'yes' 를 입력하세요: " CONFIRM
if [ "${CONFIRM}" != "yes" ]; then
    echo "취소되었습니다."
    exit 0
fi

# Helm Uninstall
echo "Helm Release 삭제 중..."
helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" || true

# PVC 삭제 전 PV 상태 확인
echo ""
echo "PV 목록 (Retain policy로 데이터 보존됨):"
kubectl get pv | grep redis-official || true

echo ""
read -p "PVC도 삭제하시겠습니까? (PV는 Retain 유지) [y/N]: " DELETE_PVC
if [ "${DELETE_PVC}" = "y" ] || [ "${DELETE_PVC}" = "Y" ]; then
    # volumeClaimTemplate 이름 "redis-data" + StatefulSet 이름 기반으로 동적 탐색
    PVCLIST=$(kubectl get pvc -n "${NAMESPACE}" --no-headers \
        -o custom-columns=":metadata.name" 2>/dev/null | grep "^redis-data-" || true)
    if [ -n "${PVCLIST}" ]; then
        echo "${PVCLIST}" | xargs kubectl delete pvc -n "${NAMESPACE}" --ignore-not-found
        echo "PVC 삭제 완료. PV는 Released 상태로 데이터 보존됨."
    else
        echo "삭제할 PVC가 없습니다."
    fi
fi

read -p "Namespace도 삭제하시겠습니까? [y/N]: " DELETE_NS
if [ "${DELETE_NS}" = "y" ] || [ "${DELETE_NS}" = "Y" ]; then
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found
fi

echo ""
echo "삭제 완료."
