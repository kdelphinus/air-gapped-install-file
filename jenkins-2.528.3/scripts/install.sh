#!/bin/bash
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
NODE_LABEL_KEY="jenkins-node"
NODE_LABEL_VALUE="true"

# 이미지 태그 정보 고정
CONTROLLER_TAG="2.528.3"
AGENT_TAG="latest"
SIDECAR_TAG="1.30.7"

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
# Jenkins v2.528.3 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
REGISTRY_URL="${REGISTRY_URL}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
DOMAIN="${DOMAIN}"
STORAGE_CLASS="${STORAGE_CLASS}"
STORAGE_SIZE="${STORAGE_SIZE}"
NODE_PORT="${NODE_PORT}"
TARGET_NODE="${TARGET_NODE}"
INSTALLED_VERSION="v2.528.3"
EOF
    echo -e "  ✅ 설정이 ${GREEN}${CONF_FILE}${NC} 에 저장되었습니다."
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
        kubectl delete pvc --all -n "$NAMESPACE" --ignore-not-found 2>/dev/null
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
        kubectl delete -f ./manifests/pv-volume.yaml --ignore-not-found 2>/dev/null || true
        kubectl delete -f ./manifests/gradle-cache-pv-pvc.yaml --ignore-not-found 2>/dev/null || true
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
    [ "$IMAGE_SOURCE" == "1" ] && echo "     - 레지스트리   : $REGISTRY_URL/$HARBOR_PROJECT"
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
        read -p "Harbor 레지스트리 주소 (예: 192.168.1.10:30002 또는 harbor.example.com): " REGISTRY_URL
        if [ -z "${REGISTRY_URL}" ]; then
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
        REGISTRY_URL=""
        HARBOR_PROJECT=""
    else
        echo -e "${RED}[오류] 1 또는 2를 선택하세요.${NC}"; exit 1
    fi

    # 2-2. 스토리지 클래스 및 용량
    echo ""
    read -p "스토리지 클래스 이름 (기본값: manual): " STORAGE_CLASS
    STORAGE_CLASS="${STORAGE_CLASS:-manual}"
    read -p "스토리지 할당 크기 (기본값: 20Gi): " STORAGE_SIZE
    STORAGE_SIZE="${STORAGE_SIZE:-20Gi}"

    # 2-3. 네트워크 및 도메인 설정
    echo ""
    read -p "사용할 NodePort (기본값: 30000): " NODE_PORT
    NODE_PORT="${NODE_PORT:-30000}"
    read -p "HTTPRoute에 사용할 도메인 이름 (공백 시 미생성): " DOMAIN

    # 2-4. 노드 고정 고정
    echo ""
    echo ">>> 사용 가능한 노드 목록:"
    kubectl get nodes -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[-1].type,ROLES:.metadata.labels.node-role\.kubernetes\.io/worker" 2>/dev/null || true
    echo ""
    read -p "Jenkins Controller를 배포할 노드 이름 (엔터 = 자동 배치): " TARGET_NODE
fi

save_conf

# ==========================================
# [3] 설정 파일(values-infra.yaml) 생성 및 리소스 배포
# ==========================================
echo "🔧 인프라 설정 파일(values-infra.yaml) 생성 중..."

# 레포지토리 정보 조립
IMAGE_PULL_SECRET="regcred"
if [ "${IMAGE_SOURCE}" = "1" ]; then
    CONTROLLER_REPO="${HARBOR_PROJECT}/cmp-jenkins-full"
    AGENT_REPO="${HARBOR_PROJECT}/inbound-agent"
    SIDECAR_REPO="${HARBOR_PROJECT}/k8s-sidecar"
    CONTROLLER_IMAGE_REG="${REGISTRY_URL}"
    AGENT_IMAGE_REG="${REGISTRY_URL}"
    SIDECAR_IMAGE_REG="${REGISTRY_URL}"
else
    CONTROLLER_REPO="jenkins/jenkins"
    AGENT_REPO="jenkins/inbound-agent"
    SIDECAR_REPO="kiwigrid/k8s-sidecar"
    CONTROLLER_IMAGE_REG="docker.io"
    AGENT_IMAGE_REG="docker.io"
    SIDECAR_IMAGE_REG="docker.io"
fi

# 노드 고정 nodeSelector 렌더링
NODE_SELECTOR_VAL="{}"
if [ -n "${TARGET_NODE}" ]; then
    kubectl label nodes "${TARGET_NODE}" "${NODE_LABEL_KEY}=${NODE_LABEL_VALUE}" --overwrite 2>/dev/null || true
    NODE_SELECTOR_VAL="${NODE_LABEL_KEY}: \"${NODE_LABEL_VALUE}\""
fi

# 단일 cat > 구조를 사용해 중복 키를 완벽 방지하는 values-infra.yaml 작성
cat > ./values-infra.yaml <<EOF
# Jenkins v2.528.3 인프라 설정 — install.sh 에 의해 자동 관리됩니다.
controller:
  image:
    registry: "${CONTROLLER_IMAGE_REG}"
    repository: "${CONTROLLER_REPO}"
    tag: "${CONTROLLER_TAG}"
    pullPolicy: "Always"
  imagePullSecrets:
    - name: "${IMAGE_PULL_SECRET}"
  serviceType: "NodePort"
  nodePort: "${NODE_PORT}"
  nodeSelector:
    ${NODE_SELECTOR_VAL}
  runAsUser: 1000
  fsGroup: 1000
  installPlugins: false
  sidecars:
    configAutoReload:
      image:
        registry: "${SIDECAR_IMAGE_REG}"
        repository: "${SIDECAR_REPO}"
        tag: "${SIDECAR_TAG}"
        pullPolicy: "IfNotPresent"

