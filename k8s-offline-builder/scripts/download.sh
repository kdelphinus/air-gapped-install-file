#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

source scripts/lib/common.sh
load_and_validate_config

if [ "$EUID" -ne 0 ]; then
    fail "download.sh 는 APT repo 등록과 ctr 사용을 위해 root 권한으로 실행해야 합니다."
fi

K8S_DEB_VERSION="${K8S_VERSION#v}-1.1"
K8S_DIR="${STAGING_DIR}/k8s"
DEB_DIR="${K8S_DIR}/debs"
BIN_DIR="${K8S_DIR}/binaries"
IMG_DIR="${K8S_DIR}/images"
UTIL_DIR="${K8S_DIR}/utils"
CHART_DIR="${K8S_DIR}/charts"

APT_LISTS_TO_CLEAN=()

cleanup_apt_lists() {
    local list_file
    for list_file in "${APT_LISTS_TO_CLEAN[@]:-}"; do
        [ -n "$list_file" ] && rm -f "$list_file"
    done
    apt-get update -qq >/dev/null 2>&1 || true
}

trap cleanup_apt_lists EXIT

download_deb_with_dependencies() {
    local pkg="$1"
    local pkg_name="${pkg%%=*}"
    local deps dep

    echo "  → ${pkg_name} 의존성 수집 중..."
    deps=$(apt-rdepends "$pkg_name" 2>/dev/null \
        | grep -v "^ " \
        | grep -Ev "^(debconf-2.0|awk|cron-daemon|mail-transport-agent)$" \
        || true)

    for dep in $deps; do
        if ls "${dep}"_*.deb >/dev/null 2>&1; then
            continue
        fi
        apt-get download "$dep" 2>/dev/null || echo "    ! ${dep} 다운로드 실패 (skip)"
    done
}

pull_and_save_image() {
    local img="$1"
    [ -z "$img" ] && return 0

    local safe_name
    safe_name=$(echo "$img" | sed -E 's#^(docker\.io|quay\.io|registry\.k8s\.io)/##' | tr ':/' '-')
    local tar_path="${IMG_DIR}/${safe_name}.tar"

    if [ -f "$tar_path" ]; then
        if tar -xOf "$tar_path" manifest.json 2>/dev/null | grep -Fq "$img"; then
            echo "  → ${img} (이미 존재, skip)"
            return 0
        fi
        echo "  → ${img} (기존 tar 이미지 ref 불일치, 재생성)"
        rm -f "$tar_path"
    fi

    echo "  → pull: ${img}"
    if ! ctr -n k8s.io images pull "$img" >/dev/null 2>&1; then
        FAILED_IMAGES+=("$img")
        echo "    ! pull 실패: $img"
        return 1
    fi

    echo "    export: $(basename "$tar_path")"
    ctr -n k8s.io images export "$tar_path" "$img"
}

echo "============================================================"
echo " Kubernetes Offline Builder - download"
echo "============================================================"
print_builder_summary
echo "============================================================"
echo ""

