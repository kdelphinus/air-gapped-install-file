#!/bin/bash

# Root 권한 체크
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

set -e

# 경로 설정
BASE_DIR=$(cd "$(dirname "$0")/.." && pwd)
RPM_DB_DIR="${BASE_DIR}/db/rpms"
RPM_COMMON_DIR="${BASE_DIR}/common/rpms"
DEB_DB_DIR="${BASE_DIR}/db/debs"
DEB_COMMON_DIR="${BASE_DIR}/common/debs"

# OS 감지
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID=$ID
    OS_LIKE=${ID_LIKE:-}
    OS_NAME=$NAME
else
    echo "OS 정보를 감지할 수 없습니다."
    exit 1
fi

is_rhel_like() {
    [[ "$OS_ID" =~ ^(rocky|rhel|centos|almalinux)$ ]] || [[ " ${OS_LIKE:-} " == *" rhel "* ]] || [[ " ${OS_LIKE:-} " == *" centos "* ]]
}

is_debian_like() {
    [[ "$OS_ID" =~ ^(ubuntu|debian)$ ]] || [[ " ${OS_LIKE:-} " == *" debian "* ]] || [[ " ${OS_LIKE:-} " == *" ubuntu "* ]]
}

echo "=========================================================="
echo " ⚠️  [안내] 본 스크립트는 현재 스크립트를 실행 중인 호스트 OS 버전을"
echo "    기준으로 설치 파일(RPM/DEB 및 의존성 패키지)을 다운로드합니다."
echo "    현재 감지된 OS: $OS_NAME ($OS_ID)"
echo "=========================================================="

# 1. Rocky/RHEL 계열
if is_rhel_like; then
    echo "📦 Rocky/RHEL 계열 MariaDB 패키지 다운로드 진행..."
    mkdir -p "$RPM_DB_DIR" "$RPM_COMMON_DIR"

    # dnf/yum 플러그인 확인
    if command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    else
        PKG_MGR="yum"
    fi

    if ! $PKG_MGR list installed 'dnf-command(download)' >/dev/null 2>&1 && ! command -v yumdownloader >/dev/null 2>&1; then
        echo "🔧 download 플러그인 설치 중..."
        sudo $PKG_MGR install -y 'dnf-command(download)' || sudo $PKG_MGR install -y yum-utils
    fi

    # MariaDB 임시 YUM 레포지토리 등록
    TEMP_MARIADB_REPO=false
    if [ ! -f /etc/yum.repos.d/mariadb.repo ]; then
        echo "🔌 MariaDB 10.11 임시 레포지토리 등록..."
        # OS 메이저 버전 확인 (Rocky 9.x면 rhel9, 8.x면 rhel8)
        OS_MAJOR=$(echo "$VERSION_ID" | cut -d. -f1)
        OS_MAJOR="${OS_MAJOR:-9}"

        cat <<EOF | sudo tee /etc/yum.repos.d/mariadb.repo
[mariadb]
name = MariaDB
baseurl = https://dlm.mariadb.com/repo/mariadb-server/10.11/yum/rhel/${OS_MAJOR}/x86_64
gpgkey = https://supplychain.mariadb.com/MariaDB-Server-GPG-KEY
gpgcheck = 1
enabled = 1
EOF
        TEMP_MARIADB_REPO=true
    fi

    echo "⬇️  MariaDB RPM 패키지 다운로드 중..."
    # 1) MariaDB 주요 패키지 다운로드
    sudo $PKG_MGR download --resolve --alldeps --destdir="$RPM_DB_DIR" \
        MariaDB-server MariaDB-client MariaDB-common MariaDB-shared galera-4

    # 2) 필수 공통 의존성 패키지 다운로드
    echo "⬇️  필수 시스템 의존성 RPM 패키지 다운로드 중..."
    sudo $PKG_MGR download --resolve --alldeps --destdir="$RPM_COMMON_DIR" \
        socat rsync tar lsof

    # 임시 레포지토리 제거
    if [ "$TEMP_MARIADB_REPO" = true ]; then
        echo "🧹 임시 레포지토리 파일 제거..."
        sudo rm -f /etc/yum.repos.d/mariadb.repo
    fi

    echo "✅ RPM 다운로드 완료: $RPM_DB_DIR 및 $RPM_COMMON_DIR"

