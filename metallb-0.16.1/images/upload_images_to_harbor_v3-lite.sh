#!/bin/bash
# ------------------------------------------------------------------------
# Harbor/Local Container Image Migration Tool (v3.2-Lite)
# [Target] Rocky Linux / Ubuntu (containerd ctr)
# ------------------------------------------------------------------------
set -e

# 스크립트 위치에 상관없이 컴포넌트 루트로 이동
COMPONENT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$COMPONENT_ROOT" || exit 1

# Root 권한 필수
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

echo "=========================================================="
echo " 이미지 마이그레이션 실행 모드 선택:"
echo "   1) 로컬 containerd(k8s.io)로 이미지 임포트"
echo "   2) Harbor 레지스트리로 이미지 업로드 (도메인/포트 자동 보정)"
read -p "선택 [1/2, 기본값: 1]: " EXEC_MODE
EXEC_MODE="${EXEC_MODE:-1}"

if [ "$EXEC_MODE" == "2" ]; then
    if [ -z "$HARBOR_REGISTRY" ]; then
        read -p "Harbor 레지스트리 주소 입력 (예: 192.168.1.10:30002): " HARBOR_REGISTRY
        if [ -n "$HARBOR_REGISTRY" ] && [[ ! "$HARBOR_REGISTRY" =~ : ]]; then
            read -p "포트가 없습니다. 기본 포트 :30002를 추가할까요? (y/N): " ADD_PORT
            if [[ "$ADD_PORT" =~ ^[yY]$ ]]; then
                HARBOR_REGISTRY="${HARBOR_REGISTRY}:30002"
                echo -e "\033[1;33m[알림] ${HARBOR_REGISTRY} 으로 설정합니다.\033[0m"
            fi
        fi
    fi
    if [ -z "$HARBOR_PROJECT" ]; then
        read -p "Harbor 프로젝트 입력 (예: library): " HARBOR_PROJECT
    fi
    HARBOR_USER="${HARBOR_USER:-admin}"
    if [ -z "$HARBOR_PASSWORD" ]; then
        read -sp "Harbor 비밀번호를 입력하세요: " HARBOR_PASSWORD; echo
    fi

    read -p "Harbor에서 HTTPS(보안 접속)를 사용합니까? (y/N, 기본 n): " IS_HTTPS
    if [[ "$IS_HTTPS" =~ ^[yY]$ ]]; then
        USE_PLAIN_HTTP="false"
    else
        USE_PLAIN_HTTP="true"
    fi
fi

CTR_NAMESPACE="k8s.io"
IMAGE_DIR="./images"
TARGET_PLATFORM="linux/amd64"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

PUSH_OPTS="--platform $TARGET_PLATFORM"
if [ "$USE_PLAIN_HTTP" = "true" ]; then
    PUSH_OPTS="$PUSH_OPTS --plain-http"
fi

echo "=========================================================="
echo " 🏗️  이미지 마이그레이션 v3.2-Lite"
echo "=========================================================="

shopt -s nullglob
image_archives=("$IMAGE_DIR"/*.tar*)
shopt -u nullglob

if [ ${#image_archives[@]} -eq 0 ]; then
    echo -e "${YELLOW}[경고] ${IMAGE_DIR} 디렉토리에 이미지 tar 파일이 없습니다.${NC}"
    echo "       처리할 이미지가 없어 작업을 중단합니다."
    exit 1
fi

FAILED_IMAGES=0

for tar_file in "${image_archives[@]}"; do
    echo ""
    echo -e "${YELLOW}📦 처리 중: $(basename "$tar_file")${NC}"

    # 1. Import
    echo -n "   └─ 1. Import... "
    if ctr -n "$CTR_NAMESPACE" images import "$tar_file" > /dev/null 2>&1; then
        echo -e "${GREEN}[성공]${NC}"
    else
        if ctr -n "$CTR_NAMESPACE" images import --all-platforms "$tar_file" > /dev/null 2>&1; then
            echo -e "${GREEN}[성공 (All-platforms)]${NC}"
        else
            echo -e "${RED}[실패]${NC}"
            FAILED_IMAGES=$((FAILED_IMAGES + 1))
            continue
        fi
    fi

    # 2. 업로드 (모드 2인 경우에만 수행)
    if [ "$EXEC_MODE" == "1" ]; then
        continue
    fi

    # RepoTags 검출
    repo_tags=$(tar -xOf "$tar_file" manifest.json | grep -o '"RepoTags":\[[^]]*\]' | sed -e 's/"RepoTags":\[//' -e 's/\]//' -e 's/"//g' | tr ',' '\n' || echo "")
    if [ -z "$repo_tags" ]; then
        echo -e "${RED}[실패] manifest.json에서 RepoTags를 찾지 못했습니다.${NC}"
        FAILED_IMAGES=$((FAILED_IMAGES + 1))
        continue
    fi

    while read -r source_image; do
        [ -z "$source_image" ] && continue

        # 로컬 이미지 이름 자동 보정
        check_image=$(ctr -n "$CTR_NAMESPACE" images list -q name=="$source_image")
        if [ -z "$check_image" ]; then
            fixed_source="docker.io/$source_image"
            if [ -n "$(ctr -n "$CTR_NAMESPACE" images list -q name=="$fixed_source")" ]; then
                source_image="$fixed_source"
            fi
        fi

        # Harbor 태그명 생성
        base_name=$(echo "$source_image" | awk -F'/' '{print $NF}')
        image_name=$(echo "$base_name" | cut -d':' -f1)
        image_tag=$(echo "$base_name" | cut -d':' -f2)

        # metallb-controller, metallb-speaker 매핑 보정
        if [ "$image_name" == "controller" ]; then
            target_name="metallb-controller"
        elif [ "$image_name" == "speaker" ]; then
            target_name="metallb-speaker"
        else
            target_name="$image_name"
        fi

        target_image="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${target_name}:${image_tag}"

        echo -n "   └─ 2. Tagging to ${target_image}... "
        ctr -n "$CTR_NAMESPACE" images tag "$source_image" "$target_image" > /dev/null
        echo -e "${GREEN}[완료]${NC}"

        echo -n "   └─ 3. Pushing to Harbor... "
        if ctr -n "$CTR_NAMESPACE" images push $PUSH_OPTS -u "${HARBOR_USER}:${HARBOR_PASSWORD}" "$target_image" > /dev/null 2>&1; then
            echo -e "${GREEN}[성공]${NC}"
        else
            echo -e "${RED}[실패] Pushing 실패, 재시도 중...${NC}"
            if ctr -n "$CTR_NAMESPACE" images push $PUSH_OPTS -u "${HARBOR_USER}:${HARBOR_PASSWORD}" "$target_image"; then
                echo -e "${GREEN}[성공]${NC}"
            else
                echo -e "${RED}[실패] 업로드 실패${NC}"
                FAILED_IMAGES=$((FAILED_IMAGES + 1))
            fi
        fi
    done <<< "$repo_tags"
done

echo ""
echo "=========================================================="
if [ "$FAILED_IMAGES" -eq 0 ]; then
    echo -e "${GREEN}✅ 모든 이미지 마이그레이션 완료!${NC}"
else
    echo -e "${RED}⚠️ 일부 이미지 처리 실패 (실패 건수: ${FAILED_IMAGES})${NC}"
fi
echo "=========================================================="
