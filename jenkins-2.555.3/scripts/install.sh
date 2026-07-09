#!/bin/bash
set -e

# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

# ==========================================
# [설정] 기본 변수
# ==========================================
NAMESPACE="jenkins"
RELEASE_NAME="jenkins"
CHART_PATH="./charts/jenkins"
VALUES_FILE="./values.yaml"
CONF_FILE="./install.conf"
PV_FILE="./manifests/pv-volume.yaml"
NAS_PV_FILE="./manifests/nas-pv.yaml"
GRADLE_CACHE_FILE="./manifests/gradle-cache-pv-pvc.yaml"
NODE_LABEL_KEY="jenkins-node"
NODE_LABEL_VALUE="true"

# 이미지 태그 정보 고정
CONTROLLER_TAG="2.555.3"
AGENT_TAG="latest"
SIDECAR_TAG="1.30.7"

# 색상 코드
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
# Jenkins 2.555.3 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
USE_CUSTOM_IMAGE="${USE_CUSTOM_IMAGE}"
ENABLE_CICD_BUILDAH="${ENABLE_CICD_BUILDAH}"
BUILDAH_AGENT_IMAGE="${BUILDAH_AGENT_IMAGE}"
STORAGE_TYPE="${STORAGE_TYPE}"
STORAGE_CLASS="${STORAGE_CLASS}"
HOSTPATH_DIR="${HOSTPATH_DIR}"
NAS_SERVER="${NAS_SERVER}"
NAS_PATH="${NAS_PATH}"
STORAGE_SIZE="${STORAGE_SIZE}"
SVC_TYPE="${SVC_TYPE}"
TLS_ENABLED="${TLS_ENABLED}"
DOMAIN="${DOMAIN}"
TARGET_NODE="${TARGET_NODE}"
INSTALLED_VERSION="v2.555.3"
EOF
    echo -e "  ✅ 설정이 ${GREEN}${CONF_FILE}${NC} 에 저장되었습니다."
}

is_hostpath_storage() {
    [ "$STORAGE_TYPE" == "hostpath" ] || [ "$STORAGE_TYPE" == "static" ]
}

is_static_pv_storage() {
    is_hostpath_storage || [ "$STORAGE_TYPE" == "nas" ]
}

# ==========================================
# [함수] 클린업 로직
# ==========================================
cleanup_resources() {
    local RESET_MODE=$1
    echo ""
    echo -e "🧹 ${YELLOW}[Clean Up] 기존 Jenkins 리소스 제거 시작...${NC}"

    # 1. PV/PVC 삭제 여부 프롬프트 먼저 획득 (P0 준수)
    local DELETE_VOLUMES="no"
    echo ""
    read -p "⚠️  PV/PVC도 함께 삭제하시겠습니까? (데이터 영구 삭제, y/n): " DELETE_DATA
    if [[ "${DELETE_DATA}" =~ ^[Yy]$ ]]; then
        DELETE_VOLUMES="yes"
    fi

    # 2. 볼륨 보존 시 helm uninstall에 의한 PVC 자동 제거 방지 (keep 어노테이션 주입)
    if [ "$DELETE_VOLUMES" != "yes" ]; then
        if kubectl get pvc jenkins -n "$NAMESPACE" >/dev/null 2>&1; then
            echo "🛡️  볼륨 보존을 위해 PVC 'jenkins'에 keep resource-policy를 설정합니다..."
            kubectl annotate pvc jenkins -n "$NAMESPACE" "helm.sh/resource-policy=keep" --overwrite 2>/dev/null || true
        fi
    fi

    # 3. Helm Uninstall
    if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "⏳ Helm 차트 삭제 중..."
        helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait=false 2>/dev/null
        sleep 3
    fi

    # 노드 라벨 제거 (Reset 모드 시에만 초기화 진행)
    if [ "$RESET_MODE" == "reset" ]; then
        echo "🗑️  노드 라벨 '$NODE_LABEL_KEY' 제거 중..."
        kubectl label nodes --all ${NODE_LABEL_KEY}- > /dev/null 2>&1 || true
    fi

    # 4. PVC/PV 삭제 처리
    if [ "$DELETE_VOLUMES" == "yes" ]; then
        echo "   - PVC 삭제 중..."
        kubectl delete pvc -n $NAMESPACE jenkins --ignore-not-found=true 2>/dev/null || true
        kubectl delete pvc -n $NAMESPACE gradle-cache-pvc --ignore-not-found=true 2>/dev/null || true
    else
        echo "➡️  PVC 및 PV 볼륨 데이터가 보존되었습니다."
    fi

    # 네임스페이스 삭제 (볼륨 보존 시 cascade delete 방지를 위해 우회)
    if [ "$DELETE_VOLUMES" == "yes" ]; then
        if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
            echo "   - 네임스페이스 삭제 중 (완료까지 시간이 걸릴 수 있습니다)..."
            kubectl delete namespace "$NAMESPACE" --ignore-not-found --timeout=30s 2>/dev/null
        fi
    else
        echo "➡️  볼륨 보존 선택에 따라 Namespace '${NAMESPACE}' 삭제 단계를 생략합니다."
    fi

    if [ "$DELETE_VOLUMES" == "yes" ]; then
        echo "   - PV 삭제 중..."
        kubectl delete pv jenkins-pv gradle-cache-pv --ignore-not-found=true 2>/dev/null || true
    fi

    if [ "$RESET_MODE" == "reset" ]; then
        rm -f "$CONF_FILE"
        rm -f "./values-infra.yaml"
        echo -e "🗑️  설정 파일 및 생성된 인프라 파일 삭제 완료 (Reset)."
    fi

    echo -e "${GREEN}✅ 초기화 완료.${NC}"
    echo ""
}

