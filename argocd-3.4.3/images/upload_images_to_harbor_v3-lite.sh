#!/bin/bash
# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

# Root 권한 체크
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

# ==================== 설정 ====================
# 색상 코드
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# CLI 자동 감지 (docker -> skopeo -> ctr)
if command -v docker >/dev/null 2>&1; then
    CLI="docker"
elif command -v skopeo >/dev/null 2>&1; then
    CLI="skopeo"
elif command -v ctr >/dev/null 2>&1; then
    CLI="ctr"
else
    echo -e "${RED}[오류] 사용할 수 있는 컨테이너 도구(docker, skopeo, ctr)가 시스템에 존재하지 않습니다.${NC}"
    exit 1
fi

echo ""
echo -e "🐳 감지된 기본 도구: ${GREEN}${CLI}${NC}"
echo "실행 모드를 선택하세요:"
echo "  1) 로컬 이미지 로드 전용 (Docker daemon 또는 containerd)"
echo "  2) 하버 레지스트리로 업로드 (Import + Tag + Push)"
read -p "선택 [1/2, 기본값 1]: " EXEC_MODE
EXEC_MODE="${EXEC_MODE:-1}"

if [ "$EXEC_MODE" == "2" ]; then
    # Harbor 정보 입력 (모드 2인 경우에만)
    if [ -z "$HARBOR_REGISTRY" ]; then
        read -p "Harbor 레지스트리 주소 입력 (예: 192.168.1.10:30002): " HARBOR_REGISTRY
        if [ -n "$HARBOR_REGISTRY" ] && [[ ! "$HARBOR_REGISTRY" =~ : ]]; then
            read -p "포트가 없습니다. 기본 포트 :30002를 추가할까요? (y/N): " ADD_PORT
            if [[ "$ADD_PORT" =~ ^[yY]([eE][sS])?$ ]]; then
                HARBOR_REGISTRY="${HARBOR_REGISTRY}:30002"
                echo -e "${YELLOW}[알림] ${HARBOR_REGISTRY} 으로 설정합니다.${NC}"
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

# Push 옵션 설정
PUSH_OPTS="--platform $TARGET_PLATFORM"
if [ "$USE_PLAIN_HTTP" = "true" ]; then
    PUSH_OPTS="$PUSH_OPTS --plain-http"
fi

echo "========================================================================"
echo " 🏗️  이미지 마이그레이션 v3.4 (Multi-CLI Auto-Detect & Root Check)"
echo "========================================================================"

