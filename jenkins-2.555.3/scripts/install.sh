#!/bin/bash

# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1


# ==========================================
# [설정] 기본 변수
# ==========================================
NAMESPACE="jenkins"
CHART_PATH="./charts/jenkins"
CONF_FILE="./install.conf"
PV_FILE="./manifests/pv-volume.yaml"

# 임시 파일 자동 클린업 trap 설정
trap 'rm -f ./values-temp.yaml' EXIT

GRADLE_CACHE_FILE="./manifests/gradle-cache-pv-pvc.yaml"

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
STORAGE_TYPE="${STORAGE_TYPE}"
STORAGE_CLASS="${STORAGE_CLASS}"
HOSTPATH_DIR="${HOSTPATH_DIR}"
SVC_TYPE="${SVC_TYPE}"
TLS_ENABLED="${TLS_ENABLED}"
DOMAIN="${DOMAIN}"
TARGET_NODE="${TARGET_NODE}"
INSTALLED_VERSION="v2.555.3"
EOF
    echo -e "  ✅ 설정이 ${GREEN}${CONF_FILE}${NC} 에 저장되었습니다."
}

# ==========================================
# [함수] 클린업 로직
# ==========================================
function cleanup_resources() {
  local RESET_MODE=$1 # "reset" 이면 install.conf 도 삭제
  echo ""
  echo -e "🧹 ${YELLOW}[Clean Up] 기존 Jenkins 리소스 제거 시작...${NC}"

  # Helm Uninstall
  if helm status jenkins -n $NAMESPACE >/dev/null 2>&1; then
      echo "⏳ Helm 차트 삭제 중..."
      helm uninstall jenkins -n $NAMESPACE --wait=false 2>/dev/null
      sleep 3
  fi

  # PVC/PV 삭제
  echo "🗑️  Jenkins PVC/PV 삭제 중..."
  kubectl delete pvc -n $NAMESPACE jenkins --timeout=10s --wait=false 2>/dev/null
  kubectl delete pvc -n $NAMESPACE gradle-cache-pvc --timeout=10s --wait=false 2>/dev/null
  kubectl delete pv jenkins-pv gradle-cache-pv --timeout=10s --wait=false 2>/dev/null

  # 네임스페이스 삭제
  if kubectl get ns $NAMESPACE > /dev/null 2>&1; then
      echo "🗑️  네임스페이스($NAMESPACE) 삭제..."
      kubectl delete ns $NAMESPACE --timeout=15s --wait=false 2>/dev/null
  fi

  if [ "$RESET_MODE" == "reset" ]; then
      rm -f "$CONF_FILE"
      rm -f "./values-temp.yaml"
      echo -e "🗑️  설정 파일 및 임시 파일 삭제 완료 (Reset)."
  fi

  echo -e "${GREEN}✅ 초기화 작업이 완료되었습니다.${NC}"
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
# ==========================================
# [1] 기존 설치 감지 및 메뉴
# ==========================================
load_conf
EXIST_HELM=$(helm status jenkins -n $NAMESPACE > /dev/null 2>&1 && echo "yes" || echo "no")
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

    # 2-3. 스토리지 타입 선택
    echo ""
    echo "Jenkins Home 영구 볼륨 스토리지 유형을 선택하세요:"
    echo "  1) HostPath (로컬 노드의 특정 경로 직접 사용)"
    echo "  2) Dynamic  (StorageClass 기반 동적 PVC)"
    read -p "선택 [1/2, 기본값 1]: " _STORAGE_SEL
    _STORAGE_SEL="${_STORAGE_SEL:-1}"

    if [ "$_STORAGE_SEL" == "1" ]; then
        STORAGE_TYPE="hostpath"
        read -p "호스트 디렉토리 경로 지정 (기본 /data/jenkins): " HOSTPATH_DIR
        HOSTPATH_DIR="${HOSTPATH_DIR:-/data/jenkins}"
    else
        STORAGE_TYPE="dynamic"
        read -p "StorageClass 이름 입력 (예: nfs-client): " STORAGE_CLASS
    fi

    # 2-4. 서비스 노출 및 도메인
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

    # 2-5. 노드 고정 배치 지정
    echo ""
    kubectl get nodes -o wide
    read -p "Jenkins 컨트롤러를 고정 배치할 노드 이름 (없으면 비워둠): " TARGET_NODE
fi

save_conf

# ==========================================
# [3] YAML 동기화 (Single Source of Truth)
# ==========================================
echo ""
echo "🔧 임시 설정 파일(values-temp.yaml) 생성 및 치환 중..."

# 1. 템플릿 복사 분기
if [ "${IMAGE_SOURCE}" = "harbor" ]; then
    cp -f ./values.yaml ./values-temp.yaml
    # Harbor 사용 시 이미지 레지스트리 주소 치환
    sed -i \
        -e "s|<HARBOR_REGISTRY>|${HARBOR_REGISTRY}|g" \
        -e "s|<HARBOR_PROJECT>|${HARBOR_PROJECT}|g" \
        ./values-temp.yaml
else
    # local/online 모드는 공개 이미지 기본값을 사용합니다.
    # local 모드는 위 단계에서 tar를 클러스터 런타임에 먼저 로드합니다.
    cp -f ./values-local.yaml ./values-temp.yaml
fi

# 2. 커스텀 OpenTofu 이미지 설정 값 준비
CONTROLLER_IMAGE_REGISTRY=""
CONTROLLER_IMAGE_REPOSITORY=""
CONTROLLER_IMAGE_PULL_POLICY="IfNotPresent"
if [ "$USE_CUSTOM_IMAGE" == "true" ]; then
    echo "   → OpenTofu 커스텀 이미지(cmp-jenkins-full) 설정을 values-temp.yaml에 적용..."
    if [ "$IMAGE_SOURCE" == "harbor" ]; then
        CONTROLLER_IMAGE_REGISTRY="${HARBOR_REGISTRY}"
        CONTROLLER_IMAGE_REPOSITORY="${HARBOR_PROJECT}/cmp-jenkins-full"
    else
        CONTROLLER_IMAGE_REGISTRY="docker.io"
        CONTROLLER_IMAGE_REPOSITORY="library/cmp-jenkins-full"
    fi
fi

# 3. 인프라 가변 설정 오버라이드 덧붙이기
cat >> ./values-temp.yaml <<EOF

controller:
  serviceType: "${SVC_TYPE}"
EOF

# NodePort 설정 시 포트 지정
if [ "$SVC_TYPE" == "NodePort" ]; then
    cat >> ./values-temp.yaml <<EOF
  nodePort: 30000
EOF
fi

# 커스텀 Jenkins 컨트롤러 이미지 설정
if [ -n "$CONTROLLER_IMAGE_REPOSITORY" ]; then
    cat >> ./values-temp.yaml <<EOF
  image:
    registry: "${CONTROLLER_IMAGE_REGISTRY}"
    repository: "${CONTROLLER_IMAGE_REPOSITORY}"
    tag: "2.555.3"
    pullPolicy: "${CONTROLLER_IMAGE_PULL_POLICY}"
EOF
fi

# 노드 고정 배치(nodeSelector) 추가
if [ -n "$TARGET_NODE" ]; then
    cat >> ./values-temp.yaml <<EOF
  nodeSelector:
    kubernetes.io/hostname: "${TARGET_NODE}"
EOF
fi

# 스토리지 볼륨 설정 추가. Jenkins chart의 persistence는 controller 하위가 아닌 top-level 키입니다.
if [ "$STORAGE_TYPE" == "hostpath" ]; then
    cat >> ./values-temp.yaml <<EOF

persistence:
  enabled: true
  storageClass: "manual"
  size: "20Gi"
EOF
else
    cat >> ./values-temp.yaml <<EOF

persistence:
  enabled: true
  storageClass: "${STORAGE_CLASS}"
  size: "20Gi"
EOF
fi

# ==========================================
# [4] Kubernetes 리소스 준비 및 설치
# ==========================================
echo ""
echo "🚀 [1/3] Kubernetes 네임스페이스 및 스토리지 구성 중..."

# 네임스페이스 생성
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# HostPath PV 수동 생성
if [ "$STORAGE_TYPE" == "hostpath" ]; then
    prepare_hostpath_permissions "$HOSTPATH_DIR"
    echo "   → HostPath 영구볼륨(PV) 생성 중..."
    sed "s|/data/jenkins|${HOSTPATH_DIR}|g" "$PV_FILE" | kubectl apply -f -
fi

# Gradle 캐시용 PV/PVC 구성
echo "   → Gradle Build 캐시용 PV/PVC 생성 중..."
kubectl apply -f "$GRADLE_CACHE_FILE" -n $NAMESPACE

# 2. 노드 라벨 지정 (필요 시)
if [ -n "$TARGET_NODE" ]; then
    echo "   → 대상 노드(${TARGET_NODE})에 jenkins-node=true 라벨 추가..."
    kubectl label nodes "$TARGET_NODE" jenkins-node=true --overwrite >/dev/null 2>&1 || true
fi

# 3. Helm 배포
echo ""
echo -e "🚀 [2/3] Jenkins Helm 차트 배포 중... (${DO_UPGRADE:+업그레이드}${DO_UPGRADE:-설치})"
if [ -d "$CHART_PATH" ]; then
    helm upgrade --install jenkins "$CHART_PATH" \
        -n "$NAMESPACE" \
        -f ./values-temp.yaml
else
    echo -e "${RED}[오류] Helm 차트 디렉토리('${CHART_PATH}')가 존재하지 않습니다.${NC}"
    exit 1
fi

echo ""
echo "========================================================"
echo -e "🎉 구성 완료! (Jenkins v2.555.3 / Chart v5.9.26)"
echo "설정 파일 : $CONF_FILE"
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
