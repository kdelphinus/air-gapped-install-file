#!/bin/bash
# Falco 8.0.1 폐쇄망 설치 스크립트
# 작성: Gemini CLI

# 0. 설정
COMPONENT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHART_PATH="$COMPONENT_ROOT/charts/falco"
VALUES_FILE="$COMPONENT_ROOT/values.yaml"
NAMESPACE="falco"

echo "[Phase 2] Falco 8.0.1 설치를 시작합니다..."

# 1. 사전 점검
if [ ! -d "$CHART_PATH" ]; then echo "ERROR: Chart ($CHART_PATH) 가 없습니다. Phase 1을 먼저 진행하세요."; exit 1; fi
if [ ! -f "$VALUES_FILE" ]; then echo "ERROR: Values ($VALUES_FILE) 파일이 없습니다."; exit 1; fi

# 2. 소켓 자동 감지 (K3s 체크)
CONTAINERD_SOCKET="/run/containerd/containerd.sock"
if [ -S "/run/k3s/containerd/containerd.sock" ]; then
    echo "[INFO] K3s 소켓이 감지되었습니다. 경로를 변경합니다."
    CONTAINERD_SOCKET="/run/k3s/containerd/containerd.sock"
fi

# 3. 네임스페이스 생성
kubectl create namespace $NAMESPACE 2>/dev/null || echo "Namespace $NAMESPACE already exists."

# 4. 노이즈 억제 룰 적용 여부 선택
SUPPRESS_VALUES=""
SUPPRESS_FILE="$COMPONENT_ROOT/values-suppress-noise.yaml"
if [ -f "$SUPPRESS_FILE" ]; then
    echo ""
    echo "=== 노이즈 억제 룰 ==="
    echo "GitLab Shell 등 알려진 정상 동작이 Falco 룰에 걸려 대시보드에 노이즈가 발생할 수 있습니다."
    echo "values-suppress-noise.yaml 에 정의된 억제 룰을 함께 적용하시겠습니까?"
    read -r -p "[y/N]: " apply_suppress
    if [[ "$apply_suppress" =~ ^[Yy]$ ]]; then
        SUPPRESS_VALUES="--values $SUPPRESS_FILE"
        echo "[INFO] 노이즈 억제 룰을 적용합니다."
    else
        echo "[INFO] 노이즈 억제 룰을 건너뜁니다."
    fi
    echo ""
fi

# 5. Helm 설치
echo "5. Helm Upgrade/Install 실행..."
# shellcheck disable=SC2086
helm upgrade --install falco "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  --values "$VALUES_FILE" \
  --set collectors.containerd.socket="$CONTAINERD_SOCKET" \
  $SUPPRESS_VALUES \
  --wait --timeout 5m

if [ $? -eq 0 ]; then
    echo "[OK] Falco 설치 성공."
    echo "  - 확인: kubectl get pods -n $NAMESPACE"
    echo "  - 로그: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=falco -f"
else
    echo "[ERROR] Falco 설치 실패."
    exit 1
fi
