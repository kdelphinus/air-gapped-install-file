#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
COMPONENT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd)
IMAGE_DIR="${COMPONENT_DIR}/images"

BUILDAH_VERSION="${BUILDAH_VERSION:-1.41.4}"
BASE_IMAGE="${BASE_IMAGE:-quay.io/buildah/stable:v${BUILDAH_VERSION}}"
TARGET_IMAGE="${TARGET_IMAGE:-jenkins-buildah-agent:${BUILDAH_VERSION}}"
TAR_PATH="${TAR_PATH:-${IMAGE_DIR}/jenkins-buildah-agent_${BUILDAH_VERSION}.tar}"

mkdir -p "$IMAGE_DIR"

if command -v docker >/dev/null 2>&1; then
    BUILD_CLI="docker"
elif command -v podman >/dev/null 2>&1; then
    BUILD_CLI="podman"
elif command -v buildah >/dev/null 2>&1; then
    BUILD_CLI="buildah"
else
    echo "[ERROR] docker, podman, buildah 중 하나가 필요합니다." >&2
    exit 1
fi

echo "==> Buildah Jenkins agent image build"
echo "    base image  : ${BASE_IMAGE}"
echo "    target image: ${TARGET_IMAGE}"
echo "    output tar  : ${TAR_PATH}"

case "$BUILD_CLI" in
    docker)
        docker build \
            --build-arg "BUILDAH_BASE_IMAGE=${BASE_IMAGE}" \
            -t "$TARGET_IMAGE" \
            "$SCRIPT_DIR"
        docker save -o "$TAR_PATH" "$TARGET_IMAGE"
        ;;
    podman)
        podman build \
            --build-arg "BUILDAH_BASE_IMAGE=${BASE_IMAGE}" \
            -t "$TARGET_IMAGE" \
            "$SCRIPT_DIR"
        podman save -o "$TAR_PATH" "$TARGET_IMAGE"
        ;;
    buildah)
        buildah bud \
            --build-arg "BUILDAH_BASE_IMAGE=${BASE_IMAGE}" \
            -t "$TARGET_IMAGE" \
            "$SCRIPT_DIR"
        buildah push "$TARGET_IMAGE" "docker-archive:${TAR_PATH}:${TARGET_IMAGE}"
        ;;
esac

echo "==> 완료: ${TAR_PATH}"
