#!/usr/bin/env bash

set -Eeuo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "[오류] sudo로 실행해야 합니다."
    exit 1
fi

K8S_VERSION="v1.36.3"
K8S_RPM_VERSION="1.36.3"
K8S_REPO_MINOR="v1.36"
CALICO_VERSION="v3.32.1"
LOCAL_PATH_VERSION="v0.0.35"
HELM_VERSION="v3.20.2"
NERDCTL_VERSION="2.2.2"

BASE_DIR=$(cd "$(dirname "$0")/.." && pwd)
K8S_DIR="${BASE_DIR}/k8s"
RPM_DIR="${K8S_DIR}/rpms"
BIN_DIR="${K8S_DIR}/binaries"
IMG_DIR="${K8S_DIR}/images"
UTIL_DIR="${K8S_DIR}/utils"
KEY_DIR="${K8S_DIR}/keys"

K8S_REPO_FILE="/etc/yum.repos.d/kubernetes-v1.36-offline-collector.repo"
DOCKER_REPO_FILE="/etc/yum.repos.d/docker-ce-offline-collector.repo"

cleanup_repositories() {
    rm -f "$K8S_REPO_FILE" "$DOCKER_REPO_FILE"
}
trap cleanup_repositories EXIT

if [ ! -r /etc/os-release ]; then
    echo "[오류] /etc/os-release를 읽을 수 없습니다."
    exit 1
fi
OS_ID=$(awk -F= '$1 == "ID" {gsub(/"/, "", $2); print $2}' /etc/os-release)
OS_VERSION=$(awk -F= '$1 == "VERSION_ID" {gsub(/"/, "", $2); print $2}' /etc/os-release)
if [ "$OS_ID" != "rocky" ] || [[ "$OS_VERSION" != 9.* ]]; then
    echo "[오류] 이 스크립트는 Rocky Linux 9.x amd64 수집 호스트 전용입니다."
    echo "감지값: ${OS_ID} ${OS_VERSION}"
    exit 1
fi
if [ "$(uname -m)" != "x86_64" ]; then
    echo "[오류] 현재 수집 스크립트는 amd64만 지원합니다."
    exit 1
fi

mkdir -p "$RPM_DIR" "$BIN_DIR" "$IMG_DIR" "$UTIL_DIR" "$KEY_DIR"
for asset_dir in "$RPM_DIR" "$BIN_DIR" "$IMG_DIR" "$UTIL_DIR" "$KEY_DIR"; do
    find "$asset_dir" -maxdepth 1 -type f ! -name '.gitkeep' -delete
done
rm -f "${K8S_DIR}/ASSET_VERSIONS.txt" "${K8S_DIR}/SHA256SUMS"

echo "Kubernetes ${K8S_VERSION} Rocky 9 보안 기준 오프라인 자산 수집"
echo "Calico ${CALICO_VERSION}, local-path-provisioner ${LOCAL_PATH_VERSION}"

dnf install -y dnf-plugins-core curl tar jq ca-certificates >/dev/null
echo "[OS] Rocky Linux 9 최신 보안 패치 적용"
dnf upgrade -y --refresh
OS_VERSION=$(awk -F= '$1 == "VERSION_ID" {gsub(/"/, "", $2); print $2}' /etc/os-release)
echo "수집 기준 Rocky Linux: ${OS_VERSION}"

curl -fsSL \
    "https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/rpm/repodata/repomd.xml.key" \
    -o "${KEY_DIR}/kubernetes-rpm-signing-key.asc"
curl -fsSL https://download.docker.com/linux/centos/gpg \
    -o "${KEY_DIR}/docker-rpm-signing-key.asc"
rpm --import "${KEY_DIR}/kubernetes-rpm-signing-key.asc"
rpm --import "${KEY_DIR}/docker-rpm-signing-key.asc"

cat > "$K8S_REPO_FILE" <<EOF
[kubernetes-v1.36-offline-collector]
name=Kubernetes v1.36 offline collector
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://${KEY_DIR}/kubernetes-rpm-signing-key.asc
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

curl -fsSL https://download.docker.com/linux/centos/docker-ce.repo \
    -o "$DOCKER_REPO_FILE"
dnf makecache -y >/dev/null

