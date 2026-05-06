#!/bin/bash
# ---------------------------------------------------------
# Cilium 1.19.3 Air-Gapped Installation Script
# [Target] General Air-gapped K8s (Any Infrastructure)
# ---------------------------------------------------------
cd "$(dirname "$0")/.." || exit 1

# 바이너리 경로 정밀 감지 함수
find_binary() {
    local name=$1
    local p=$(which $name 2>/dev/null)
    [ -z "$p" ] && p=$(find /home /usr/local/bin /usr/bin -name $name -type f -executable 2>/dev/null | head -n 1)
    echo "${p:-$name}"
}

KUBECTL=$(find_binary kubectl)
HELM=$(find_binary helm)
CTR=$(find_binary ctr)
FUSER=$(find_binary fuser)

# 감지 결과 로그 (디버깅용)
# echo "Detected binaries: KUBECTL=$KUBECTL, HELM=$HELM, CTR=$CTR, FUSER=$FUSER"

NAMESPACE="kube-system"
RELEASE_NAME="cilium"
CHART_PATH="./charts/cilium"
VALUES_FILE="./values.yaml"
CONF_FILE="./install.conf"

INSTALLED_VERSION="v1.19.3"

# 색상 코드
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# ── 리소스 및 런타임 클린업 함수 ───────────────────────────
cleanup_cilium_completely() {
    echo -e "${YELLOW}🔍 Cilium 리소스 및 호스트 잔재 클린업 중...${NC}"
    
    # 1. Kubernetes 자원 강제 정리
    $KUBECTL delete ds cilium -n $NAMESPACE --ignore-not-found=true --force --grace-period=0 >/dev/null 2>&1
    $KUBECTL delete deployment hubble-relay hubble-ui -n $NAMESPACE --ignore-not-found=true --force --grace-period=0 >/dev/null 2>&1

    # 2. Namespace 정리 (Terminating 상태 강제 해결)
    for ns in "cilium-secrets" "cilium-test"; do
        if $KUBECTL get ns "$ns" >/dev/null 2>&1; then
            echo -e "    * Namespace [$ns] 정리 중..."
            $KUBECTL delete ns "$ns" --ignore-not-found=true --timeout=5s >/dev/null 2>&1
            
            # 계속 남아있는 경우 Finalizer 강제 제거
            if $KUBECTL get ns "$ns" 2>/dev/null | grep -q "Terminating"; then
                echo -e "    * [$ns] Finalizer 강제 제거 시도..."
                $KUBECTL get namespace "$ns" -o json | \
                sed 's/"finalizers": \[.*\]/"finalizers": []/' | \
                $KUBECTL replace --raw "/api/v1/namespaces/$ns/finalize" -f - >/dev/null 2>&1
            fi
            
            # 실제 삭제될 때까지 대기
            local retry=0
            while $KUBECTL get ns "$ns" >/dev/null 2>&1 && [ $retry -lt 15 ]; do
                sleep 2
                ((retry++))
            done
        fi
    done

    # 3. Containerd 런타임 작업 및 컨테이너 강제 중지
    for ns in k8s.io default; do
        CIDS=$(sudo $CTR -n $ns containers list -q | grep -E "cilium|hubble" 2>/dev/null)
        if [ -n "$CIDS" ]; then
            for cid in $CIDS; do
                echo "    * [$ns] 좀비 컨테이너 정리: $cid"
                sudo $CTR -n $ns tasks kill -s SIGKILL "$cid" >/dev/null 2>&1
                sudo $CTR -n $ns containers rm "$cid" >/dev/null 2>&1
            done
        fi
    done

    # 4. 호스트 포트 점유 프로세스 강제 종료
    local ports="9234 9963 4240 4244 9876 9890"
    for port in $ports; do
        if sudo $FUSER "$port/tcp" >/dev/null 2>&1; then
            echo "    * 포트 ${port}번 프로세스 종료"
            sudo $FUSER -k -9 "$port/tcp" >/dev/null 2>&1
        fi
    done
    echo -e "${GREEN}  ✅ 클린업이 완료되었습니다.${NC}"
}

