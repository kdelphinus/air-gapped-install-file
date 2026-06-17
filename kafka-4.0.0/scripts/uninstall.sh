#!/bin/bash
# ---------------------------------------------------------
# Apache Kafka v4.0.0 (KRaft Mode) Uninstallation Script
# ---------------------------------------------------------
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="kafka"
RELEASE_NAME="kafka"
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
echo -e "🧹 ${YELLOW}[Kafka 삭제] 기존 리소스 제거 시작...${NC}"

# 1. Helm Uninstall
if helm status $RELEASE_NAME -n $NAMESPACE >/dev/null 2>&1; then
    echo "⏳ Helm 차트 삭제 중..."
    helm uninstall $RELEASE_NAME -n $NAMESPACE --wait=false 2>/dev/null
    sleep 3
fi

# 2. PVC 삭제
echo "🗑️  Kafka PVC 삭제 중..."
kubectl delete pvc -n $NAMESPACE -l "app.kubernetes.io/instance=${RELEASE_NAME}" --timeout=10s --wait=false 2>/dev/null

# 3. PV 삭제 (정적 PV들 제거)
echo "🗑️  Kafka 정적 PV 삭제 중..."
kubectl delete pv kafka-pv-0 kafka-pv-1 kafka-pv-2 --timeout=10s --wait=false 2>/dev/null

# 4. 네임스페이스 삭제
if kubectl get ns $NAMESPACE > /dev/null 2>&1; then
    echo "🗑️  네임스페이스($NAMESPACE) 삭제..."
    kubectl delete ns $NAMESPACE --timeout=15s --wait=false 2>/dev/null
fi

if [ "$RESET_MODE" == "reset" ]; then
    rm -f "$CONF_FILE"
    rm -f "./values-temp.yaml"
    echo -e "🗑️  설정 파일 및 임시 파일 삭제 완료 (Reset)."
fi

echo -e "${GREEN}✅ 삭제 완료!${NC}"
echo ""