agent:
  image:
    registry: "${AGENT_IMAGE_REG}"
    repository: "${AGENT_REPO}"
    tag: "${AGENT_TAG}"
    pullPolicy: "IfNotPresent"
  imagePullSecrets:
    - name: "${IMAGE_PULL_SECRET}"

persistence:
  storageClass: "${STORAGE_CLASS}"
  size: "${STORAGE_SIZE}"
EOF

# ==========================================
# [4] K8s 리소스 배포 및 Helm 설치 진행
# ==========================================
echo ""
echo -e "🚀 ${GREEN}[1/3] K8s 네임스페이스 및 볼륨 리소스 적용 중...${NC}"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 정적 PV/PVC 배포
kubectl apply -f ./manifests/pv-volume.yaml
kubectl apply -f ./manifests/gradle-cache-pv-pvc.yaml

# Helm이 직접 생성하지 않은 PVC를 관리할 수 있도록 adoption 레이블/어노테이션 추가
kubectl label pvc jenkins -n "${NAMESPACE}" "app.kubernetes.io/managed-by=Helm" --overwrite 2>/dev/null || true
kubectl annotate pvc jenkins -n "${NAMESPACE}" "meta.helm.sh/release-name=jenkins" "meta.helm.sh/release-namespace=${NAMESPACE}" --overwrite 2>/dev/null || true

echo ""
echo -e "🚀 ${GREEN}[2/3] Jenkins Helm 차트 배포 중... (${DO_UPGRADE:+업그레이드}${DO_UPGRADE:-설치})${NC}"
if [ ! -d "${CHART_PATH}" ]; then
    echo -e "${RED}[오류] Helm 차트 디렉토리 '${CHART_PATH}' 가 없습니다.${NC}"; exit 1
fi

helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  -f "$VALUES_FILE" \
  -f ./values-infra.yaml \
  --wait

echo "⏳ [5/6] Pod가 준비될 때까지 대기 중... (최대 5분)"
# Pod가 Running 및 Ready 상태가 될 때까지 대기
kubectl wait --namespace "$NAMESPACE" \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=jenkins-controller \
  --timeout=300s

echo "🔑 [6/6] 초기 관리자 비밀번호 확인"
echo "--------------------------------------------------------"
PASSWORD=$(kubectl get secret -n "$NAMESPACE" jenkins -o jsonpath="{.data.jenkins-admin-password}" | base64 --decode)
echo "   👤 ID: admin"
echo "   🔐 PW: $PASSWORD"
echo "   🖥️  Node: $TARGET_NODE"
echo "--------------------------------------------------------"
echo "🎉 Jenkins 배포가 완료되었습니다!"
echo "👉 접속 주소: http://<NodeIP>:$NODE_PORT"

# ---- CoreDNS 등록 ----
add_coredns_host() {
    local ip="$1"
    local domain="$2"
    if kubectl get configmap coredns -n kube-system \
            -o jsonpath='{.data.NodeHosts}' | grep -qw "$domain"; then
        echo "  - CoreDNS: ${domain} 이미 등록됨, 건너뜁니다."
        return 0
    fi
    local new_hosts
    new_hosts="$(kubectl get configmap coredns -n kube-system \
        -o jsonpath='{.data.NodeHosts}')
${ip} ${domain}"
    kubectl get configmap coredns -n kube-system -o json \
        | jq --arg h "$new_hosts" '.data.NodeHosts = $h' \
        | kubectl apply -f -
    echo "  - CoreDNS: ${ip} ${domain} 등록 완료 (15초 내 자동 반영)"
}

if [ -n "$DOMAIN" ]; then
    echo ""
    read -p "❓ ${DOMAIN} 이 DNS 서버에 이미 등록되어 있나요? (y/n): " DNS_REGISTERED
    if [[ "$DNS_REGISTERED" == "y" || "$DNS_REGISTERED" == "Y" ]]; then
        echo "  - DNS 서버에 등록됨 — CoreDNS 등록을 건너뜁니다."
    else
        echo ">>> CoreDNS에 ${DOMAIN} 등록 중..."
        NODE_IP=$(kubectl get nodes \
            -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
        add_coredns_host "$NODE_IP" "$DOMAIN"
    fi
else
    echo ""
    echo ">>> DOMAIN 미설정 — CoreDNS 등록을 건너뜁니다. (NodePort로만 접속)"
fi

if [ -n "$DOMAIN" ]; then
    echo ""
    echo "==========================================="
    echo " [주의] 클라이언트 hosts 등록 필요"
    echo "==========================================="
    echo " 도메인으로 접속하려면 접속할 PC의 hosts 파일에 아래 항목을 추가하세요."
    echo ""
    echo "   <GATEWAY_IP>  ${DOMAIN}"
    echo ""
    echo " - Windows: C:\\Windows\\System32\\drivers\\etc\\hosts"
    echo " - Linux/Mac: /etc/hosts"
    echo "==========================================="
    echo ""
    echo "Envoy HTTPRoute를 사용할 경우 아래 명령을 수동 적용하세요:"
    echo "  sed \"s|jenkins.test.com|${DOMAIN}|g\" ./manifests/route-jenkins.yaml | kubectl apply -f -"
    echo "  kubectl get httproute jenkins-route -n ${NAMESPACE}"
fi
