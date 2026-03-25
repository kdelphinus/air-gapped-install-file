#!/bin/bash
cd "$(dirname "$0")/.." || exit 1
set -e

################################################################################
# Tar 이미지 일괄 업로드 스크립트 (v2: Flatten Multi-Arch)
#
# [해결 전략]
# 1. Import: 부분 데이터만이라도 일단 로드
# 2. Convert: ctr convert 명령어로 'Manifest List'에서 'Single Manifest'로 변환
#    -> 이 과정에서 없는 아키텍처 정보는 제거되고 amd64만 남음.
# 3. Push: 깨끗해진 단일 이미지를 업로드
#
# [보안 참고] ctr push의 --user 플래그는 ps 목록에 노출될 수 있습니다.
#   환경변수(HARBOR_USER, HARBOR_PASSWORD)로 사전 설정하거나
#   실행 시 프롬프트로 입력하는 것을 권장합니다.
################################################################################

# ==================== 설정 ====================
HARBOR_REGISTRY="${HARBOR_REGISTRY:-<NODE_IP>:30002}"
HARBOR_PROJECT="${HARBOR_PROJECT:-library}"
HARBOR_USER="${HARBOR_USER:-admin}"
if [ -z "$HARBOR_PASSWORD" ]; then
    read -sp "Harbor 비밀번호를 입력하세요: " HARBOR_PASSWORD; echo
fi
CTR_NAMESPACE="k8s.io"
IMAGE_DIR="./saved_tars"
USE_PLAIN_HTTP="false"
TARGET_PLATFORM="linux/amd64" # 고정
# ==============================================

# 색상 코드
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Push 옵션
PUSH_OPTS="--platform $TARGET_PLATFORM"
if [ "$USE_PLAIN_HTTP" = "true" ]; then
    PUSH_OPTS="$PUSH_OPTS --plain-http"
fi

echo "========================================================================"
echo " 🏗️  이미지 마이그레이션 v6 (Convert & Flatten)"
echo "========================================================================"

for tar_file in "$IMAGE_DIR"/*.tar; do
    [ -e "$tar_file" ] || break
    
    echo ""
    echo -e "${YELLOW}📦 처리 중: $(basename "$tar_file")${NC}"

    # 1. Import (기본 모드)
    echo -n "   └─ 1. Import... "
    ctr -n "$CTR_NAMESPACE" images import "$tar_file" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[성공]${NC}"
    else
        # --all-platforms로 재시도 (혹시 모르니)
        if ctr -n "$CTR_NAMESPACE" images import --all-platforms "$tar_file" > /dev/null 2>&1; then
            echo -e "${GREEN}[성공 (All-platforms)]${NC}"
        else
            echo -e "${RED}[실패]${NC}"
            continue
        fi
    fi

    # 2. 태그 추출
    repo_tags=$(tar -xOf "$tar_file" manifest.json | grep -o '"RepoTags":\[[^]]*\]' | sed 's/"RepoTags":\[//;s/\]//;s/"//g' | tr ',' '\n')

    for source_image in $repo_tags; do
        if [ -z "$source_image" ]; then continue; fi

        # 이름 보정 (v4/v5 동일)
        check_image=$(ctr -n "$CTR_NAMESPACE" images list -q name=="$source_image")
        if [ -z "$check_image" ]; then
            fixed_source="docker.io/$source_image"
            if [ -n "$(ctr -n "$CTR_NAMESPACE" images list -q name=="$fixed_source")" ]; then
                source_image="$fixed_source"
            else
                fixed_source_lib="docker.io/library/$source_image"
                if [ -n "$(ctr -n "$CTR_NAMESPACE" images list -q name=="$fixed_source_lib")" ]; then
                    source_image="$fixed_source_lib"
                fi
            fi
        fi

        # 타겟 이름 생성
        image_name_tag=$(echo "$source_image" | awk -F/ '{print $NF}')
        target_image="$HARBOR_REGISTRY/$HARBOR_PROJECT/$image_name_tag"

        # -------------------------------------------------------------
        # [핵심 변경] 2. Convert (Tag 대신 사용)
        # 멀티 아키텍처 인덱스를 깨고, amd64 단일 이미지로 변환하여 생성
        # -------------------------------------------------------------
        echo -e "   └─ 2. Convert: $target_image"
        
        # 이미지가 이미 있으면 삭제 (Convert 충돌 방지)
        ctr -n "$CTR_NAMESPACE" images rm "$target_image" > /dev/null 2>&1

        # 변환 실행
        ctr -n "$CTR_NAMESPACE" images convert \
            --platform "$TARGET_PLATFORM" \
            "$source_image" "$target_image" > /dev/null 2>&1

        if [ $? -ne 0 ]; then
            # Convert 실패 시 (이미 단일 아키텍처인 경우 등) 일반 Tag 시도
            echo -e "      (Convert 불가 -> 일반 Tag 진행)"
            ctr -n "$CTR_NAMESPACE" images tag "$source_image" "$target_image"
        fi
        
        # 3. Push
        echo -n "   └─ 3. Push... "
        if ctr -n "$CTR_NAMESPACE" images push $PUSH_OPTS --user "$HARBOR_USER:$HARBOR_PASSWORD" "$target_image" > /dev/null 2>&1; then
            echo -e "${GREEN}[성공]${NC}"
        else
            echo -e "${RED}[실패]${NC}"
            # 에러 로그 출력
            ctr -n "$CTR_NAMESPACE" images push $PUSH_OPTS --user "$HARBOR_USER:$HARBOR_PASSWORD" "$target_image"
        fi
    done
done
