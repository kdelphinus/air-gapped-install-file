#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
COMPONENT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd)
IMAGE_DIR="${COMPONENT_DIR}/images"

BUILDAH_VERSION="${BUILDAH_VERSION:-1.41.4}"
BASE_IMAGE="${BASE_IMAGE:-quay.io/buildah/stable:v${BUILDAH_VERSION}}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-jenkins-buildah-agent}"
COMMON_JDK_VERSIONS=(8 11 17 21)

BUILD_ALL="false"
DRY_RUN="false"
ENV_JDK_VERSION="${JDK_VERSION:-}"
EXPLICIT_JDK="false"
JDK_VERSION="${ENV_JDK_VERSION:-17}"
if [[ -n "$ENV_JDK_VERSION" ]]; then
    EXPLICIT_JDK="true"
fi

usage() {
    cat <<EOF
Usage: $0 [--jdk <8|11|17|21>] [--all] [--list] [--dry-run]

Options:
  --jdk <version>   지정한 JDK 버전용 Buildah agent 이미지를 빌드합니다.
  --all             많이 쓰는 JDK 버전(${COMMON_JDK_VERSIONS[*]}) 이미지를 모두 빌드합니다.
  --list            지원하는 JDK 버전과 패키지명을 출력합니다.
  --dry-run         실제 빌드 없이 생성될 이미지명과 tar 경로만 출력합니다.
  -h, --help        도움말을 출력합니다.

Environment:
  BUILDAH_VERSION   Buildah base image 버전. 기본값: ${BUILDAH_VERSION}
  BASE_IMAGE        Buildah base image. 기본값: ${BASE_IMAGE}
  IMAGE_REPOSITORY  생성할 이미지 repository. 기본값: ${IMAGE_REPOSITORY}
  TARGET_IMAGE      단일 빌드 시 사용할 전체 이미지명. --all에서는 무시됩니다.
  TAR_PATH          단일 빌드 시 사용할 tar 출력 경로. --all에서는 무시됩니다.

Examples:
  $0
  $0 --jdk 21
  $0 --all
  $0 --all --dry-run
  IMAGE_REPOSITORY=harbor.example.local/devops/jenkins-buildah-agent $0 --jdk 17
EOF
}

jdk_package() {
    case "$1" in
        8) echo "java-1.8.0-openjdk-devel" ;;
        11) echo "java-11-openjdk-devel" ;;
        17) echo "java-17-openjdk-devel" ;;
        21) echo "java-21-openjdk-devel" ;;
        *)
            echo "[ERROR] 지원하지 않는 JDK 버전입니다: $1" >&2
            echo "        지원 버전: ${COMMON_JDK_VERSIONS[*]}" >&2
            exit 1
            ;;
    esac
}

list_versions() {
    for version in "${COMMON_JDK_VERSIONS[@]}"; do
        printf 'JDK %s -> %s\n' "$version" "$(jdk_package "$version")"
    done
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --jdk)
            if [[ $# -lt 2 ]]; then
                echo "[ERROR] --jdk 옵션에는 버전 값이 필요합니다." >&2
                exit 1
            fi
            JDK_VERSION="$2"
            EXPLICIT_JDK="true"
            shift 2
            ;;
        --all)
            BUILD_ALL="true"
            shift
            ;;
        --list)
            list_versions
            exit 0
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[ERROR] 알 수 없는 옵션입니다: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

mkdir -p "$IMAGE_DIR"

if [[ "$DRY_RUN" == "true" ]]; then
    BUILD_CLI="dry-run"
elif command -v docker >/dev/null 2>&1; then
    BUILD_CLI="docker"
elif command -v podman >/dev/null 2>&1; then
    BUILD_CLI="podman"
elif command -v buildah >/dev/null 2>&1; then
    BUILD_CLI="buildah"
else
    echo "[ERROR] docker, podman, buildah 중 하나가 필요합니다." >&2
    exit 1
fi

build_one() {
    local jdk_version="$1"
    local jdk_package_name
    local target_image
    local tar_path

    jdk_package_name="$(jdk_package "$jdk_version")"

    if [[ "$BUILD_ALL" == "true" || "$EXPLICIT_JDK" == "true" ]]; then
        target_image="${IMAGE_REPOSITORY}:jdk${jdk_version}-${BUILDAH_VERSION}"
        tar_path="${IMAGE_DIR}/jenkins-buildah-agent_jdk${jdk_version}_${BUILDAH_VERSION}.tar"
    else
        target_image="${TARGET_IMAGE:-${IMAGE_REPOSITORY}:${BUILDAH_VERSION}}"
        tar_path="${TAR_PATH:-${IMAGE_DIR}/jenkins-buildah-agent_${BUILDAH_VERSION}.tar}"
    fi

    echo "==> Buildah Jenkins agent image build"
    echo "    build cli   : ${BUILD_CLI}"
    echo "    base image  : ${BASE_IMAGE}"
    echo "    jdk version : ${jdk_version}"
    echo "    jdk package : ${jdk_package_name}"
    echo "    target image: ${target_image}"
    echo "    output tar  : ${tar_path}"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "==> dry-run: 실제 빌드는 수행하지 않습니다."
        return 0
    fi

    case "$BUILD_CLI" in
        docker)
            docker build \
                --build-arg "BUILDAH_BASE_IMAGE=${BASE_IMAGE}" \
                --build-arg "JDK_PACKAGE=${jdk_package_name}" \
                -t "$target_image" \
                "$SCRIPT_DIR"
            docker save -o "$tar_path" "$target_image"
            ;;
        podman)
            podman build \
                --build-arg "BUILDAH_BASE_IMAGE=${BASE_IMAGE}" \
                --build-arg "JDK_PACKAGE=${jdk_package_name}" \
                -t "$target_image" \
                "$SCRIPT_DIR"
            podman save -o "$tar_path" "$target_image"
            ;;
        buildah)
            buildah bud \
                --build-arg "BUILDAH_BASE_IMAGE=${BASE_IMAGE}" \
                --build-arg "JDK_PACKAGE=${jdk_package_name}" \
                -t "$target_image" \
                "$SCRIPT_DIR"
            buildah push "$target_image" "docker-archive:${tar_path}:${target_image}"
            ;;
    esac

    echo "==> 완료: ${tar_path}"
}

if [[ "$BUILD_ALL" == "true" ]]; then
    for version in "${COMMON_JDK_VERSIONS[@]}"; do
        build_one "$version"
    done
else
    build_one "$JDK_VERSION"
fi
