#!/bin/bash

# 패키지 디렉토리
DEB_DIR="./basic_tools_bundle_ubuntu"

if [ ! -d "$DEB_DIR" ]; then
    echo "❌ 오류: $DEB_DIR 디렉토리를 찾을 수 없습니다."
    exit 1
fi

echo "📦 Ubuntu 기본 도구 설치를 시작합니다..."

# dpkg를 사용하여 설치
# -i: 설치
# -R: 재귀적 (디렉토리 내 모든 파일)
sudo dpkg -i $DEB_DIR/*.deb

# 의존성 문제가 발생할 경우를 대비해 -f install 실행 (하지만 오프라인이므로 의미가 적을 수 있음)
# sudo apt-get install -f -y

if [ $? -eq 0 ]; then
    echo "------------------------------------------------"
    echo "✅ 설치가 완료되었습니다."
    echo "------------------------------------------------"
else
    echo "⚠️  일부 패키지 설치 중 의존성 경고가 발생했을 수 있습니다."
    echo "    dpkg -i 를 다시 실행하거나 누락된 패키지를 확인하세요."
fi
