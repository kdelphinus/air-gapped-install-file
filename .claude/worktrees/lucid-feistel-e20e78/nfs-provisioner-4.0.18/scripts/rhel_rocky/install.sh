#!/bin/bash
# [폐쇄망] 내부 Rocky/RHEL 서버에서 실행하세요.

set -e

PKG_DIR="./nfs-packages"

if [ ! -d "$PKG_DIR" ]; then
    echo "오류: '$PKG_DIR' 디렉토리가 없습니다."
    exit 1
fi

echo "=== [Rocky/RHEL] NFS 패키지 오프라인 설치 시작 ==="
cd "$PKG_DIR"

if command -v dnf &> /dev/null; then
    PKG_MGR="dnf"
else
    PKG_MGR="yum"
fi

# localinstall 사용 (의존성 관계를 알아서 정리해줌)
# --nogpgcheck: Rocky에서 받은 패키지를 RHEL에 설치하거나 그 반대의 경우 GPG 키 오류를 무시하기 위함
sudo $PKG_MGR localinstall -y *.rpm --nogpgcheck

echo "=== 설치 완료 ==="
echo "NFS 서비스 활성화 및 시작..."
sudo systemctl enable --now nfs-server

echo "상태 확인:"
systemctl status nfs-server --no-pager
