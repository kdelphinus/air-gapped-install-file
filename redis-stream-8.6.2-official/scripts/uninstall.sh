#!/bin/bash
# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="redis-stream-official"
RELEASE_NAME="redis-stream-official"
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

echo "======================================================"
echo " Redis Stream (공식 이미지 - Helm) 삭제"
echo " Namespace: ${NAMESPACE}"
echo " Release:   ${RELEASE_NAME}"
echo " Mode:      ${RESET_MODE}"
echo "======================================================"
echo ""

# 1차 y/N 삭제 확인 (P4 준수)
read -p "❓ Redis Stream 릴리즈를 언인스톨하시겠습니까? (y/n): " CONFIRM
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
    echo "취소되었습니다."
    exit 0
fi

# Helm Uninstall
echo "Helm Release 삭제 중..."
helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait || true

# 2. PV 및 PVC, Namespace 삭제 (Reset 시에만)
if [ "${RESET_MODE}" == "reset" ]; then
    echo ""
    echo -e "${RED}⚠️  [주의] 데이터 완전 초기화 모드입니다.${NC}"
    echo "    - 모든 영구 데이터 볼륨(PVC/PV)과 네임스페이스가 영구적으로 삭제됩니다."
    echo ""

    # 2차 정밀 y/N 프롬프트 데이터 소거 확인
    read -p "❓ 정말 모든 데이터 볼륨(PVC/PV)과 네임스페이스를 완전히 삭제하시겠습니까? (y/N): " RESET_CONFIRM
    if [[ "${RESET_CONFIRM}" =~ ^[Yy]$ ]]; then
        echo "PersistentVolumeClaim 삭제 중..."
        PVCLIST=$(kubectl get pvc -n "${NAMESPACE}" --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep "^redis-data-" || true)
        if [ -n "${PVCLIST}" ]; then
            echo "${PVCLIST}" | xargs kubectl delete pvc -n "${NAMESPACE}" --ignore-not-found=true --timeout=30s 2>/dev/null || true
            echo "PVC 삭제 완료."
        else
            echo "삭제할 PVC가 없습니다."
        fi

        echo "PersistentVolume 삭제 중..."
        for i in 0 1 2; do
            kubectl delete pv "redis-official-node-${i}-pv" --ignore-not-found=true --timeout=30s 2>/dev/null || true
        done
        echo "PV 삭제 완료."

        echo "Namespace '${NAMESPACE}' 삭제 중..."
        kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true --timeout=30s 2>/dev/null || true
        echo "네임스페이스 삭제 완료."

        # 가변 설정 파일 삭제
        rm -f "$CONF_FILE" "values-infra.yaml"
        echo "🗑️  설정 파일(install.conf, values-infra.yaml) 삭제 완료."
    else
        echo -e "${YELLOW}[안내] 리소스를 보존한 채 작업을 완료합니다.${NC}"
    fi
else
    echo ""
    echo -e "${GREEN}[알림] 일반 언인스톨 모드로 리소스와 데이터를 안전하게 보존합니다.${NC}"
    echo "       (PVC, PV 및 install.conf, values-infra.yaml 이 유지됨)"
fi

echo ""
echo -e "${GREEN}✅ Redis Stream 삭제 완료.${NC}"
echo ""
