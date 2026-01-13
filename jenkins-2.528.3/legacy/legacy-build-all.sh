#!/bin/bash
set -e

echo "🚀 [Start] Jenkins All-in-One 폐쇄망 이미지 빌드 시작"

# 1. 플러그인 다운로드 (호환성 검증)
echo "🔄 [1/3] 플러그인 다운로드 중..."
mkdir -p ./downloaded_plugins
chmod 777 ./downloaded_plugins
rm -rf ./downloaded_plugins/*

# Jenkins CLI를 이용해 플러그인을 호스트 폴더로 다운로드
docker run --rm \
  -v $(pwd)/plugins.txt:/tmp/plugins.txt \
  -v $(pwd)/downloaded_plugins:/usr/share/jenkins/ref/plugins \
  jenkins/jenkins:2.528.3 \
  jenkins-plugin-cli \
  --plugin-file /tmp/plugins.txt \
  --plugin-download-directory /usr/share/jenkins/ref/plugins \
  --verbose

if [ -z "$(ls -A ./downloaded_plugins)" ]; then
    echo "❌ 실패: 다운로드된 플러그인이 없습니다."
    exit 1
fi

# 2. Docker 이미지 빌드
echo "🐳 [2/3] Docker 이미지 빌드 중 (Tools + Providers 포함)..."
docker build -t cmp-jenkins-full:2.528.3 .

# 3. 이미지 파일로 저장
echo "💾 [3/3] 이미지 tar 저장 중..."
docker save -o cmp-jenkins-full.tar cmp-jenkins-full:2.528.3

echo "🎉 [Success] 완료! 생성된 'cmp-jenkins-full.tar'를 사용하세요."
