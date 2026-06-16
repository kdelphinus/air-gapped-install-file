#!/bin/bash
set -e

# 스크립트 위치 기준으로 이동
cd "$(dirname "$0")" || exit 1

# 색상 코드
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "=========================================================="
echo -e " 🚀  Jenkins All-in-One Custom Image Builder (v2.555.3)"
echo "=========================================================="

# 1. Tofu 버전 입력
read -p "🔹 OpenTofu 버전을 입력하세요 (기본값 1.6.0): " TOFU_VER
TOFU_VER="${TOFU_VER:-1.6.0}"

# 2. 설치할 CSP 선택
echo ""
echo "🔹 설치할 CSP 프로바이더를 선택하세요 (공백이나 쉼표로 구분):"
echo "   (사용 가능: aws, azure, vmware, openstack)"
read -p "입력 [기본값: aws]: " PROVIDERS_INPUT
PROVIDERS_INPUT="${PROVIDERS_INPUT:-aws}"

# 입력값 소문자 치환 및 쉼표 형식으로 정규화
PROVIDERS_LIST=$(echo "$PROVIDERS_INPUT" | tr ' ' ',' | tr '[:upper:]' '[:lower:]')

# 3. 플러그인 다운로드 진행
echo ""
echo "🔹 Jenkins 플러그인 다운로드 여부를 선택하세요:"
echo "  1) 새로 다운로드 (인터넷망 필요, plugins.txt 기반)"
echo "  2) 기존 다운로드 폴더 그대로 사용 (downloaded_plugins/)"
read -p "선택 [1/2, 기본값 2]: " PLUGINS_SEL
PLUGINS_SEL="${PLUGINS_SEL:-2}"

if [ "$PLUGINS_SEL" == "1" ]; then
    echo "🔄 [1/3] 플러그인 다운로드 시작 (jenkins-plugin-cli)..."
    rm -rf ./downloaded_plugins
    mkdir -p ./downloaded_plugins
    chmod 777 ./downloaded_plugins
    
    docker run --rm \
      -v "$(pwd)/plugins.txt:/tmp/plugins.txt" \
      -v "$(pwd)/downloaded_plugins:/usr/share/jenkins/ref/plugins" \
      jenkins/jenkins:2.555.3-jdk21 \
      jenkins-plugin-cli \
      --plugin-file /tmp/plugins.txt \
      --plugin-download-directory /usr/share/jenkins/ref/plugins \
      --verbose
    echo "   ✅ 플러그인 다운로드 완료."
else
    if [ ! -d "./downloaded_plugins" ] || [ -z "$(ls -A ./downloaded_plugins)" ]; then
        echo -e "${YELLOW}   ⚠️  downloaded_plugins 폴더가 비어 있습니다. 빈 상태로 빌드를 진행합니다.${NC}"
        mkdir -p ./downloaded_plugins
    else
        echo "   ✅ 기존 downloaded_plugins 폴더를 사용합니다."
    fi
fi

# 4. 이미지 빌드
echo ""
echo -e "🐳 [2/3] Custom Docker Image 빌드 중... (${GREEN}cmp-jenkins-full:2.555.3${NC})"
echo "   - OpenTofu: v$TOFU_VER"
echo "   - CSP: $PROVIDERS_LIST"
echo "----------------------------------------------------------"

docker build \
  --build-arg TOFU_VERSION="$TOFU_VER" \
  --build-arg PROVIDERS="$PROVIDERS_LIST" \
  -t cmp-jenkins-full:2.555.3 .

# 5. 이미지 저장
echo ""
echo -e "💾 [3/3] 빌드된 이미지를 tar 아카이브로 내보내는 중..."
docker save -o cmp-jenkins-full.tar cmp-jenkins-full:2.555.3

echo ""
echo "=========================================================="
echo -e "🎉 ${GREEN}[SUCCESS] Custom Image Build Completed!${NC}"
echo "출력 파일: ./jenkins-build/cmp-jenkins-full.tar"
echo "=========================================================="

# 6. 컴포넌트 images 디렉터리로 복사 제안
read -p "❓ 빌드된 tar 파일을 컴포넌트의 images/ 디렉터리로 이동시킬까요? (y/n, 기본 y): " MOVE_YN
if [[ "${MOVE_YN:-y}" =~ ^[Yy]$ ]]; then
    mkdir -p ../images
    mv ./cmp-jenkins-full.tar ../images/
    echo -e "   🚚 ${GREEN}../images/cmp-jenkins-full.tar${NC} 로 이동 완료."
fi
echo ""
