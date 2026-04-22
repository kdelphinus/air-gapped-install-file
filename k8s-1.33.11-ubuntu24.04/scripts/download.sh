#!/bin/bash

# ==========================================
# k8s-1.33.11-ubuntu24.04 오프라인 설치 파일 다운로드 스크립트
#   - 인터넷 연결 호스트(Ubuntu 24.04)에서 실행
#   - 실행 결과: k8s/{debs,binaries,images,utils} 를 채움
# ==========================================

# Root 권한 체크 (APT repo 등록, ctr 사용 필요)
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

set -e

# ── 버전 설정 (변경 시 여기만 수정) ────────────────────────────
K8S_VERSION="v1.33.11"
K8S_DEB_VERSION="1.33.11-1.1"     # pkgs.k8s.io DEB 버전 포맷
K8S_REPO_MINOR="v1.33"             # pkgs.k8s.io 경로용 (마이너 버전)
CONTAINERD_VERSION=""              # 비우면 Docker CE repo 최신, 고정 시 예: "2.3.0-1"
HELM_VERSION="v3.20.2"
NERDCTL_VERSION="2.2.2"            # nerdctl-full tar 파일명 기준 (v 없음)
CALICO_VERSION="v3.31.0"

# ── 경로 설정 ────────────────────────────────────────────────
BASE_DIR=$(cd "$(dirname "$0")/.." && pwd)
K8S_DIR="${BASE_DIR}/k8s"
DEB_DIR="${K8S_DIR}/debs"
BIN_DIR="${K8S_DIR}/binaries"
IMG_DIR="${K8S_DIR}/images"
UTIL_DIR="${K8S_DIR}/utils"

mkdir -p "$DEB_DIR" "$BIN_DIR" "$IMG_DIR" "$UTIL_DIR"

echo "============================================================"
echo " k8s ${K8S_VERSION} / Calico ${CALICO_VERSION} 파일 다운로드"
echo " 대상 디렉토리: ${K8S_DIR}"
echo "============================================================"

# ==========================================
# [1/6] APT repo 임시 등록 (Kubernetes + Docker CE)
# ==========================================
echo ""
echo "[1/6] APT repo 임시 등록..."

# 사전 필수 패키지
apt-get update -qq
apt-get install -y --no-install-recommends \
    apt-transport-https ca-certificates curl gpg \
    gnupg lsb-release apt-rdepends >/dev/null

# Kubernetes repo (pkgs.k8s.io)
K8S_KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
K8S_LIST="/etc/apt/sources.list.d/kubernetes.list"
mkdir -p /etc/apt/keyrings
if [ ! -f "$K8S_KEYRING" ]; then
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/deb/Release.key" | \
        gpg --dearmor -o "$K8S_KEYRING"
fi
echo "deb [signed-by=${K8S_KEYRING}] https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/deb/ /" \
    > "$K8S_LIST"

