#!/bin/bash

# Root 권한 체크
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

set -e

# 버전 설정
K8S_VERSION="v1.30.0"
K8S_RPM_VERSION="1.30.0"
K8S_DEB_VERSION="1.30.0-1.1"
K8S_REPO_MINOR="v1.30"
HELM_VERSION="v3.14.0"
NERDCTL_VERSION="2.2.2"
CRI_DOCKERD_VERSION="0.3.10"
LOCAL_PATH_VERSION="v0.0.35"
CALICO_VERSION="v3.27.0"

# 경로 설정
BASE_DIR=$(cd "$(dirname "$0")/.." && pwd)
K8S_DIR="${BASE_DIR}/k8s"
RPM_DIR="${K8S_DIR}/rpms"
COMMON_RPM_DIR="${BASE_DIR}/common/rpms"
DEB_DIR="${K8S_DIR}/debs"
COMMON_DEB_DIR="${BASE_DIR}/common/debs"
BIN_DIR="${K8S_DIR}/binaries"
IMG_DIR="${K8S_DIR}/images"
UTIL_DIR="${K8S_DIR}/utils"

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
echo "  1) 전체 (OS 패키지 + 바이너리 + 컨테이너 이미지)"
echo "  2) OS 패키지만"
echo "  3) 바이너리 + 컨테이너 이미지만"
read -p "선택 [1/2/3, 기본값: 1]: " DOWNLOAD_SCOPE
DOWNLOAD_SCOPE="${DOWNLOAD_SCOPE:-1}"

case "$DOWNLOAD_SCOPE" in
    1) DL_PKGS=true; DL_BINS=true; DL_IMGS=true ;;
    2) DL_PKGS=true; DL_BINS=false; DL_IMGS=false ;;
    3) DL_PKGS=false; DL_BINS=true; DL_IMGS=true ;;
    *) echo "[오류] 올바른 옵션을 선택하세요."; exit 1 ;;
esac

