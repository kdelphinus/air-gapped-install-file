#!/bin/bash

# Root 권한 체크
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi
# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

# ==================== 설정 ====================
# 0. 실행 모드 선택
echo ""
echo "실행 모드를 선택하세요:"
echo "  1) 로컬 이미지 로드 전용 (ctr import)"
echo "  2) 하버 레지스트리로 업로드 (Import + Tag + Push)"
read -p "선택 [1/2, 기본값 1]: " EXEC_MODE
EXEC_MODE="${EXEC_MODE:-1}"

if [ "$EXEC_MODE" == "2" ]; then
    # Harbor 정보 입력 (모드 2인 경우에만)
    if [ -z "$HARBOR_REGISTRY" ]; then
        echo -e "${YELLOW}[안내] 포트 번호를 포함하지 않으면 기본값(30002)이 사용됩니다.${NC}"
        read -p "Harbor 레지스트리 주소 입력: " HARBOR_REGISTRY
        if [[ ! "$HARBOR_REGISTRY" =~ : ]]; then
            echo -e "${YELLOW}[알림] 포트가 없어서 기본 포트 :30002를 추가합니다.${NC}"
            HARBOR_REGISTRY="${HARBOR_REGISTRY}:30002"
        fi
    fi

    if [ -z "$HARBOR_PROJECT" ]; then
        read -p "Harbor 프로젝트 입력 (예: library): " HARBOR_PROJECT
    fi
    HARBOR_USER="${HARBOR_USER:-admin}"
    if [ -z "$HARBOR_PASSWORD" ]; then
        read -sp "Harbor 비밀번호를 입력하세요: " HARBOR_PASSWORD; echo
    fi

    # HTTPS 사용 여부 선택
    read -p "Harbor에서 HTTPS(보안 접속)를 사용합니까? (y/N, 기본 n): " IS_HTTPS
    if [[ "$IS_HTTPS" =~ ^[yY]([eE][sS])?$ ]]; then
        USE_PLAIN_HTTP="false"
    else
        USE_PLAIN_HTTP="true"
    fi
fi

CTR_NAMESPACE="k8s.io"
IMAGE_DIR="./images"
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
echo " 🏗️  이미지 마이그레이션 v3.1-Lite (Air-Gapped & Space Handling)"
echo "========================================================================"

for tar_file in "$IMAGE_DIR"/*.tar*; do
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

    # 2. 태그 추출 및 업로드 (모드 2인 경우에만 수행)
    if [ "$EXEC_MODE" == "1" ]; then
        continue
    fi

    # 태그 추출 (jq 없이 표준 도구만 사용)
    repo_tags=$(tar -xOf "$tar_file" manifest.json | grep -o '"RepoTags":\[[^]]*\]' | sed -e 's/"RepoTags":\[//' -e 's/\]//' -e 's/"//g' | tr ',' '\n')

    while read -r source_image; do
        [ -z "$source_image" ] && continue

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

        image_name_tag=$(echo "$source_image" | awk -F/ '{print $NF}' | sed 's/ /-/g')
        target_image="$HARBOR_REGISTRY/$HARBOR_PROJECT/$image_name_tag"

        echo -e "   └─ 2. Convert/Tag: $target_image"
        
        ctr -n "$CTR_NAMESPACE" images rm "$target_image" > /dev/null 2>&1
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
    done <<< "$repo_tags"
done
