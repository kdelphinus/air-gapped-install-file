#!/bin/bash
cd "$(dirname "$0")/.."

NAMESPACE="redis-stream"
RELEASE_NAME="redis-stream"

echo "======================================================"
echo " 🚀 Redis Stream (HA) 설치 시작"
echo "======================================================"

kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

read -p "Storage Type 선택 (hostpath/nfs) [기본값: hostpath]: " STORAGE_TYPE
STORAGE_TYPE=${STORAGE_TYPE:-hostpath}

if [ "$STORAGE_TYPE" == "hostpath" ]; then
    echo "📦 HostPath 디렉토리 및 PV 생성 중..."
    ./scripts/setup-host-dirs.sh
    kubectl apply -f manifests/redis-stream-pv.yaml
fi

read -s -p "🔑 Redis 비밀번호 입력: " REDIS_PASSWORD
echo ""

echo "⏳ Helm Chart 설치 중..."
helm upgrade --install $RELEASE_NAME ./charts/redis \
    -n $NAMESPACE \
    -f values.yaml \
    --set auth.password="$REDIS_PASSWORD" \
    --timeout 600s

echo "⌛ Pod들이 준비될 때까지 대기합니다..."
kubectl rollout status statefulset/redis-stream-master -n $NAMESPACE --timeout=300s
kubectl rollout status statefulset/redis-stream-replicas -n $NAMESPACE --timeout=300s

echo "✅ 설치가 완료되었습니다!"
echo "접속 정보: Redis Sentinel - redis-stream.redis-stream.svc:26379"
