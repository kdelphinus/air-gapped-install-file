#!/bin/bash
# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="nginx-ingress"
RELEASE_NAME="nginx-ingress"
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

echo "========================================================================"
echo " F5 NGINX Ingress Controller v5.3.1 삭제"
echo "========================================================================"
read -p "❓ 정말 삭제하시겠습니까? (y/n): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "취소되었습니다."; exit 0; }

# Helm 릴리스 삭제
if helm status "$RELEASE_NAME" -n "$NAMESPACE" > /dev/null 2>&1; then
    echo "🗑️  Helm Release '$RELEASE_NAME' 삭제 중..."
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE"
else
    echo "  - 삭제할 Helm Release가 없습니다."
fi

# 네임스페이스 삭제
if kubectl get ns "$NAMESPACE" > /dev/null 2>&1; then
    echo "🗑️  Namespace '$NAMESPACE' 삭제 중..."
    kubectl delete ns "$NAMESPACE" --ignore-not-found=true --timeout=30s
fi

# CRD 삭제 조치 (오직 Reset 모드이며 다중 승인 시에만 수행)
if [ "$RESET_MODE" == "reset" ]; then
    echo ""
    echo -e "${RED}⚠️  [경고] CRD(Custom Resource Definition) 삭제 경고${NC}"
    echo -e "${YELLOW}NIC CRD를 삭제하면 클러스터 전체에 배포된 타 네임스페이스의 Ingress,${NC}"
    echo -e "${YELLOW}VirtualServer, VirtualServerRoute, Policy 리소스들이 함께 연쇄 삭제됩니다.${NC}"
    echo -e "${YELLOW}이 작업은 현재 기동 중인 모든 서비스의 네트워크 차단 장애를 발생시킵니다.${NC}"
    echo ""
    read -p "❓ 위 장애 위험을 감수하고도 CRD를 영구 삭제하시겠습니까? (y/N): " DELETE_CRD_1
    if [[ "$DELETE_CRD_1" =~ ^[Yy]$ ]]; then
        read -p "❗ 정말로 삭제하시겠습니까? 최종 확인입니다. (y/N): " DELETE_CRD_2
        if [[ "$DELETE_CRD_2" =~ ^[Yy]$ ]]; then
            echo "🗑️  NIC CRD 삭제 중 (manifests/)..."
            kubectl delete -k ./manifests/ --ignore-not-found=true || true
        else
            echo "➡️  CRD 삭제를 건너뜁니다."
        fi
    else
        echo "➡️  CRD 삭제를 건너뜁니다."
    fi

    # 설정 파일 삭제
    if [ -f "$CONF_FILE" ]; then
        rm -f "$CONF_FILE"
        echo "🗑️  설정 파일(install.conf) 삭제 완료."
    fi
    if [ -f "./values-infra.yaml" ]; then
        rm -f "./values-infra.yaml"
        echo "🗑️  인프라 설정 파일(values-infra.yaml) 삭제 완료."
    fi
else
    echo "➡️  일반 삭제 모드입니다. 설정 파일과 CRD를 안전하게 보존합니다."
fi

echo ""
echo -e "${GREEN}✅ NGINX Ingress Controller 삭제 완료!${NC}"
echo "========================================================================"
