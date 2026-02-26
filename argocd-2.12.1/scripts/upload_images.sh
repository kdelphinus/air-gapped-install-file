#!/bin/bash

# ==================== Config ====================
HARBOR_REGISTRY="harbor.local:30002"
HARBOR_PROJECT="goe"
HARBOR_USER="admin"
HARBOR_PASSWORD="password"
CTR_NAMESPACE="k8s.io"
IMAGE_DIR="../images"
USE_PLAIN_HTTP="true" # Use plain http for local registry if TLS is not configured
TARGET_PLATFORM="linux/amd64"
# ================================================

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Push options
PUSH_OPTS="--platform $TARGET_PLATFORM"
if [ "$USE_PLAIN_HTTP" = "true" ]; then
    PUSH_OPTS="$PUSH_OPTS --plain-http"
fi

echo "========================================================================"
echo " 🏗️  ArgoCD 2.12.1 Image Migration (Convert & Flatten)"
echo "========================================================================"

# Manual mapping for exported files
# 1. quay.io_argoproj_argocd_v2.12.1.tar -> argocd:v2.12.1
# 2. public.ecr.aws_docker_library_redis_7.2.4-alpine.tar -> redis:7.2.4-alpine
# 3. public.ecr.aws_docker_library_haproxy_2.9.7-alpine.tar -> haproxy:2.9.7-alpine

for tar_file in "$IMAGE_DIR"/*.tar; do
    [ -e "$tar_file" ] || break
    
    echo ""
    echo -e "${YELLOW}📦 Processing: $(basename "$tar_file")${NC}"

    # 1. Import (기본 모드)
    echo -n "   └─ 1. Import... "
    ctr -n "$CTR_NAMESPACE" images import "$tar_file" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[Success]${NC}"
    else
        # --all-platforms retry
        if ctr -n "$CTR_NAMESPACE" images import --all-platforms "$tar_file" > /dev/null 2>&1; then
            echo -e "${GREEN}[Success (All-platforms)]${NC}"
        else
            echo -e "${RED}[Fail]${NC}"
            continue
        fi
    fi

    # 2. Extract tags
    repo_tags=$(tar -xOf "$tar_file" manifest.json | grep -o '"RepoTags":\[[^]]*\]' | sed 's/"RepoTags":\[//;s/\]//;s/"//g' | tr ',' '
')

    for source_image in $repo_tags; do
        if [ -z "$source_image" ]; then continue; fi

        # Image name correction (Add docker.io/library if needed)
        check_image=$(ctr -n "$CTR_NAMESPACE" images list -q name=="$source_image")
        if [ -z "$check_image" ]; then
            fixed_source="docker.io/$source_image"
            if [ -n "$(ctr -n "$CTR_NAMESPACE" images list -q name=="$fixed_source")" ]; then
                source_image="$fixed_source"
            else
                fixed_source_lib="docker.io/library/$source_image"
                if [ -n "$(ctr -n "$CTR_NAMESPACE" images list -q name=="$fixed_source_lib")" ]; then
                    source_image="$fixed_source_lib"
                fi
            fi
        fi

        # Target image name generation
        # e.g., ghcr.io/argoproj/argo-cd/argocd:v2.12.1 -> harbor.local:30002/goe/argocd:v2.12.1
        image_name_tag=$(echo "$source_image" | awk -F/ '{print $NF}')
        target_image="$HARBOR_REGISTRY/$HARBOR_PROJECT/$image_name_tag"

        # 2. Convert: Flatten multi-arch into single manifest (amd64)
        echo -e "   └─ 2. Convert: $target_image"
        
        # Cleanup if target already exists to prevent convert conflict
        ctr -n "$CTR_NAMESPACE" images rm "$target_image" > /dev/null 2>&1

        # Perform conversion
        ctr -n "$CTR_NAMESPACE" images convert 
            --platform "$TARGET_PLATFORM" 
            "$source_image" "$target_image" > /dev/null 2>&1

        if [ $? -ne 0 ]; then
            # Convert fail case (e.g., image is already single-arch)
            echo -e "      (Convert not available -> attempting regular tag)"
            ctr -n "$CTR_NAMESPACE" images tag "$source_image" "$target_image"
        fi
        
        # 3. Push
        echo -n "   └─ 3. Push... "
        if ctr -n "$CTR_NAMESPACE" images push $PUSH_OPTS --user "$HARBOR_USER:$HARBOR_PASSWORD" "$target_image" > /dev/null 2>&1; then
            echo -e "${GREEN}[Success]${NC}"
        else
            echo -e "${RED}[Fail]${NC}"
            # Show error log
            ctr -n "$CTR_NAMESPACE" images push $PUSH_OPTS --user "$HARBOR_USER:$HARBOR_PASSWORD" "$target_image"
        fi
    done
done
