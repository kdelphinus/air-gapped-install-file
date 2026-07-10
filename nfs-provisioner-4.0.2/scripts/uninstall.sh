#!/bin/bash
# ---------------------------------------------------------
# NFS Provisioner Uninstall Script
# [Target] Rocky Linux / Ubuntu (Online/Offline)
# ---------------------------------------------------------
cd "$(dirname "$0")/.." || exit 1

RELEASE_NAME="nfs-provisioner"
NAMESPACE="kube-system"
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
echo " NFS Provisioner 삭제 스크립트"
echo " Namespace: ${NAMESPACE}"
echo " Release:   ${RELEASE_NAME}"
echo " Mode:      ${RESET_MODE}"
echo "======================================================"
echo ""

# 1차 y/N 삭제 확인
read -p "❓ NFS Provisioner를 삭제하시겠습니까? (y/n): " CONFIRM
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
    echo "취소되었습니다."
    exit 0
fi

# 1. 추가 StorageClass 삭제
if [ -f "./manifests/additional-sc.yaml" ]; then
    echo "추가 StorageClass(backup, test) 삭제 중..."
    kubectl delete -f ./manifests/additional-sc.yaml --ignore-not-found=true 2>/dev/null || true
fi

# 2. Helm Uninstall
echo "Helm Release 삭제 중..."
helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait 2>/dev/null || true

# 3. 설정 및 데이터 소거 (Reset 시에만)
if [ "${RESET_MODE}" == "reset" ]; then
    echo ""
    echo -e "${RED}⚠️  [주의] 데이터 완전 초기화 모드입니다.${NC}"
    echo "    - 로컬 설정 파일 및 values-infra.yaml 정보가 영구적으로 제거됩니다."
    echo ""
    
    # 2차 정밀 y/N 프롬프트 데이터 소거 확인
    read -p "❓ 정말 모든 인프라 설정 파일을 완전히 삭제하시겠습니까? (y/N): " RESET_CONFIRM
    if [[ "${RESET_CONFIRM}" =~ ^[Yy]$ ]]; then
        rm -f "$CONF_FILE" "values-infra.yaml"
        echo "🗑️  설정 파일(install.conf, values-infra.yaml) 삭제 완료."
    else
        echo -e "${YELLOW}[안내] 설정 파일을 보존한 채 작업을 완료합니다.${NC}"
    fi
else
    echo ""
    echo -e "${GREEN}[알림] 일반 언인스톨 모드로 인프라 설정을 안전하게 보존합니다.${NC}"
    echo "       (install.conf, values-infra.yaml 이 유지됨)"
fi

echo ""
echo -e "${GREEN}✅ NFS Provisioner 삭제 완료.${NC}"
echo ""