# ── install.conf 로드 / 저장 ──────────────────────────────
load_conf() {
    [ -f "$CONF_FILE" ] && source "$CONF_FILE"
}

save_conf() {
    cat > "$CONF_FILE" <<EOF
# Cilium ${INSTALLED_VERSION} 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
ENABLE_HUBBLE="${ENABLE_HUBBLE}"
K8S_SERVICE_HOST="${K8S_SERVICE_HOST}"
K8S_SERVICE_PORT="${K8S_SERVICE_PORT}"
POD_CIDR="${POD_CIDR}"
MTU_VALUE="${MTU_VALUE}"
INSTALLED_VERSION="${INSTALLED_VERSION}"
EOF
    echo -e "${GREEN}  ✅ 설정이 ${CONF_FILE} 에 저장되었습니다.${NC}"
}

load_conf

# ── 기존 설치 확인 ────────────────────────────────────────
EXIST_HELM=$($HELM status $RELEASE_NAME -n $NAMESPACE > /dev/null 2>&1 && echo "yes" || echo "no")
EXIST_K8S=$($KUBECTL get ds cilium -n $NAMESPACE > /dev/null 2>&1 && echo "yes" || echo "no")

DO_UPGRADE=""

if [ "$EXIST_HELM" = "yes" ] || [ "$EXIST_K8S" = "yes" ]; then
    echo -e "${YELLOW}[알림] Cilium이 이미 설치되어 있는 것으로 보입니다.${NC}"
    if [ -f "$CONF_FILE" ]; then
        echo ""
        echo -e "  📋 ${CYAN}저장된 설정 (${CONF_FILE}):${NC}"
        echo "     이미지 소스   : ${IMAGE_SOURCE:-미설정}"
        [ "${IMAGE_SOURCE}" = "harbor" ] && echo "     Harbor        : ${HARBOR_REGISTRY}/${HARBOR_PROJECT}"
        echo "     API 호스트    : ${K8S_SERVICE_HOST}"
        echo "     API 포트      : ${K8S_SERVICE_PORT}"
        echo "     Pod CIDR      : ${POD_CIDR}"
        echo "     MTU           : ${MTU_VALUE}"
        echo "     Hubble 활성화 : ${ENABLE_HUBBLE}"
    fi

    echo ""
    echo "동작을 선택하세요:"
    echo "  1) 업그레이드   — 저장된 설정 유지, Helm upgrade --install"
    echo "  2) 재설치       — 설정 재입력, 기존 리소스 삭제 및 좀비 프로세스 정리 후 설치"
    echo "  3) 초기화(리셋) — 리소스 + 데이터 + install.conf + 좀비 프로세스 완전 삭제"
    echo "  4) 취소"
    echo -e "${RED}  ※ 주의: Cilium(CNI) 재설치/초기화 시 클러스터 내 네트워크 통신이 일시적으로 단절됩니다.${NC}"
    read -p "선택 [1/2/3/4, 기본값 4]: " INSTALL_ACTION
    INSTALL_ACTION="${INSTALL_ACTION:-4}"

    case "$INSTALL_ACTION" in
        1)
            echo "🚀 업그레이드 모드로 진행합니다."
            DO_UPGRADE="true"
            ;;
        2)
            echo "🔥 기존 Cilium 자원 삭제 및 클린업 중..."
            if [ "$EXIST_HELM" = "yes" ]; then
                $HELM uninstall $RELEASE_NAME -n $NAMESPACE --wait=false 2>/dev/null || true
            fi
            cleanup_cilium_completely
            echo "✅ 삭제 및 클린업 완료. 설정을 다시 입력받습니다."
            IMAGE_SOURCE="" HARBOR_REGISTRY="" HARBOR_PROJECT="" ENABLE_HUBBLE=""
            K8S_SERVICE_HOST="" K8S_SERVICE_PORT="" POD_CIDR="" MTU_VALUE=""
            ;;
        3)
            echo "🗑️  초기화 및 클린업 중..."
            if [ "$EXIST_HELM" = "yes" ]; then
                $HELM uninstall $RELEASE_NAME -n $NAMESPACE --wait=false 2>/dev/null || true
            fi
            cleanup_cilium_completely
            [ -f "$CONF_FILE" ] && rm -f "$CONF_FILE" && echo "  - install.conf 삭제됨"
            echo "✅ 초기화 완료. 신규 설치 과정을 시작합니다."
            IMAGE_SOURCE="" HARBOR_REGISTRY="" HARBOR_PROJECT="" ENABLE_HUBBLE=""
            K8S_SERVICE_HOST="" K8S_SERVICE_PORT="" POD_CIDR="" MTU_VALUE=""
            ;;
        *)
            echo "❌ 설치가 취소되었습니다."
            exit 0
            ;;
    esac
