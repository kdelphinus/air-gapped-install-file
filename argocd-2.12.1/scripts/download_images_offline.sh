#!/bin/bash

# Root 권한 체크
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

# ArgoCD 2.12.1 Image Download Script (using ctr)
# This script pulls images from public registries and exports them to .tar files.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
IMAGE_DIR="${SCRIPT_DIR}/../images"
mkdir -p "$IMAGE_DIR"

IMAGES=(
    "ghcr.io/argoproj/argo-cd/argocd:v2.12.1"
    "public.ecr.aws/docker/library/redis:7.2.4-alpine"
    "public.ecr.aws/docker/library/haproxy:2.9.7-alpine"
)

echo "===================================================="
echo " 📥 Downloading ArgoCD Images using ctr"
echo "===================================================="

for img in "${IMAGES[@]}"; do
    echo "🚀 Processing: $img"
    
    # 1. Pull image
    echo "   └─ Pulling..."
    ctr -n k8s.io images pull "$img"
    
    # 2. Export to tar
    # Sanitize image name for filename
    filename=$(echo "$img" | sed 's/\//_/g; s/:/_/g').tar
    echo "   └─ Exporting to $IMAGE_DIR/$filename..."
    ctr -n k8s.io images export "$IMAGE_DIR/$filename" "$img"
    
    if [ $? -eq 0 ]; then
        echo "   ✅ Done: $filename"
    else
        echo "   ❌ Failed to export $img"
    fi
done

echo ""
echo "🎉 All images have been saved to $IMAGE_DIR"
