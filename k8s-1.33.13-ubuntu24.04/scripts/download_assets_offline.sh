#!/usr/bin/env bash

set -Eeuo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "[오류] sudo로 실행해야 합니다."
    exit 1
fi

K8S_VERSION="v1.33.13"
K8S_DEB_VERSION="1.33.13-1.1"
K8S_REPO_MINOR="v1.33"
CALICO_VERSION="v3.31.6"
LOCAL_PATH_VERSION="v0.0.35"
HELM_VERSION="v3.20.2"
NERDCTL_VERSION="2.2.2"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-}"

BASE_DIR=$(cd "$(dirname "$0")/.." && pwd)
K8S_DIR="${BASE_DIR}/k8s"
DEB_DIR="${K8S_DIR}/debs"
BIN_DIR="${K8S_DIR}/binaries"
IMG_DIR="${K8S_DIR}/images"
UTIL_DIR="${K8S_DIR}/utils"
if [ ! -r /etc/os-release ]; then
    echo "[오류] /etc/os-release를 읽을 수 없습니다."
    exit 1
fi
OS_ID=$(awk -F= '$1 == "ID" {gsub(/"/, "", $2); print $2}' /etc/os-release)
OS_VERSION=$(awk -F= '$1 == "VERSION_ID" {gsub(/"/, "", $2); print $2}' /etc/os-release)
if [ "$OS_ID" != "ubuntu" ] || [[ "$OS_VERSION" != 24.04* ]]; then
    echo "[오류] 이 수집기는 Ubuntu 24.04 amd64 전용입니다: ${OS_ID} ${OS_VERSION}"
    exit 1
fi

if [ "$(uname -m)" != "x86_64" ]; then
    echo "[오류] 현재 수집 스크립트는 amd64만 지원합니다."
    exit 1
fi

mkdir -p "$DEB_DIR" "$BIN_DIR" "$IMG_DIR" "$UTIL_DIR"
for asset_dir in "$DEB_DIR" "$BIN_DIR" "$IMG_DIR" "$UTIL_DIR"; do
    find "$asset_dir" -maxdepth 1 -type f ! -name '.gitkeep' -delete
done
rm -f "${K8S_DIR}/ASSET_VERSIONS.txt" "${K8S_DIR}/SHA256SUMS"
echo "Kubernetes ${K8S_VERSION} 보안 기준 오프라인 자산 수집"
echo "Calico ${CALICO_VERSION}, local-path-provisioner ${LOCAL_PATH_VERSION}"
echo "결과: ${K8S_DIR}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    apt-transport-https ca-certificates curl gpg gnupg lsb-release \
    apt-rdepends jq tar >/dev/null

mkdir -p /etc/apt/keyrings
K8S_KEYRING="/etc/apt/keyrings/kubernetes-v1.33-archive-keyring.gpg"
K8S_LIST="/etc/apt/sources.list.d/kubernetes-v1.33.list"
DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
DOCKER_LIST="/etc/apt/sources.list.d/docker.list"

curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/deb/Release.key" |
    gpg --dearmor --yes -o "$K8S_KEYRING"
echo "deb [signed-by=${K8S_KEYRING}] https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/deb/ /" > "$K8S_LIST"

curl -fsSL https://download.docker.com/linux/ubuntu/gpg |
    gpg --dearmor --yes -o "$DOCKER_KEYRING"
UBUNTU_CODENAME=$(lsb_release -cs)
echo "deb [arch=amd64 signed-by=${DOCKER_KEYRING}] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" > "$DOCKER_LIST"
apt-get update -qq

if ! apt-cache madison kubeadm | awk '{print $3}' | grep -Fxq "$K8S_DEB_VERSION"; then
    echo "[오류] pkgs.k8s.io에서 kubeadm ${K8S_DEB_VERSION}을 찾지 못했습니다."
    exit 1
fi

if [ -z "$CONTAINERD_VERSION" ]; then
    CONTAINERD_VERSION=$(apt-cache policy containerd.io | awk '/Candidate:/ {print $2}')
fi
if [ -z "$CONTAINERD_VERSION" ] || [ "$CONTAINERD_VERSION" = "(none)" ]; then
    echo "[오류] containerd.io 설치 후보 버전을 찾지 못했습니다."
    exit 1
fi

echo "고정 버전: Kubernetes ${K8S_DEB_VERSION}, containerd.io ${CONTAINERD_VERSION}"

