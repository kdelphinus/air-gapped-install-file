#!/bin/bash
# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

# ==========================================
# [설정] 기본 변수
# ==========================================
NAMESPACE="nexus"
RELEASE_NAME="nexus"
CHART_PATH="./charts/nexus-repository-manager"
VALUES_FILE="./values.yaml"
CONF_FILE="./install.conf"
NODE_LABEL_KEY="nexus-node"
NODE_LABEL_VALUE="true"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ── install.conf 로드 / 저장 ──────────────────────────────
load_conf() {
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
    fi
}

save_conf() {
    cat > "$CONF_FILE" <<EOF
# Nexus v3.70.1 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
IMAGE_REGISTRY="${IMAGE_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
STORAGE_CLASS="${STORAGE_CLASS}"
STORAGE_SIZE="${STORAGE_SIZE}"
TARGET_NODE="${TARGET_NODE}"
INSTALLED_VERSION="v3.70.1"
EOF
    echo -e "  ✅ 설정이 ${GREEN}${CONF_FILE}${NC} 에 저장되었습니다."
}

# ==========================================
# [함수] 클린업 로직
# ==========================================
cleanup_resources() {
    local RESET_MODE=$1
    echo ""
    echo -e "🧹 ${YELLOW}[Clean Up] 기존 Nexus 리소스 제거 시작...${NC}"

    # Helm Uninstall
    if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "⏳ Helm 차트 삭제 중..."
        helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait=false 2>/dev/null
        sleep 3
    fi

    # HTTPRoute 제거
    if [ -f "./manifests/httproute.yaml" ]; then
        echo "🗑️  HTTPRoute 삭제 중..."
        kubectl delete -f ./manifests/httproute.yaml --ignore-not-found=true 2>/dev/null
    fi

    local DELETE_VOLUMES="no"
    if [ "$RESET_MODE" == "reset" ]; then
        DELETE_VOLUMES="yes"
    else
        echo ""
        read -p "⚠️  PV/PVC 도 함께 삭제하시겠습니까? (데이터 영구 삭제, y/n): " DELETE_DATA
        if [[ "${DELETE_DATA}" =~ ^[Yy]$ ]]; then
            DELETE_VOLUMES="yes"
        fi
    fi

    if [ "$DELETE_VOLUMES" == "yes" ]; then
        echo "🗑️  PVC 삭제 중..."
        kubectl delete pvc -n "$NAMESPACE" --all --ignore-not-found=true 2>/dev/null
    else
        echo "➡️  PVC 및 PV 볼륨 데이터가 보존되었습니다."
    fi

    # 네임스페이스 삭제 (볼륨 보존 시 cascade delete 방지를 위해 우회)
    if [ "$DELETE_VOLUMES" == "yes" ]; then
        if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
            echo "🗑️  Namespace '${NAMESPACE}' 삭제 중..."
            kubectl delete ns "$NAMESPACE" --ignore-not-found=true --timeout=30s 2>/dev/null
        fi
    else
        echo "➡️  볼륨 보존 선택에 따라 Namespace '${NAMESPACE}' 삭제 단계를 생략합니다."
    fi

    if [ "$DELETE_VOLUMES" == "yes" ]; then
        echo "🗑️  PV 삭제 중..."
        kubectl get pv 2>/dev/null | grep "$NAMESPACE" | awk '{print $1}' | xargs -r kubectl delete pv 2>/dev/null
    fi

    if [ "$RESET_MODE" == "reset" ]; then
        rm -f "$CONF_FILE"
        rm -f "./values-infra.yaml"
        echo -e "🗑️  설정 파일 및 생성된 인프라 파일 삭제 완료 (Reset)."
    fi

    echo -e "${GREEN}✅ 초기화 완료.${NC}"
    echo ""
}

# 쉘 명령어 사전 체크
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}[오류] '$1' 명령어를 찾을 수 없습니다. 설치 후 다시 진행하십시오.${NC}"
        exit 1
    fi
}

# ==========================================
# [1] 기존 설치 감지 및 메뉴
# ==========================================
load_conf
check_command kubectl
check_command helm

