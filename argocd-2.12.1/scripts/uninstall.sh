#!/bin/bash
# ---------------------------------------------------------
# ArgoCD Uninstall Script
# [Target] Rocky Linux / Ubuntu (Online/Offline)
# ---------------------------------------------------------
cd "$(dirname "$0")/.." || exit 1

RELEASE_NAME="argocd"
NAMESPACE="argocd"
CONF_FILE="./install.conf"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

RESET_MODE="uninstall"
if [ "$1" == "--reset" ] || [ "$1" == "reset" ]; then
    RESET_MODE="reset"
fi

echo "======================================================"
echo " ArgoCD 삭제 스크립트"
echo " Namespace: ${NAMESPACE}"
echo " Release:   ${RELEASE_NAME}"
echo " Mode:      ${RESET_MODE}"
echo "======================================================"
echo ""

# 1차 y/N 삭제 확인
read -p "❓ ArgoCD를 삭제하시겠습니까? (y/n): " CONFIRM
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
    echo "취소되었습니다."
    exit 0
fi

# 1. Helm Uninstall
if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "🗑️  Helm Release '$RELEASE_NAME' 삭제 중..."
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait || true
else
    echo "  - 삭제할 Helm Release가 없습니다."
fi

# 2. NodePort 서비스 삭제
echo "🗑️  NodePort Service 삭제 중..."
kubectl delete svc argocd-server-nodeport -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true

# 3. HTTPRoute 삭제
echo "🗑️  HTTPRoute 삭제 중..."
kubectl delete httproute argocd-route -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true

# 4. 설정 및 네임스페이스 소거 (Reset 시에만)
if [ "${RESET_MODE}" == "reset" ]; then
    echo ""
    echo -e "${RED}⚠️  [주의] 데이터 완전 초기화 모드입니다.${NC}"
    echo "    - 네임스페이스 '${NAMESPACE}'가 통째로 삭제되어 PVC 등의 데이터가 유실됩니다."
    echo "    - 로컬 설정 파일 및 values-infra.yaml 정보가 영구적으로 제거됩니다."
    echo ""

    # 2차 정밀 y/N 프롬프트 데이터 소거 확인
    read -p "❓ 정말 모든 데이터 및 설정을 완전히 삭제하시겠습니까? (y/N): " RESET_CONFIRM
    if [[ "${RESET_CONFIRM}" =~ ^[Yy]$ ]]; then
        # 네임스페이스 삭제
        echo "🗑️  Namespace '${NAMESPACE}' 삭제 중..."
        kubectl delete ns "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true

        # 설정 파일 삭제
        rm -f "$CONF_FILE" "values-infra.yaml"
        echo "🗑️  설정 파일(install.conf, values-infra.yaml) 삭제 완료."
    else
        echo -e "${YELLOW}[안내] 네임스페이스 및 설정 파일을 보존한 채 작업을 완료합니다.${NC}"
    fi
else
    echo ""
    echo -e "${GREEN}[알림] 일반 언인스톨 모드로 데이터와 설정을 안전하게 보존합니다.${NC}"
    echo "       (Namespace '${NAMESPACE}', install.conf, values-infra.yaml 이 유지됨)"
fi

echo ""
echo -e "${GREEN}✅ ArgoCD 삭제 완료.${NC}"
echo ""
