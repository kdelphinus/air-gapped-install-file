#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="redis-stream-official"
RELEASE_NAME="redis-stream-official"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}======================================================"
echo -e " Redis Stream 기능 테스트 (공식 이미지 방식)"
echo -e "======================================================${NC}"

# 비밀번호 추출
echo -n "Redis 비밀번호를 Secret에서 추출 중... "
REAL_PASSWORD=$(kubectl get secret redis-secret -n "${NAMESPACE}" \
    -o jsonpath="{.data.redis-password}" | base64 -d)
if [ -z "${REAL_PASSWORD}" ]; then
    echo -e "${RED}[실패] 비밀번호를 가져올 수 없습니다.${NC}"
    exit 1
fi
echo -e "${GREEN}[완료]${NC}"

# 이미지 경로
read -p "Harbor 레지스트리 노드 IP 입력 (예: 192.168.1.10): " REGISTRY_IP
if [ -z "${REGISTRY_IP}" ]; then
    echo -e "${RED}[오류] 레지스트리 IP가 필요합니다.${NC}"
    exit 1
fi
TEST_IMAGE="${REGISTRY_IP}:30002/library/redis:8.6.2-alpine3.23"

# 테스트용 Pod 생성 (--rm/-i 제거, 마지막에 명시적 삭제)
echo "테스트 Pod 생성 중..."
kubectl run redis-official-test \
    --image="${TEST_IMAGE}" \
    --restart=Never \
    -n "${NAMESPACE}" \
    --command -- sleep 600

kubectl wait pod/redis-official-test -n "${NAMESPACE}" \
    --for=condition=Ready --timeout=60s

# 실행 함수
function redis_exec() {
    kubectl exec -i redis-official-test -n "${NAMESPACE}" -- \
        redis-cli -h redis-node-0.redis-headless.${NAMESPACE}.svc.cluster.local \
        -a "${REAL_PASSWORD}" --no-auth-warning "$@" 2>/dev/null
}

function sentinel_exec() {
    kubectl exec -i redis-official-test -n "${NAMESPACE}" -- \
        redis-cli -h redis-sentinel-0.redis-sentinel-headless.${NAMESPACE}.svc.cluster.local \
        -p 26379 --no-auth-warning "$@" 2>/dev/null
}

# 1. 클러스터 상태 확인
echo ""
echo -e "${CYAN}[1] Sentinel 상태 확인${NC}"
sentinel_exec SENTINEL masters

echo ""
echo -e "${CYAN}[2] Master Replication 정보${NC}"
redis_exec INFO replication | grep -E "role:|connected_slaves:|slave[0-9]+"

# 2. Stream 기능 테스트
echo ""
echo -e "${CYAN}[3] Redis Stream 쓰기/읽기 테스트${NC}"
TEST_STREAM="test-stream-official"
redis_exec DEL "${TEST_STREAM}" > /dev/null

for i in 1 2 3; do
    ID=$(redis_exec XADD "${TEST_STREAM}" '*' msg "message-${i}" idx "${i}")
    echo -e "   XADD: ${ID}"
done

COUNT=$(redis_exec XLEN "${TEST_STREAM}")
echo -e "   XLEN: ${COUNT} (예상: 3)"
if [ "${COUNT}" = "3" ]; then
    echo -e "   ${GREEN}[통과]${NC}"
else
    echo -e "   ${RED}[실패]${NC}"
fi

# 3. Failover 테스트
echo ""
echo -e "${CYAN}[4] Sentinel Failover 테스트${NC}"
echo "   현재 Master:"
CURRENT_MASTER=$(sentinel_exec SENTINEL get-master-addr-by-name mymaster | head -1)
echo "   ${CURRENT_MASTER}"
echo ""
echo "   [참고] Failover 테스트는 아래 명령으로 수행:"
echo "   kubectl delete pod redis-node-0 -n ${NAMESPACE}"
echo "   이후 sentinel_exec SENTINEL masters 로 새 master 확인"

# 정리
kubectl delete pod redis-official-test -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true

echo ""
echo -e "${GREEN}테스트 완료.${NC}"
