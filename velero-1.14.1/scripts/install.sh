#!/bin/bash

cd "$(dirname "$0")/.." || exit 1

NAMESPACE="velero"
RELEASE_NAME="velero"
CHART_PATH="./charts/velero"
VALUES_FILE="./values.yaml"

# ── 이미지 소스 선택 ──────────────────────────────────────────
echo ""
echo "이미지 소스를 선택하세요:"
echo "  1) Harbor 레지스트리 사용 (사전에 images/upload_images_to_harbor_v3-lite.sh 실행 필요)"
echo "  2) 로컬 tar 직접 import (이미 이미지가 로드된 경우 건너뜀)"
read -p "선택 [1/2, 기본값: 1]: " IMAGE_SOURCE
IMAGE_SOURCE="${IMAGE_SOURCE:-1}"

if [ "${IMAGE_SOURCE}" = "1" ]; then
    read -p "Harbor 레지스트리 주소 (예: 192.168.1.10:30002 또는 harbor.example.com): " HARBOR_IP
    if [ -z "${HARBOR_IP}" ]; then
        echo "[오류] Harbor 레지스트리 주소가 필요합니다."; exit 1
    fi
    read -p "Harbor 프로젝트 (예: library, oss): " HARBOR_PROJECT
    if [ -z "${HARBOR_PROJECT}" ]; then
        echo "[오류] Harbor 프로젝트가 필요합니다."; exit 1
    fi
elif [ "${IMAGE_SOURCE}" = "2" ]; then
    echo "로컬 tar 파일을 containerd(k8s.io)에 import 중..."
    IMPORT_COUNT=0
    for tar_file in ./images/*.tar; do
        [ -e "${tar_file}" ] || continue
        echo "  → $(basename "${tar_file}")"
        sudo ctr -n k8s.io images import "${tar_file}"
        IMPORT_COUNT=$((IMPORT_COUNT + 1))
    done
    [ "${IMPORT_COUNT}" -eq 0 ] && echo "[경고] ./images/ 에 tar 파일이 없습니다."
    echo "  ${IMPORT_COUNT}개 이미지 import 완료"
    HARBOR_IP=""
    HARBOR_PROJECT=""
else
    echo "[오류] 1 또는 2를 선택하세요."; exit 1
fi

if [ "${IMAGE_SOURCE}" = "1" ]; then
    echo "🔧 Preparing manifests and values with Harbor IP: $HARBOR_IP, Project: $HARBOR_PROJECT..."
    sed -e "s/<NODE_IP>/$HARBOR_IP/g" -e "s/<PROJECT>/$HARBOR_PROJECT/g" manifests/minio.yaml > manifests/minio-temp.yaml
    sed -e "s/<NODE_IP>/$HARBOR_IP/g" -e "s/<PROJECT>/$HARBOR_PROJECT/g" "$VALUES_FILE" > ./values-temp.yaml
else
    echo "🔧 로컬 import 모드 — values 파일을 그대로 사용합니다."
    cp manifests/minio.yaml manifests/minio-temp.yaml
    cp "$VALUES_FILE" ./values-temp.yaml
fi

echo "🚀 Creating Velero S3 credentials secret (with Helm ownership)..."
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# [수정] 변수 확장을 방지하기 위해 'EOF'에 싱글 쿼테이션 사용
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: velero-s3-credentials
  namespace: velero
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: velero
    meta.helm.sh/release-namespace: velero
type: Opaque
stringData:
  cloud: |
    [default]
    aws_access_key_id=minioadmin
    aws_secret_access_key=minioadmin
EOF

echo "🚀 Installing MinIO for Velero storage..."
kubectl apply -f manifests/minio-temp.yaml
kubectl apply -f manifests/minio-httproute.yaml

echo "⏳ Waiting for MinIO to be ready..."
kubectl rollout status deployment/minio -n $NAMESPACE --timeout=120s

echo "🚀 Installing Velero via Helm..."
helm upgrade --install $RELEASE_NAME "$CHART_PATH" \
  --namespace $NAMESPACE \
  -f ./values-temp.yaml \
  --wait

# 작업 완료 후 임시 파일 정리
rm manifests/minio-temp.yaml ./values-temp.yaml

echo "✅ Velero and MinIO installation completed successfully!"
