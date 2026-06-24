#!/bin/bash

# Root 권한 체크
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

set -e

# 버전 설정
DOCKER_STATIC_VERSION="29.1.5"

# 경로 설정
BASE_DIR=$(cd "$(dirname "$0")/.." && pwd)
RPM_DIR="${BASE_DIR}/rpm"
DEB_DIR="${BASE_DIR}/deb"
STATIC_DIR="${BASE_DIR}/static"

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

echo "다운로드 범위를 선택하세요:"
echo "  1) 전체 (OS 패키지 + Static Binary)"
echo "  2) OS 패키지만 (RPM 또는 DEB)"
echo "  3) Static Binary만"
read -p "선택 [1/2/3, 기본값: 1]: " DOWNLOAD_SCOPE
DOWNLOAD_SCOPE="${DOWNLOAD_SCOPE:-1}"

case "$DOWNLOAD_SCOPE" in
    1) DL_PKGS=true; DL_STATIC=true ;;
    2) DL_PKGS=true; DL_STATIC=false ;;
    3) DL_PKGS=false; DL_STATIC=true ;;
    *) echo "[오류] 올바른 옵션을 선택하세요."; exit 1 ;;
esac

# 1. OS 패키지 다운로드
if [ "$DL_PKGS" = true ]; then
    # Rocky/RHEL 계열
    if is_rhel_like; then
        echo ""
        echo "📦 Rocky/RHEL 계열 패키지 다운로드 진행..."
        mkdir -p "$RPM_DIR"

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

        # Docker CE Repo 추가
        TEMP_REPO_ADDED=false
        if [ ! -f /etc/yum.repos.d/docker-ce.repo ]; then
            echo "🔌 Docker CE 임시 레포지토리 등록..."
            if command -v yum-config-manager &>/dev/null; then
                sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            else
                sudo curl -fsSL https://download.docker.com/linux/centos/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo
            fi
            TEMP_REPO_ADDED=true
        fi

        echo "⬇️  Docker RPM 패키지 다운로드 중..."
        # Rocky 9.x / RHEL 9.x용 Docker RPM 및 의존성 다운로드
        sudo $PKG_MGR download --resolve --alldeps --destdir="$RPM_DIR" \
            docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        if [ "$TEMP_REPO_ADDED" = true ]; then
            echo "🧹 임시 레포지토리 파일 제거..."
            sudo rm -f /etc/yum.repos.d/docker-ce.repo
        fi

        echo "✅ RPM 다운로드 완료: $RPM_DIR"

    # Ubuntu/Debian 계열
    elif is_debian_like; then
        echo ""
        echo "📦 Ubuntu/Debian 계열 패키지 다운로드 진행..."
        mkdir -p "$DEB_DIR"

        sudo apt-get update -qq
        sudo apt-get install -y --no-install-recommends \
            apt-transport-https ca-certificates curl gnupg lsb-release apt-rdepends >/dev/null

        DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
        DOCKER_LIST="/etc/apt/sources.list.d/docker.list"
        sudo mkdir -p /etc/apt/keyrings
        DOCKER_APT_OS="ubuntu"
        if [ "$OS_ID" = "debian" ]; then
            DOCKER_APT_OS="debian"
        fi
        if [ ! -f "$DOCKER_KEYRING" ]; then
            sudo curl -fsSL "https://download.docker.com/linux/${DOCKER_APT_OS}/gpg" | sudo gpg --dearmor -o "$DOCKER_KEYRING"
        fi
        CODENAME=$(lsb_release -cs)
        echo "deb [arch=amd64 signed-by=${DOCKER_KEYRING}] https://download.docker.com/linux/${DOCKER_APT_OS} ${CODENAME} stable" | sudo tee "$DOCKER_LIST" > /dev/null
        sudo apt-get update -qq

        echo "⬇️  Docker DEB 패키지 다운로드 중..."
        PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
        cd "$DEB_DIR"
        # 기존 파일 정리
        rm -f *.deb
        for PKG in "${PKGS[@]}"; do
            echo "  → ${PKG} 의존성 수집 및 다운로드..."
            DEPS=$(apt-rdepends "$PKG" 2>/dev/null | grep -v "^ " | grep -Ev "^(debconf-2.0|awk|cron-daemon|mail-transport-agent)$" || true)
            for DEP in $DEPS; do
                if ls "${DEP}"_*.deb >/dev/null 2>&1; then
                    continue
                fi
                sudo apt-get download "$DEP" 2>/dev/null || echo "    ! ${DEP} 다운로드 실패 (skip)"
            done
            sudo apt-get download "$PKG"
        done
        cd "$BASE_DIR"

        sudo rm -f "$DOCKER_LIST"
        sudo apt-get update -qq >/dev/null 2>&1 || true
        echo "✅ DEB 다운로드 완료: $DEB_DIR"
    else
        echo "❌ 지원되지 않는 OS입니다. Rocky Linux 또는 Ubuntu 호스트에서 실행해주세요."
        exit 1
    fi
fi

# 2. Static Binary 다운로드
if [ "$DL_STATIC" = true ]; then
    echo ""
    echo "⬇️  Docker Static Binary 다운로드 중..."
    mkdir -p "$STATIC_DIR"
    STATIC_TGZ="docker-${DOCKER_STATIC_VERSION}.tgz"
    if [ ! -f "${STATIC_DIR}/${STATIC_TGZ}" ]; then
        curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/${STATIC_TGZ}" -o "${STATIC_DIR}/${STATIC_TGZ}"
        echo "✅ Static Binary 다운로드 완료: ${STATIC_DIR}/${STATIC_TGZ}"
    else
        echo "ℹ️  이미 파일이 존재하여 다운로드를 건너뜁니다: ${STATIC_DIR}/${STATIC_TGZ}"
    fi
fi

echo ""
echo "🎉 Docker 오프라인 에셋 다운로드 완료!"