rm -f "${RPM_DIR}"/*.rpm

K8S_PACKAGES=(
    "kubelet-${K8S_RPM_VERSION}"
    "kubeadm-${K8S_RPM_VERSION}"
    "kubectl-${K8S_RPM_VERSION}"
)
UTILITY_PACKAGES=(
    containerd.io cri-tools kubernetes-cni
    socat conntrack-tools ebtables ipset iproute-tc ipvsadm
    jq chrony openssl tar psmisc firewalld NetworkManager
    container-selinux policycoreutils-python-utils
    dnf-plugins-core python3-dnf-plugin-versionlock
)

echo "[RPM] Kubernetes 및 전체 의존성 다운로드"
dnf download --resolve --alldeps --arch=x86_64,noarch \
    --disableexcludes=all --destdir="$RPM_DIR" \
    "${K8S_PACKAGES[@]}" "${UTILITY_PACKAGES[@]}"

for package in kubelet kubeadm kubectl; do
    found=false
    for rpm_file in "${RPM_DIR}"/${package}-*.rpm; do
        [ -f "$rpm_file" ] || continue
        if [ "$(rpm -qp --qf '%{VERSION}' "$rpm_file")" = "$K8S_RPM_VERSION" ]; then
            found=true
            break
        fi
    done
    if [ "$found" != "true" ]; then
        echo "[오류] ${package} ${K8S_RPM_VERSION} RPM을 찾지 못했습니다."
        exit 1
    fi
done

for rpm_file in "${RPM_DIR}"/*.rpm; do
    rpm --checksig "$rpm_file"
done

CONTAINERD_VERSION=$(
    for rpm_file in "${RPM_DIR}"/containerd.io-*.rpm; do
        [ -f "$rpm_file" ] || continue
        rpm -qp --qf '%{EPOCHNUM}:%{VERSION}-%{RELEASE}\n' "$rpm_file"
    done | sort -V | tail -1
)
if [ -z "$CONTAINERD_VERSION" ]; then
    echo "[오류] containerd.io RPM 버전을 확인하지 못했습니다."
    exit 1
fi

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

dnf install -y --disableexcludes=all \
    "kubeadm-${K8S_RPM_VERSION}" containerd.io >/dev/null
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
        grep -E '^[A-Za-z0-9._-]+([.:][A-Za-z0-9._-]+)?(/|$)' |
        sort -u
)

normalize_image_ref() {
    local image="$1"
    local first_component="${image%%/*}"
    local last_component="${image##*/}"

    if [[ "$image" != */* ]]; then
        image="docker.io/library/${image}"
    elif [[ "$first_component" != *.* &&
            "$first_component" != *:* &&
            "$first_component" != "localhost" ]]; then
        image="docker.io/${image}"
    fi
    if [[ "$last_component" != *:* && "$image" != *@* ]]; then
        image="${image}:latest"
    fi
    printf '%s\n' "$image"
}

mapfile -t ALL_IMAGES < <(
    for image in "${CORE_IMAGES[@]}" "${MANIFEST_IMAGES[@]}"; do
        [ -n "$image" ] && normalize_image_ref "$image"
    done |
        sort -u
)

pull_image() {
    local image="$1"
    local attempt

    for attempt in 1 2 3; do
        if ctr -n k8s.io images pull "$image"; then
            return 0
        fi
        echo "[재시도 ${attempt}/3] 이미지 pull 실패: ${image}"
        [ "$attempt" -eq 3 ] || sleep $((attempt * 2))
    done
    return 1
}

export_image() {
    local image="$1"
    local archive="$2"
    local attempt

    for attempt in 1 2 3; do
        rm -f "$archive"
        if ctr -n k8s.io images export "$archive" "$image"; then
            return 0
        fi
        echo "[재시도 ${attempt}/3] 이미지 export 실패: ${image}"
        [ "$attempt" -eq 3 ] || sleep $((attempt * 2))
    done
    return 1
}

FAILED_IMAGES=()
for image in "${ALL_IMAGES[@]}"; do
    safe_name=$(printf '%s' "$image" | sed -E 's#^[a-z]+://##; s#[/@:]#-#g')
    archive="${IMG_DIR}/${safe_name}.tar"
    echo "[IMAGE] ${image}"
    if ! pull_image "$image"; then
        FAILED_IMAGES+=("$image")
        continue
    fi
    if ! export_image "$image" "$archive"; then
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
KUBERNETES_RPM=${K8S_RPM_VERSION}
CONTAINERD=${CONTAINERD_VERSION}
CALICO=${CALICO_VERSION}
LOCAL_PATH_PROVISIONER=${LOCAL_PATH_VERSION}
HELM=${HELM_VERSION}
NERDCTL=${NERDCTL_VERSION}
OS=rocky-${OS_VERSION}
ARCH=amd64
GENERATED_AT_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

(
    cd "$K8S_DIR"
    find rpms binaries images utils keys -type f ! -name '.gitkeep' -print0 |
        sort -z |
        xargs -0 sha256sum > SHA256SUMS
    sha256sum ASSET_VERSIONS.txt >> SHA256SUMS
)

printf 'RPM=%s\n' "$(find "$RPM_DIR" -maxdepth 1 -name '*.rpm' | wc -l)"
printf 'IMAGE=%s\n' "$(find "$IMG_DIR" -maxdepth 1 -name '*.tar' | wc -l)"
echo "완료: ${K8S_DIR}/SHA256SUMS로 반입 후 무결성을 검증할 수 있습니다."