for tar_file in "$IMAGE_DIR"/*.tar*; do
    [ -e "$tar_file" ] || break
    
    echo ""
    echo -e "${YELLOW}📦 처리 중: $(basename "$tar_file")${NC}"

    # 1. 로컬 로드 모드 (EXEC_MODE = 1)
    if [ "$EXEC_MODE" == "1" ]; then
        # skopeo는 로컬 로드 기능이 모호하므로 docker나 ctr을 사용
        LOCAL_LOAD_CLI="$CLI"
        if [ "$LOCAL_LOAD_CLI" == "skopeo" ]; then
            if command -v docker >/dev/null 2>&1; then
                LOCAL_LOAD_CLI="docker"
            elif command -v ctr >/dev/null 2>&1; then
                LOCAL_LOAD_CLI="ctr"
            else
                echo -e "${RED}[오류] 로컬 이미지 로드를 위해 필요한 docker 또는 ctr이 없습니다.${NC}"
                exit 1
            fi
        fi

        echo -n "   └─ 로컬 이미지 로드 중 (${LOCAL_LOAD_CLI})... "
        if [ "$LOCAL_LOAD_CLI" == "docker" ]; then
            docker load -i "$tar_file" > /dev/null 2>&1
        elif [ "$LOCAL_LOAD_CLI" == "ctr" ]; then
            ctr -n "$CTR_NAMESPACE" images import "$tar_file" > /dev/null 2>&1
        fi

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}[성공]${NC}"
        else
            echo -e "${RED}[실패]${NC}"
        fi
        continue
    fi

    # 2. Harbor 업로드 모드 (EXEC_MODE = 2)
    # tar 파일 내부의 이미지 명 태그 정보 추출
    repo_tags=$(tar -xOf "$tar_file" manifest.json 2>/dev/null | grep -o '"RepoTags":\[[^]]*\]' | sed -e 's/"RepoTags":\[//' -e 's/\]//' -e 's/"//g' | tr ',' '\n')

    if [ -z "$repo_tags" ]; then
        echo -e "${RED}   └─ [경고] tar 파일에서 RepoTags를 추출할 수 없습니다. 파일 형식을 확인하세요.${NC}"
        continue
    fi

    # skopeo를 사용한 직접 push 최적화
    if [ "$CLI" == "skopeo" ]; then
        while read -r source_image; do
            [ -z "$source_image" ] && continue
            
            # 태그명 파싱 (예: quay.io/argoproj/argocd:v3.4.4 -> argocd:v3.4.4)
            image_name_tag=$(echo "$source_image" | awk -F/ '{print $NF}' | sed 's/ /-/g')
            target_image="$HARBOR_REGISTRY/$HARBOR_PROJECT/$image_name_tag"
            
            echo -e "   └─ [skopeo] 직접 업로드 진행: $target_image"
            SKOPEO_OPTS="--override-os linux --override-arch amd64 --dest-creds $HARBOR_USER:$HARBOR_PASSWORD"
            if [ "$USE_PLAIN_HTTP" == "true" ]; then
                SKOPEO_OPTS="$SKOPEO_OPTS --dest-tls-verify=false"
            fi

            # docker-archive:$tar_file:$source_image 형태로 복사
            skopeo copy $SKOPEO_OPTS "docker-archive:${tar_file}:${source_image}" "docker://${target_image}"
            if [ $? -eq 0 ]; then
                echo -e "   └─ ${GREEN}[성공] Harbor 업로드 완료${NC}"
            else
                echo -e "   └─ ${RED}[실패] Harbor 업로드 에러${NC}"
            fi
        done <<< "$repo_tags"

    # docker를 사용한 push
    elif [ "$CLI" == "docker" ]; then
        echo -n "   └─ 1. docker load... "
        docker load -i "$tar_file" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}[성공]${NC}"
        else
            echo -e "${RED}[실패]${NC}"
            continue
        fi

        # Harbor 로그인
        echo "   └─ 2. Harbor 로그인..."
        DOCKER_LOGIN_OPTS=""
        # insecure registry 설정은 daemon.json에 있어야 하나, 여기서 로그인 시도
        echo "$HARBOR_PASSWORD" | docker login "$HARBOR_REGISTRY" -u "$HARBOR_USER" --password-stdin > /dev/null 2>&1
        
        while read -r source_image; do
            [ -z "$source_image" ] && continue

            image_name_tag=$(echo "$source_image" | awk -F/ '{print $NF}' | sed 's/ /-/g')
            target_image="$HARBOR_REGISTRY/$HARBOR_PROJECT/$image_name_tag"

            echo "   └─ 3. Tagging: $source_image -> $target_image"
            docker tag "$source_image" "$target_image"

            echo -n "   └─ 4. Push... "
            if docker push "$target_image" > /dev/null 2>&1; then
                echo -e "${GREEN}[성공]${NC}"
            else
                echo -e "${RED}[실패] (재시도 로그 출력)"
                docker push "$target_image"
            fi
        done <<< "$repo_tags"

    # ctr을 사용한 push (마지노선)
    elif [ "$CLI" == "ctr" ]; then
        echo -n "   └─ 1. ctr import... "
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

        while read -r source_image; do
            [ -z "$source_image" ] && continue

            # containerd 내부 이름 존재성 보정 (docker.io 등 접두사 유무 체크)
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
            
            # Push
            echo -n "   └─ 3. Push... "
            if ctr -n "$CTR_NAMESPACE" images push $PUSH_OPTS --user "$HARBOR_USER:$HARBOR_PASSWORD" "$target_image" > /dev/null 2>&1; then
                echo -e "${GREEN}[성공]${NC}"
            else
                echo -e "${RED}[실패]${NC}"
                echo "      [Error Log]"
                ctr -n "$CTR_NAMESPACE" images push $PUSH_OPTS --user "$HARBOR_USER:$HARBOR_PASSWORD" "$target_image"
            fi
        done <<< "$repo_tags"
    fi
done

echo ""
echo -e "${GREEN}🎉 모든 이미지 작업이 완료되었습니다.${NC}"