prepare_hostpath_permissions() {
    local jenkins_path="$1"
    local gradle_path="/data/gradle-cache"
    local current_context
    current_context=$(kubectl config current-context 2>/dev/null || true)

    echo "   → HostPath 디렉터리 권한 확인 중..."
    if [[ "$current_context" == kind-* ]] && command -v kind >/dev/null 2>&1 && command -v docker >/dev/null 2>&1; then
        local kind_cluster="${current_context#kind-}"
        local kind_nodes
        kind_nodes=$(kind get nodes --name "$kind_cluster" 2>/dev/null || true)
        if [ -z "$kind_nodes" ]; then
            echo -e "${YELLOW}[경고] kind 노드 목록을 확인하지 못했습니다. HostPath 권한 보정을 건너뜁니다.${NC}"
            return 0
        fi

        while IFS= read -r node_name; do
            [ -n "$node_name" ] || continue
            echo "     - ${node_name}: ${jenkins_path}, ${gradle_path} -> 1000:1000"
            docker exec "$node_name" sh -c "mkdir -p '$jenkins_path' '$gradle_path' && chown -R 1000:1000 '$jenkins_path' '$gradle_path'" >/dev/null
        done <<< "$kind_nodes"
        return 0
    fi

    echo -e "${YELLOW}[주의] HostPath 디렉터리는 Jenkins UID/GID 1000이 쓸 수 있어야 합니다.${NC}"
    if [ -n "$TARGET_NODE" ]; then
        echo "       대상 노드(${TARGET_NODE})에서 아래 명령을 먼저 실행하세요:"
    else
        echo "       Jenkins Pod가 배치될 모든 후보 노드에서 아래 명령을 먼저 실행하세요:"
    fi
    echo "       sudo mkdir -p '${jenkins_path}' '${gradle_path}'"
    echo "       sudo chown -R 1000:1000 '${jenkins_path}' '${gradle_path}'"
}

load_image_archive_to_cluster() {
    local tar_file="$1"

    if [ ! -f "$tar_file" ]; then
        echo -e "${RED}[오류] 이미지 tar 파일이 없습니다: ${tar_file}${NC}"
        return 1
    fi

    local current_context
    current_context=$(kubectl config current-context 2>/dev/null || true)
    if [[ "$current_context" == kind-* ]] && command -v kind >/dev/null 2>&1; then
        local kind_cluster="${current_context#kind-}"
        echo "   → kind 클러스터(${kind_cluster})에 $(basename "$tar_file") 로드 중..."
        kind load image-archive "$tar_file" --name "$kind_cluster"
        return 0
    fi

    if command -v docker >/dev/null 2>&1; then
        echo "   → docker에 $(basename "$tar_file") 로드 중..."
        docker load -i "$tar_file" >/dev/null
        return 0
    fi

    if command -v ctr >/dev/null 2>&1; then
        echo "   → containerd(k8s.io)에 $(basename "$tar_file") 로드 중..."
        sudo ctr -n k8s.io images import "$tar_file" >/dev/null
        return 0
    fi

    echo -e "${RED}[오류] 이미지 로드를 위해 kind, docker 또는 ctr 중 하나가 필요합니다.${NC}"
    return 1
}

