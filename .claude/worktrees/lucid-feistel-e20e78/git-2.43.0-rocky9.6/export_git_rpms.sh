#!/bin/bash

# 1. 저장할 디렉토리 생성
DOWNLOAD_DIR="./git_offline_bundle"
mkdir -p $DOWNLOAD_DIR

# 기존 파일 정리
rm -rf $DOWNLOAD_DIR/*

echo "📦 Rocky Linux 9.6 환경에서 Git 패키지 추출을 시작합니다..."

# 2. 다운로드에 필요한 플러그인 확인 및 설치
if ! dnf list installed 'dnf-command(download)' > /dev/null 2>&1; then
    echo "🔧 download 플러그인 설치 중..."
    sudo dnf install -y 'dnf-command(download)'
fi

# 3. Git 및 의존성 다운로드
# --resolve: 의존성 해결
# --alldeps: 모든 의존성 포함
# --destdir: 저장 경로
echo "⬇️  패키지 다운로드 중..."
sudo dnf download --resolve --alldeps --destdir=$DOWNLOAD_DIR git

# 4. (선택사항) 자주 쓰이는 도구들도 같이 받기 (필요 없으면 주석 처리)
# 폐쇄망에서는 zip, unzip, tar, net-tools, curl도 종종 없어서 고생하므로 같이 받으면 좋습니다.
sudo dnf download --resolve --alldeps --destdir=$DOWNLOAD_DIR zip unzip tar net-tools curl wget

# 5. 결과 확인 및 압축
FILE_COUNT=$(ls $DOWNLOAD_DIR/*.rpm 2>/dev/null | wc -l)

if [ "$FILE_COUNT" -gt 0 ]; then
    echo "------------------------------------------------"
    echo "✅ 추출 성공! 총 $FILE_COUNT 개의 RPM 파일 확보."
    
    # 압축 파일명에 날짜 포함
    TAR_NAME="git_bundle_rocky96_$(date +%Y%m%d).tar.gz"
    tar -czf $TAR_NAME $DOWNLOAD_DIR
    
    echo "💾 압축 파일: $TAR_NAME"
    echo "🚀 이 파일을 로컬로 가져온 뒤, 폐쇄망 서버로 옮기세요."
    echo "------------------------------------------------"
else
    echo "❌ 다운로드된 파일이 없습니다. 인터넷 연결이나 레포지토리를 확인하세요."
fi