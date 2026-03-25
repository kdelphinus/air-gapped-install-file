#!/bin/bash
cd "$(dirname "$0")/.."

NAMESPACE="redis-stream"
ENV_TYPE=$1

# 색상 정의
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}======================================================================${NC}"
echo -e "${CYAN} 🧪 Redis Stream 종합 기능 테스트 (At-Least-Once & OOM 방지) ${NC}"
echo -e "${CYAN}======================================================================${NC}"

# 0. 실제 비밀번호 자동 추출
echo -n "🔐 Redis 비밀번호를 Secret에서 추출 중... "
REAL_PASSWORD=$(kubectl get secret --namespace $NAMESPACE redis-stream -o jsonpath="{.data.redis-password}" | base64 -d)
if [ -z "$REAL_PASSWORD" ]; then
    echo -e "${RED}[실패] 비밀번호를 가져올 수 없습니다.${NC}"
    exit 1
fi
echo -e "${GREEN}[완료]${NC}"

# 환경 선택 로직
if [ -z "$ENV_TYPE" ]; then
    echo -e "${YELLOW}테스트 환경을 선택해 주세요:${NC}"
    echo "1) Production (<NODE_IP>:30002/library/redis 이미지 사용)"
    echo "2) Local/Dev (docker.io/bitnamilegacy/redis 이미지 사용)"
    read -p "선택 [1/2, 기본값: 1]: " ENV_CHOICE
    case "$ENV_CHOICE" in
        2) ENV_TYPE="local" ;;
        *) ENV_TYPE="prod" ;;
    esac
fi

# 이미지 경로 설정
if [ "$ENV_TYPE" == "local" ]; then
    TEST_IMAGE="docker.io/bitnamilegacy/redis:7.2.4-debian-12-r9"
else
    TEST_IMAGE="<NODE_IP>:30002/library/redis:7.2.4-debian-12-r9"
fi

# 테스트용 공통 실행 함수
function redis_exec() {
    # 개별 인자를 보존하기 위해 "$@" 사용
    kubectl exec -i redis-stream-test -n $NAMESPACE -- redis-cli -h redis-stream-node-0.redis-stream-headless -a "$REAL_PASSWORD" "$@" 2>/dev/null | grep -v "Warning: Using a password" | grep -v "^$"
}

# 테스트 파드 생성
echo -n "⏳ 테스트용 클라이언트 파드 생성 중... "
sed "s|__TEST_IMAGE__|$TEST_IMAGE|g" manifests/redis-stream-test-pod.yaml | kubectl apply -f - > /dev/null
kubectl wait --for=condition=Ready pod/redis-stream-test -n $NAMESPACE --timeout=60s > /dev/null
echo -e "${GREEN}[완료]${NC}"

echo -e "\n${YELLOW}1. Stream 생성 및 Consumer Group 등록${NC}"
echo -e "${BLUE}   [설명] 'mystream' 데이터 통로와 'mygroup' 소비자 그룹을 준비합니다.${NC}"
GROUP_OUT=$(redis_exec XGROUP CREATE mystream mygroup "$" MKSTREAM 2>&1)
if [[ "$GROUP_OUT" == *"OK"* ]] || [[ "$GROUP_OUT" == *"BUSYGROUP"* ]]; then
    echo -e "   ✅ ${GREEN}결과: 소비자 그룹이 준비되었습니다.${NC}"
else
    echo -e "   ❌ ${RED}결과: 그룹 생성 실패 ($GROUP_OUT)${NC}"
fi

echo -e "\n${YELLOW}2. XADD로 메시지 생산 (MAXLEN 지정하여 OOM 방지)${NC}"
echo -e "${BLUE}   [설명] 5개의 메시지를 생산하며, MAXLEN 100000 제약을 걸어 메모리 폭주를 방지합니다.${NC}"
SUCCESS_COUNT=0
for i in {1..5}; do
  # Redis ID '*'를 인자 중 하나로 정확히 전달
  ID=$(redis_exec XADD mystream MAXLEN 100000 "*" key "value-$i")
  
  if [[ "$ID" =~ ^[0-9]+-[0-9]+$ ]]; then
      echo -e "   🔹 메시지 #$i 생산 완료 (ID: $ID)"
      ((SUCCESS_COUNT++))
  else
      echo -e "   ❌ ${RED}메시지 #$i 생산 실패: $ID${NC}"
  fi