case "$TARGET_OS" in
    ubuntu24.04)
        mkdir -p "$DEB_DIR" "$BIN_DIR" "$IMG_DIR" "$UTIL_DIR" "$CHART_DIR"

        echo "[1/6] APT repo 임시 등록..."
        apt-get update -qq
        apt-get install -y --no-install-recommends \
            apt-transport-https ca-certificates curl gpg \
            gnupg lsb-release apt-rdepends >/dev/null

        K8S_KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
        K8S_LIST="/etc/apt/sources.list.d/kubernetes.list"
        mkdir -p /etc/apt/keyrings
        if [ ! -f "$K8S_KEYRING" ]; then
            curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" | \
                gpg --dearmor -o "$K8S_KEYRING"
        fi
        echo "deb [signed-by=${K8S_KEYRING}] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
            > "$K8S_LIST"
        APT_LISTS_TO_CLEAN+=("$K8S_LIST")

        DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
        DOCKER_LIST="/etc/apt/sources.list.d/docker.list"
        if [ ! -f "$DOCKER_KEYRING" ]; then
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
                gpg --dearmor -o "$DOCKER_KEYRING"
        fi
        UBUNTU_CODENAME=$(lsb_release -cs)
        echo "deb [arch=${ARCH} signed-by=${DOCKER_KEYRING}] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
            > "$DOCKER_LIST"
        APT_LISTS_TO_CLEAN+=("$DOCKER_LIST")

        apt-get update -qq
        echo "  → repo 등록 완료"

        echo ""
        echo "[2/6] DEB 다운로드..."
        FIXED_PKGS=(
            "kubelet=${K8S_DEB_VERSION}"
            "kubeadm=${K8S_DEB_VERSION}"
            "kubectl=${K8S_DEB_VERSION}"
            "cri-tools"
        )
        if [ "$CONTAINERD_VERSION" = "auto" ]; then
            FIXED_PKGS+=("containerd.io")
        else
            FIXED_PKGS+=("containerd.io=${CONTAINERD_VERSION}")
        fi

        UTIL_PKGS=(
            conntrack socat ebtables ipset
            jq chrony
            haproxy keepalived psmisc
        )

        cd "$DEB_DIR"
        rm -f ./*.deb
        for pkg in "${FIXED_PKGS[@]}" "${UTIL_PKGS[@]}"; do
            download_deb_with_dependencies "$pkg"
        done
        for pkg in "${FIXED_PKGS[@]}"; do
            apt-get download "$pkg" 2>/dev/null || true
        done
        cd - >/dev/null
        echo "  → DEB $(ls -1 "$DEB_DIR"/*.deb 2>/dev/null | wc -l)개 수집 완료"

        echo ""
        echo "[3/6] 바이너리 tarball 다운로드..."
        HELM_TGZ="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
        if [ ! -f "${BIN_DIR}/${HELM_TGZ}" ]; then
            curl -fsSL "https://get.helm.sh/${HELM_TGZ}" -o "${BIN_DIR}/${HELM_TGZ}"
        fi
        NERDCTL_TGZ="nerdctl-full-${NERDCTL_VERSION}-linux-${ARCH}.tar.gz"
        if [ ! -f "${BIN_DIR}/${NERDCTL_TGZ}" ]; then
            curl -fsSL "https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/${NERDCTL_TGZ}" \
                -o "${BIN_DIR}/${NERDCTL_TGZ}"
        fi
        echo "  → 바이너리 $(ls -1 "$BIN_DIR"/*.tar.gz 2>/dev/null | wc -l)개 수집 완료"

        echo ""
        echo "[4/6] 매니페스트 다운로드..."
        if [ "$CNI_CHOICE" = "calico" ]; then
            curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" \
                -o "${UTIL_DIR}/calico.yaml"
            curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml" \
                -o "${UTIL_DIR}/tigera-operator.yaml"
            curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml" \
                -o "${UTIL_DIR}/calico-custom-resources.yaml"
            echo "  → Calico 매니페스트 수집 완료"
        fi
        if [ "$CNI_CHOICE" = "cilium" ]; then
            CILIUM_CHART_VERSION="${CILIUM_VERSION#v}"
            curl -fsSL "https://helm.cilium.io/cilium-${CILIUM_CHART_VERSION}.tgz" \
                -o "${CHART_DIR}/cilium-${CILIUM_CHART_VERSION}.tgz"
            echo "  → Cilium Helm chart 수집 완료"
        fi
        curl -fsSL "https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml" \
            -o "${UTIL_DIR}/local-path-storage.yaml"

        echo ""
        echo "[5/6] 컨테이너 이미지 다운로드..."
        if ! command -v ctr >/dev/null 2>&1; then
            echo "  ! ctr 미존재 → containerd.io 임시 설치"
            apt-get install -y containerd.io >/dev/null
            systemctl enable --now containerd >/dev/null 2>&1 || true
        fi
        if ! command -v kubeadm >/dev/null 2>&1; then
            apt-get install -y "kubeadm=${K8S_DEB_VERSION}" >/dev/null
        fi

        K8S_IMAGES=$(kubeadm config images list --kubernetes-version="${K8S_VERSION}")
        FAILED_IMAGES=()

        for img in $K8S_IMAGES; do
            pull_and_save_image "$img" || true
        done

        if [ "$CNI_CHOICE" = "calico" ]; then
            TIGERA_OPERATOR_IMAGE=$(grep 'image:' "${UTIL_DIR}/tigera-operator.yaml" | awk '{print $2}' | head -1)
            [ -z "$TIGERA_OPERATOR_IMAGE" ] && TIGERA_OPERATOR_IMAGE="quay.io/tigera/operator:v1.40.0"
            CALICO_IMAGES=(
                "$TIGERA_OPERATOR_IMAGE"
                "quay.io/calico/cni:${CALICO_VERSION}"
                "quay.io/calico/node:${CALICO_VERSION}"
                "quay.io/calico/kube-controllers:${CALICO_VERSION}"
                "quay.io/calico/typha:${CALICO_VERSION}"
                "quay.io/calico/pod2daemon-flexvol:${CALICO_VERSION}"
                "quay.io/calico/csi:${CALICO_VERSION}"
                "quay.io/calico/node-driver-registrar:${CALICO_VERSION}"
                "quay.io/calico/apiserver:${CALICO_VERSION}"
            )
            for img in "${CALICO_IMAGES[@]}"; do
                pull_and_save_image "$img" || true
            done
        fi

        if [ "$CNI_CHOICE" = "cilium" ]; then
            CILIUM_IMAGES=(
                "quay.io/cilium/cilium:${CILIUM_VERSION}"
                "quay.io/cilium/operator-generic:${CILIUM_VERSION}"
                "quay.io/cilium/hubble-relay:${CILIUM_VERSION}"
                "quay.io/cilium/hubble-ui:v0.13.3"
                "quay.io/cilium/hubble-ui-backend:v0.13.3"
                "quay.io/cilium/cilium-envoy:v1.36.6-1776000132-2437d2edeaf4d9b56ef279bd0d71127440c067aa"
            )
            for img in "${CILIUM_IMAGES[@]}"; do
                pull_and_save_image "$img" || true
            done
        fi

        if [ "${#FAILED_IMAGES[@]}" -gt 0 ]; then
            echo "  ⚠ pull 실패 목록:"
            for img in "${FAILED_IMAGES[@]}"; do
                echo "    - $img"
            done
        fi
        ;;
    *)
        fail "현재는 ubuntu24.04 만 지원합니다: $TARGET_OS"
        ;;
esac

echo ""
echo "[6/6] 결과 요약"
echo "  DEB        : $(ls -1 "$DEB_DIR"/*.deb 2>/dev/null | wc -l) 개"
echo "  바이너리   : $(ls -1 "$BIN_DIR"/*.tar.gz 2>/dev/null | wc -l) 개"
echo "  이미지     : $(ls -1 "$IMG_DIR"/*.tar 2>/dev/null | wc -l) 개"
echo "  매니페스트 : $(ls -1 "$UTIL_DIR"/*.yaml 2>/dev/null | wc -l) 개"
echo "  Helm chart : $(ls -1 "$CHART_DIR"/*.tgz 2>/dev/null | wc -l) 개"
echo ""
echo "다음 단계: ./scripts/build_bundle.sh"
