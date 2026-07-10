#!/bin/bash
# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="kube-system"
RELEASE_NAME="tetragon"
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

echo "==========================================="
echo " Uninstalling Tetragon (eBPF Security Engine)"
echo "==========================================="

read -p "❓ 정말 삭제하시겠습니까? (y/n): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "취소되었습니다."; exit 0; }

# 1. Helm 제거
if helm status "$RELEASE_NAME" -n "$NAMESPACE" > /dev/null 2>&1; then
    echo "🗑️  Helm Release '$RELEASE_NAME' 삭제 중..."
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE"
else
    echo "  - 삭제할 Helm Release가 없습니다."
fi

# 2. Reset 모드 시에만 샘플 TracingPolicy 삭제 및 파일 정리
if [ "$RESET_MODE" == "reset" ]; then
    echo ""
    read -p "⚠️  Tetragon 샘플 정책(block-sensitive-read)도 함께 삭제하시겠습니까? (y/n): " DELETE_POLICY
    if [[ "${DELETE_POLICY}" =~ ^[Yy]$ ]]; then
        echo "🗑️  샘플 TracingPolicy (block-sensitive-read) 삭제 중..."
        kubectl delete tracingpolicy block-sensitive-read --ignore-not-found=true 2>/dev/null || true
    fi

    if [ -f "$CONF_FILE" ]; then
        rm -f "$CONF_FILE"
        echo "🗑️  설정 파일(install.conf) 삭제 완료."
    fi
    if [ -f "./values-infra.yaml" ]; then
        rm -f "./values-infra.yaml"
        echo "🗑️  인프라 설정 파일(values-infra.yaml) 삭제 완료."
    fi
else
    echo -e "${YELLOW}  ℹ️  일반 삭제 모드로 인프라 설정 및 TracingPolicy를 보존합니다.${NC}"
fi

echo ""
echo -e "${GREEN}✅ Tetragon 삭제 완료.${NC}"
echo ""
