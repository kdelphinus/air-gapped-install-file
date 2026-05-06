#!/bin/bash
# Tetragon 1.6.0 폐쇄망 설치 스크립트
# 작성: Gemini CLI

# 0. 설정
COMPONENT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHART_PATH="$COMPONENT_ROOT/charts/tetragon"
VALUES_FILE="$COMPONENT_ROOT/values-local.yaml"
NAMESPACE="kube-system"

echo "[Phase 2] Tetragon 1.6.0 설치를 시작합니다..."

# 1. 사전 점검
if [ ! -d "$CHART_PATH" ]; then echo "ERROR: Chart ($CHART_PATH) 가 없습니다. Phase 1을 먼저 진행하세요."; exit 1; fi
if [ ! -f "$VALUES_FILE" ]; then echo "ERROR: Values ($VALUES_FILE) 파일이 없습니다."; exit 1; fi

# 2. Helm 설치
echo "2. Helm Upgrade/Install 실행 (Namespace: $NAMESPACE)..."
helm upgrade --install tetragon "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  --values "$VALUES_FILE" \
  --wait --timeout 5m

if [ $? -eq 0 ]; then
    echo "[OK] Tetragon 설치 성공."
    echo "  - 확인: kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=tetragon"
    echo "  - 로그: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=tetragon -f"
    
    # 정책 적용 여부 확인
    read -p "민감 파일 읽기 차단 정책(TracingPolicy)을 지금 적용하시겠습니까? (y/n): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        kubectl apply -f "$COMPONENT_ROOT/manifests/block-sensitive-read.yaml"
        echo "[OK] TracingPolicy 적용 완료."
    fi
else
    echo "[ERROR] Tetragon 설치 실패."
    exit 1
fi
