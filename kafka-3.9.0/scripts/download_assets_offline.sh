#!/bin/bash
# ---------------------------------------------------------
# Apache Kafka v3.9.0 Offline Asset Downloader
# [Usage] Run this script on an internet-connected PC.
# ---------------------------------------------------------
cd "$(dirname "$0")/.." || exit 1

CHART_VERSION="31.4.0"
IMAGES_DIR="./images"
CHART_DIR="./charts"

# 이미지 태그 정의
KAFKA_TAG="3.9.0-debian-12-r10"
OS_SHELL_TAG="12-debian-12-r51"
KUBECTL_TAG="1.33.4-debian-12-r0"
JMX_EXPORTER_TAG="1.4.0-debian-12-r0"

# 색상 코드
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}===========================================${NC}"
echo -e "${CYAN}   Kafka v${CHART_VERSION} (Apache 2.0) 자산 다운로드  ${NC}"
echo -e "${CYAN}===========================================${NC}"

mkdir -p "$IMAGES_DIR"
mkdir -p "$CHART_DIR"

# 1. Helm Chart 다운로드
echo -e "\n${YELLOW}📦 [1/2] Bitnami Kafka Helm Chart 다운로드 중...${NC}"
if command -v helm &> /dev/null; then
    helm repo add bitnami https://charts.bitnami.com/bitnami --force-update 2>/dev/null || true
    helm repo update 2>/dev/null || true
    helm pull bitnami/kafka --version "$CHART_VERSION" --untar --untardir "$CHART_DIR"
    echo -e "${GREEN}✅ Helm 차트 다운로드 완료.${NC}"
else
    echo "⚠️  [경고] helm CLI를 찾을 수 없습니다. Helm 차트 획득을 건너뜁니다."
    echo "    차트는 수동으로 다운로드하여 ./charts/kafka 에 압축 해제해야 합니다."
fi

# 2. Docker 이미지 다운로드 및 저장
echo -e "\n${YELLOW}🚚 [2/2] 필수 컨테이너 이미지 4종 다운로드 및 패키징 중...${NC}"

# CLI 도구 감지
if command -v docker &> /dev/null; then
    CLI="docker"
elif command -v podman &> /dev/null; then
    CLI="podman"
else
    echo -e "\033[0;31m❌ [오류] docker 또는 podman CLI를 찾을 수 없습니다. 이미지 다운로드를 중단합니다.\033[0m"
    exit 1
fi

echo -e "💡 감지된 컨테이너 도구: ${GREEN}${CLI}${NC}"

IMAGES=(
    "docker.io/bitnami/kafka:${KAFKA_TAG}"
    "docker.io/bitnami/os-shell:${OS_SHELL_TAG}"
    "docker.io/bitnami/kubectl:${KUBECTL_TAG}"
    "docker.io/bitnami/jmx-exporter:${JMX_EXPORTER_TAG}"
)

for img in "${IMAGES[@]}"; do
    echo -e "   → 이미지 Pull 중: ${CYAN}${img}${NC}"
    $CLI pull "$img"
done

# 단일 tar 아카이브로 통합 저장
OUTPUT_TAR="${IMAGES_DIR}/kafka-images.tar"
echo -e "\n📦 이미지 아카이브 생성 중: ${GREEN}${OUTPUT_TAR}${NC}..."
$CLI save -o "$OUTPUT_TAR" "${IMAGES[@]}"

echo -e "\n==========================================="
echo -e "${GREEN} ✅ Kafka 오프라인 자산 다운로드 완료!${NC}"
echo "==========================================="
echo "  - Helm 차트 경로 : ./charts/kafka"
echo "  - 이미지 경로    : ./images/kafka-images.tar"
echo "==========================================="