# Docker CE repo (containerd.io 제공)
DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
DOCKER_LIST="/etc/apt/sources.list.d/docker.list"
if [ ! -f "$DOCKER_KEYRING" ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o "$DOCKER_KEYRING"
fi
UBUNTU_CODENAME=$(lsb_release -cs)
echo "deb [arch=amd64 signed-by=${DOCKER_KEYRING}] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
    > "$DOCKER_LIST"

apt-get update -qq
echo "  → repo 등록 완료 (kubernetes.list / docker.list)"

# ==========================================
# [2/6] DEB 다운로드 (kubeadm + 유틸 + 의존성)
# ==========================================
echo ""
echo "[2/6] DEB 다운로드..."

# 버전 고정 패키지
FIXED_PKGS=(
    "kubelet=${K8S_DEB_VERSION}"
    "kubeadm=${K8S_DEB_VERSION}"
    "kubectl=${K8S_DEB_VERSION}"
    "cri-tools"
)

# containerd.io는 버전 변수 유무에 따라 분기
if [ -n "$CONTAINERD_VERSION" ]; then
    FIXED_PKGS+=("containerd.io=${CONTAINERD_VERSION}")
else
    FIXED_PKGS+=("containerd.io")
fi

# 시스템 유틸 (k8s 사전 요구 + HA 구성용)
UTIL_PKGS=(
    conntrack socat ebtables ipset
    jq chrony
    haproxy keepalived psmisc
)

ALL_PKGS=("${FIXED_PKGS[@]}" "${UTIL_PKGS[@]}")

# apt-rdepends 로 전체 의존성 그래프 수집
cd "$DEB_DIR"

# 기존 DEB 정리 (버전 혼동 방지)
rm -f "$DEB_DIR"/*.deb

for PKG in "${ALL_PKGS[@]}"; do
    PKG_NAME="${PKG%%=*}"
    echo "  → ${PKG_NAME} 의존성 수집 중..."
    # apt-rdepends 출력에서 실제 패키지명만 추출 (Depends: 라인 제외, 가상 패키지 필터)
    DEPS=$(apt-rdepends "$PKG_NAME" 2>/dev/null \
        | grep -v "^ " \
        | grep -Ev "^(debconf-2.0|awk|cron-daemon|mail-transport-agent)$" \
        || true)

    for DEP in $DEPS; do
        # 이미 다운로드된 것은 skip (파일 존재 기반)
        if ls "${DEP}"_*.deb >/dev/null 2>&1; then
            continue
        fi
        apt-get download "$DEP" 2>/dev/null || echo "    ! ${DEP} 다운로드 실패 (skip)"
    done
done

# 버전 고정 패키지는 명시적 재다운로드 (정확한 버전 확보)
for PKG in "${FIXED_PKGS[@]}"; do
    apt-get download "$PKG" 2>/dev/null || true
done

DEB_COUNT=$(ls -1 "$DEB_DIR"/*.deb 2>/dev/null | wc -l)
echo "  → DEB ${DEB_COUNT}개 수집 완료"

cd "$BASE_DIR"

# ==========================================
# [3/6] 바이너리 tarball (helm, nerdctl)
# ==========================================
echo ""
echo "[3/6] 바이너리 tarball 다운로드..."

# helm
HELM_TGZ="helm-${HELM_VERSION}-linux-amd64.tar.gz"
if [ ! -f "${BIN_DIR}/${HELM_TGZ}" ]; then
    echo "  → helm ${HELM_VERSION}"
    curl -fsSL "https://get.helm.sh/${HELM_TGZ}" -o "${BIN_DIR}/${HELM_TGZ}"
else
    echo "  → helm ${HELM_VERSION} (이미 존재, skip)"
fi

# nerdctl-full
NERDCTL_TGZ="nerdctl-full-${NERDCTL_VERSION}-linux-amd64.tar.gz"
if [ ! -f "${BIN_DIR}/${NERDCTL_TGZ}" ]; then
    echo "  → nerdctl-full v${NERDCTL_VERSION}"
    curl -fsSL "https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/${NERDCTL_TGZ}" \
        -o "${BIN_DIR}/${NERDCTL_TGZ}"
else
    echo "  → nerdctl-full v${NERDCTL_VERSION} (이미 존재, skip)"
fi

# ==========================================
# [4/6] 컨테이너 이미지 (k8s 코어 + Calico)
# ==========================================
echo ""
echo "[4/6] 컨테이너 이미지 다운로드..."

# containerd가 설치되어 있어야 ctr 사용 가능 — 임시 설치 확인
if ! command -v ctr >/dev/null 2>&1; then
    echo "  ! ctr 미존재 → containerd.io 임시 설치"
    apt-get install -y containerd.io >/dev/null
    systemctl enable --now containerd >/dev/null 2>&1 || true
fi

# kubeadm 바이너리도 필요 (images list 생성용)
if ! command -v kubeadm >/dev/null 2>&1; then
    apt-get install -y "kubeadm=${K8S_DEB_VERSION}" >/dev/null
fi

# k8s 코어 이미지 목록 동적 생성
K8S_IMAGES=$(kubeadm config images list --kubernetes-version="${K8S_VERSION}")

# Calico v3.31 이미지 (Tigera Operator 방식)
CALICO_IMAGES=(
    "quay.io/tigera/operator:${CALICO_VERSION}"
    "docker.io/calico/cni:${CALICO_VERSION}"
    "docker.io/calico/node:${CALICO_VERSION}"
    "docker.io/calico/kube-controllers:${CALICO_VERSION}"
    "docker.io/calico/typha:${CALICO_VERSION}"
    "docker.io/calico/pod2daemon-flexvol:${CALICO_VERSION}"
    "docker.io/calico/csi:${CALICO_VERSION}"
    "docker.io/calico/node-driver-registrar:${CALICO_VERSION}"
    "docker.io/calico/apiserver:${CALICO_VERSION}"
)

pull_and_save() {
    local IMG="$1"
    # registry prefix 제거 + ':', '/' 를 '-' 로
    local SAFE_NAME
    SAFE_NAME=$(echo "$IMG" | sed -E 's|^(docker\.io/|quay\.io/|registry\.k8s\.io/)||' | tr ':/' '-')
    local TAR="${IMG_DIR}/${SAFE_NAME}.tar"
    if [ -f "$TAR" ]; then
        echo "  → ${IMG} (이미 존재, skip)"
        return 0
    fi
    echo "  → pull: ${IMG}"
    ctr -n k8s.io images pull "$IMG" >/dev/null 2>&1 || { echo "    ! pull 실패: $IMG"; return 1; }
    echo "    export: $(basename "$TAR")"
    ctr -n k8s.io images export "$TAR" "$IMG"
}

for IMG in $K8S_IMAGES; do
    pull_and_save "$IMG" || true
done
for IMG in "${CALICO_IMAGES[@]}"; do
    pull_and_save "$IMG" || true
done

IMG_COUNT=$(ls -1 "$IMG_DIR"/*.tar 2>/dev/null | wc -l)
echo "  → 이미지 ${IMG_COUNT}개 저장 완료"

# ==========================================
# [5/6] 매니페스트 (Calico + local-path-storage)
# ==========================================
echo ""
echo "[5/6] 매니페스트 다운로드..."

# Calico — Tigera Operator 방식: 두 파일 분리 저장 (선택지 A)
curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml" \
    -o "${UTIL_DIR}/tigera-operator.yaml"
curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml" \
    -o "${UTIL_DIR}/calico-custom-resources.yaml"
echo "  → Calico: tigera-operator.yaml + calico-custom-resources.yaml"

# local-path-storage (Rancher)
curl -fsSL "https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml" \
    -o "${UTIL_DIR}/local-path-storage.yaml"
echo "  → local-path-storage.yaml"

# ==========================================
# [6/6] 임시 APT repo 정리 + 결과 요약
# ==========================================
echo ""
echo "[6/6] 임시 APT repo 정리..."
rm -f "$K8S_LIST" "$DOCKER_LIST"
apt-get update -qq >/dev/null 2>&1 || true
echo "  → 정리 완료"

echo ""
echo "============================================================"
echo " 다운로드 완료"
echo "============================================================"
echo "  DEB      : $(ls -1 "$DEB_DIR"/*.deb 2>/dev/null | wc -l) 개"
echo "  바이너리 : $(ls -1 "$BIN_DIR"/*.tar.gz 2>/dev/null | wc -l) 개"
echo "  이미지   : $(ls -1 "$IMG_DIR"/*.tar 2>/dev/null | wc -l) 개"
echo "  매니페스트: $(ls -1 "$UTIL_DIR"/*.yaml 2>/dev/null | wc -l) 개"
echo ""
echo " 다음 단계: 아래 명령으로 tar 묶음을 생성하여 폐쇄망으로 이관하세요."
echo ""
echo "   cd $(dirname "$BASE_DIR")"
echo "   tar czf $(basename "$BASE_DIR").tar.gz $(basename "$BASE_DIR")/"
echo "============================================================"
