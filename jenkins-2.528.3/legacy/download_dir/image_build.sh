#!/bin/bash

# 1. 다운로드 디렉토리 생성 및 초기화
mkdir -p ./downloaded_plugins
# [중요] 컨테이너 내부의 jenkins 유저가 쓸 수 있도록 권한 부여 (또는 chown 1000:1000 사용)
chmod 777 ./downloaded_plugins 
rm -rf ./downloaded_plugins/*

echo "🔄 플러그인 다운로드를 시작합니다..."

# 2. Docker를 이용한 플러그인 다운로드 실행
# 수정사항: --output 대신 --plugin-download-directory (-d) 사용
docker run --rm \
   -v $(pwd)/plugins.txt:/tmp/plugins.txt \
   -v $(pwd)/downloaded_plugins:/usr/share/jenkins/ref/plugins \
   jenkins/jenkins:2.528.3 \
   jenkins-plugin-cli \
      --plugin-file /tmp/plugins.txt \
      --plugin-download-directory /usr/share/jenkins/ref/plugins \
      --verbose

# 3. 다운로드 결과 확인 (파일이 없으면 빌드 중단)
if [ -z "$(ls -A ./downloaded_plugins)" ]; then
   echo "❌ 플러그인 다운로드 실패: 디렉토리가 비어 있습니다."
   exit 1
else
   echo "✅ 플러그인 다운로드 완료."
fi

sleep 5

# 4. Docker 이미지 빌드 및 저장
echo "🐳 Docker 이미지를 빌드합니다..."
docker build -t cmp-jenkins:2.528.3 .

echo "💾 이미지를 tar 파일로 저장합니다..."
docker save -o cmp-jenkins-2.528.3.tar cmp-jenkins:2.528.3

echo "🎉 모든 작업이 완료되었습니다."