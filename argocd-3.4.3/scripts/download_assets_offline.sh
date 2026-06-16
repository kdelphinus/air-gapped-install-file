#!/bin/bash

# Root 권한 체크
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

set -e

# 스크립트 위치 기준으로 컴포넌트 루트 디렉토리 결정
BASE_DIR=$(cd "$(dirname "$0")/.." && pwd)
CHART_DIR="${BASE_DIR}/charts"
IMAGE_DIR="${BASE_DIR}/images"

mkdir -p "$CHART_DIR" "$IMAGE_DIR"

select_download_scope() {
    echo "===================================================="
    echo " 📥 ArgoCD v3.4.3 오프라인 에셋 다운로드"
    echo "===================================================="
    echo "다운로드 범위를 선택하세요:"
    echo "  1) 전체 (Helm 차트 + 컨테이너 이미지)"
    echo "  2) Helm 차트만"
    echo "  3) 컨테이너 이미지만"
    read -p "선택 [1/2/3, 기본값: 1]: " DOWNLOAD_SCOPE
    DOWNLOAD_SCOPE="${DOWNLOAD_SCOPE:-1}"

    case "$DOWNLOAD_SCOPE" in
        1|all|ALL) DOWNLOAD_HELM=true; DOWNLOAD_IMAGES=true ;;
        2|helm|HELM) DOWNLOAD_HELM=true; DOWNLOAD_IMAGES=false ;;
        3|image|images|IMAGE|IMAGES) DOWNLOAD_HELM=false; DOWNLOAD_IMAGES=true ;;
        *) echo "[오류] 1, 2, 또는 3을 선택하세요."; exit 1 ;;
    esac
}

select_download_scope

# 1. Helm 차트 다운로드
if [ "$DOWNLOAD_HELM" = true ]; then
    echo ""
    echo "📦 [1/2] ArgoCD Helm 차트 다운로드 중..."
    helm repo add argo https://argoproj.github.io/argo-helm > /dev/null 2>&1 || true
    helm repo update > /dev/null 2>&1 || true
    
    # 9.5.21 차트를 CHART_DIR에 풀 받음
    helm pull argo/argo-cd --version 9.5.21 -d "$CHART_DIR"
    echo "   ✅ Helm 차트 다운로드 완료: argo-cd-9.5.21.tgz"
fi

# 2. 컨테이너 이미지 다운로드
IMAGES=(
    "quay.io/argoproj/argocd:v3.4.4"
    "ghcr.io/dexidp/dex:v2.45.1"
    "ecr-public.aws.com/docker/library/redis:8.2.3-alpine"
    "ghcr.io/oliver006/redis_exporter:v1.86.0"
    "public.ecr.aws/docker/library/haproxy:3.0.8-alpine"
    "quay.io/argoprojlabs/argocd-extension-installer:v1.0.1"
)

if [ "$DOWNLOAD_IMAGES" = true ]; then
    echo ""
    echo "🚀 [2/2] 컨테이너 이미지 다운로드 및 저장 중..."
    
    # 사용 가능한 CLI 자동 감지 (docker -> skopeo -> ctr)
    if command -v docker >/dev/null 2>&1; then
        CLI="docker"
        echo "   ℹ️ 감지된 CLI: docker (이것을 사용하여 이미지를 다운로드/저장합니다.)"
    elif command -v skopeo >/dev/null 2>&1; then
        CLI="skopeo"
        echo "   ℹ️ 감지된 CLI: skopeo (이것을 사용하여 이미지를 다운로드/저장합니다.)"
    elif command -v ctr >/dev/null 2>&1; then
        CLI="ctr"
        echo "   ℹ️ 감지된 CLI: ctr (이것을 사용하여 이미지를 다운로드/저장합니다.)"
    else
        echo -e "   \033[0;31m[오류] 이미지를 다운로드할 수 있는 도구(docker, skopeo, ctr)가 설치되어 있지 않습니다.\033[0m"
        exit 1
    fi

    for IMG in "${IMAGES[@]}"; do
        # 파일명으로 적절하게 변환
        FILENAME=$(echo "$IMG" | sed 's/\//_/g; s/:/_/g').tar
        TAR_PATH="${IMAGE_DIR}/${FILENAME}"

        echo "   → 저장 예정 경로: ${TAR_PATH}"
        rm -f "$TAR_PATH"

        if [ "$CLI" = "docker" ]; then
            echo "     └─ [docker] pulling: $IMG"
            docker pull "$IMG"
            echo "     └─ [docker] exporting to tar..."
            docker save -o "$TAR_PATH" "$IMG"
        elif [ "$CLI" = "skopeo" ]; then
            echo "     └─ [skopeo] copying: $IMG"
            skopeo copy \
              --override-os linux \
              --override-arch amd64 \
              "docker://${IMG}" \
              "docker-archive:${TAR_PATH}:${IMG}"
        elif [ "$CLI" = "ctr" ]; then
            echo "     └─ [ctr] pulling (k8s.io namespace): $IMG"
            ctr -n k8s.io images pull "$IMG"
            echo "     └─ [ctr] exporting to tar..."
            ctr -n k8s.io images export "$TAR_PATH" "$IMG"
        fi

        if [ $? -eq 0 ] && [ -f "$TAR_PATH" ]; then
            echo "     ✅ 성공: $(basename "$TAR_PATH")"
        else
            echo "     ❌ 실패: $IMG 다운로드 또는 저장 오류"
            exit 1
        fi
    done
fi

echo ""
echo "🎉 모든 오프라인 에셋 다운로드가 완료되었습니다."
echo "   - 차트 경로: $CHART_DIR"
echo "   - 이미지 경로: $IMAGE_DIR"