# 2. Ubuntu/Debian 계열
elif is_debian_like; then
    echo "📦 Ubuntu/Debian 계열 MariaDB 패키지 다운로드 진행..."
    mkdir -p "$DEB_DB_DIR" "$DEB_COMMON_DIR"

    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends \
        apt-transport-https ca-certificates curl gnupg lsb-release apt-rdepends >/dev/null

    # MariaDB 공식 APT 레포지토리 임시 등록
    MARIADB_LIST="/etc/apt/sources.list.d/mariadb.list"
    TEMP_APT_ADDED=false
    if [ ! -f "$MARIADB_LIST" ]; then
        echo "🔌 MariaDB 10.11 임시 APT 레포지토리 등록..."
        sudo mkdir -p /etc/apt/keyrings
        sudo curl -fsSL https://mariadb.org/mariadb_release_key | sudo gpg --dearmor -o /etc/apt/keyrings/mariadb.gpg
        CODENAME=$(lsb_release -cs)
        MARIADB_APT_OS="ubuntu"
        if [ "$OS_ID" = "debian" ]; then
            MARIADB_APT_OS="debian"
        fi
        echo "deb [signed-by=/etc/apt/keyrings/mariadb.gpg] https://dlm.mariadb.com/repo/mariadb-server/10.11/repo/${MARIADB_APT_OS} ${CODENAME} main" | sudo tee "$MARIADB_LIST" > /dev/null
        sudo apt-get update -qq
        TEMP_APT_ADDED=true
    fi

    echo "⬇️  MariaDB DEB 패키지 다운로드 중..."
    PKGS=(mariadb-server mariadb-client)
    UTIL_PKGS=(socat rsync tar lsof)

    # 1) MariaDB 패키지 및 의존성 다운로드
    cd "$DEB_DB_DIR"
    rm -f *.deb
    for PKG in "${PKGS[@]}"; do
        DEPS=$(apt-rdepends "$PKG" 2>/dev/null | grep -v "^ " | grep -Ev "^(debconf-2.0|awk|cron-daemon|mail-transport-agent)$" || true)
        for DEP in $DEPS; do
            if ls "${DEP}"_*.deb >/dev/null 2>&1; then continue; fi
            sudo apt-get download "$DEP" 2>/dev/null || true
        done
        sudo apt-get download "$PKG"
    done

    # 2) 공통 유틸 패키지 다운로드
    cd "$DEB_COMMON_DIR"
    rm -f *.deb
    for PKG in "${UTIL_PKGS[@]}"; do
        DEPS=$(apt-rdepends "$PKG" 2>/dev/null | grep -v "^ " | grep -Ev "^(debconf-2.0|awk|cron-daemon|mail-transport-agent)$" || true)
        for DEP in $DEPS; do
            if ls "${DEP}"_*.deb >/dev/null 2>&1; then continue; fi
            sudo apt-get download "$DEP" 2>/dev/null || true
        done
        sudo apt-get download "$PKG"
    done
    cd "$BASE_DIR"

    # 임시 레포지토리 제거
    if [ "$TEMP_APT_ADDED" = true ]; then
        sudo rm -f "$MARIADB_LIST"
        sudo apt-get update -qq >/dev/null 2>&1 || true
    fi

    echo "✅ DEB 다운로드 완료: $DEB_DB_DIR 및 $DEB_COMMON_DIR"
else
    echo "❌ 지원되지 않는 OS입니다. Rocky Linux 또는 Ubuntu 호스트에서 실행해주세요."
    exit 1
fi

echo "🎉 MariaDB 오프라인 에셋 다운로드 완료!"
