#!/bin/bash
cd "$(dirname "$0")/.." || exit 1
set -e

NAMESPACE="redis-stream"
RELEASE_NAME="redis-stream"
ENV_TYPE=$1

echo "======================================================"
echo " 🚀 Redis Stream (HA) 설치 시작"
echo "======================================================"

# 환경 선택 로직
if [ -z "$ENV_TYPE" ]; then
    echo "설치 환경을 선택해 주세요:"
    echo "1) Production (values.yaml 사용)"
    echo "2) Local/Dev (values.yaml + values-local.yaml 사용)"
    read -p "선택 [1/2, 기본값: 1]: " ENV_CHOICE
    case "$ENV_CHOICE" in
        2) ENV_TYPE="local" ;;
        *) ENV_TYPE="prod" ;;
    esac
fi

VALUES_FILE_OPT="-f values.yaml"
[ "$ENV_TYPE" == "local" ] && [ -f "values-local.yaml" ] && VALUES_FILE_OPT="$VALUES_FILE_OPT -f values-local.yaml"

kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

read -p "Storage Type 선택 (hostpath/nfs) [기본값: hostpath]: " STORAGE_TYPE
STORAGE_TYPE=${STORAGE_TYPE:-hostpath}

if [ "$STORAGE_TYPE" == "hostpath" ]; then
    echo "📦 HostPath 설정 진행 중..."
    NODES=($(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'))
    if [ ${#NODES[@]} -gt 0 ]; then
        echo "사용 가능한 노드 목록:"
        for i in "${!NODES[@]}"; do echo "  $((i+1))) ${NODES[$i]}"; done
        read -p "노드 번호 선택 [1-${#NODES[@]}, 기본값: 1]: " NODE_INDEX
        NODE_INDEX=${NODE_INDEX:-1}
        NODE_NAME=${NODES[$((NODE_INDEX-1))]}
    else
        NODE_NAME=$(hostname)
    fi
    read -p "HostPath 기본 경로 [기본값: /data/redis-stream]: " HOST_BASE_PATH
    HOST_BASE_PATH="${HOST_BASE_PATH:-/data/redis-stream}"
    ./scripts/setup-host-dirs.sh "$NODE_NAME" "$HOST_BASE_PATH"
    sed -e "s|__NODE_NAME__|${NODE_NAME}|g" \
        -e "s|__BASE_PATH__|${HOST_BASE_PATH}|g" \
        manifests/redis-stream-pv.yaml | kubectl apply -f -
elif [ "$STORAGE_TYPE" == "nfs" ]; then
    echo "📦 NFS 설정 진행 중..."
    read -p "NFS 서버 IP (예: 192.168.1.100): " NFS_SERVER
    if [ -z "$NFS_SERVER" ]; then
        echo "❌ NFS 서버 IP가 필요합니다."
        exit 1
    fi
    read -p "NFS 기본 경로 [기본값: /nfs/redis-stream]: " NFS_BASE_PATH
    NFS_BASE_PATH="${NFS_BASE_PATH:-/nfs/redis-stream}"
    read -p "PV 스토리지 크기 [기본값: 10Gi]: " STORAGE_SIZE
    STORAGE_SIZE="${STORAGE_SIZE:-10Gi}"

    echo ""
    echo "⚠️  NFS 서버(${NFS_SERVER})에 아래 디렉토리가 사전에 생성되어 있어야 합니다."
    echo "   NFS 서버에서 다음 명령을 실행하세요:"
    echo ""
    echo "   sudo mkdir -p ${NFS_BASE_PATH}/{master,replica-0,replica-1}"
    echo "   sudo chmod -R 777 ${NFS_BASE_PATH}"
    echo ""
    read -p "디렉토리 생성을 완료했으면 Enter를 눌러 계속하세요..."

    NFS_PV_FILE=$(mktemp /tmp/redis-stream-nfs-pv.XXXXXX.yaml)
    trap 'rm -f "$NFS_PV_FILE"' EXIT
    cat > "$NFS_PV_FILE" <<EOF
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: redis-stream-master-pv
spec:
  capacity:
    storage: ${STORAGE_SIZE}
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  nfs:
    server: ${NFS_SERVER}
    path: ${NFS_BASE_PATH}/master
  claimRef:
    name: redis-data-redis-stream-master-0
    namespace: ${NAMESPACE}
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: redis-stream-replica-0-pv
spec:
  capacity:
    storage: ${STORAGE_SIZE}
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  nfs:
    server: ${NFS_SERVER}
    path: ${NFS_BASE_PATH}/replica-0
  claimRef:
    name: redis-data-redis-stream-replicas-0
    namespace: ${NAMESPACE}
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: redis-stream-replica-1-pv
spec:
  capacity:
    storage: ${STORAGE_SIZE}
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  nfs:
    server: ${NFS_SERVER}
    path: ${NFS_BASE_PATH}/replica-1
  claimRef:
    name: redis-data-redis-stream-replicas-1
    namespace: ${NAMESPACE}
EOF
    kubectl apply -f "$NFS_PV_FILE"
fi

read -s -p "🔑 Redis 비밀번호 입력: " REDIS_PASSWORD
echo -e "\n"

echo "⏳ Helm Chart 설치 중..."
helm upgrade --install $RELEASE_NAME ./charts/redis \
    -n $NAMESPACE \
    $VALUES_FILE_OPT \
    --set auth.password="$REDIS_PASSWORD" \
    --timeout 600s

echo "⌛ Pod 상태 확인 시작 (최대 5분)..."
MAX_ATTEMPTS=30
ATTEMPT=1
while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    READY_PODS=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/instance=$RELEASE_NAME --no-headers | grep -c "Running" || true)
    TOTAL_PODS=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/instance=$RELEASE_NAME --no-headers | wc -l || true)
    
    echo "   [시도 $ATTEMPT/$MAX_ATTEMPTS] 현재 준비된 Pod: $READY_PODS / $TOTAL_PODS"
    
    # 모든 Pod가 Running이고 Ready이면 종료 (여기서는 간단히 개수로 판단)
    if [ "$READY_PODS" -gt 0 ] && [ "$READY_PODS" == "$TOTAL_PODS" ]; then
        echo "✅ 모든 Pod가 준비되었습니다!"
        break
    fi
    
    # 에러 상태인 Pod가 있는지 확인하여 경고 출력
    ERR_PODS=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/instance=$RELEASE_NAME --no-headers | grep -E "Error|CrashLoopBackOff|ImagePullBackOff" || true)
    if [ -n "$ERR_PODS" ]; then
        echo "⚠️  문제가 발생한 Pod 발견:"
        echo "$ERR_PODS" | sed 's/^/      /'
    fi

    sleep 10
    ATTEMPT=$((ATTEMPT+1))
done

if [ $ATTEMPT -gt $MAX_ATTEMPTS ]; then
    echo "❌ 설치 대기 시간이 초과되었습니다. 'kubectl get pods -n $NAMESPACE'로 상태를 확인하세요."
else
    echo "✅ 설치가 완료되었습니다!"
    echo "접속 정보: Redis Sentinel - redis-stream.redis-stream.svc:26379"
fi