fi

# ── 이미지 소스 설정 ──────────────────────────────────────
if [ -z "${IMAGE_SOURCE}" ]; then
    echo ""
    echo -e "${CYAN}이미지 소스를 선택하세요:${NC}"
    echo "  1) Harbor 레지스트리 사용"
    echo "  2) 로컬 tar 직접 import"
    read -p "선택 [1/2, 기본값: 1]: " _IMG_SRC
    _IMG_SRC="${_IMG_SRC:-1}"
    IMAGE_SOURCE=$([ "$_IMG_SRC" = "1" ] && echo "harbor" || echo "local")
fi

if [ "${IMAGE_SOURCE}" = "harbor" ]; then
    [ -z "${HARBOR_REGISTRY}" ] && read -p "Harbor 레지스트리 주소 (예: 172.30.235.200): " HARBOR_REGISTRY
    [ -z "${HARBOR_PROJECT}" ] && read -p "Harbor 프로젝트 입력 (예: library): " HARBOR_PROJECT
fi

# ── 환경별 핵심 설정 입력 (API, CIDR, MTU) ────────────────
if [ -z "${K8S_SERVICE_HOST}" ]; then
    echo -e "\n${CYAN}🔍 현재 클러스터 노드 정보 (INTERNAL-IP를 확인하세요):${NC}"
    $KUBECTL get nodes -o wide
    echo ""
    DETECTED_API_HOST=$($KUBECTL config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's|https?://([^:/]+).*|\1|')
    read -p "K8s API 서버 호스트 IP (기본값: ${DETECTED_API_HOST:-127.0.0.1}): " K8S_SERVICE_HOST
    K8S_SERVICE_HOST="${K8S_SERVICE_HOST:-${DETECTED_API_HOST:-127.0.0.1}}"
    read -p "K8s API 서버 포트 (기본값: 6443): " K8S_SERVICE_PORT
    K8S_SERVICE_PORT="${K8S_SERVICE_PORT:-6443}"
fi

if [ -z "${POD_CIDR}" ]; then
    echo -e "\n${CYAN}🔍 클러스터 네트워크 설정 확인 중...${NC}"
    KCM_CMD=$($KUBECTL get pod -n kube-system -l component=kube-controller-manager -o jsonpath='{.items[0].spec.containers[0].command}' 2>/dev/null)
    KCM_CIDR=$(echo "$KCM_CMD" | tr ' ' '\n' | grep "cluster-cidr" | cut -d= -f2)
    
    if [ -n "$KCM_CIDR" ]; then
        echo -e "  - controller-manager 설정값: ${GREEN}${KCM_CIDR}${NC}"
    fi
    echo -e "  - 노드별 할당 현황:"
    $KUBECTL get nodes -o custom-columns=NAME:.metadata.name,POD-CIDR:.spec.podCIDR --no-headers | sed 's/^/      /'
    
    PROJECT_DEFAULT="192.168.0.0/16"
    DETECTED_CIDR=${KCM_CIDR:-$PROJECT_DEFAULT}

    echo ""
    read -p "Pod CIDR 입력 (기본값: ${DETECTED_CIDR}): " POD_CIDR
    POD_CIDR="${POD_CIDR:-${DETECTED_CIDR}}"
fi