EXIST_HELM=$(helm status "$RELEASE_NAME" -n "$NAMESPACE" > /dev/null 2>&1 && echo "yes" || echo "no")
DO_UPGRADE=false

if [ "$EXIST_HELM" == "yes" ] || [ -f "$CONF_FILE" ]; then
    echo ""
    echo -e "⚠️  ${YELLOW}기존 설치 또는 설정이 감지되었습니다.${NC}"
    [ -f "$CONF_FILE" ] && echo "  📋 저장된 설정 정보:"
    [ -n "$IMAGE_SOURCE" ] && echo "     - 이미지 소스  : $IMAGE_SOURCE (1=Harbor, 2=Local)"
    [ "$IMAGE_SOURCE" == "1" ] && echo "     - 레지스트리   : $IMAGE_REGISTRY/$HARBOR_PROJECT"
    [ -n "$STORAGE_CLASS" ] && echo "     - 스토리지클래스: $STORAGE_CLASS (용량: $STORAGE_SIZE)"
    [ -n "$TARGET_NODE" ] && echo "     - 고정 노드    : $TARGET_NODE"

    echo ""
    echo "동작을 선택하세요:"
    echo "  1) 업그레이드 (저장된 설정 유지, Helm upgrade)"
    echo "  2) 재설치     (기존 리소스 삭제 후 새로 설치)"
    echo "  3) 초기화     (모든 리소스 및 설정 파일 완전 삭제)"
    echo "  4) 취소"
    read -p "선택 [1/2/3/4]: " ACTION

    case "$ACTION" in
        1) DO_UPGRADE=true ;;
        2) cleanup_resources "reinstall" ;;
        3) cleanup_resources "reset"; exit 0 ;;
        *) echo "취소되었습니다."; exit 0 ;;
    esac
fi

