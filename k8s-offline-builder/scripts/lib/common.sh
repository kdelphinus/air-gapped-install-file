#!/bin/bash

set -euo pipefail

fail() {
    echo "[오류] $*" >&2
    exit 1
}

require_file() {
    local path="$1"
    [ -f "$path" ] || fail "파일을 찾을 수 없습니다: $path"
}

load_builder_config() {
    CONF_FILE="${CONF_FILE:-install.conf}"
    require_file "$CONF_FILE"
    # shellcheck disable=SC1090
    source "$CONF_FILE"
}

normalize_builder_config() {
    K8S_VERSION="${K8S_VERSION:-}"
    [ -n "$K8S_VERSION" ] || fail "K8S_VERSION 값이 비어 있습니다."

    if [[ "$K8S_VERSION" != v* ]]; then
        K8S_VERSION="v${K8S_VERSION}"
    fi

    if [[ ! "$K8S_VERSION" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        fail "K8S_VERSION 형식이 올바르지 않습니다: $K8S_VERSION (예: v1.33.11)"
    fi

    K8S_MAJOR="${BASH_REMATCH[1]}"
    K8S_MINOR_NUMBER="${BASH_REMATCH[2]}"
    K8S_PATCH="${BASH_REMATCH[3]}"
    K8S_MINOR="v${K8S_MAJOR}.${K8S_MINOR_NUMBER}"

    TARGET_OS="${TARGET_OS:-ubuntu24.04}"
    ARCH="${ARCH:-amd64}"
    CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-containerd}"
    CONTAINERD_VERSION="${CONTAINERD_VERSION:-auto}"
    CNI_CHOICE="${CNI_CHOICE:-calico}"
    CALICO_VERSION="${CALICO_VERSION:-v3.31.0}"
    CALICO_INSTALL_METHOD="${CALICO_INSTALL_METHOD:-manifest}"
    CILIUM_VERSION="${CILIUM_VERSION:-v1.19.3}"
    ENABLE_HUBBLE="${ENABLE_HUBBLE:-true}"
    MTU_VALUE="${MTU_VALUE:-1500}"
    HELM_VERSION="${HELM_VERSION:-v3.20.2}"
    NERDCTL_VERSION="${NERDCTL_VERSION:-2.2.2}"
    BUNDLE_OUTPUT_DIR="${BUNDLE_OUTPUT_DIR:-bundles}"

    BUNDLE_NAME="k8s-${K8S_VERSION}-${TARGET_OS}"
    STAGING_DIR="${BUNDLE_OUTPUT_DIR}/${BUNDLE_NAME}"
    ARCHIVE_PATH="${BUNDLE_OUTPUT_DIR}/${BUNDLE_NAME}.tar.gz"
}

validate_choice() {
    local name="$1"
    local value="$2"
    shift 2

    local allowed
    for allowed in "$@"; do
        [ "$value" = "$allowed" ] && return 0
    done

    fail "${name} 값이 허용 범위를 벗어났습니다: ${value} (허용: $*)"
}

validate_builder_config() {
    validate_choice "TARGET_OS" "$TARGET_OS" "ubuntu24.04"
    validate_choice "ARCH" "$ARCH" "amd64"
    validate_choice "CONTAINER_RUNTIME" "$CONTAINER_RUNTIME" "containerd"
    validate_choice "CNI_CHOICE" "$CNI_CHOICE" "calico" "cilium"

    if [ "$CNI_CHOICE" = "calico" ]; then
        validate_choice "CALICO_INSTALL_METHOD" "$CALICO_INSTALL_METHOD" "manifest" "operator"
        [[ "$CALICO_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
            fail "CALICO_VERSION 형식이 올바르지 않습니다: $CALICO_VERSION"
    fi

    if [ "$CNI_CHOICE" = "cilium" ]; then
        [[ "$CILIUM_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
            fail "CILIUM_VERSION 형식이 올바르지 않습니다: $CILIUM_VERSION"
        validate_choice "ENABLE_HUBBLE" "$ENABLE_HUBBLE" "true" "false"
        [[ "$MTU_VALUE" =~ ^[0-9]+$ ]] || fail "MTU_VALUE 형식이 올바르지 않습니다: $MTU_VALUE"
    fi
}

load_and_validate_config() {
    load_builder_config
    normalize_builder_config
    validate_builder_config
}

print_builder_summary() {
    echo "  Kubernetes        : ${K8S_VERSION} (${K8S_MINOR})"
    echo "  Target OS         : ${TARGET_OS}"
    echo "  Architecture      : ${ARCH}"
    echo "  Runtime           : ${CONTAINER_RUNTIME} (${CONTAINERD_VERSION})"
    echo "  CNI               : ${CNI_CHOICE}"
    if [ "${CNI_CHOICE}" = "calico" ]; then
        echo "  Calico            : ${CALICO_VERSION} (${CALICO_INSTALL_METHOD})"
    fi
    if [ "${CNI_CHOICE}" = "cilium" ]; then
        echo "  Cilium            : ${CILIUM_VERSION}"
        echo "  Hubble            : ${ENABLE_HUBBLE}"
        echo "  MTU               : ${MTU_VALUE}"
    fi
    echo "  Staging directory : ${STAGING_DIR}"
}
