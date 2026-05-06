#!/bin/bash
# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

# Root 권한 체크
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

IMAGE_DIR="./images"
CTR_NAMESPACE="k8s.io"

# 색상 코드
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "========================================================================"
echo " Harbor 구성 이미지 로컬 로드 (ctr import)"
echo " 대상 네임스페이스: ${CTR_NAMESPACE}"
echo "========================================================================"

if [ ! -d "$IMAGE_DIR" ]; then
    echo -e "${RED}[오류] 이미지 디렉토리(${IMAGE_DIR})를 찾을 수 없습니다.${NC}"
    exit 1
fi

# tar 파일 목록 확인
TAR_FILES=$(ls "$IMAGE_DIR"/*.tar 2>/dev/null)
if [ -z "$TAR_FILES" ]; then
    echo -e "${YELLOW}[경고] 로드할 .tar 파일이 ${IMAGE_DIR}에 없습니다.${NC}"
    exit 0
fi

for tar_file in $TAR_FILES; do
    echo -e "${YELLOW}로드 중: $(basename "$tar_file")${NC}"
    
    # 1. Import
    if sudo ctr -n "$CTR_NAMESPACE" images import "$tar_file"; then
        echo -e "   └─ ${GREEN}[성공]${NC}"
    else
        echo -e "   └─ ${RED}[실패]${NC}"
    fi
done

echo ""
echo "========================================================================"
echo " 로드된 Harbor 관련 이미지 목록:"
sudo ctr -n "$CTR_NAMESPACE" images list | grep "goharbor" || echo "로드된 이미지가 없습니다."
echo "========================================================================"
echo "[안내] 이 작업은 모든 Kubernetes 노드(Master, Worker)에서 실행해야 합니다."