prepare_buildah_agent_image() {
    [ "$ENABLE_CICD_BUILDAH" == "true" ] || return 0

    local buildah_tar="./images/jenkins-buildah-agent_1.41.4.tar"

    if [ "$IMAGE_SOURCE" == "harbor" ]; then
        BUILDAH_AGENT_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/jenkins-buildah-agent:1.41.4"
        echo "   → Buildah agent 이미지는 Harbor에서 pull합니다: ${BUILDAH_AGENT_IMAGE}"
        read -p "Jenkins namespace에 harbor-regcred Secret을 생성/갱신하시겠습니까? (y/N): " _CREATE_REGCRED
        if [[ "$_CREATE_REGCRED" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            read -p "Harbor 사용자명 (기본 admin): " HARBOR_USER
            HARBOR_USER="${HARBOR_USER:-admin}"
            read -sp "Harbor 비밀번호: " HARBOR_PASSWORD; echo
            kubectl -n "$NAMESPACE" create secret docker-registry harbor-regcred \
                --docker-server="$HARBOR_REGISTRY" \
                --docker-username="$HARBOR_USER" \
                --docker-password="$HARBOR_PASSWORD" \
                --dry-run=client -o yaml | kubectl apply -f -
        fi
        return 0
    fi

    BUILDAH_AGENT_IMAGE="jenkins-buildah-agent:1.41.4"
    if [ ! -f "$buildah_tar" ]; then
        if [ "$IMAGE_SOURCE" != "online" ]; then
            echo -e "${RED}[오류] Buildah agent tar가 없습니다: ${buildah_tar}${NC}"
            echo "       온라인 모드에서 자동 빌드하거나, 온라인 준비 환경에서 jenkins-build/buildah-agent/build-buildah-agent.sh를 먼저 실행하세요."
            exit 1
        fi
        echo "   → 온라인 모드: Buildah agent 이미지를 자동 빌드합니다."
        (cd ./jenkins-build/buildah-agent && chmod +x ./build-buildah-agent.sh && ./build-buildah-agent.sh)
    fi

    load_image_archive_to_cluster "$buildah_tar"
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
    [ -n "$IMAGE_SOURCE" ] && echo "     - 이미지 소스   : $IMAGE_SOURCE"
    [ -n "$USE_CUSTOM_IMAGE" ] && echo "     - 커스텀 이미지 : $USE_CUSTOM_IMAGE (OpenTofu 내장)"
    [ -n "$STORAGE_TYPE" ] && echo "     - 스토리지 유형 : $STORAGE_TYPE"
    [ -n "$SVC_TYPE" ] && echo "     - 서비스 노출   : $SVC_TYPE"
    [ -n "$DOMAIN" ] && echo "     - 도메인 주소   : $DOMAIN"

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
if [ "$DO_UPGRADE" == "true" ]; then
    echo ""
    _DEFAULT_BUILDAH="y"
    [ "$ENABLE_CICD_BUILDAH" == "false" ] && _DEFAULT_BUILDAH="n"
    read -p "CI/CD용 Buildah Jenkins agent를 구성/갱신하시겠습니까? (y/n, 기본 ${_DEFAULT_BUILDAH}): " _ENABLE_BUILDAH
    _ENABLE_BUILDAH="${_ENABLE_BUILDAH:-$_DEFAULT_BUILDAH}"
    if [[ "$_ENABLE_BUILDAH" =~ ^[Yy]$ ]]; then
        ENABLE_CICD_BUILDAH="true"
    else
        ENABLE_CICD_BUILDAH="false"
        BUILDAH_AGENT_IMAGE=""
    fi
fi

if [ "$DO_UPGRADE" != "true" ]; then
    # 2-1. 이미지 소스 선택
    echo ""
    echo "이미지 소스를 선택하세요:"
    echo "  1) Harbor 레지스트리 사용 (폐쇄망 권장)"
    echo "  2) 로컬 이미지 tar 직접 사용 (kind/docker/containerd 로드)"
    echo "  3) 온라인 공개 레지스트리 사용 (인터넷 연결 필요)"
    read -p "선택 [1/2/3, 기본값 1]: " _IMG_SRC
    case "${_IMG_SRC:-1}" in
        1)
            IMAGE_SOURCE="harbor"
            read -p "Harbor 주소 (예: 192.168.1.10:30002): " HARBOR_REGISTRY
            read -p "Harbor 프로젝트 (예: library): " HARBOR_PROJECT
            ;;
        2)
            IMAGE_SOURCE="local"
            HARBOR_REGISTRY=""
            HARBOR_PROJECT=""
            ;;
        3)
            IMAGE_SOURCE="online"
            HARBOR_REGISTRY=""
            HARBOR_PROJECT=""
            echo "온라인 공개 레지스트리(docker.io)에서 Jenkins 기본 이미지를 pull합니다."
            ;;
        *)
            echo -e "${RED}[오류] 이미지 소스는 1, 2, 3 중 하나를 선택해야 합니다.${NC}"
            exit 1
            ;;
    esac

    if [ "$IMAGE_SOURCE" == "local" ]; then
        shopt -s nullglob
        IMAGE_ARCHIVES=(./images/*.tar*)
        shopt -u nullglob
        if [ ${#IMAGE_ARCHIVES[@]} -eq 0 ]; then
            echo -e "${YELLOW}[경고] ./images/ 아래에 이미지 tar 파일이 없습니다.${NC}"
            echo "       폐쇄망 설치에서는 이미지 tar를 준비하거나 Harbor 레지스트리 방식을 선택하세요."
            exit 1
        fi

        CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || true)
        if [[ "$CURRENT_CONTEXT" == kind-* ]] && command -v kind >/dev/null 2>&1; then
            KIND_CLUSTER="${CURRENT_CONTEXT#kind-}"
            LOCAL_CLI="kind"
            echo -e "📦 kind 클러스터(${GREEN}${KIND_CLUSTER}${NC})에 로컬 이미지를 로드 중..."
            for tar_file in "${IMAGE_ARCHIVES[@]}"; do
                echo "  → $(basename "$tar_file") -> kind/${KIND_CLUSTER}"
                kind load image-archive "$tar_file" --name "$KIND_CLUSTER"
            done
        else
            NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
            if [ "${NODE_COUNT:-0}" -gt 1 ]; then
                echo -e "${YELLOW}[경고] 멀티노드 클러스터(${NODE_COUNT} nodes)에서 로컬 이미지 방식을 선택했습니다.${NC}"
                echo "       docker/ctr import는 현재 접속한 런타임에만 이미지를 넣습니다."
                echo "       Jenkins Pod가 다른 노드에 스케줄되면 ImagePullBackOff가 발생할 수 있습니다."
                read -p "현재 노드에만 이미지를 로드하고 계속하시겠습니까? (y/N): " CONTINUE_LOCAL_IMPORT
                if [[ ! "$CONTINUE_LOCAL_IMPORT" =~ ^[Yy]([Ee][Ss])?$ ]]; then
                    echo -e "${RED}[오류] 로컬 이미지 import를 취소했습니다. Harbor 방식을 사용하거나 모든 노드에 이미지를 로드하세요.${NC}"
                    exit 1
                fi
            fi

            # CLI 감지
            if command -v docker >/dev/null 2>&1; then
                LOCAL_CLI="docker"
            elif command -v ctr >/dev/null 2>&1; then
                LOCAL_CLI="ctr"
            else
                echo -e "${RED}[오류] 로컬 이미지를 로드할 수 있는 kind, docker 또는 ctr이 설치되어 있지 않습니다.${NC}"
                exit 1
            fi

            echo -e "📦 ${GREEN}${LOCAL_CLI}${NC}를 사용하여 로컬 이미지를 containerd/docker에 로드 중..."
            for tar_file in "${IMAGE_ARCHIVES[@]}"; do
                echo "  → $(basename "$tar_file") 임포트 중"
                if [ "$LOCAL_CLI" == "docker" ]; then
                    docker load -i "$tar_file" 2>/dev/null
                else
                    sudo ctr -n k8s.io images import "$tar_file" 2>/dev/null
                fi
            done
        fi
    fi

    # 2-2. OpenTofu 커스텀 이미지 사용 여부
    echo ""
    if [ "$IMAGE_SOURCE" == "online" ]; then
        USE_CUSTOM_IMAGE="false"
        echo "온라인 공개 레지스트리 모드는 Jenkins 공식 이미지를 사용합니다."
        echo "OpenTofu 커스텀 이미지가 필요하면 Harbor 또는 로컬 이미지 tar 방식을 선택하세요."
    else
        read -p "OpenTofu가 내장된 커스텀 이미지(cmp-jenkins-full)를 사용하겠습니까? (y/n, 기본 y): " _USE_CUSTOM
        if [[ "${_USE_CUSTOM:-y}" =~ ^[Yy]$ ]]; then
            USE_CUSTOM_IMAGE="true"
        else
            USE_CUSTOM_IMAGE="false"
        fi
    fi

    # 2-3. CI/CD Buildah agent 구성 여부
    echo ""
    read -p "CI/CD용 Buildah Jenkins agent를 자동 구성하시겠습니까? (y/n, 기본 y): " _ENABLE_BUILDAH
    if [[ "${_ENABLE_BUILDAH:-y}" =~ ^[Yy]$ ]]; then
        ENABLE_CICD_BUILDAH="true"
    else
        ENABLE_CICD_BUILDAH="false"
        BUILDAH_AGENT_IMAGE=""
    fi

    # 2-4. 스토리지 타입 선택
    echo ""
    echo "Jenkins Home 영구 볼륨 스토리지 유형을 선택하세요:"
    echo "  1) HostPath (특정 노드의 로컬 디렉터리를 정적 PV로 사용)"
    echo "  2) NAS 정적 할당 (NFS 서버/경로를 정적 PV로 사용)"
    echo "  3) Dynamic  (StorageClass 기반 동적 PVC)"
    read -p "선택 [1/2/3, 기본값 1]: " _STORAGE_SEL
    _STORAGE_SEL="${_STORAGE_SEL:-1}"

    STORAGE_SIZE="${STORAGE_SIZE:-20Gi}"
    case "$_STORAGE_SEL" in
        1)
            STORAGE_TYPE="hostpath"
            STORAGE_CLASS="manual"
            NAS_SERVER=""
            NAS_PATH=""
            read -p "HostPath 경로 지정 (기본 /data/jenkins): " HOSTPATH_DIR
            HOSTPATH_DIR="${HOSTPATH_DIR:-/data/jenkins}"
            ;;
        2)
            STORAGE_TYPE="nas"
            STORAGE_CLASS="manual"
            HOSTPATH_DIR=""
            read -p "NFS 서버 주소 (예: 192.168.1.100): " NAS_SERVER
            if [ -z "$NAS_SERVER" ]; then
                echo -e "${RED}[오류] NFS 서버 주소는 필수입니다.${NC}"
                exit 1
            fi
            read -p "NFS Jenkins Home 경로 (예: /nas/jenkins): " NAS_PATH
            if [ -z "$NAS_PATH" ]; then
                echo -e "${RED}[오류] NFS 경로는 필수입니다.${NC}"
                exit 1
            fi
            read -p "Jenkins Home 볼륨 크기 (기본 ${STORAGE_SIZE}): " _STORAGE_SIZE
            STORAGE_SIZE="${_STORAGE_SIZE:-$STORAGE_SIZE}"
            ;;
        3)
            STORAGE_TYPE="dynamic"
            HOSTPATH_DIR=""
            NAS_SERVER=""
            NAS_PATH=""
            read -p "StorageClass 이름 입력 (예: nfs-client): " STORAGE_CLASS
            read -p "Jenkins Home 볼륨 크기 (기본 ${STORAGE_SIZE}): " _STORAGE_SIZE
            STORAGE_SIZE="${_STORAGE_SIZE:-$STORAGE_SIZE}"
            ;;
        *)
            echo -e "${RED}[오류] 스토리지 유형은 1, 2, 3 중 하나를 선택해야 합니다.${NC}"
            exit 1
            ;;
    esac

    # 2-5. 서비스 노출 및 도메인
    echo ""
    echo "Jenkins 컨트롤러 웹 UI 노출 방식을 선택하세요:"
    echo "  1) ClusterIP (인그레스 또는 Envoy HTTPRoute 연동 권장)"
    echo "  2) NodePort  (독립 노출)"
    read -p "선택 [1/2, 기본값 2]: " _SVC_SEL
    if [ "${_SVC_SEL:-2}" == "1" ]; then
        SVC_TYPE="ClusterIP"
    else
        SVC_TYPE="NodePort"
    fi

    # TLS 활성화 여부
    read -p "TLS(HTTPS) 접속을 활성화하시겠습니까? (y/n, 기본값 y): " _TLS_YN
    if [[ "${_TLS_YN:-y}" =~ ^[Yy]$ ]]; then
        TLS_ENABLED="true"
    else
        TLS_ENABLED="false"
    fi

    # 도메인 입력
    read -p "Jenkins 접속 도메인 (기본: jenkins.test.com): " DOMAIN
    DOMAIN="${DOMAIN:-jenkins.test.com}"

    # 2-6. 노드 고정 배치 지정
    echo ""
    kubectl get nodes -o wide
    read -p "Jenkins 컨트롤러를 고정 배치할 노드 이름 (없으면 비워둠): " TARGET_NODE
fi

if [ "$ENABLE_CICD_BUILDAH" == "true" ]; then
    if [ "$IMAGE_SOURCE" == "harbor" ]; then
        BUILDAH_AGENT_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/jenkins-buildah-agent:1.41.4"
    else
        BUILDAH_AGENT_IMAGE="jenkins-buildah-agent:1.41.4"
    fi
fi

save_conf

# ==========================================
# [3] YAML 동기화 및 values-infra.yaml 생성
# ==========================================
echo ""
echo "🔧 인프라 설정 파일(values-infra.yaml) 생성 중..."

# 이미지 변수들 셋업
IMAGE_PULL_SECRET="regcred"
if [ "${IMAGE_SOURCE}" = "harbor" ]; then
    CONTROLLER_IMAGE_REGISTRY="${HARBOR_REGISTRY}"
    if [ "$USE_CUSTOM_IMAGE" == "true" ]; then
        CONTROLLER_IMAGE_REPOSITORY="${HARBOR_PROJECT}/cmp-jenkins-full"
    else
        CONTROLLER_IMAGE_REPOSITORY="${HARBOR_PROJECT}/jenkins"
    fi
    AGENT_IMAGE_REGISTRY="${HARBOR_REGISTRY}"
    AGENT_IMAGE_REPOSITORY="${HARBOR_PROJECT}/inbound-agent"
    SIDECAR_IMAGE_REGISTRY="${HARBOR_REGISTRY}"
    SIDECAR_IMAGE_REPOSITORY="${HARBOR_PROJECT}/k8s-sidecar"
else
    CONTROLLER_IMAGE_REGISTRY="docker.io"
    if [ "$USE_CUSTOM_IMAGE" == "true" ]; then
        CONTROLLER_IMAGE_REPOSITORY="library/cmp-jenkins-full"
    else
        CONTROLLER_IMAGE_REPOSITORY="jenkins/jenkins"
    fi
    AGENT_IMAGE_REGISTRY="docker.io"
    AGENT_IMAGE_REPOSITORY="jenkins/inbound-agent"
    SIDECAR_IMAGE_REGISTRY="docker.io"
    SIDECAR_IMAGE_REPOSITORY="kiwigrid/k8s-sidecar"
fi

# 노드 고정 (nodeSelector) 설정
NODE_SELECTOR_VAL="{}"
if [ -n "${TARGET_NODE}" ]; then
    kubectl label nodes "${TARGET_NODE}" "${NODE_LABEL_KEY}=${NODE_LABEL_VALUE}" --overwrite 2>/dev/null || true
    NODE_SELECTOR_VAL="${NODE_LABEL_KEY}: \"${NODE_LABEL_VALUE}\""
fi

# 스토리지 사양 정의
if is_static_pv_storage; then
    RESOLVED_STORAGE_CLASS="manual"
else
    RESOLVED_STORAGE_CLASS="${STORAGE_CLASS}"
fi

# Buildah agent 설정 블록 조립
BUILDAH_AGENT_YAML_BLOCK=""
BUILDAH_SA_YAML_BLOCK=""
if [ "$ENABLE_CICD_BUILDAH" == "true" ]; then
    BUILDAH_AGENT_YAML_BLOCK="  imagePullSecretName: harbor-regcred
  podTemplates:
    buildah: |
      - name: buildah
        label: buildah
        serviceAccount: jenkins-agent
        containers:
          - name: buildah
            image: \"${BUILDAH_AGENT_IMAGE}\"
            command: \"sleep\"
            args: \"999999\"
            ttyEnabled: true
            privileged: false
            resourceRequestCpu: \"500m\"
            resourceRequestMemory: \"1Gi\"
            resourceLimitCpu: \"2\"
            resourceLimitMemory: \"4Gi\"
            envVars:
              - envVar:
                  key: BUILDAH_ISOLATION
                  value: chroot
              - envVar:
                  key: STORAGE_DRIVER
                  value: vfs
              - envVar:
                  key: XDG_RUNTIME_DIR
                  value: /tmp
              - envVar:
                  key: HOME
                  value: /home/jenkins
              - envVar:
                  key: CONTAINERS_STORAGE_CONF
                  value: /home/jenkins/.config/containers/storage.conf
        volumes:
          - emptyDirVolume:
              mountPath: /home/jenkins/.local/share/containers
              memory: false
          - emptyDirVolume:
              mountPath: /tmp
              memory: false"

    BUILDAH_SA_YAML_BLOCK="serviceAccountAgent:
  create: true
  name: jenkins-agent
  imagePullSecretName: harbor-regcred"
fi

# 단일 cat > 구조를 사용해 중복 키를 완벽 방지하는 values-infra.yaml 작성
cat > ./values-infra.yaml <<EOF
# Jenkins v2.555.3 인프라 설정 — install.sh 에 의해 자동 관리됩니다.
controller:
  image:
    registry: "${CONTROLLER_IMAGE_REGISTRY}"
    repository: "${CONTROLLER_IMAGE_REPOSITORY}"
    tag: "${CONTROLLER_TAG}"
    pullPolicy: "Always"
  imagePullSecrets:
    - name: "${IMAGE_PULL_SECRET}"
  serviceType: "${SVC_TYPE}"
  nodePort: 30000
  nodeSelector:
    ${NODE_SELECTOR_VAL}
  runAsUser: 1000
  fsGroup: 1000
  installPlugins: false
  sidecars:
    configAutoReload:
      image:
        registry: "${SIDECAR_IMAGE_REGISTRY}"
        repository: "${SIDECAR_IMAGE_REPOSITORY}"
        tag: "${SIDECAR_TAG}"
        pullPolicy: "IfNotPresent"

agent:
  image:
    registry: "${AGENT_IMAGE_REGISTRY}"
    repository: "${AGENT_IMAGE_REPOSITORY}"
    tag: "${AGENT_TAG}"
    pullPolicy: "IfNotPresent"
  imagePullSecrets:
    - name: "${IMAGE_PULL_SECRET}"
${BUILDAH_AGENT_YAML_BLOCK}

persistence:
  enabled: true
  storageClass: "${RESOLVED_STORAGE_CLASS}"
  size: "${STORAGE_SIZE:-20Gi}"

${BUILDAH_SA_YAML_BLOCK}
EOF

# ==========================================
# [4] Kubernetes 리소스 준비 및 설치
# ==========================================
echo ""
echo -e "🚀 ${GREEN}[1/3] Kubernetes 네임스페이스 및 스토리지 구성 중...${NC}"

# 네임스페이스 생성
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

prepare_buildah_agent_image

# HostPath 정적 PV 생성
if is_hostpath_storage; then
    prepare_hostpath_permissions "$HOSTPATH_DIR"
    echo "   → HostPath 정적 영구볼륨(PV) 생성 중..."
    sed \
        -e "s|/data/jenkins|${HOSTPATH_DIR}|g" \
        -e "s|20Gi|${STORAGE_SIZE:-20Gi}|g" \
        "$PV_FILE" | kubectl apply -f -
fi

# NAS(NFS) 정적 PV 생성
if [ "$STORAGE_TYPE" == "nas" ]; then
    echo "   → NAS(NFS) 정적 영구볼륨(PV) 생성 중..."
    sed \
        -e "s|192.168.1.100|${NAS_SERVER}|g" \
        -e "s|/nas/jenkins|${NAS_PATH}|g" \
        -e "s|20Gi|${STORAGE_SIZE:-20Gi}|g" \
        "$NAS_PV_FILE" | kubectl apply -f -
fi

# Gradle 캐시용 PV/PVC 구성
echo "   → Gradle Build 캐시용 PV/PVC 생성 중..."
kubectl apply -f "$GRADLE_CACHE_FILE" -n $NAMESPACE

# Helm이 직접 생성하지 않은 PVC를 관리할 수 있도록 adoption 레이블/어노테이션 추가
kubectl label pvc jenkins -n "${NAMESPACE}" "app.kubernetes.io/managed-by=Helm" --overwrite 2>/dev/null || true
kubectl annotate pvc jenkins -n "${NAMESPACE}" "meta.helm.sh/release-name=jenkins" "meta.helm.sh/release-namespace=${NAMESPACE}" --overwrite 2>/dev/null || true

# 2. 노드 라벨 지정 (필요 시)
if [ -n "$TARGET_NODE" ]; then
    echo "   → 대상 노드(${TARGET_NODE})에 jenkins-node=true 라벨 추가..."
    kubectl label nodes "$TARGET_NODE" jenkins-node=true --overwrite >/dev/null 2>&1 || true
fi

# 3. Helm 배포 (upgrade --install 명령 고정으로 멱등성 보장)
echo ""
echo -e "🚀 [2/3] Jenkins Helm 차트 배포 중... (${DO_UPGRADE:+업그레이드}${DO_UPGRADE:-설치})"
if [ -d "$CHART_PATH" ]; then
    helm upgrade --install jenkins "$CHART_PATH" \
        -n "$NAMESPACE" \
        -f "$VALUES_FILE" \
        -f ./values-infra.yaml \
        --wait
else
    echo -e "${RED}[오류] Helm 차트 디렉토리('${CHART_PATH}')가 존재하지 않습니다.${NC}"
    exit 1
fi

echo ""
echo "========================================================"
echo -e "${GREEN}🎉 구성 완료! (Jenkins v2.555.3 / Chart v5.9.26)${NC}"
echo "설정 파일 : $CONF_FILE"
if [ "$ENABLE_CICD_BUILDAH" == "true" ]; then
    echo "Buildah CI : enabled (${BUILDAH_AGENT_IMAGE})"
else
    echo "Buildah CI : disabled"
fi
if [ "$TLS_ENABLED" == "true" ]; then
    PROTOCOL="https"
else
    PROTOCOL="http"
fi
echo "도메인    : $PROTOCOL://$DOMAIN"
if [ "$SVC_TYPE" == "NodePort" ]; then
    echo "접속 포트 : 30000 (NodePort)"
else
    echo "노출 방식 : ClusterIP (Envoy HTTPRoute 수동 적용 필요)"
    echo "HTTPRoute 적용 명령:"
    echo "  sed \"s|jenkins.test.com|${DOMAIN}|g\" ./manifests/route-jenkins.yaml | kubectl apply -f -"
    echo "HTTPRoute 확인 명령:"
    echo "  kubectl get httproute jenkins-route -n ${NAMESPACE}"
fi
echo "========================================================"
echo "⏳ 초기 관리자(admin) 비밀번호 확인 방법:"
echo "👉 kubectl get secret jenkins -n $NAMESPACE -o jsonpath=\"{.data.jenkins-admin-password}\" | base64 -d"
echo ""
kubectl get pods -n $NAMESPACE
