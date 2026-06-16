#!/bin/bash

# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1


NAMESPACE="jenkins"
CONF_FILE="./install.conf"

# 색상 코드
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

RESET_MODE="uninstall"
if [ "$1" == "--reset" ] || [ "$1" == "reset" ]; then
    RESET_MODE="reset"
fi

echo ""
echo -e "🧹 ${YELLOW}[Jenkins 삭제] 기존 리소스 제거 시작...${NC}"

# Helm Uninstall
if helm status jenkins -n $NAMESPACE >/dev/null 2>&1; then
    echo "⏳ Helm 차트 삭제 중..."
    helm uninstall jenkins -n $NAMESPACE --wait=false 2>/dev/null
    sleep 3
fi

# PVC/PV 삭제
echo "🗑️  Jenkins PVC/PV 삭제 중..."
kubectl delete pvc -n $NAMESPACE jenkins --timeout=10s --wait=false 2>/dev/null
kubectl delete pvc -n $NAMESPACE gradle-cache-pvc --timeout=10s --wait=false 2>/dev/null
kubectl delete pv jenkins-pv gradle-cache-pv --timeout=10s --wait=false 2>/dev/null

# 네임스페이스 삭제
if kubectl get ns $NAMESPACE > /dev/null 2>&1; then
    echo "🗑️  네임스페이스($NAMESPACE) 삭제..."
    kubectl delete ns $NAMESPACE --timeout=15s --wait=false 2>/dev/null
fi

if [ "$RESET_MODE" == "reset" ]; then
    rm -f "$CONF_FILE"
    rm -f "./values-override.yaml"
    cp -f ./values.yaml.orig ./values.yaml 2>/dev/null || true
    echo -e "🗑️  설정 파일 및 백업 복원 완료 (Reset)."
fi

echo -e "${GREEN}✅ 삭제 완료!${NC}"
echo ""
