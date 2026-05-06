#!/bin/bash

# 1. 저장할 디렉토리 생성
DOWNLOAD_DIR="./basic_tools_bundle_ubuntu"
mkdir -p $DOWNLOAD_DIR

# 기존 파일 정리
rm -rf $DOWNLOAD_DIR/*

echo "📦 Ubuntu 24.04 환경에서 기본 도구 패키지 추출을 시작합니다..."

# 2. 도구 목록 정의
TOOLS="curl wget zip unzip tar net-tools dnsutils vim telnet lsof rsync jq"

echo "⬇️  패키지 및 의존성 다운로드 중..."

# 의존성까지 한꺼번에 다운로드하기 위한 함수
download_with_deps() {
    local pkg=$1
    echo "🔎 $pkg 의존성 확인 중..."
    
    # apt-get download는 의존성을 자동으로 받지 않으므로, 
    # apt-rdepends가 없으면 단순 apt-cache depends를 활용하여 목록 추출
    DEPS=$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances $pkg | grep "^\w" | sort -u)
    
    for dep in $DEPS; do
        apt-get download $dep 2>/dev/null
    done
    apt-get download $pkg 2>/dev/null
}

cd $DOWNLOAD_DIR

for tool in $TOOLS; do
    echo "🚚 $tool 다운로드 시작..."
    # 단순 다운로드 (시스템에 이미 최신이면 안받아질 수 있으므로 --reinstall 스타일은 불가하지만 download는 가능)
    # 의존성을 완벽하게 추적하려면 복잡하므로, 주요 패키지 위주로 먼저 시도
    apt-get download $(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances $tool | grep "^\w" | sort -u) $tool 2>/dev/null
done

# 3. 결과 확인 및 압축
cd ..
FILE_COUNT=$(ls $DOWNLOAD_DIR/*.deb 2>/dev/null | wc -l)

if [ "$FILE_COUNT" -gt 0 ]; then
    echo "------------------------------------------------"
    echo "✅ 추출 성공! 총 $FILE_COUNT 개의 DEB 파일 확보."
    
    # 압축 파일명
    TAR_NAME="basic_tools_ubuntu2404_$(date +%Y%m%d).tar.gz"
    tar -czf $TAR_NAME $DOWNLOAD_DIR
    
    echo "💾 압축 파일: $TAR_NAME"
    echo "------------------------------------------------"
else
    echo "❌ 다운로드된 파일이 없습니다. 인터넷 연결이나 저장소를 확인하세요."
fi