# ==========================================
# [2] 설치 설정 입력 (새로 설치 시에만)
# ==========================================
if [ "$DO_UPGRADE" != "true" ]; then
    # 2-1. 이미지 소스
    echo ""
    echo "이미지 소스를 선택하세요:"
    echo "  1) Harbor 레지스트리 사용 (사전에 images/upload_images_to_harbor_v3-lite.sh 실행 필요)"
    echo "  2) 로컬 tar 직접 import (이미 이미지가 로드된 경우 건너뜀)"
    read -p "선택 [1/2, 기본값: 1]: " IMAGE_SOURCE
    IMAGE_SOURCE="${IMAGE_SOURCE:-1}"

    if [ "${IMAGE_SOURCE}" = "1" ]; then
        read -p "Harbor 레지스트리 주소 (예: 192.168.1.10:30002 또는 harbor.example.com): " IMAGE_REGISTRY
        if [ -z "${IMAGE_REGISTRY}" ]; then
            echo -e "${RED}[오류] Harbor 레지스트리 주소가 필요합니다.${NC}"; exit 1
        fi
        read -p "Harbor 프로젝트 (예: library, oss): " HARBOR_PROJECT
        if [ -z "${HARBOR_PROJECT}" ]; then
            echo -e "${RED}[오류] Harbor 프로젝트가 필요합니다.${NC}"; exit 1
        fi
    elif [ "${IMAGE_SOURCE}" = "2" ]; then
        echo "로컬 tar 파일을 containerd(k8s.io)에 import 중..."
        IMPORT_COUNT=0
        for tar_file in ./images/*.tar; do
            [ -e "${tar_file}" ] || continue
            echo "  → $(basename "${tar_file}")"
            sudo ctr -n k8s.io images import "${tar_file}" 2>/dev/null || true
            IMPORT_COUNT=$((IMPORT_COUNT + 1))
        done
        [ "${IMPORT_COUNT}" -eq 0 ] && echo -e "${YELLOW}[경고] ./images/ 에 tar 파일이 없습니다.${NC}"
        echo "  ${IMPORT_COUNT}개 이미지 import 완료"
        IMAGE_REGISTRY=""
        HARBOR_PROJECT=""
    else
        echo -e "${RED}[오류] 1 또는 2를 선택하세요.${NC}"; exit 1
    fi

    # 2-2. 스토리지 클래스 및 용량 입력
    echo ""
    read -p "스토리지 클래스 이름 (기본값: nfs-provisioner): " STORAGE_CLASS
    STORAGE_CLASS="${STORAGE_CLASS:-nfs-provisioner}"
    read -p "스토리지 할당 크기 (기본값: 100Gi): " STORAGE_SIZE
    STORAGE_SIZE="${STORAGE_SIZE:-100Gi}"

    # 2-3. 노드 고정 고정
    echo ""
    echo ">>> 사용 가능한 노드 목록:"
    kubectl get nodes -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[-1].type,ROLES:.metadata.labels.node-role\.kubernetes\.io/worker" 2>/dev/null || true
    echo ""
    read -p "Nexus를 배치할 노드 이름 (엔터 = 자동 배치): " TARGET_NODE
fi

save_conf

# ==========================================
# [3] 설정 파일(values-infra.yaml) 생성 및 리소스 배포
# ==========================================
echo "🔧 인프라 설정 파일(values-infra.yaml) 생성 중..."

# Nexus 이미지 설정
if [ "${IMAGE_SOURCE}" = "1" ]; then
    NEXUS_IMAGE_REPO="${IMAGE_REGISTRY}/${HARBOR_PROJECT}/nexus3"
else
    NEXUS_IMAGE_REPO="sonatype/nexus3"
fi

# 노드 고정 (nodeSelector) 블록 구성
NODE_SELECTOR_BLOCK="nodeSelector: {}"
if [ -n "${TARGET_NODE}" ]; then
    kubectl label nodes "${TARGET_NODE}" "${NODE_LABEL_KEY}=${NODE_LABEL_VALUE}" --overwrite 2>/dev/null || true
    NODE_SELECTOR_BLOCK="nodeSelector:
  ${NODE_LABEL_KEY}: \"${NODE_LABEL_VALUE}\""
fi

cat > ./values-infra.yaml <<EOF
# Nexus v3.70.1 인프라 설정 — install.sh 에 의해 자동 관리됩니다.
image:
  repository: "${NEXUS_IMAGE_REPO}"
  tag: "3.70.1"
  pullPolicy: "IfNotPresent"

persistence:
  enabled: true
  accessMode: "ReadWriteOnce"
  storageClass: "${STORAGE_CLASS}"
  size: "${STORAGE_SIZE}"

${NODE_SELECTOR_BLOCK}
EOF

# ==========================================
# [4] K8s 리소스 배포 및 Helm 설치 진행
# ==========================================
echo ""
echo -e "🚀 ${GREEN}[1/2] K8s 네임스페이스 리소스 생성 중...${NC}"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo -e "🚀 ${GREEN}[2/2] Nexus Helm 차트 배포 중... (${DO_UPGRADE:+업그레이드}${DO_UPGRADE:-설치})${NC}"
if [ ! -d "${CHART_PATH}" ]; then
    echo -e "${RED}[오류] Helm 차트 디렉토리 '${CHART_PATH}' 가 없습니다.${NC}"; exit 1
fi

helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" \
    --namespace "$NAMESPACE" \
    -f "$VALUES_FILE" \
    -f ./values-infra.yaml \
    --wait

echo ""
echo "========================================================"
echo -e " 🎉 ${GREEN}구성 완료! (Nexus Repository Manager v3.70.1)${NC}"
echo " 네임스페이스 : ${NAMESPACE}"
echo " 접속 포트   : 30081 (NodePort)"
echo " 접속 주소   : http://<NodeIP>:30081"
echo ""
echo " Envoy HTTPRoute를 사용할 경우 아래 명령을 수동 적용하세요:"
echo "   sed \"s|nexus.devops.internal|<NEXUS_DOMAIN>|g\" ./manifests/httproute.yaml | kubectl apply -f -"
echo "   kubectl get httproute nexus-route -n ${NAMESPACE}"
echo "========================================================"
echo ""
