#!/bin/bash
# Falco 감지 테스트 스크립트
# 상주 파드에 exec하여 시나리오 A/B/C를 순서대로 실행합니다.

cd "$(dirname "$0")/.." || exit 1

POD_NAME="falco-test-pod"
NAMESPACE="default"

echo "=== Falco 감지 테스트 시작 ==="
echo ""

# 테스트 파드 준비
echo "[준비] 테스트 파드 기동..."
kubectl apply -f manifests/test-pod.yaml
kubectl wait --for=condition=Ready pod/$POD_NAME -n $NAMESPACE --timeout=60s
echo ""

echo "Falco 로그는 별도 터미널에서 확인하세요:"
echo "  kubectl logs -n falco -l app.kubernetes.io/name=falco -f | grep -v STDOUT"
echo ""
read -p "준비되면 Enter를 눌러 테스트를 시작합니다..."
echo ""

# 시나리오 A: TTY 셸 접근
echo "[A] 컨테이너 내 셸 접근 → 예상: 'Terminal shell in container'"
kubectl exec -it $POD_NAME -n $NAMESPACE -- /bin/bash -c "echo '[A] shell triggered'; exit"
echo ""
sleep 2

# 시나리오 B: 민감 파일 접근
echo "[B] /etc/shadow 읽기 → 예상: 'Read sensitive file untrusted'"
kubectl exec $POD_NAME -n $NAMESPACE -- sh -c "cat /etc/shadow 2>/dev/null && echo '[B] read done' || echo '[B] file not found'"
echo ""
sleep 2

# 시나리오 C: 패키지 설치 시도
echo "[C] apt-get 실행 → 예상: 'Launch Package Management Process in Container'"
kubectl exec $POD_NAME -n $NAMESPACE -- bash -c "apt-get update -qq 2>&1 | tail -3; echo '[C] apt done'"
echo ""
sleep 2

echo "=== 테스트 완료 ==="
echo ""
echo "Falco 감지 결과 확인:"
echo "  kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=200 | grep -E 'Terminal shell|sensitive|Package Management'"
echo ""
read -p "테스트 파드를 삭제할까요? (y/n): " choice
if [[ "$choice" =~ ^[Yy]$ ]]; then
    kubectl delete pod $POD_NAME -n $NAMESPACE
    echo "테스트 파드 삭제 완료."
fi
