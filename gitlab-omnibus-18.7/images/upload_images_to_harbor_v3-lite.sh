#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

# ==================== 모드 선택 ====================
echo ""
echo "실행 모드를 선택하세요:"
echo "  1) 로컬 이미지 로드 전용"
echo "  2) Harbor 레지스트리로 업로드 (Load + Tag + Push)"
read -p "선택 [1/2, 기본값 1]: " EXEC_MODE
EXEC_MODE="${EXEC_MODE:-1}"

if [ "$EXEC_MODE" == "2" ]; then
    if [ -z "$HARBOR_REGISTRY" ]; then
        read -p "Harbor 레지스트리 주소 입력 (예: 172.30.235.20:30002): " HARBOR_REGISTRY
        if [ -n "$HARBOR_REGISTRY" ] && [[ ! "$HARBOR_REGISTRY" =~ : ]]; then
            read -p "포트가 없습니다. 기본 포트 :30002를 추가할까요? (y/N): " ADD_PORT
            [[ "$ADD_PORT" =~ ^[yY]([eE][sS])?$ ]] && HARBOR_REGISTRY="${HARBOR_REGISTRY}:30002"
        fi
    fi
    [ -z "$HARBOR_PROJECT" ] && read -p "Harbor 프로젝트 입력 (예: library): " HARBOR_PROJECT
    HARBOR_USER="${HARBOR_USER:-admin}"
    [ -z "$HARBOR_PASSWORD" ] && { read -sp "Harbor 비밀번호를 입력하세요: " HARBOR_PASSWORD; echo; }
    read -p "Harbor에서 HTTPS를 사용합니까? (y/N, 기본 n): " IS_HTTPS
    [[ "$IS_HTTPS" =~ ^[yY]([eE][sS])?$ ]] && USE_HTTPS="true" || USE_HTTPS="false"
fi

IMAGE_DIR="./images"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ==================== 도구 감지 ====================
USE_DOCKER=false
USE_CTR=false
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    USE_DOCKER=true
elif command -v ctr &>/dev/null; then
    USE_CTR=true
else
    echo -e "${RED}[오류] docker 또는 ctr 명령이 필요합니다.${NC}"
    exit 1
fi

echo "========================================================================"
echo " GitLab Omnibus 이미지 마이그레이션"
[ "$USE_DOCKER" = "true" ] && echo " 도구: docker" || echo " 도구: ctr (k8s.io)"
echo "========================================================================"

# ==================== tar 처리 ====================
for tar_file in "$IMAGE_DIR"/*.tar*; do
    [ -e "$tar_file" ] || { echo "[경고] images/ 디렉토리에 .tar 파일이 없습니다."; break; }

    echo ""
    echo -e "${YELLOW}📦 처리 중: $(basename "$tar_file")${NC}"

    # ── 1. Load/Import ──────────────────────────────
    echo -n "   └─ 1. Load... "
    if [ "$USE_DOCKER" = "true" ]; then
        load_out=$(docker load -i "$tar_file" 2>&1)
        if echo "$load_out" | grep -q "Loaded image"; then
            echo -e "${GREEN}[성공]${NC}"
            # docker load 출력에서 이미지 이름 추출: "Loaded image: gitlab/gitlab-ce:18.7.0-ce.0"
            loaded_images=$(echo "$load_out" | grep "Loaded image" | sed 's/Loaded image[s]*: //' | tr -d ' ')
        else
            echo -e "${RED}[실패]${NC}"
            echo "$load_out"
            continue
        fi
    else
        # ctr: manifest.json에서 태그 추출 후 import
        if sudo ctr -n k8s.io images import "$tar_file" > /dev/null 2>&1 || \
           sudo ctr -n k8s.io images import --all-platforms "$tar_file" > /dev/null 2>&1; then
            echo -e "${GREEN}[성공]${NC}"
            loaded_images=$(tar -xOf "$tar_file" manifest.json 2>/dev/null \
                | grep -o '"RepoTags":\[[^]]*\]' \
                | sed -e 's/"RepoTags":\[//' -e 's/\]//' -e 's/"//g' \
                | tr ',' '\n')
        else
            echo -e "${RED}[실패]${NC}"
            sudo ctr -n k8s.io images import "$tar_file" 2>&1 | head -5
            continue
        fi
    fi

    [ "$EXEC_MODE" == "1" ] && continue

    # ── 2. Tag + Push ───────────────────────────────
    while read -r source_image; do
        [ -z "$source_image" ] && continue

        image_name_tag=$(echo "$source_image" | awk -F/ '{print $NF}')
        target_image="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${image_name_tag}"

        echo -e "   └─ 2. Tag: $target_image"

        if [ "$USE_DOCKER" = "true" ]; then
            docker tag "$source_image" "$target_image" 2>/dev/null || \
                docker tag "docker.io/$source_image" "$target_image" 2>/dev/null || true

            echo -n "   └─ 3. Push... "
            if [ "$USE_HTTPS" = "true" ]; then
                push_cmd="docker push $target_image"
            else
                # HTTP Harbor: daemon에 insecure-registries 필요
                push_cmd="docker push $target_image"
            fi
            if docker login "$HARBOR_REGISTRY" -u "$HARBOR_USER" -p "$HARBOR_PASSWORD" > /dev/null 2>&1 && \
               $push_cmd > /dev/null 2>&1; then
                echo -e "${GREEN}[성공]${NC}"
            else
                echo -e "${RED}[실패]${NC}"
                docker push "$target_image" 2>&1 | tail -5
            fi
        else
            # ctr: docker.io prefix 보정
            actual_src="$source_image"
            for prefix in "" "docker.io/" "docker.io/library/"; do
                candidate="${prefix}${source_image}"
                if [ -n "$(sudo ctr -n k8s.io images list -q name=="$candidate" 2>/dev/null)" ]; then
                    actual_src="$candidate"
                    break
                fi
            done

            sudo ctr -n k8s.io images rm "$target_image" > /dev/null 2>&1
            if ! sudo ctr -n k8s.io images convert \
                    --platform linux/amd64 \
                    "$actual_src" "$target_image" > /dev/null 2>&1; then
                sudo ctr -n k8s.io images tag "$actual_src" "$target_image" > /dev/null 2>&1
            fi

            PUSH_OPTS="--platform linux/amd64"
            [ "$USE_HTTPS" != "true" ] && PUSH_OPTS="$PUSH_OPTS --plain-http"

            echo -n "   └─ 3. Push... "
            if sudo ctr -n k8s.io images push $PUSH_OPTS \
                    --user "$HARBOR_USER:$HARBOR_PASSWORD" "$target_image" > /dev/null 2>&1; then
                echo -e "${GREEN}[성공]${NC}"
            else
                echo -e "${RED}[실패]${NC}"
                sudo ctr -n k8s.io images push $PUSH_OPTS \
                    --user "$HARBOR_USER:$HARBOR_PASSWORD" "$target_image" 2>&1 | tail -5
            fi
        fi
    done <<< "$loaded_images"
done

echo ""
echo "✅ 완료"