# 1. OS 패키지 다운로드
if [ "$DL_PKGS" = true ]; then
    # Rocky/RHEL 계열
    if is_rhel_like; then
        echo ""
        echo "📦 [1/4] Rocky/RHEL 계열 패키지 다운로드 진행..."
        mkdir -p "$RPM_DIR" "$COMMON_RPM_DIR"

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

        # Kubernetes 레포지토리 등록
        TEMP_K8S_REPO=false
        if [ ! -f /etc/yum.repos.d/kubernetes.repo ]; then
            echo "🔌 Kubernetes 임시 레포지토리 등록..."
            cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
            TEMP_K8S_REPO=true
        fi

        # Docker CE (containerd.io 용) 레포지토리 등록
        TEMP_DOCKER_REPO=false
        if [ ! -f /etc/yum.repos.d/docker-ce.repo ]; then
            echo "🔌 Docker CE 임시 레포지토리 등록..."
            if command -v yum-config-manager &>/dev/null; then
                sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            else
                sudo curl -fsSL https://download.docker.com/linux/centos/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo
            fi
            TEMP_DOCKER_REPO=true
        fi

        echo "⬇️  Kubernetes RPM 패키지 다운로드 중..."
        # 1) k8s 코어 패키지 다운로드
        sudo $PKG_MGR download --resolve --alldeps --disableexcludes=kubernetes --destdir="$RPM_DIR" \
            kubelet-"${K8S_RPM_VERSION}" kubeadm-"${K8S_RPM_VERSION}" kubectl-"${K8S_RPM_VERSION}" containerd.io

        # 2) 필수 공통 유틸 패키지 다운로드
        echo "⬇️  필수 시스템 의존성 RPM 패키지 다운로드 중..."
        sudo $PKG_MGR download --resolve --alldeps --destdir="$COMMON_RPM_DIR" \
            socat conntrack-tools ebtables ipset jq chrony haproxy keepalived psmisc

        # 임시 레포지토리 제거
        if [ "$TEMP_K8S_REPO" = true ]; then
            sudo rm -f /etc/yum.repos.d/kubernetes.repo
        fi
        if [ "$TEMP_DOCKER_REPO" = true ]; then
            sudo rm -f /etc/yum.repos.d/docker-ce.repo
        fi

        echo "✅ RPM 다운로드 완료: $RPM_DIR 및 $COMMON_RPM_DIR"

    # Ubuntu/Debian 계열
    elif is_debian_like; then
        echo ""
        echo "📦 [1/4] Ubuntu/Debian 계열 패키지 다운로드 진행..."
        mkdir -p "$DEB_DIR" "$COMMON_DEB_DIR"

        sudo apt-get update -qq
        sudo apt-get install -y --no-install-recommends \
            apt-transport-https ca-certificates curl gnupg lsb-release apt-rdepends >/dev/null

        # K8s repo 등록
        K8S_KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
        K8S_LIST="/etc/apt/sources.list.d/kubernetes.list"
        sudo mkdir -p /etc/apt/keyrings
        if [ ! -f "$K8S_KEYRING" ]; then
            sudo curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/deb/Release.key" | sudo gpg --dearmor -o "$K8S_KEYRING"
        fi
        echo "deb [signed-by=${K8S_KEYRING}] https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/deb/ /" | sudo tee "$K8S_LIST" > /dev/null

        # Docker CE repo 등록
        DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
        DOCKER_LIST="/etc/apt/sources.list.d/docker.list"
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

        # 패키지 다운로드
        FIXED_PKGS=(
            "kubelet=${K8S_DEB_VERSION}"
            "kubeadm=${K8S_DEB_VERSION}"
            "kubectl=${K8S_DEB_VERSION}"
            "cri-tools"
            "containerd.io"
        )
        UTIL_PKGS=(
            conntrack socat ebtables ipset jq chrony haproxy keepalived psmisc
        )

        # K8s 관련 패키지 의존성 다운로드
        cd "$DEB_DIR"
        rm -f *.deb
        for PKG in "${FIXED_PKGS[@]}"; do
            PKG_NAME="${PKG%%=*}"
            DEPS=$(apt-rdepends "$PKG_NAME" 2>/dev/null | grep -v "^ " | grep -Ev "^(debconf-2.0|awk|cron-daemon|mail-transport-agent)$" || true)
            for DEP in $DEPS; do
                if ls "${DEP}"_*.deb >/dev/null 2>&1; then continue; fi
                sudo apt-get download "$DEP" 2>/dev/null || true
            done
            sudo apt-get download "$PKG"
        done

        # 공통 유틸 패키지 다운로드
        cd "$COMMON_DEB_DIR"
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

        # 레포지토리 정리
        sudo rm -f "$K8S_LIST" "$DOCKER_LIST"
        sudo apt-get update -qq >/dev/null 2>&1 || true
        echo "✅ DEB 다운로드 완료: $DEB_DIR 및 $COMMON_DEB_DIR"
    else
        echo "❌ 지원되지 않는 OS입니다. Rocky Linux 또는 Ubuntu 호스트에서 실행해주세요."
        exit 1
    fi
fi

# 2. 바이너리 다운로드
if [ "$DL_BINS" = true ]; then
    echo ""
    echo "📦 [2/4] 외부 바이너리(Helm, nerdctl, cri-dockerd) 다운로드 중..."
    mkdir -p "$BIN_DIR"

    # Helm
    HELM_TGZ="helm-${HELM_VERSION}-linux-amd64.tar.gz"
    if [ ! -f "${BIN_DIR}/${HELM_TGZ}" ]; then
        curl -fsSL "https://get.helm.sh/${HELM_TGZ}" -o "${BIN_DIR}/${HELM_TGZ}"
        echo "  → Helm 완료"
    fi

    # nerdctl-full
    NERDCTL_TGZ="nerdctl-full-${NERDCTL_VERSION}-linux-amd64.tar.gz"
    if [ ! -f "${BIN_DIR}/${NERDCTL_TGZ}" ]; then
        curl -fsSL "https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/${NERDCTL_TGZ}" -o "${BIN_DIR}/${NERDCTL_TGZ}"
        echo "  → nerdctl-full 완료"
    fi

    # cri-dockerd
    CRI_TGZ="cri-dockerd-${CRI_DOCKERD_VERSION}.amd64.tgz"
    if [ ! -f "${BIN_DIR}/${CRI_TGZ}" ]; then
        curl -fsSL "https://github.com/Mirantis/cri-dockerd/releases/download/v${CRI_DOCKERD_VERSION}/${CRI_TGZ}" -o "${BIN_DIR}/${CRI_TGZ}"
        echo "  → cri-dockerd 완료"
    fi
