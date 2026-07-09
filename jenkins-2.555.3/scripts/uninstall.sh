#!/bin/bash
# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="jenkins"
RELEASE_NAME="jenkins"
CONF_FILE="./install.conf"
NODE_LABEL_KEY="jenkins-node"

# 색상 코드
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

RESET_MODE="uninstall"
if [ "$1" == "--reset" ] || [ "$1" == "reset" ]; then
    RESET_MODE="reset"
fi

echo "==========================================="
echo " Uninstalling Jenkins 2.555.3"
echo "==========================================="

read -p "❓ 정말 삭제하시겠습니까? (y/n): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "취소되었습니다."; exit 0; }

echo ""
read -p "⚠️  PV/PVC도 함께 삭제하시겠습니까? (데이터 영구 삭제, y/n): " DELETE_PV

# 볼륨 보존 시 helm uninstall에 의한 PVC 자동 제거 방지 (keep 어노테이션 주입)
if [[ ! "${DELETE_PV}" =~ ^[Yy]$ ]]; then
    if kubectl get pvc jenkins -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "🛡️  볼륨 보존을 위해 PVC 'jenkins'에 keep resource-policy를 설정합니다..."
        kubectl annotate pvc jenkins -n "$NAMESPACE" "helm.sh/resource-policy=keep" --overwrite 2>/dev/null || true
    fi
fi

# Helm 제거
if helm status $RELEASE_NAME -n $NAMESPACE > /dev/null 2>&1; then
    echo "🗑️  Helm Release '$RELEASE_NAME' 삭제 중..."
    helm uninstall $RELEASE_NAME -n $NAMESPACE
else
    echo "  - 삭제할 Helm Release가 없습니다."
fi

# 노드 라벨 제거 (Reset 모드 시에만 초기화 진행)
if [ "$RESET_MODE" == "reset" ]; then
    echo "🗑️  노드 라벨 '$NODE_LABEL_KEY' 제거 중..."
    kubectl label nodes --all ${NODE_LABEL_KEY}- > /dev/null 2>&1 || true
fi

# PVC 먼저 삭제 (볼륨 삭제 선택 시)
if [[ "${DELETE_PV}" =~ ^[Yy]$ ]]; then
    echo "🗑️  PVC 삭제 중..."
    kubectl delete pvc -n $NAMESPACE jenkins --ignore-not-found=true 2>/dev/null || true
    kubectl delete pvc -n $NAMESPACE gradle-cache-pvc --ignore-not-found=true 2>/dev/null || true
fi

# 네임스페이스 삭제 (볼륨 보존 시 cascade delete 방지를 위해 우회)
if [[ "${DELETE_PV}" =~ ^[Yy]$ ]]; then
    echo "🗑️  Namespace '${NAMESPACE}' 삭제 중..."
    kubectl delete ns $NAMESPACE --ignore-not-found=true --timeout=30s
else
    echo "➡️  볼륨 보존 선택에 따라 Namespace '${NAMESPACE}' 삭제 단계를 생략합니다."
fi

# PV 삭제 (네임스페이스 삭제 후)
if [[ "${DELETE_PV}" =~ ^[Yy]$ ]]; then
    echo "🗑️  PV 삭제 중..."
    kubectl delete pv jenkins-pv gradle-cache-pv --ignore-not-found=true 2>/dev/null || true
fi

# install.conf 및 values-infra.yaml 삭제 (Reset 모드 시에만 초기화 진행)
if [ "$RESET_MODE" == "reset" ]; then
    if [ -f "$CONF_FILE" ]; then
        rm -f "$CONF_FILE"
        echo "🗑️  설정 파일(install.conf) 삭제 완료."
    fi
    if [ -f "./values-infra.yaml" ]; then
        rm -f "./values-infra.yaml"
        echo "🗑️  인프라 설정 파일(values-infra.yaml) 삭제 완료."
    fi
fi

echo ""
echo -e "${GREEN}✅ Jenkins 삭제 완료.${NC}"
echo ""
