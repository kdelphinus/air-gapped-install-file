#!/bin/bash
set -e

echo "🚀 [Start] Jenkins All-in-One 이미지 빌드 (Config Fix Ver)"

# 1. 플러그인 다운로드 (이미 다운로드 되어 있다면 건너뛰어도 됨)
if [ ! -d "./downloaded_plugins" ] || [ -z "$(ls -A ./downloaded_plugins)" ]; then
    echo "🔄 [1/3] 플러그인 다운로드 시작..."
    mkdir -p ./downloaded_plugins
    chmod 777 ./downloaded_plugins
    
    docker run --rm \
      -v $(pwd)/plugins.txt:/tmp/plugins.txt \
      -v $(pwd)/downloaded_plugins:/usr/share/jenkins/ref/plugins \
      jenkins/jenkins:2.528.3 \
      jenkins-plugin-cli \
      --plugin-file /tmp/plugins.txt \
      --plugin-download-directory /usr/share/jenkins/ref/plugins \
      --verbose
else
    echo "✅ [1/3] 플러그인 폴더가 이미 존재하므로 다운로드를 생략합니다."
fi

# 2. Docker 이미지 빌드
echo "🐳 [2/3] Docker 이미지 빌드 중: cmp-jenkins-full:2.528.3"
docker build -t cmp-jenkins-full:2.528.3 .

# 3. 이미지 저장
echo "💾 [3/3] 이미지 tar 저장 중..."
docker save -o cmp-jenkins-full.tar cmp-jenkins-full:2.528.3

echo "🎉 [Success] 빌드 완료! cmp-jenkins-full.tar 파일이 생성되었습니다."
