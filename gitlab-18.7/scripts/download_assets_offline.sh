#!/bin/bash

# Root 권한 체크
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

# GitLab v18.7.0 (Helm) 에셋 다운로드 스크립트

set -e

BASE_DIR=$(cd "$(dirname "$0")/.." && pwd)
CHART_DIR="${BASE_DIR}/charts"
IMAGE_DIR="${BASE_DIR}/images"

mkdir -p "$CHART_DIR" "$IMAGE_DIR"

echo "[1/2] Helm 차트 다운로드 중..."
helm repo add gitlab https://charts.gitlab.io/
helm repo update
helm pull gitlab/gitlab --version 18.7.0 -d "$CHART_DIR"

echo "[2/2] 컨테이너 이미지 다운로드 및 저장 중..."
IMAGES=(
    "registry.gitlab.com/gitlab-org/build/cng/gitlab-webservice-ce:v18.7.0"
    "registry.gitlab.com/gitlab-org/build/cng/gitlab-sidekiq-ce:v18.7.0"
    "registry.gitlab.com/gitlab-org/build/cng/gitaly:v18.7.0"
    "registry.gitlab.com/gitlab-org/build/cng/gitlab-shell:v18.7.0"
    "registry.gitlab.com/gitlab-org/build/cng/gitlab-base:v18.7.0"
    "registry.gitlab.com/gitlab-org/build/cng/gitlab-toolbox-ce:v18.7.0"
    "registry.gitlab.com/gitlab-org/build/cng/gitlab-migrations-ce:v18.7.0"
    "registry.gitlab.com/gitlab-org/build/cng/gitlab-workhorse-ce:v18.7.0"
    "registry.gitlab.com/gitlab-org/build/cng/gitlab-kas:v18.7.0"
    "registry.gitlab.com/gitlab-org/build/cng/gitlab-exporter:v18.7.0"
    "registry.gitlab.com/gitlab-org/build/cng/gitlab-container-registry:v18.7.0"
    "quay.io/jetstack/cert-manager-controller:v1.17.4"
    "quay.io/jetstack/cert-manager-webhook:v1.17.4"
    "quay.io/jetstack/cert-manager-cainjector:v1.17.4"
    "quay.io/jetstack/cert-manager-startupapicheck:v1.17.4"
    "docker.io/bitnami/postgresql:16.2.0"
    "docker.io/bitnami/postgres-exporter:0.15.0-debian-11-r7"
    "docker.io/bitnami/redis:7.2.4"
    "docker.io/bitnami/redis-exporter:1.58.0-debian-12-r4"
    "docker.io/bitnami/minio:RELEASE.2017-12-28T01-21-00Z"
    "docker.io/bitnami/mc:RELEASE.2018-07-13T00-53-22Z"
    "docker.io/bitnami/kubectl:1.28.6"
)

for IMG in "${IMAGES[@]}"; do
    FILENAME=$(echo $IMG | tr ':/' '-')
    echo "-> 다운로드: $IMG"
    sudo ctr images pull "$IMG"
    echo "-> 저장: ${IMAGE_DIR}/${FILENAME}.tar"
    sudo ctr images export "${IMAGE_DIR}/${FILENAME}.tar" "$IMG"
done

echo "[완료] 모든 에셋이 저장되었습니다."
