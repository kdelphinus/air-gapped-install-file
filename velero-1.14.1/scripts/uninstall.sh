#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="velero"
RELEASE_NAME="velero"

echo "==========================================="
echo " 🗑️ Uninstalling Velero & MinIO 1.14.1"
echo "==========================================="
read -p "❓ 정말 모든 데이터(백업 저장소 포함)를 삭제하시겠습니까? (y/n): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "취소되었습니다."; exit 0; }

# 1. Velero 헬름 삭제
if helm status $RELEASE_NAME -n $NAMESPACE > /dev/null 2>&1; then
    echo "📦 Helm Release '$RELEASE_NAME' 삭제 중..."
    helm uninstall $RELEASE_NAME -n $NAMESPACE
else
    echo "  - 삭제할 Velero Helm Release가 없습니다."
fi

# 2. MinIO 매니페스트 삭제 (PVC, Job 등 포함)
echo "📦 MinIO Resources 삭제 중..."
if [ -f manifests/minio.yaml ]; then
    kubectl delete -f manifests/minio.yaml -n $NAMESPACE --ignore-not-found=true
fi
if [ -f manifests/minio-local.yaml ]; then
    kubectl delete -f manifests/minio-local.yaml -n $NAMESPACE --ignore-not-found=true
fi

# 3. 추가 자원 삭제 (Secret 등)
echo "🔐 관련 Secrets 삭제 중..."
kubectl delete secret velero-s3-credentials -n $NAMESPACE --ignore-not-found=true

# 4. 네임스페이스 삭제 (PVC 데이터 포함 삭제)
echo "📂 Namespace '$NAMESPACE' 삭제 중..."
kubectl delete ns $NAMESPACE --ignore-not-found=true

echo ""
echo "✅ Velero 및 MinIO 삭제가 완료되었습니다."
