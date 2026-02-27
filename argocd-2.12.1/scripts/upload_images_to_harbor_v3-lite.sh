#!/bin/bash

################################################################################
# Tar 이미지 일괄 업로드 스크립트 (v3-Lite: 폐쇄망 최적화 버전)
# 
# [주요 특징]
# 1. 의존성 최소화: jq 없이 표준 도구(grep, sed, awk, tr)만 사용하여 폐쇄망 대응
# 2. 공백 이름 대응: 이미지 이름에 공백이 있어도 while read 루프로 안전하게 처리
# 3. 규격 자동 보정: Harbor 업로드 시 이름의 공백을 하이픈(-)으로 자동 치환
# 4. 멀티 아키텍처 대응: ctr convert를 통해 amd64 단일 이미지로 Flattening 수행
################################################################################

# ==================== 설정 ====================
HARBOR_REGISTRY="harbor.local:30002"
HARBOR_PROJECT="library"
HARBOR_USER="admin"
HARBOR_PASSWORD="Password"
CTR_NAMESPACE="k8s.io"
IMAGE_DIR="../images"
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
echo " 🏗️  이미지 마이그레이션 v3-Lite (Air-Gapped & Space Handling)"
echo "========================================================================"

for tar_file in "$IMAGE_DIR"/*.tar; do
    [ -e "$tar_file" ] || break
    
    echo ""
    echo -e "${YELLOW}📦 처리 중: $(basename "$tar_file")${NC}"

    # 1. Import
    echo -n "   └─ 1. Import... "
    ctr -n "$CTR_NAMESPACE" images import "$tar_file" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[성공]${NC}"
    else
        if ctr -n "$CTR_NAMESPACE" images import --all-platforms "$tar_file" > /dev/null 2>&1; then
            echo -e "${GREEN}[성공 (All-platforms)]${NC}"
        else
            echo -e "${RED}[실패]${NC}"
            continue
        fi
    fi

    # 2. 태그 추출 (jq 없이 표준 도구만 사용)
    # RepoTags 배열을 추출하여 쉼표(,)를 줄바꿈(\n)으로 변환해 각 태그를 분리
    repo_tags=$(tar -xOf "$tar_file" manifest.json | grep -o '"RepoTags":\[[^]]*\]' | sed -e 's/"RepoTags":\[//' -e 's/\]//' -e 's/"//g' | tr ',' '\n')

    # while read를 사용하여 공백이 포함된 이미지 이름 한 줄씩 처리
    echo "$repo_tags" | while read -r source_image; do
        [ -z "$source_image" ] && continue

        # 이름 보정 로직 (컨테이너디 내부 이름 확인)
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

        # 타겟 이름 생성: 공백을 하이픈(-)으로 치환
        image_name_tag=$(echo "$source_image" | awk -F/ '{print $NF}' | sed 's/ /-/g')
        target_image="$HARBOR_REGISTRY/$HARBOR_PROJECT/$image_name_tag"

        echo -e "   └─ 2. Convert/Tag: $target_image"
        
        # 이미지가 이미 있으면 삭제
        ctr -n "$CTR_NAMESPACE" images rm "$target_image" > /dev/null 2>&1

        # 변환 실행 (멀티 아키텍처 인덱스를 깨고 amd64 단일 이미지로 변환)
        ctr -n "$CTR_NAMESPACE" images convert \
            --platform "$TARGET_PLATFORM" \
            "$source_image" "$target_image" > /dev/null 2>&1

        if [ $? -ne 0 ]; then
            echo -e "      (Convert 불가 -> 일반 Tag 진행)"
            ctr -n "$CTR_NAMESPACE" images tag "$source_image" "$target_image" > /dev/null 2>&1
        fi
        
        # 3. Push
        echo -n "   └─ 3. Push... "
        if ctr -n "$CTR_NAMESPACE" images push $PUSH_OPTS --user "$HARBOR_USER:$HARBOR_PASSWORD" "$target_image" > /dev/null 2>&1; then
            echo -e "${GREEN}[성공]${NC}"
        else
            echo -e "${RED}[실패]${NC}"
            echo "      [Error Log]"
            ctr -n "$CTR_NAMESPACE" images push $PUSH_OPTS --user "$HARBOR_USER:$HARBOR_PASSWORD" "$target_image"
        fi
    done
done
