#!/bin/bash
cd "$(dirname "$0")/.."

NAMESPACE="redis-stream"

echo "🧪 Redis Stream At-Least-Once 및 MAXLEN(OOM 방지) 테스트"

read -s -p "🔑 Redis 비밀번호 입력: " REDIS_PASSWORD
echo ""

# 테스트 파드 생성
kubectl apply -f manifests/redis-stream-test-pod.yaml
kubectl wait --for=condition=Ready pod/redis-stream-test -n $NAMESPACE --timeout=60s

echo "1. Stream 생성 및 Consumer Group 등록"
kubectl exec -i redis-stream-test -n $NAMESPACE -- redis-cli -h redis-stream -a "$REDIS_PASSWORD" XGROUP CREATE mystream mygroup $ MKSTREAM

echo "2. XADD로 메시지 생산 (MAXLEN 지정하여 OOM 방지)"
for i in {1..5}; do
  kubectl exec -i redis-stream-test -n $NAMESPACE -- redis-cli -h redis-stream -a "$REDIS_PASSWORD" XADD mystream MAXLEN 100000 '*' key "value-$i"
done

echo "3. WAIT 1 5000 (동기 복제 대기)"
kubectl exec -i redis-stream-test -n $NAMESPACE -- redis-cli -h redis-stream -a "$REDIS_PASSWORD" WAIT 1 5000

echo "4. XREADGROUP으로 소비 (Pending 상태로 만듦)"
kubectl exec -i redis-stream-test -n $NAMESPACE -- redis-cli -h redis-stream -a "$REDIS_PASSWORD" XREADGROUP GROUP mygroup consumer1 COUNT 5 STREAMS mystream ">"

echo "5. XPENDING 확인 (ACK 전)"
kubectl exec -i redis-stream-test -n $NAMESPACE -- redis-cli -h redis-stream -a "$REDIS_PASSWORD" XPENDING mystream mygroup

echo "6. 첫 번째 메시지에 대해 XACK 처리 (ID 직접 입력 필요)"
echo "   (테스트 스크립트에서는 생략하고 XINFO로 상태 확인)"

echo "7. 스트림 상태 확인 (XINFO)"
kubectl exec -i redis-stream-test -n $NAMESPACE -- redis-cli -h redis-stream -a "$REDIS_PASSWORD" XINFO STREAM mystream

echo "✅ 테스트가 끝났습니다. 테스트 파드를 삭제하려면 다음을 실행하세요:"
echo "kubectl delete -f manifests/redis-stream-test-pod.yaml"
