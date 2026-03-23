#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

# ==========================================================
# [사용자 설정] 설치 전 Harbor(NODE) IP와 Project명을 입력하세요.
# ==========================================================
HARBOR_IP="<실제_HARBOR_IP>" 
HARBOR_PROJECT="library"
# ==========================================================

NAMESPACE="velero"
RELEASE_NAME="velero"
CHART_PATH="./charts/velero"
VALUES_FILE="./values.yaml"

# IP 설정 확인
if [[ "$HARBOR_IP" == "<실제_HARBOR_IP>" ]]; then
    echo "❌ 에러: scripts/install.sh 파일 상단의 HARBOR_IP 변수를 실제 서버 IP로 수정해주세요."
    exit 1
fi

echo "🔧 Preparing manifests and values with Harbor IP: $HARBOR_IP, Project: $HARBOR_PROJECT..."
sed -e "s/<NODE_IP>/$HARBOR_IP/g" -e "s/<PROJECT>/$HARBOR_PROJECT/g" manifests/minio.yaml > manifests/minio-temp.yaml
sed -e "s/<NODE_IP>/$HARBOR_IP/g" -e "s/<PROJECT>/$HARBOR_PROJECT/g" "$VALUES_FILE" > ./values-temp.yaml

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
