#!/bin/bash
# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1
set -e

# =================================================================
# --- 설정 변수 (사용자 환경에 맞게 이 부분을 수정하세요) ---
# =================================================================

NAMESPACE="nginx-ingress"
RELEASE_NAME="nginx-ingress"
HELM_CHART_PATH="./charts/nginx-ingress-5.3.1"
# 로컬 차트 경로 사용 시 --version 플래그는 Helm이 무시함 (참고용)
# Chart version: 2.4.1 / App version: 5.3.1

# =================================================================
# --- 메인 스크립트 로직 ---
# =================================================================

check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "오류: '$1' 명령어를 찾을 수 없습니다."
        exit 1
    fi
}

echo "========================================================================"
echo " F5 NGINX Ingress Controller v5.3.1 폐쇄망 설치"
echo "========================================================================"

# 1. 도구 및 차트 파일 확인
check_command kubectl
check_command helm

if [ ! -d "$HELM_CHART_PATH" ]; then
    echo "오류: Helm 차트 디렉토리 '$HELM_CHART_PATH'을 찾을 수 없습니다."
    echo "  → charts/nginx-ingress-5.3.1/ 디렉토리를 먼저 준비하세요."
    echo "    (git clone https://github.com/nginx/kubernetes-ingress.git 후"
    echo "     git checkout v5.3.1, 이후 deployments/helm-chart/ 를"
    echo "     charts/nginx-ingress-5.3.1/ 로 복사)"
    exit 1
fi

# 2. 기존 릴리스 확인 및 처리
if helm status "$RELEASE_NAME" -n "$NAMESPACE" &>/dev/null; then
    echo "기존 릴리스 '$RELEASE_NAME'이 감지되었습니다."
    read -p "삭제 후 재설치하시겠습니까? (y/N): " DELETE_EXISTING
    if [[ "$DELETE_EXISTING" =~ ^[yY]([eE][sS])?$ ]]; then
        echo "기존 Helm 릴리스 삭제 중..."
        helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" || true
        sleep 5
    else
        echo "설치를 중단합니다."
        exit 1
    fi
fi

# 3. CRD 적용 (Helm 차트에 crds/ 없음 — 차트 외부에서 선적용 필요)
echo "CRD 적용 중 (manifests/)..."
kubectl apply -k ./manifests/

# 4. 네임스페이스 생성
echo "네임스페이스 '$NAMESPACE' 생성 중..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 5. Helm 설치
echo "Helm으로 F5 NIC를 배포합니다..."
helm upgrade --install "$RELEASE_NAME" "$HELM_CHART_PATH" \
    --namespace "$NAMESPACE" \
    --atomic \
    --wait \
    -f ./values.yaml

# 6. 설치 확인
echo ""
echo "========================================================================"
echo " F5 NGINX Ingress Controller 설치 완료"
echo "========================================================================"
sleep 3

kubectl get pods -n "$NAMESPACE"
echo ""
kubectl get svc -n "$NAMESPACE"
echo ""
echo "HTTP  진입점: http://<NODE_IP>:30080"
echo "HTTPS 진입점: https://<NODE_IP>:30443"
echo "========================================================================"