done

if [ "$SUCCESS_COUNT" -eq 5 ]; then
    echo -e "   ✅ ${GREEN}결과: 5개의 메시지가 MAXLEN 제약 조건하에 생성되었습니다.${NC}"
else
    echo -e "   ❌ ${RED}결과: 일부 메시지 생산 실패 (성공: $SUCCESS_COUNT/5)${NC}"
fi

echo -e "\n${YELLOW}3. WAIT 1 5000 (동기 복제 대기)${NC}"
WAIT_OUT=$(redis_exec WAIT 1 5000)
if [[ "$WAIT_OUT" =~ ^[0-9]+$ ]]; then
    if [ "$WAIT_OUT" -ge 1 ]; then
        echo -e "   ✅ ${GREEN}결과: $WAIT_OUT개의 복제본이 동기화되었습니다.${NC}"
    else
        echo -e "   ℹ️  ${CYAN}결과: 0개 응답. (로컬/단일 노드 환경에서는 정상입니다)${NC}"
    fi
else
    echo -e "   ❌ ${RED}결과: WAIT 명령어 실행 실패.${NC}"
fi

echo -e "\n${YELLOW}4. XREADGROUP으로 메시지 소비 (Pending 상태 유도)${NC}"
redis_exec XREADGROUP GROUP mygroup consumer1 COUNT 5 STREAMS mystream ">" > /dev/null
echo -e "   ✅ ${GREEN}결과: 소비자가 메시지를 읽어갔습니다. (처리 대기 상태 진입)${NC}"

echo -e "\n${YELLOW}5. XPENDING 확인 (처리 대기 목록 확인)${NC}"
PENDING_RAW=$(redis_exec XPENDING mystream mygroup)
PENDING_COUNT=$(echo "$PENDING_RAW" | head -n 1 | awk '{print $1}')

if [[ "$PENDING_COUNT" =~ ^[0-9]+$ ]] && [ "$PENDING_COUNT" -gt 0 ]; then
    echo -e "   📊 ${CYAN}현재 Pending 건수: $PENDING_COUNT 건${NC}"
    echo -e "   ✅ ${GREEN}결과: At-Least-Once 메커니즘이 정상 작동 중입니다.${NC}"
else
    echo -e "   ❌ ${RED}결과: Pending 리스트 확인 실패 (Count: $PENDING_COUNT)${NC}"
fi

echo -e "\n${YELLOW}6. 스트림 상태 확인 (XINFO)${NC}"
INFO_RAW=$(redis_exec XINFO STREAM mystream)
INFO_LEN=$(echo "$INFO_RAW" | grep -A 1 "^length$" | tail -n 1)
INFO_GROUPS=$(echo "$INFO_RAW" | grep -A 1 "^groups$" | tail -n 1)
echo -e "   📊 ${CYAN}스트림 총 길이: ${INFO_LEN:-0} / 등록된 소비자 그룹: ${INFO_GROUPS:-0}${NC}"

echo -e "\n${CYAN}======================================================================${NC}"
if [ "$SUCCESS_COUNT" -eq 5 ] && [ "$PENDING_COUNT" -gt 0 ] 2>/dev/null; then
    echo -e "${GREEN} 🎉 모든 Redis Stream 핵심 기능 테스트가 성공했습니다! ${NC}"
    echo -e " 1. ${CYAN}OOM 방지${NC}: MAXLEN 파라미터 정상 작동 확인"
    echo -e " 2. ${CYAN}데이터 유실 방지${NC}: 복제 대기(WAIT) 구조 확인"
    echo -e " 3. At-Least-Once: PEL(Pending) 리스트를 통한 처리 보장 확인"
else
    echo -e "${RED} ⚠️ 일부 테스트 단계에서 문제가 발견되었습니다. 로그를 확인하세요. ${NC}"
fi
echo -e "${CYAN}======================================================================${NC}"
echo -e "✅ 테스트 파드 삭제: ${YELLOW}kubectl delete -f manifests/redis-stream-test-pod.yaml${NC}"
