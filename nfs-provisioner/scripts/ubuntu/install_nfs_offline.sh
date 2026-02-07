#!/bin/bash
# [폐쇄망] 내부 우분투 서버에서 실행하세요.
# download_nfs_offline.sh로 받은 nfs-packages 폴더가 필요합니다.

set -e

PKG_DIR="./nfs-packages"

if [ ! -d "$PKG_DIR" ]; then
    echo "오류: '$PKG_DIR' 디렉토리가 없습니다. 압축을 풀거나 경로를 확인하세요."
    exit 1
fi

echo "=== [Ubuntu] NFS 패키지 오프라인 설치 시작 ==="
cd "$PKG_DIR"

# dpkg로 설치
# 의존성 순서 문제가 있을 수 있으므로 한 번에 지정
sudo dpkg -i *.deb

# 의존성 오류 발생 시 (보통 오프라인이라 apt --fix-broken install은 안되지만,
# 다운로드 스크립트가 의존성을 잘 챙겼다면 dpkg가 처리함)
if [ $? -ne 0 ]; then
    echo "설치 중 오류가 발생했습니다. 의존성 누락을 확인하세요."
    exit 1
fi

echo "=== 설치 완료 ==="
echo "NFS 서비스 상태 확인:"
systemctl status nfs-server --no-pager
