#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="gitlab-omnibus"
RELEASE_NAME="gitlab-omnibus"
PV_FILE="./manifests/gitlab-omnibus-pv-temp.yaml"
HTTPROUTE_FILE="./manifests/gitlab-omnibus-httproute-temp.yaml"
CONF_FILE="./install.conf"

# install.conf에서 HOSTPATH_DIR / STORAGE_TYPE 같은 정보 가져오기
[ -f "$CONF_FILE" ] && source "$CONF_FILE"

echo "========================================================"
echo "🗑️  GitLab Omnibus 제거"
echo "========================================================"
[ -n "${STORAGE_TYPE}" ] && echo "  - 스토리지 타입: ${STORAGE_TYPE}"
[ "${STORAGE_TYPE}" = "hostpath" ] && [ -n "${HOSTPATH_DIR}" ] && echo "  - HostPath: ${HOSTPATH_DIR}"
echo ""

read -p "정말 GitLab Omnibus를 제거하시겠습니까? (y/N): " CONFIRM
CONFIRM="${CONFIRM:-N}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "❌ 제거가 취소되었습니다."
    exit 0
fi

DELETE_DATA="N"
if [ "${STORAGE_TYPE}" = "hostpath" ] && [ -n "${HOSTPATH_DIR}" ] && [ -d "${HOSTPATH_DIR}" ]; then
    read -p "⚠️  HostPath 데이터(${HOSTPATH_DIR})도 모두 삭제할까요? (y/N): " DELETE_DATA
    DELETE_DATA="${DELETE_DATA:-N}"
elif [ "${STORAGE_TYPE}" = "dynamic" ]; then
    read -p "⚠️  동적 PVC도 삭제할까요? (y/N, 백엔드 볼륨은 reclaimPolicy 따름): " DELETE_DATA
    DELETE_DATA="${DELETE_DATA:-N}"
fi

DELETE_CONF="N"
if [ -f "$CONF_FILE" ]; then
    read -p "install.conf도 삭제할까요? (y/N): " DELETE_CONF
    DELETE_CONF="${DELETE_CONF:-N}"
fi

echo ""
echo "🔥 제거 진행 중..."

# 1. Helm Release
if helm status "$RELEASE_NAME" -n "$NAMESPACE" > /dev/null 2>&1; then
    echo "  - Helm Release 삭제 중..."
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait=false 2>/dev/null || true
fi

# 2. HTTPRoute (현재 네임스페이스 + 구버전 envoy-gateway-system 양쪽)
echo "  - HTTPRoute 삭제 중..."
kubectl delete httproute -n "$NAMESPACE" gitlab-omnibus --ignore-not-found=true 2>/dev/null || true
kubectl delete httproute -n envoy-gateway-system gitlab-omnibus --ignore-not-found=true 2>/dev/null || true

# 3. 동적 모드 PVC (네임스페이스 삭제 전에 명시적으로)
if [ "${STORAGE_TYPE}" = "dynamic" ] && [[ "$DELETE_DATA" =~ ^[Yy]$ ]]; then
    echo "  - 동적 PVC 삭제 중..."
    kubectl delete pvc -n "$NAMESPACE" "${RELEASE_NAME}-data" "${RELEASE_NAME}-config" --ignore-not-found=true 2>/dev/null || true
fi

# 4. 정적 PV
echo "  - 정적 PV 삭제 중..."
kubectl delete pv gitlab-omnibus-data-pv gitlab-omnibus-config-pv --ignore-not-found=true 2>/dev/null || true

# 5. Namespace
echo "  - Namespace '$NAMESPACE' 삭제 중 (대기)..."
kubectl delete ns "$NAMESPACE" --ignore-not-found=true --wait=false 2>/dev/null || true
kubectl wait --for=delete "namespace/$NAMESPACE" --timeout=120s 2>/dev/null || true

# 6. HostPath 데이터
if [[ "$DELETE_DATA" =~ ^[Yy]$ ]] && [ "${STORAGE_TYPE}" = "hostpath" ] && [ -n "${HOSTPATH_DIR}" ]; then
    if [ -d "${HOSTPATH_DIR}" ]; then
        echo "  - HostPath 데이터 삭제 중: ${HOSTPATH_DIR}"
        sudo rm -rf "${HOSTPATH_DIR:?}"/*
        echo "    ✅ ${HOSTPATH_DIR} 초기화 완료"
    fi
fi

# 7. 임시 매니페스트
rm -f "$PV_FILE" "$HTTPROUTE_FILE" 2>/dev/null || true

# 8. install.conf
if [[ "$DELETE_CONF" =~ ^[Yy]$ ]] && [ -f "$CONF_FILE" ]; then
    rm -f "$CONF_FILE"
    echo "  - install.conf 삭제됨"
fi

echo ""
echo "========================================================"
echo " ✅ GitLab Omnibus 제거 완료"
echo "========================================================"
