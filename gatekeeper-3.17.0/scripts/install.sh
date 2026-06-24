#!/bin/bash

cd "$(dirname "$0")/.." || exit 1

set -euo pipefail

find_binary() {
    local name=$1
    local path
    path=$(command -v "$name" 2>/dev/null || true)
    echo "${path:-$name}"
}

KUBECTL=$(find_binary kubectl)
HELM=$(find_binary helm)
CTR=$(find_binary ctr)

NAMESPACE="gatekeeper-system"
RELEASE="gatekeeper"
CHART="./charts/gatekeeper"
VALUES_FILE="./values.yaml"
VALUES_LOCAL_FILE="./values-local.yaml"
VALUES_TEMP_FILE="./values-temp.yaml"
CONF_FILE="./install.conf"
INSTALLED_VERSION="v3.17.0"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "========================================================================"
echo " Gatekeeper ${INSTALLED_VERSION} offline installer"
echo "========================================================================"

load_conf() {
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
    fi
}

save_conf() {
    cat > "$CONF_FILE" <<EOF
# Gatekeeper ${INSTALLED_VERSION} install configuration. Managed by scripts/install.sh.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY:-}"
HARBOR_PROJECT="${HARBOR_PROJECT:-}"
NAMESPACE="${NAMESPACE}"
REPLICAS="${REPLICAS}"
AUDIT_INTERVAL="${AUDIT_INTERVAL}"
INSTALLED_VERSION="${INSTALLED_VERSION}"
EOF
    echo -e "${GREEN}  - Saved configuration to ${CONF_FILE}.${NC}"
}

cleanup_resources() {
    local reset_mode=$1

    echo -e "${YELLOW}[Clean Up] Removing existing Gatekeeper release...${NC}"
    $HELM uninstall "$RELEASE" -n "$NAMESPACE" --wait=false 2>/dev/null || true

    echo "Waiting for webhook resources to disappear..."
    $KUBECTL delete validatingwebhookconfiguration gatekeeper-validating-webhook-configuration \
        --ignore-not-found=true 2>/dev/null || true
    $KUBECTL delete mutatingwebhookconfiguration gatekeeper-mutating-webhook-configuration \
        --ignore-not-found=true 2>/dev/null || true

    if [ "$reset_mode" = "reset" ]; then
        $KUBECTL delete ns "$NAMESPACE" --ignore-not-found=true --timeout=30s 2>/dev/null || true
        rm -f "$CONF_FILE"
        echo "  - Removed ${CONF_FILE}."
    fi
}

