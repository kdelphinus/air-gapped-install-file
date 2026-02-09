#!/bin/bash

# 1. 저장할 디렉토리 생성
DOWNLOAD_DIR="./basic_tools_bundle"
mkdir -p $DOWNLOAD_DIR

# 기존 파일 정리
rm -rf $DOWNLOAD_DIR/*

echo "📦 Rocky Linux 9.6 환경에서 기본 도구 패키지 추출을 시작합니다..."

# 2. 다운로드에 필요한 플러그인 확인 및 설치
if ! dnf list installed 'dnf-command(download)' > /dev/null 2>&1; then
    echo "🔧 download 플러그인 설치 중..."
    sudo dnf install -y 'dnf-command(download)'
fi

# 3. 도구 목록 정의
# curl, wget: 파일 다운로드
# zip, unzip, tar: 압축 관리
# net-tools: ifconfig, netstat 등 네트워크 확인
# bind-utils: dig, nslookup 등 DNS 확인
# vim: 에디터
# telnet: 포트 연결 확인
# lsof: 열린 파일/포트 확인
TOOLS="curl wget zip unzip tar net-tools bind-utils vim telnet lsof rsync jq"

echo "⬇️  패키지 다운로드 중: $TOOLS"

# --resolve: 의존성 해결
# --alldeps: 모든 의존성 포함
# --destdir: 저장 경로
sudo dnf download --resolve --alldeps --destdir=$DOWNLOAD_DIR $TOOLS

# 4. 결과 확인 및 압축
FILE_COUNT=$(ls $DOWNLOAD_DIR/*.rpm 2>/dev/null | wc -l)

if [ "$FILE_COUNT" -gt 0 ]; then
    echo "------------------------------------------------"
    echo "✅ 추출 성공! 총 $FILE_COUNT 개의 RPM 파일 확보."
    
    # 압축 파일명에 날짜 포함
    TAR_NAME="basic_tools_rocky96_$(date +%Y%m%d).tar.gz"
    tar -czf $TAR_NAME $DOWNLOAD_DIR
    
    echo "💾 압축 파일: $TAR_NAME"
    echo "🚀 이 파일을 로컬로 가져온 뒤, 폐쇄망 서버로 옮기세요."
    echo "------------------------------------------------"
else
    echo "❌ 다운로드된 파일이 없습니다. 인터넷 연결이나 레포지토리를 확인하세요."
fi
