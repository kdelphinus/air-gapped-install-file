#!/bin/bash
# ---------------------------------------------------------
# MetalLB v0.16.1 Uninstall Script
# [Target] Rocky Linux / Ubuntu (Online/Offline)
# ---------------------------------------------------------
cd "$(dirname "$0")/.." || exit 1

RELEASE_NAME="metallb"
NAMESPACE="metallb-system"
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
echo " MetalLB 삭제 스크립트"
echo " Namespace: ${NAMESPACE}"
echo " Release:   ${RELEASE_NAME}"
echo " Mode:      ${RESET_MODE}"
echo "======================================================"
echo ""

# ⚠️ 1차 서비스 단절 경고
echo -e "${RED}⚠️  [주의] MetalLB controller/speaker 가 제거되므로"
echo -e "          기존의 모든 LoadBalancer 외부 통신망이 즉시 전면 차단됩니다.${NC}"
echo ""

read -p "❓ 정말 MetalLB 릴리즈를 삭제하시겠습니까? (y/N): " CONFIRM
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
    echo "취소되었습니다."
    exit 0
fi

# 1. Helm Uninstall
if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "🗑️  Helm Release '$RELEASE_NAME' 삭제 중..."
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait=false || true
else
    echo "  - 삭제할 Helm Release가 없습니다."
fi

# 2. Namespace 및 설정 소거 (Reset 시에만)
if [ "${RESET_MODE}" == "reset" ]; then
    echo ""
    echo -e "${RED}⚠️  [주의] 데이터 완전 초기화 모드입니다.${NC}"
    echo -e "          네임스페이스 '${NAMESPACE}'가 통째로 삭제되면서"
    echo -e "          네임스페이스 하위의 IPAddressPool 및 L2Advertisement 도 물리적으로 완전 소거됩니다."
    echo -e "          로컬 설정 백업 파일도 영구히 삭제됩니다.${NC}"
    echo ""

    # 2차 정밀 y/N 프롬프트 데이터 소거 확인
    read -p "❓ 정말 모든 데이터와 설정을 완전히 삭제하시겠습니까? (y/N): " RESET_CONFIRM
    if [[ "${RESET_CONFIRM}" =~ ^[Yy]$ ]]; then
        echo "   - MetalLB Custom Resource Finalizer 일괄 제거 중..."
        for KIND in ipaddresspool l2advertisement bgpadvertisement bgppeer community bfdprofile; do
            kubectl get "$KIND" -n "$NAMESPACE" -o name 2>/dev/null | \
            xargs -r -I {} kubectl patch {} -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        done

        echo "🗑️  Namespace '${NAMESPACE}' 삭제 중..."
        kubectl delete ns "$NAMESPACE" --timeout=30s --wait=false 2>/dev/null || true

        # 설정 파일 삭제
        rm -f "$CONF_FILE" "values-infra.yaml"
        echo "🗑️  설정 파일(install.conf, values-infra.yaml) 삭제 완료."
    else
        echo -e "${YELLOW}[안내] 네임스페이스 및 설정 파일을 보존한 채 작업을 완료합니다.${NC}"
    fi
else
    echo ""
    echo -e "${GREEN}[알림] 일반 삭제 모드로 네임스페이스 및 설정을 안전하게 보존합니다.${NC}"
    echo "       (Namespace '${NAMESPACE}', install.conf, values-infra.yaml 이 유지됨)"
fi

echo ""
echo -e "${GREEN}✅ MetalLB 삭제 완료.${NC}"
echo ""
