#!/bin/bash

# Root 권한 체크
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

# ArgoCD v2.12.1 오프라인 자산 다운로드 스크립트
# [Chart Version] 7.4.1 (argo-cd)
# [App/Image Version] v2.12.1

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
COMPONENT_ROOT="${SCRIPT_DIR}/.."
CHART_DIR="${COMPONENT_ROOT}/charts"
IMAGE_DIR="${COMPONENT_ROOT}/images"

echo "===================================================="
echo " 다운로드 범위를 선택하세요:"
echo "  1) 전체 (Helm 차트 + 컨테이너 이미지)"
echo "  2) Helm 차트만"
echo "  3) 컨테이너 이미지만"
read -p "선택 [1/2/3, 기본값: 1]: " RANGE_CHOICE
RANGE_CHOICE="${RANGE_CHOICE:-1}"

DOWNLOAD_HELM=false
DOWNLOAD_IMAGES=false

case "$RANGE_CHOICE" in
    1) DOWNLOAD_HELM=true; DOWNLOAD_IMAGES=true ;;
    2) DOWNLOAD_HELM=true ;;
    3) DOWNLOAD_IMAGES=true ;;
    *) echo "[오류] 1, 2, 3 중 하나를 선택하세요."; exit 1 ;;
esac

# 1. Helm 차트 다운로드 (외부망)
if [ "$DOWNLOAD_HELM" = true ]; then
    echo ""
    echo ">> [1/2] ArgoCD Helm 차트 다운로드 중 (version 7.4.1)..."
    mkdir -p "$CHART_DIR"
    rm -rf "$CHART_DIR/argo-cd"

    # 헬름 레포 추가 및 갱신
    if command -v helm &> /dev/null; then
        helm repo add argocd https://argoproj.github.io/argo-helm --force-update
        helm repo update
        helm pull argocd/argo-cd --version 7.4.1 -d "$CHART_DIR" --untar
        echo "✅ Helm 차트 다운로드 및 untar 완료: $CHART_DIR/argo-cd"
    else
        echo "❌ [오류] helm CLI를 찾을 수 없습니다. 외부망에 helm 설치가 필요합니다."
        exit 1
    fi
fi

# 2. 이미지 다운로드 (외부망)
if [ "$DOWNLOAD_IMAGES" = true ]; then
    echo ""
    echo ">> [2/2] 컨테이너 이미지 수집 시작 (Using ctr)..."
    mkdir -p "$IMAGE_DIR"

    if ! command -v ctr &> /dev/null; then
        echo "❌ [오류] ctr(containerd) 명령을 찾을 수 없습니다. containerd가 기동되는 노드에서 실행하십시오."
        exit 1
    fi

    # haproxy 및 shellcheck: Redis HA 다중화 배포 및 Helm test를 위한 예비 수집용 자산
    IMAGES=(
        "quay.io/argoproj/argocd:v2.12.1"
        "public.ecr.aws/docker/library/redis:7.2.4-alpine"
        "public.ecr.aws/docker/library/haproxy:2.9-alpine"
        "docker.io/koalaman/shellcheck:v0.5.0"
    )

    for img in "${IMAGES[@]}"; do
        echo ""
        echo "🚀 처리 중: $img"
        if [[ "$img" =~ haproxy ]]; then
            echo "   (알림: haproxy는 Redis HA 구성 시에만 선택적으로 사용되는 예비 자산입니다.)"
        elif [[ "$img" =~ shellcheck ]]; then
            echo "   (알림: shellcheck은 Redis HA 모드 시 Helm test 훅용 예비 자산입니다.)"
        fi

        echo -n "   └─ Pulling... "
        if ctr -n k8s.io images pull "$img" > /dev/null 2>&1; then
            echo -e "\033[0;32m[성공]\033[0m"
        else
            echo -e "\033[0;31m[실패]\033[0m"
            echo "   다시 Pull 수행:"
            ctr -n k8s.io images pull "$img" || exit 1
        fi

        filename=$(echo "$img" | sed 's/\//_/g; s/:/_/g').tar
        echo -n "   └─ Exporting to $filename... "
        if ctr -n k8s.io images export "$IMAGE_DIR/$filename" "$img" > /dev/null 2>&1; then
            echo -e "\033[0;32m[성공]\033[0m"
        else
            echo -e "\033[0;31m[실패]\033[0m"
            ctr -n k8s.io images export "$IMAGE_DIR/$filename" "$img" || exit 1
        fi
    done
fi

echo ""
echo "🎉 모든 오프라인 설치 자산 준비 완료."
