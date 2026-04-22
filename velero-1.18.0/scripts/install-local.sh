#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

# [Local Mode] 이미지가 클러스터에 미리 로드되어 있거나 public 레지스트리를 사용합니다.
NAMESPACE="velero"
RELEASE_NAME="velero"
CHART_PATH="./charts/velero"
VALUES_FILE="./values-local.yaml"

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

echo "🚀 Installing MinIO (Local mode) for Velero storage..."
kubectl apply -f manifests/minio-local.yaml
kubectl apply -f manifests/minio-httproute.yaml

echo "⏳ Waiting for MinIO to be ready..."
kubectl rollout status deployment/minio -n $NAMESPACE --timeout=120s

echo "🚀 Installing Velero (Local mode) via Helm..."
# values-local.yaml에 정의된 이미지를 그대로 사용합니다.
helm upgrade --install $RELEASE_NAME "$CHART_PATH" \
  --namespace $NAMESPACE \
  -f "$VALUES_FILE" \
  --wait

echo "✅ Velero and MinIO (Local) installation completed successfully!"
