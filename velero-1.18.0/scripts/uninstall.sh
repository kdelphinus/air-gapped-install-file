#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="velero"
RELEASE_NAME="velero"
CONF_FILE="./install.conf"

# install.conf 에서 스토리지 경로 정보 로드
[ -f "$CONF_FILE" ] && source "$CONF_FILE"

echo "==========================================="
echo " Uninstalling Velero & MinIO 1.18.0"
echo "==========================================="
read -p "❓ Velero & MinIO를 삭제하시겠습니까? (y/n): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "취소되었습니다."; exit 0; }

read -p "⚠️  MinIO 백업 데이터(PVC/PV)도 함께 삭제하시겠습니까? (y=삭제, n=서비스만 제거): " DELETE_DATA

# 1. Velero Helm 삭제
if helm status $RELEASE_NAME -n $NAMESPACE > /dev/null 2>&1; then
    echo "📦 Helm Release '$RELEASE_NAME' 삭제 중..."
    helm uninstall $RELEASE_NAME -n $NAMESPACE --wait=false
else
    echo "  - 삭제할 Velero Helm Release가 없습니다."
fi

# 2. MinIO Deployment/Job 삭제 및 Pod 종료 대기
#    (kubernetes.io/pvc-protection finalizer는 Pod가 완전히 사라져야 해제됨)
echo "📦 MinIO Pod 종료 대기 중..."
kubectl delete deployment minio -n $NAMESPACE --ignore-not-found=true
kubectl delete job minio-setup -n $NAMESPACE --ignore-not-found=true
kubectl wait --for=delete pod -l app=minio -n $NAMESPACE --timeout=60s 2>/dev/null || true

# 3. PVC/PV 삭제 — Pod 종료 후 안전하게 삭제
if [[ "$DELETE_DATA" =~ ^[Yy]$ ]]; then
    PV_NAME=$(kubectl get pvc minio-pvc -n $NAMESPACE \
        -o jsonpath='{.spec.volumeName}' 2>/dev/null)
    echo "📦 MinIO PVC 삭제 중..."
    kubectl delete pvc minio-pvc -n $NAMESPACE --ignore-not-found=true
    if [ -n "$PV_NAME" ]; then
        echo "📦 MinIO PV ($PV_NAME) 삭제 중..."
        kubectl delete pv "$PV_NAME" --ignore-not-found=true
    fi
fi

# 4. Secret 삭제
echo "🔐 관련 Secrets 삭제 중..."
kubectl delete secret velero-s3-credentials -n $NAMESPACE --ignore-not-found=true

# 5. 네임스페이스 삭제
echo "📂 Namespace '$NAMESPACE' 삭제 중..."
kubectl delete ns $NAMESPACE --ignore-not-found=true --timeout=60s

# 6. install.conf 삭제 여부 확인
if [ -f "$CONF_FILE" ]; then
    read -p "🗑️  install.conf(저장된 설정)도 삭제하시겠습니까? (y/n): " DEL_CONF
    if [[ "$DEL_CONF" =~ ^[Yy]$ ]]; then
        rm -f "$CONF_FILE"
        echo "  - install.conf 삭제됨"
    else
        echo "  - install.conf 유지됨 (다음 설치 시 재사용됩니다)"
    fi
fi

if [[ "$DELETE_DATA" =~ ^[Yy]$ ]]; then
    echo ""
    echo "  ⚠️  호스트/NFS 볼륨의 실제 데이터는 수동으로 삭제하세요."
    if [ "${STORAGE_TYPE}" = "hostpath" ] && [ -n "${HOSTPATH_DIR}" ]; then
        echo "       HostPath 경로: ${HOSTPATH_DIR}"
    elif [ "${STORAGE_TYPE}" = "nfs" ] && [ -n "${NFS_SERVER}" ]; then
        echo "       NFS 경로: ${NFS_SERVER}:${NFS_PATH}"
    elif [ -n "$PV_NAME" ]; then
        echo "       경로 확인: kubectl describe pv $PV_NAME"
    fi
fi

echo ""
echo "✅ Velero 및 MinIO 삭제가 완료되었습니다."