fi

# 3. 매니페스트 다운로드
if [ "$DL_BINS" = true ]; then
    echo ""
    echo "📄 [3/4] 매니페스트 다운로드 중..."
    mkdir -p "$UTIL_DIR"

    # Calico 매니페스트
    curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" -o "${UTIL_DIR}/calico.yaml"
    echo "  → Calico 매니페스트 완료"

    # Rancher Local Path Storage
    curl -fsSL "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml" -o "${UTIL_DIR}/local-path-storage.yaml"
    echo "  → Local Path Storage 완료"
fi

# 4. 컨테이너 이미지 다운로드
if [ "$DL_IMGS" = true ]; then
    echo ""
    echo "🚀 [4/4] 컨테이너 이미지 다운로드 및 저장 중..."
    mkdir -p "$IMG_DIR"

    # Local CLI 감지
    if command -v docker >/dev/null 2>&1; then
        CLI="docker"
    elif command -v ctr >/dev/null 2>&1; then
        CLI="ctr"
    else
        echo "⚠️  이미지 pull을 위해 docker 또는 ctr(containerd)이 필요합니다. 먼저 설치를 완료하세요."
        exit 1
    fi

    # 다운로드할 이미지 목록
    IMAGES=(
        "registry.k8s.io/kube-apiserver:${K8S_VERSION}"
        "registry.k8s.io/kube-controller-manager:${K8S_VERSION}"
        "registry.k8s.io/kube-scheduler:${K8S_VERSION}"
        "registry.k8s.io/kube-proxy:${K8S_VERSION}"
        "registry.k8s.io/pause:3.9"
        "registry.k8s.io/etcd:3.5.12-0"
        "registry.k8s.io/coredns/coredns:v1.10.1"
        "docker.io/rancher/local-path-provisioner:${LOCAL_PATH_VERSION}"
        "docker.io/calico/cni:${CALICO_VERSION}"
        "docker.io/calico/node:${CALICO_VERSION}"
        "docker.io/calico/kube-controllers:${CALICO_VERSION}"
    )

    for IMG in "${IMAGES[@]}"; do
        # 파일명으로 적절하게 변환
        FILENAME=$(echo "$IMG" | sed -E 's#^(docker\.io|quay\.io|registry\.k8s\.io)/##' | tr ':/' '-')
        TAR_PATH="${IMG_DIR}/${FILENAME}.tar"

        echo "   → 저장 예정 경로: ${TAR_PATH}"
        rm -f "$TAR_PATH"

        if [ "$CLI" = "docker" ]; then
            echo "     └─ [docker] pulling: $IMG"
            docker pull "$IMG"
            echo "     └─ [docker] exporting to tar..."
            docker save -o "$TAR_PATH" "$IMG"
        elif [ "$CLI" = "ctr" ]; then
            echo "     └─ [ctr] pulling (k8s.io namespace): $IMG"
            sudo ctr -n k8s.io images pull "$IMG"
            echo "     └─ [ctr] exporting to tar..."
            sudo ctr -n k8s.io images export "$TAR_PATH" "$IMG"
        fi

        if [ $? -eq 0 ] && [ -f "$TAR_PATH" ]; then
            echo "     ✅ 성공: $(basename "$TAR_PATH")"
        else
            echo "     ❌ 실패: $IMG"
            exit 1
        fi
    done
fi

echo ""
echo "🎉 Kubernetes ${K8S_VERSION} 오프라인 에셋 다운로드 완료!"