rm -f "${DEB_DIR}"/*.deb
cd "$DEB_DIR"

FIXED_PACKAGES=(
    "kubelet=${K8S_DEB_VERSION}"
    "kubeadm=${K8S_DEB_VERSION}"
    "kubectl=${K8S_DEB_VERSION}"
    "containerd.io=${CONTAINERD_VERSION}"
)
UTILITY_PACKAGES=(
    cri-tools conntrack socat ebtables ipset jq chrony
    openssl iptables ipvsadm psmisc ufw apparmor apparmor-utils
)
ALL_PACKAGES=("${FIXED_PACKAGES[@]}" "${UTILITY_PACKAGES[@]}")

for package in "${ALL_PACKAGES[@]}"; do
    name="${package%%=*}"
    echo "[DEB] ${name} 및 의존성"
    while IFS= read -r dependency; do
        [ -n "$dependency" ] || continue
        [ "$dependency" = "$name" ] && continue
        if apt-cache show "$dependency" >/dev/null 2>&1; then
            apt-get download "$dependency" >/dev/null
        fi
    done < <(
        apt-rdepends "$name" 2>/dev/null |
            awk '/^[A-Za-z0-9][A-Za-z0-9+.-]*(:[A-Za-z0-9]+)?$/ {print}' |
            sort -u
    )
    apt-get download "$package" >/dev/null
done

for package in "${FIXED_PACKAGES[@]}"; do
    name="${package%%=*}"
    expected_version="${package#*=}"
    found=false
    for deb in "${DEB_DIR}"/*.deb; do
        if [ "$(dpkg-deb -f "$deb" Package 2>/dev/null)" = "$name" ] &&
           [ "$(dpkg-deb -f "$deb" Version 2>/dev/null)" = "$expected_version" ]; then
            found=true
            break
        fi
    done
    if [ "$found" != "true" ]; then
        echo "[오류] 고정 DEB 검증 실패: ${name}=${expected_version}"
        exit 1
    fi
done

cd "$BASE_DIR"

HELM_ARCHIVE="helm-${HELM_VERSION}-linux-amd64.tar.gz"
NERDCTL_ARCHIVE="nerdctl-full-${NERDCTL_VERSION}-linux-amd64.tar.gz"
curl -fsSL "https://get.helm.sh/${HELM_ARCHIVE}" -o "${BIN_DIR}/${HELM_ARCHIVE}"
curl -fsSL \
    "https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/${NERDCTL_ARCHIVE}" \
    -o "${BIN_DIR}/${NERDCTL_ARCHIVE}"

curl -fsSL \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" \
    -o "${UTIL_DIR}/calico.yaml"
curl -fsSL \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml" \
    -o "${UTIL_DIR}/tigera-operator.yaml"
curl -fsSL \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml" \
    -o "${UTIL_DIR}/calico-custom-resources.yaml"
curl -fsSL \
    "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml" \
    -o "${UTIL_DIR}/local-path-storage.yaml"

apt-get install -y \
    "containerd.io=${CONTAINERD_VERSION}" \
    "kubeadm=${K8S_DEB_VERSION}" >/dev/null
systemctl enable --now containerd >/dev/null

mapfile -t CORE_IMAGES < <(
    kubeadm config images list --kubernetes-version "$K8S_VERSION"
)
mapfile -t MANIFEST_IMAGES < <(
    grep -hE '^[[:space:]]*image:[[:space:]]*' \
        "${UTIL_DIR}/calico.yaml" \
        "${UTIL_DIR}/tigera-operator.yaml" \
        "${UTIL_DIR}/calico-custom-resources.yaml" \
        "${UTIL_DIR}/local-path-storage.yaml" |
        sed -E 's/^[[:space:]]*image:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/' |
        grep -E '^[A-Za-z0-9._-]+([.:][A-Za-z0-9._-]+)?/' |
        sort -u
)
mapfile -t ALL_IMAGES < <(
    printf '%s\n' "${CORE_IMAGES[@]}" "${MANIFEST_IMAGES[@]}" |
        sed '/^$/d' |
        sort -u
)

FAILED_IMAGES=()
for image in "${ALL_IMAGES[@]}"; do
    safe_name=$(printf '%s' "$image" | sed -E 's#^[a-z]+://##; s#[/@:]#-#g')
    archive="${IMG_DIR}/${safe_name}.tar"
    echo "[IMAGE] ${image}"
    if ! ctr -n k8s.io images pull "$image"; then
        FAILED_IMAGES+=("$image")
        continue
    fi
    if ! ctr -n k8s.io images export "$archive" "$image"; then
        FAILED_IMAGES+=("$image")
        continue
    fi
    if ! tar -tf "$archive" | grep -qx 'index.json'; then
        echo "[오류] OCI archive 검증 실패: ${archive}"
        FAILED_IMAGES+=("$image")
        rm -f "$archive"
    fi
done

if [ "${#FAILED_IMAGES[@]}" -ne 0 ]; then
    echo "[오류] 다음 이미지 수집에 실패했습니다:"
    printf '  - %s\n' "${FAILED_IMAGES[@]}"
    exit 1
fi

cat > "${K8S_DIR}/ASSET_VERSIONS.txt" <<EOF
KUBERNETES=${K8S_VERSION}
KUBERNETES_DEB=${K8S_DEB_VERSION}
CONTAINERD=${CONTAINERD_VERSION}
CALICO=${CALICO_VERSION}
LOCAL_PATH_PROVISIONER=${LOCAL_PATH_VERSION}
HELM=${HELM_VERSION}
NERDCTL=${NERDCTL_VERSION}
OS=ubuntu-${OS_VERSION}
ARCH=amd64
GENERATED_AT_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

(
    cd "$K8S_DIR"
    find debs binaries images utils -type f ! -name '.gitkeep' -print0 |
        sort -z |
        xargs -0 sha256sum > SHA256SUMS
    sha256sum ASSET_VERSIONS.txt >> SHA256SUMS
)

printf 'DEB=%s\n' "$(find "$DEB_DIR" -maxdepth 1 -name '*.deb' | wc -l)"
printf 'IMAGE=%s\n' "$(find "$IMG_DIR" -maxdepth 1 -name '*.tar' | wc -l)"
echo "완료: ${K8S_DIR}/SHA256SUMS로 반입 후 무결성을 검증할 수 있습니다."