if [ -z "${MTU_VALUE}" ]; then
    read -p "네트워크 MTU 입력 (기본값: 1500, 터널링 사용 시 1450 권장): " MTU_VALUE
    MTU_VALUE="${MTU_VALUE:-1500}"
fi

# ── Hubble 도구 설정 ──────────────────────────────────────
if [ -z "${ENABLE_HUBBLE}" ]; then
    echo -e "\n${CYAN}🔍 Hubble 설치 (가시성 UI 및 Relay)${NC}"
    read -p "Hubble을 활성화하시겠습니까? (y/n, 기본값: y): " _HUBBLE
    ENABLE_HUBBLE=$([[ "$_HUBBLE" =~ ^[Nn]$ ]] && echo "false" || echo "true")
fi

save_conf

# ── 매니페스트 치환 및 준비 ────────────────────────────────
echo ""
echo -e "${YELLOW}🔧 매니페스트 및 values 파일 준비 중...${NC}"

# 기본 values 파일 복사
if [ "${IMAGE_SOURCE}" = "local" ] && [ -f "./values-local.yaml" ]; then
    cp "./values-local.yaml" ./values-temp.yaml
else
    cp "$VALUES_FILE" ./values-temp.yaml
fi

# 공통 환경 변수 치환
sed -i \
    -e "s|<K8S_SERVICE_HOST>|${K8S_SERVICE_HOST}|g" \
    -e "s|<K8S_SERVICE_PORT>|${K8S_SERVICE_PORT}|g" \
    -e "s|<POD_CIDR>|${POD_CIDR}|g" \
    -e "s|<MTU_VALUE>|${MTU_VALUE}|g" \
    ./values-temp.yaml

# Harbor 사용 시 이미지 레지스트리 정보 치환
if [ "${IMAGE_SOURCE}" = "harbor" ]; then
    sed -i \
        -e "s|<NODE_IP>|${HARBOR_REGISTRY}|g" \
        -e "s|<PROJECT>|${HARBOR_PROJECT}|g" \
        ./values-temp.yaml
fi

# K3s 환경 자동 감지 및 CNI 경로 설정
HELM_EXTRA_ARGS=""
if $KUBECTL get nodes -o wide 2>/dev/null | grep -qi "k3s"; then
    echo -e "${CYAN}🔍 K3s 환경이 감지되었습니다. K3s용 CNI 경로를 적용합니다.${NC}"
    HELM_EXTRA_ARGS="--set cni.binPath=/var/lib/rancher/k3s/data/cni --set cni.confPath=/var/lib/rancher/k3s/agent/etc/cni/net.d"
else
    echo -e "${CYAN}🔍 일반 Kubernetes 환경으로 감지되었습니다.${NC}"
fi

# ── Cilium Helm 설치/업그레이드 ───────────────────────────
echo -e "${YELLOW}🚀 Cilium Helm ${DO_UPGRADE:+upgrade}${DO_UPGRADE:-install} 중...${NC}"
$HELM upgrade --install $RELEASE_NAME "$CHART_PATH" \
    --namespace $NAMESPACE \
    -f ./values-temp.yaml \
    --set hubble.relay.enabled=${ENABLE_HUBBLE} \
    --set hubble.ui.enabled=${ENABLE_HUBBLE} \
    $HELM_EXTRA_ARGS \
    --wait

# ── 추가 매니페스트 자동 적용 ─────────────────────────────
if [ -d "./manifests" ] && [ "$(ls -A ./manifests/*.yaml 2>/dev/null)" ]; then
    echo -e "${YELLOW}🚀 추가 매니페스트(HTTPRoute 등) 적용 중...${NC}"
    $KUBECTL apply -f ./manifests/
fi

rm -f ./values-temp.yaml
echo -e "\n==========================================="
echo -e "${GREEN} ✅ Cilium ${INSTALLED_VERSION} 설치 완료${NC}"
echo "==========================================="
echo " 설정 파일 : ${CONF_FILE}"
echo "==========================================="
$KUBECTL get pods -n $NAMESPACE -l "app.kubernetes.io/part-of=cilium"