ensure_chart() {
    if [ -d "$CHART" ]; then
        return
    fi

    local tgz
    tgz=$(find ./charts -maxdepth 1 -name 'gatekeeper-*.tgz' -print -quit 2>/dev/null || true)
    if [ -n "$tgz" ]; then
        echo "Found chart archive: $tgz"
        tar -xzf "$tgz" -C ./charts
        return
    fi

    echo -e "${YELLOW}[WARN] ./charts/gatekeeper 경로에 Gatekeeper Helm 차트가 없습니다.${NC}"
    echo "       폐쇄망 설치는 사전 준비된 차트가 필요하지만, 온라인 테스트 환경에서는 지금 다운로드할 수 있습니다."
    read -r -p "Gatekeeper 차트를 온라인으로 지금 다운로드할까요? (y/N): " DOWNLOAD_CHART_ONLINE
    if [[ "$DOWNLOAD_CHART_ONLINE" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        echo "Gatekeeper Helm chart ${INSTALLED_VERSION#v} 다운로드 중..."
        mkdir -p ./charts
        $HELM repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts --force-update >/dev/null 2>&1 || true
        $HELM repo update
        $HELM pull gatekeeper/gatekeeper --version "${INSTALLED_VERSION#v}" --untar -d ./charts
        return
    fi

    echo -e "${RED}[ERROR] Gatekeeper chart is missing.${NC}"
    echo "Place the chart under ./charts/gatekeeper or run ./scripts/download_assets_offline.sh on an internet-connected host."
    exit 1
}

import_local_images() {
    echo "Importing local image tar files into the cluster runtime..."
    shopt -s nullglob
    local image_archives=(./images/*.tar*)
    shopt -u nullglob

    if [ ${#image_archives[@]} -eq 0 ]; then
        echo -e "${YELLOW}[WARN] No image archives were found under ./images.${NC}"
        echo "       이미지 import를 건너뜁니다. 클러스터가 인터넷에 접근 가능하면 Helm 설치 중 공개 레지스트리에서 이미지를 pull합니다."
        echo "       폐쇄망 설치에서는 인터넷 연결 호스트에서 ./scripts/download_assets_offline.sh 실행 후 .tar 파일을 복사하십시오."
        return 0
    fi

    local current_context
    current_context=$($KUBECTL config current-context 2>/dev/null || true)
    if [[ "$current_context" == kind-* ]] && command -v kind >/dev/null 2>&1; then
        local kind_cluster="${current_context#kind-}"
        echo "Detected kind context (${current_context}); loading archives with kind load image-archive."
        for tar_file in "${image_archives[@]}"; do
            echo "  - $(basename "$tar_file") -> kind cluster ${kind_cluster}"
            kind load image-archive "$tar_file" --name "$kind_cluster"
        done
        return 0
    fi

    local node_count
    node_count=$($KUBECTL get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "${node_count:-0}" -gt 1 ]; then
        echo -e "${YELLOW}[WARN] Multi-node cluster detected (${node_count} nodes).${NC}"
        echo "       ctr import only loads images into the current node runtime."
        echo "       Gatekeeper Pods may be scheduled onto worker nodes that do not have these images."
        echo "       For multi-node offline clusters, use Harbor or import the tar files on every schedulable node before installing."
        read -r -p "Continue importing only on this node? (y/N): " CONTINUE_SINGLE_NODE_IMPORT
        if [[ ! "$CONTINUE_SINGLE_NODE_IMPORT" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            echo -e "${RED}[ERROR] Local image import cancelled for multi-node safety.${NC}"
            echo "        Recommended: choose Harbor image source, or run ctr import on every node that can run Gatekeeper Pods."
            exit 1
        fi
    fi

    if ! command -v "$CTR" >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] ctr command was not found, so local image import cannot be performed.${NC}"
        echo "        In kind, use: kind load image-archive ./images/<image>.tar --name <cluster-name>"
        echo "        In a normal containerd cluster, install containerd/ctr or choose Harbor image source."
        exit 1
    fi

    for tar_file in "${image_archives[@]}"; do
        echo "  - $(basename "$tar_file")"
        $CTR -n k8s.io images import "$tar_file"
    done
}

load_conf

EXIST_HELM=$($HELM status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1 && echo "yes" || echo "no")
DO_UPGRADE=false

if [ "$EXIST_HELM" = "yes" ] || [ -f "$CONF_FILE" ]; then
    echo ""
    echo -e "${YELLOW}Existing Gatekeeper installation or configuration detected.${NC}"
    [ -f "$CONF_FILE" ] && echo "  - Config file: $CONF_FILE"
    [ -n "${IMAGE_SOURCE:-}" ] && echo "  - Image source: $IMAGE_SOURCE"
    [ -n "${HARBOR_REGISTRY:-}" ] && echo "  - Harbor: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}"
    [ -n "${NAMESPACE:-}" ] && echo "  - Namespace: $NAMESPACE"
    [ -n "${REPLICAS:-}" ] && echo "  - Replicas: $REPLICAS"
    [ -n "${AUDIT_INTERVAL:-}" ] && echo "  - Audit interval: $AUDIT_INTERVAL"

    echo ""
    echo "작업을 선택하십시오."
    echo "  1) 업그레이드 (저장된 설정 유지, Helm upgrade)"
    echo "  2) 재설치 (기존 릴리스 제거 후 새 설정 입력)"
    echo "  3) 초기화 (릴리스, 네임스페이스, install.conf 제거)"
    echo "  4) 취소"
    read -r -p "선택 [1/2/3/4, 기본값 4]: " ACTION
    ACTION="${ACTION:-4}"

    case "$ACTION" in
        1) DO_UPGRADE=true ;;
        2)
            cleanup_resources "reinstall"
            IMAGE_SOURCE="" HARBOR_REGISTRY="" HARBOR_PROJECT=""
            REPLICAS="" AUDIT_INTERVAL=""
            ;;
        3)
            cleanup_resources "reset"
            echo "초기화가 완료되었습니다."
            exit 0
            ;;
        *)
            echo "설치를 취소했습니다."
            exit 0
            ;;
    esac
fi

if [ -z "${IMAGE_SOURCE:-}" ]; then
    echo ""
    echo "이미지 소스를 선택하십시오."
    echo "  1) Harbor 레지스트리 사용"
    echo "  2) 공개 레지스트리/로컬 이미지 사용"
    read -r -p "선택 [1/2, 기본값 1]: " IMG_SRC
    IMG_SRC="${IMG_SRC:-1}"
    IMAGE_SOURCE=$([ "$IMG_SRC" = "2" ] && echo "local" || echo "harbor")
fi

if [ "$IMAGE_SOURCE" = "harbor" ]; then
    if [ -z "${HARBOR_REGISTRY:-}" ]; then
        read -r -p "Harbor 레지스트리 주소 (예: 172.30.235.20:30002): " HARBOR_REGISTRY
    fi
    if [ -z "${HARBOR_PROJECT:-}" ]; then
        read -r -p "Harbor 프로젝트 (예: library): " HARBOR_PROJECT
        HARBOR_PROJECT="${HARBOR_PROJECT:-library}"
    fi
else
    import_local_images
fi

if [ -z "${NAMESPACE:-}" ]; then
    read -r -p "Namespace [기본값 gatekeeper-system]: " NAMESPACE
    NAMESPACE="${NAMESPACE:-gatekeeper-system}"
fi

if [ -z "${REPLICAS:-}" ]; then
    read -r -p "controller-manager replicas [기본값 3]: " REPLICAS
    REPLICAS="${REPLICAS:-3}"
fi

if [ -z "${AUDIT_INTERVAL:-}" ]; then
    read -r -p "audit interval seconds [기본값 60]: " AUDIT_INTERVAL
    AUDIT_INTERVAL="${AUDIT_INTERVAL:-60}"
fi

ensure_chart
save_conf

echo ""
echo "Preparing Helm values..."
if [ "$IMAGE_SOURCE" = "local" ]; then
    cp "$VALUES_LOCAL_FILE" "$VALUES_TEMP_FILE"
    sed -i -e "s|^replicas:.*|replicas: ${REPLICAS}|g" "$VALUES_LOCAL_FILE"
    sed -i -e "s|^  interval:.*|  interval: ${AUDIT_INTERVAL}|g" "$VALUES_LOCAL_FILE"
else
    GATEKEEPER_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gatekeeper"
    GATEKEEPER_CRDS_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gatekeeper-crds"
    cp "$VALUES_FILE" "$VALUES_TEMP_FILE"
    sed -i -e "s|^  repository:.*|  repository: ${GATEKEEPER_IMAGE}|g" "$VALUES_FILE"
    sed -i -e "s|^  crdRepository:.*|  crdRepository: ${GATEKEEPER_CRDS_IMAGE}|g" "$VALUES_FILE"
    sed -i -e "s|^replicas:.*|replicas: ${REPLICAS}|g" "$VALUES_FILE"
    sed -i -e "s|^  interval:.*|  interval: ${AUDIT_INTERVAL}|g" "$VALUES_FILE"
    
    sed -i -e "s|^  repository:.*|  repository: ${GATEKEEPER_IMAGE}|g" "$VALUES_TEMP_FILE"
    sed -i -e "s|^  crdRepository:.*|  crdRepository: ${GATEKEEPER_CRDS_IMAGE}|g" "$VALUES_TEMP_FILE"
fi

sed -i -e "s|^replicas:.*|replicas: ${REPLICAS}|g" "$VALUES_TEMP_FILE"
sed -i -e "s|^  interval:.*|  interval: ${AUDIT_INTERVAL}|g" "$VALUES_TEMP_FILE"

if [ "$DO_UPGRADE" = true ]; then
    ACTION_TEXT="upgrade"
else
    ACTION_TEXT="install"
fi

echo "Running Gatekeeper Helm ${ACTION_TEXT}..."
$HELM upgrade --install "$RELEASE" "$CHART" \
    -n "$NAMESPACE" \
    --create-namespace \
    -f "$VALUES_TEMP_FILE" \
    --wait

rm -f "$VALUES_TEMP_FILE"

echo ""
echo "========================================================"
echo -e "${GREEN}Gatekeeper ${INSTALLED_VERSION} installation complete.${NC}"
echo "Namespace : $NAMESPACE"
echo "Config    : $CONF_FILE"
echo "========================================================"
$KUBECTL get pods -n "$NAMESPACE"
