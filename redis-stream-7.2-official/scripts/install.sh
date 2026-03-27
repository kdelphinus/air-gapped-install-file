#!/bin/bash
cd "$(dirname "$0")/.." || exit 1
set -e

NAMESPACE="redis-stream-official"
RELEASE_NAME="redis-stream-official"
MANIFEST_DIR="./manifests"

echo "======================================================"
echo " Redis Stream (HA) 설치 - 공식 이미지 (Helm) 방식"
echo " Namespace: ${NAMESPACE}"
echo "======================================================"

# 1. Namespace 생성 (Helm으로도 생성 가능하나 명시적 유지)
echo "1. Namespace 생성 및 확인 중..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# 2. Harbor 레지스트리 IP 입력
echo ""
read -p "Harbor 레지스트리 노드 IP 입력 (예: 192.168.1.10): " REGISTRY_IP
if [ -z "${REGISTRY_IP}" ]; then
    echo "[오류] Harbor 노드 IP가 필요합니다."
    exit 1
fi
IMAGE_REGISTRY="${REGISTRY_IP}:30002"

# 3. Redis 비밀번호 입력
echo ""
read -s -p "Redis 비밀번호 입력: " REDIS_PASSWORD
echo ""
if [ -z "${REDIS_PASSWORD}" ]; then
    echo "[오류] 비밀번호가 비어 있습니다."
    exit 1
fi

# 4. 스토리지 설정 (PV는 Helm 밖에서 정적으로 유지)
echo ""
read -p "Storage Type 선택 (hostpath/nfs) [기본값: hostpath]: " STORAGE_TYPE
STORAGE_TYPE="${STORAGE_TYPE:-hostpath}"

if [ "${STORAGE_TYPE}" = "hostpath" ]; then
    echo "2. HostPath PV 설정 중..."
    NODES=($(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'))
    if [ ${#NODES[@]} -gt 0 ]; then
        echo "   사용 가능한 노드 목록:"
        for i in "${!NODES[@]}"; do echo "     $((i+1))) ${NODES[$i]}"; done
        read -p "   노드 번호 선택 [1-${#NODES[@]}, 기본값: 1]: " NODE_INDEX
        NODE_INDEX="${NODE_INDEX:-1}"
        NODE_NAME="${NODES[$((NODE_INDEX-1))]}"
    else
        NODE_NAME=$(hostname)
    fi
    read -p "   HostPath 기본 경로 [기본값: /data/redis-official]: " HOST_BASE_PATH
    HOST_BASE_PATH="${HOST_BASE_PATH:-/data/redis-official}"
    read -p "   PV 크기 [기본값: 10Gi]: " STORAGE_SIZE
    STORAGE_SIZE="${STORAGE_SIZE:-10Gi}"

    echo "   노드: ${NODE_NAME}, 경로: ${HOST_BASE_PATH}"
    echo ""
    echo "   [주의] 노드(${NODE_NAME})에서 다음 명령을 미리 실행하세요:"
    echo "     mkdir -p ${HOST_BASE_PATH}/{node-0,node-1,node-2}"
    echo "     chmod 777 ${HOST_BASE_PATH}/{node-0,node-1,node-2}"
    echo ""
    read -p "   디렉토리 생성을 완료했으면 Enter를 눌러 계속..."

    sed -e "s|__NODE_NAME__|${NODE_NAME}|g" \
        -e "s|__BASE_PATH__|${HOST_BASE_PATH}|g" \
        -e "s|__STORAGE_SIZE__|${STORAGE_SIZE}|g" \
        "${MANIFEST_DIR}/10-pv-hostpath.yaml" | kubectl apply -f -

elif [ "${STORAGE_TYPE}" = "nfs" ]; then
    echo "2. NFS PV 설정 중..."
    read -p "   NFS 서버 IP: " NFS_SERVER
    if [ -z "${NFS_SERVER}" ]; then
        echo "[오류] NFS 서버 IP가 필요합니다."
        exit 1
    fi
    read -p "   NFS 기본 경로 [기본값: /nfs/redis-official]: " NFS_BASE_PATH
    NFS_BASE_PATH="${NFS_BASE_PATH:-/nfs/redis-official}"
    read -p "   PV 크기 [기본값: 10Gi]: " STORAGE_SIZE
    STORAGE_SIZE="${STORAGE_SIZE:-10Gi}"

    echo ""
    echo "   [주의] NFS 서버(${NFS_SERVER})에서 다음 명령을 미리 실행하세요:"
    echo "     mkdir -p ${NFS_BASE_PATH}/{node-0,node-1,node-2}"
    echo "     chmod 777 ${NFS_BASE_PATH}/{node-0,node-1,node-2}"
    echo ""
    read -p "   디렉토리 생성을 완료했으면 Enter를 눌러 계속..."

    sed -e "s|__NFS_SERVER__|${NFS_SERVER}|g" \
        -e "s|__NFS_BASE_PATH__|${NFS_BASE_PATH}|g" \
        -e "s|__STORAGE_SIZE__|${STORAGE_SIZE}|g" \
        "${MANIFEST_DIR}/10-pv-nfs.yaml" | kubectl apply -f -
else
    echo "[오류] 알 수 없는 Storage Type: ${STORAGE_TYPE}"
    exit 1
fi

# 3. Helm 배포
echo ""
echo "3. Helm Chart 배포 중..."

helm upgrade --install ${RELEASE_NAME} charts/redis-sentinel \
    --namespace ${NAMESPACE} \
    -f values.yaml \
    --set global.imageRegistry="${IMAGE_REGISTRY}" \
    --set redis.password="${REDIS_PASSWORD}" \
    --set storage.type="${STORAGE_TYPE}" \
    --set storage.size="${STORAGE_SIZE}" \
    --wait --timeout 300s

# 4. 최종 상태 확인
echo ""
echo "======================================================"
echo " 배포 완료 - 현재 Pod 상태"
echo "======================================================"
kubectl get pods -n "${NAMESPACE}"

echo ""
echo "접속 정보:"
echo "  Redis:    redis.${NAMESPACE}.svc.cluster.local:6379"
echo "  Sentinel: redis-sentinel.${NAMESPACE}.svc.cluster.local:26379"
echo ""
echo "연결 테스트:"
echo "  kubectl exec -it redis-node-0 -n ${NAMESPACE} -- \\"
echo "    redis-cli -a <password> --no-auth-warning INFO replication"
