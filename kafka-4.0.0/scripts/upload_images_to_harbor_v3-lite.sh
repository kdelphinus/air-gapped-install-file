#!/bin/bash
# ---------------------------------------------------------
# Apache Kafka v4.0.0 Air-Gapped Image Upload Tool (v3-lite)
# ---------------------------------------------------------
cd "$(dirname "$0")/.." || exit 1

CONF_FILE="./install.conf"
IMAGES_DIR="./images"

# 색상 코드
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# 기존 설정 로드
[ -f "$CONF_FILE" ] && source "$CONF_FILE"

echo -e "${CYAN}===========================================${NC}"
echo -e "${CYAN}   Kafka 에어갭 이미지 Harbor 업로드 도구  ${NC}"
echo -e "${CYAN}===========================================${NC}"

# 입력 프롬프트
if [ -z "${HARBOR_REGISTRY}" ]; then
    read -p "Harbor 레지스트리 주소 (예: 192.168.1.10:30002): " HARBOR_REGISTRY
fi
if [ -z "${HARBOR_PROJECT}" ]; then
    read -p "Harbor 대상 프로젝트 (예: library): " HARBOR_PROJECT
fi

if [ -z "${HARBOR_REGISTRY}" ] || [ -z "${HARBOR_PROJECT}" ]; then
    echo -e "${RED}[오류] Harbor 레지스트리 주소와 프로젝트 명칭은 필수 입력값입니다.${NC}"
    exit 1
fi

# 업로드 대상 이미지 정의
KAFKA_TAG="4.0.0-debian-12-r10"
OS_SHELL_TAG="12-debian-12-r51"
KUBECTL_TAG="1.33.4-debian-12-r0"
JMX_EXPORTER_TAG="1.4.0-debian-12-r0"

IMAGES=(
    "bitnami/kafka:${KAFKA_TAG}"
    "bitnami/os-shell:${OS_SHELL_TAG}"
    "bitnami/kubectl:${KUBECTL_TAG}"
    "bitnami/jmx-exporter:${JMX_EXPORTER_TAG}"
)

# skopeo 또는 docker/podman 도구 감지
SKOPEO_BIN=$(command -v skopeo || true)
DOCKER_BIN=$(command -v docker || command -v podman || true)

if [ -n "$SKOPEO_BIN" ]; then
    echo -e "${GREEN}Detected Skopeo!${NC} Skopeo copy 기능을 사용하여 빠르고 안전하게 다이렉트 푸시를 진행합니다."
    
    TAR_FILE="${IMAGES_DIR}/kafka-images.tar"
    if [ ! -f "$TAR_FILE" ]; then
        echo -e "${RED}[오류] 이미지 아카이브 파일(${TAR_FILE})을 찾을 수 없습니다.${NC}"
        exit 1
    fi

    # Harbor 로그인 정보 확인 및 복사 수행
    echo -e "\n${YELLOW}🚚 Skopeo로 이미지 푸시 중...${NC}"
    for img in "${IMAGES[@]}"; do
        echo "   → Push: ${CYAN}${img}${NC}"
        # docker-archive를 docker 레지스트리로 바로 복사 (Skopeo v3-lite core)
        $SKOPEO_BIN copy \
            --insecure-policy \
            --dest-tls-verify=false \
            docker-archive:"$TAR_FILE":"docker.io/${img}" \
            docker://"${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${img##*/}"
    done

elif [ -n "$DOCKER_BIN" ]; then
    echo -e "${YELLOW}Skopeo가 감지되지 않아 ${GREEN}${DOCKER_BIN}${YELLOW} CLI Fallback 모드로 진행합니다.${NC}"
    
    TAR_FILE="${IMAGES_DIR}/kafka-images.tar"
    if [ ! -f "$TAR_FILE" ]; then
        echo -e "${RED}[오류] 이미지 아카이브 파일(${TAR_FILE})을 찾을 수 없습니다.${NC}"
        exit 1
    fi

    echo -e "\n⏳ 이미지 아카이브 로드 중..."
    $DOCKER_BIN load -i "$TAR_FILE"

    echo -e "\n🚚 태깅 및 Harbor 푸시 중..."
    for img in "${IMAGES[@]}"; do
        local_img="docker.io/${img}"
        target_img="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${img##*/}"
        
        echo "   → Tag & Push: ${CYAN}${target_img}${NC}"
        $DOCKER_BIN tag "$local_img" "$target_img"
        $DOCKER_BIN push "$target_img" || {
            echo -e "${YELLOW}⚠️  일반 push 실패. TLS 검증 무시 설정 적용 시도 중...${NC}"
            # docker의 경우 daemon.json에 insecure-registries가 등록되어 있어야 합니다.
            $DOCKER_BIN push "$target_img"
        }
    done
else
    echo -e "${RED}[오류] skopeo, docker, podman 중 어떠한 업로드 도구도 찾을 수 없습니다.${NC}"
    exit 1
fi

echo -e "\n========================================================"
echo -e "${GREEN} 🎉 Kafka 에어갭 이미지 Harbor 업로드 완료!${NC}"
echo "========================================================"
echo " 대상 저장소: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}"
echo "========================================================"
