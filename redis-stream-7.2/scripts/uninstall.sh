#!/bin/bash
cd "$(dirname "$0")/.."

NAMESPACE="redis-stream"
RELEASE_NAME="redis-stream"

echo "⚠️ $RELEASE_NAME 삭제를 시작합니다."

helm uninstall $RELEASE_NAME -n $NAMESPACE
kubectl delete pvc -l app.kubernetes.io/instance=$RELEASE_NAME -n $NAMESPACE
kubectl delete -f manifests/redis-stream-pv.yaml --ignore-not-found

echo "🗑️ 삭제 완료."
