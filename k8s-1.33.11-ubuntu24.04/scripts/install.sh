#!/bin/bash

# ==========================================
# k8s-1.33.11-ubuntu24.04 오프라인 설치 스크립트
#   - WSL2/VM 자동 감지 · CNI 선택 · install.conf 저장
#   - CNI=calico → ../envoy-1.37.2/scripts/install.sh 자동 호출 (옵션)
#   - CNI=cilium → ../cilium-1.19.3/scripts/install.sh 자동 호출 (옵션)
#
# 사용법:
#   sudo ./scripts/install.sh                        # 컨트롤 플레인 설치
#   sudo ./scripts/install.sh --join <token> <hash> <endpoint>   # 워커/추가 마스터 합류
# ==========================================

cd "$(dirname "$0")/.." || exit 1

# Root 권한 체크
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── 경로 상수 ────────────────────────────────────────────────
BASE_DIR="$(pwd)"
CONF_FILE="${BASE_DIR}/install.conf"
DEB_DIR="${BASE_DIR}/k8s/debs"
BIN_DIR="${BASE_DIR}/k8s/binaries"
IMG_DIR="${BASE_DIR}/k8s/images"
UTIL_DIR="${BASE_DIR}/k8s/utils"

K8S_VERSION="v1.33.11"
CILIUM_COMPONENT_DIR="../cilium-1.19.3"
ENVOY_COMPONENT_DIR="../envoy-1.37.2"

# ── install.conf 로드 / 저장 ─────────────────────────────────
load_conf() {
    [ -f "$CONF_FILE" ] && source "$CONF_FILE"
}

save_conf() {
    cat > "$CONF_FILE" <<EOF
# k8s-1.33.11-ubuntu24.04 설치 설정 — install.sh 에 의해 자동 관리됩니다.
ENV_TYPE="${ENV_TYPE}"
NODE_ROLE="${NODE_ROLE}"
CNI_CHOICE="${CNI_CHOICE}"
CNI_INSTALL_MODE="${CNI_INSTALL_MODE}"
GATEWAY_INSTALL_MODE="${GATEWAY_INSTALL_MODE}"
POD_CIDR="${POD_CIDR}"
SERVICE_CIDR="${SERVICE_CIDR}"
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT}"
CRI_SOCKET="${CRI_SOCKET}"
INSTALLED_VERSION="${K8S_VERSION}"
EOF
    echo -e "  ${GREEN}✅ 설정이 ${CONF_FILE} 에 저장되었습니다.${NC}"
}

reset_conf_vars() {
    ENV_TYPE="" NODE_ROLE="" CNI_CHOICE="" CNI_INSTALL_MODE="" GATEWAY_INSTALL_MODE=""
    POD_CIDR="" CONTROL_PLANE_ENDPOINT=""
}

load_conf
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
CRI_SOCKET="${CRI_SOCKET:-unix:///run/containerd/containerd.sock}"

# ==========================================
# 워커/추가 마스터 합류 모드
# ==========================================
if [ "$1" = "--join" ]; then
    JOIN_TOKEN="$2"
    JOIN_HASH="$3"
    JOIN_ENDPOINT="$4"

    if [ -z "$JOIN_TOKEN" ] || [ -z "$JOIN_HASH" ] || [ -z "$JOIN_ENDPOINT" ]; then
        echo -e "${RED}[오류] 사용법: $0 --join <token> <ca-hash> <endpoint>${NC}"
        exit 1
    fi

    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN} 워커 노드 합류 모드${NC}"
    echo -e "${CYAN}   endpoint: ${JOIN_ENDPOINT}${NC}"
    echo -e "${CYAN}============================================================${NC}"

    # 공통 준비(DEB/OS/containerd/이미지)는 아래 함수에서 재사용
    NODE_ROLE="worker"
    echo -e "${YELLOW}DEB 설치 · OS 사전 설정 · containerd 구성 · 이미지 로드 진행...${NC}"

    dpkg -i "$DEB_DIR"/*.deb 2>/dev/null || apt-get install -f -y --no-download || true
    systemctl enable kubelet

    modprobe overlay; modprobe br_netfilter
    cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
    cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    sysctl --system >/dev/null
    swapoff -a
    sed -i '/\sswap\s/s/^/#/' /etc/fstab

    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10"|' /etc/containerd/config.toml
    systemctl enable --now containerd

    for tar_file in "$IMG_DIR"/*.tar; do
        [ -e "$tar_file" ] || continue
        ctr -n k8s.io images import "$tar_file" >/dev/null
    done

    echo -e "${CYAN}kubeadm join 실행 중...${NC}"
    kubeadm join "$JOIN_ENDPOINT" \
        --token "$JOIN_TOKEN" \
        --discovery-token-ca-cert-hash "sha256:$JOIN_HASH"

    save_conf
    echo -e "${GREEN}✅ 노드 합류 완료${NC}"
    exit 0
fi

# ==========================================
# 컨트롤 플레인 설치 메인 플로우
# ==========================================
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} Kubernetes ${K8S_VERSION} 오프라인 설치 (컨트롤 플레인)${NC}"
echo -e "${CYAN}============================================================${NC}"

# ── [1] 환경 감지 ────────────────────────────────────────────
DETECTED_ENV="vm"
if grep -qi "microsoft" /proc/version 2>/dev/null; then
    DETECTED_ENV="wsl2"
fi

if [ -z "$ENV_TYPE" ]; then
    echo ""
    echo "환경이 '${DETECTED_ENV}' 로 감지되었습니다."
    read -p "이대로 진행할까요? [Y/n]: " _ENV_OK
    _ENV_OK="${_ENV_OK:-Y}"
    if [[ "$_ENV_OK" =~ ^[Yy]$ ]]; then
        ENV_TYPE="$DETECTED_ENV"
    else
        read -p "환경을 직접 지정하세요 (wsl2/vm): " ENV_TYPE
        [[ "$ENV_TYPE" != "wsl2" && "$ENV_TYPE" != "vm" ]] && \
            { echo -e "${RED}[오류] wsl2 또는 vm 이어야 합니다.${NC}"; exit 1; }
    fi
fi

# WSL2 systemd 확인
if [ "$ENV_TYPE" = "wsl2" ]; then
    if ! pidof systemd >/dev/null 2>&1; then
        echo -e "${RED}[오류] WSL2 systemd 가 활성화되어 있지 않습니다.${NC}"
        echo "       먼저 'sudo ./scripts/wsl2_prep.sh' 실행 후 wsl --shutdown 재기동하세요."
        exit 1
    fi
fi

# ── [2] 기존 설치 감지 + 메뉴 ───────────────────────────────
EXIST_K8S="no"
if command -v kubectl >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1; then
    EXIST_K8S="yes"
elif [ -f /etc/kubernetes/admin.conf ]; then
    EXIST_K8S="yes"
fi

if [ "$EXIST_K8S" = "yes" ]; then
    echo ""
    echo -e "${YELLOW}[알림] 기존 Kubernetes 설치가 감지되었습니다.${NC}"
    if [ -f "$CONF_FILE" ]; then
        echo "  📋 저장된 설정:"
        echo "     환경     : ${ENV_TYPE:-미설정}"
        echo "     CNI      : ${CNI_CHOICE:-미설정} (모드: ${CNI_INSTALL_MODE:-미설정})"
        echo "     설치버전 : ${INSTALLED_VERSION:-미설정}"
    fi
    echo ""
    echo "동작을 선택하세요:"
    echo "  1) 재설치       — 초기화 후 재설치 (설정 재입력)"
    echo "  2) 초기화       — uninstall.sh 실행 후 종료"
    echo "  3) 취소"
    read -p "선택 [1/2/3, 기본값 3]: " _ACT
    _ACT="${_ACT:-3}"
    case "$_ACT" in
        1)
            echo -e "${CYAN}🔥 기존 클러스터 초기화 중...${NC}"
            bash "$BASE_DIR/scripts/uninstall.sh" --yes || true
            reset_conf_vars
            rm -f "$CONF_FILE"
            ENV_TYPE="$DETECTED_ENV"
            ;;
        2)
            bash "$BASE_DIR/scripts/uninstall.sh"
            exit 0
            ;;
        *)
            echo "취소합니다."
            exit 0
            ;;
    esac
fi

NODE_ROLE="control-plane"

# ── [3] CNI 선택 ────────────────────────────────────────────
if [ -z "$CNI_CHOICE" ]; then
    echo ""
    echo "CNI 를 선택하세요:"
    echo "  1) Calico v3.31  (kube-proxy 사용, L7은 Envoy Gateway)"
    echo "  2) Cilium v1.19.3 (kubeProxyReplacement, Gateway API 내장)"
    read -p "선택 [1/2, 기본값: 1]: " _CNI
    _CNI="${_CNI:-1}"
    case "$_CNI" in
        1) CNI_CHOICE="calico"; POD_CIDR="192.168.0.0/16" ;;
        2) CNI_CHOICE="cilium"; POD_CIDR="10.0.0.0/16" ;;
        *) echo -e "${RED}[오류] 1 또는 2를 선택하세요.${NC}"; exit 1 ;;
    esac
fi

if [ -z "$CNI_INSTALL_MODE" ]; then
    echo ""
    echo "CNI 설치 모드:"
    echo "  1) auto   — 본 스크립트가 ${CNI_CHOICE} 까지 자동 설치"
    echo "  2) manual — kubeadm init 까지만 수행, CNI 는 사용자가 수동 설치"
    read -p "선택 [1/2, 기본값: 1]: " _CMODE
    _CMODE="${_CMODE:-1}"
    case "$_CMODE" in
        1) CNI_INSTALL_MODE="auto" ;;
        2) CNI_INSTALL_MODE="manual" ;;
        *) echo -e "${RED}[오류] 1 또는 2를 선택하세요.${NC}"; exit 1 ;;
    esac
fi

# Envoy Gateway 설치 모드 (calico + auto 시에만)
if [ "$CNI_CHOICE" = "calico" ] && [ "$CNI_INSTALL_MODE" = "auto" ]; then
    if [ -z "$GATEWAY_INSTALL_MODE" ]; then
        echo ""
        echo "Envoy Gateway(L7) 설치 모드:"
        echo "  1) auto   — Calico 설치 후 ${ENVOY_COMPONENT_DIR}/scripts/install.sh 자동 호출"
        echo "  2) manual — 사용자가 별도 설치"
        read -p "선택 [1/2, 기본값: 1]: " _GMODE
        _GMODE="${_GMODE:-1}"
        case "$_GMODE" in
            1) GATEWAY_INSTALL_MODE="auto" ;;
            2) GATEWAY_INSTALL_MODE="manual" ;;
            *) echo -e "${RED}[오류] 1 또는 2를 선택하세요.${NC}"; exit 1 ;;
        esac
    fi
fi

# ── [4] 컨트롤 플레인 엔드포인트 ────────────────────────────
if [ -z "$CONTROL_PLANE_ENDPOINT" ]; then
    if [ "$ENV_TYPE" = "wsl2" ]; then
        # WSL2: eth0 IP 자동 감지
        DEFAULT_IP=$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
        read -p "컨트롤 플레인 엔드포인트 [기본: ${DEFAULT_IP}]: " CONTROL_PLANE_ENDPOINT
        CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-$DEFAULT_IP}"
    else
        read -p "컨트롤 플레인 엔드포인트 (단일: 노드 IP / HA: VIP 또는 FQDN): " CONTROL_PLANE_ENDPOINT
        [ -z "$CONTROL_PLANE_ENDPOINT" ] && \
            { echo -e "${RED}[오류] 엔드포인트가 필요합니다.${NC}"; exit 1; }
    fi
fi

echo ""
echo -e "${CYAN}🔧 설정 요약${NC}"
echo "   환경          : $ENV_TYPE"
echo "   CNI           : $CNI_CHOICE ($CNI_INSTALL_MODE)"
[ "$CNI_CHOICE" = "calico" ] && echo "   Envoy Gateway : ${GATEWAY_INSTALL_MODE:-N/A}"
echo "   Pod CIDR      : $POD_CIDR"
echo "   Service CIDR  : $SERVICE_CIDR"
echo "   Endpoint      : $CONTROL_PLANE_ENDPOINT"
echo ""
read -p "위 설정으로 진행할까요? [Y/n]: " _GO
_GO="${_GO:-Y}"
[[ ! "$_GO" =~ ^[Yy]$ ]] && { echo "취소합니다."; exit 0; }

save_conf

# ── [5] DEB 설치 ────────────────────────────────────────────
echo ""
echo -e "${CYAN}[5/10] DEB 설치...${NC}"
if ! ls "$DEB_DIR"/*.deb >/dev/null 2>&1; then
    echo -e "${RED}[오류] $DEB_DIR 에 DEB 파일이 없습니다.${NC}"
    echo "       인터넷 호스트에서 scripts/download.sh 실행 후 재시도하세요."
    exit 1
fi
dpkg -i "$DEB_DIR"/*.deb 2>/dev/null || apt-get install -f -y --no-download || true
systemctl enable kubelet

# ── [6] OS 사전 설정 ────────────────────────────────────────
echo ""
echo -e "${CYAN}[6/10] OS 사전 설정...${NC}"
modprobe overlay; modprobe br_netfilter
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null
swapoff -a
sed -i '/\sswap\s/s/^/#/' /etc/fstab

if [ "$ENV_TYPE" = "wsl2" ]; then
    update-alternatives --set iptables /usr/sbin/iptables-legacy >/dev/null 2>&1 || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >/dev/null 2>&1 || true
fi

# ── [7] containerd 구성 ─────────────────────────────────────
echo ""
echo -e "${CYAN}[7/10] containerd 구성...${NC}"
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10"|' /etc/containerd/config.toml
sed -i "s|config_path = '/etc/containerd/certs.d:/etc/docker/certs.d'|config_path = '/etc/containerd/certs.d'|g" /etc/containerd/config.toml
systemctl enable --now containerd
systemctl restart containerd
sleep 2

# ── [8] 이미지 pre-load ─────────────────────────────────────
echo ""
echo -e "${CYAN}[8/10] 컨테이너 이미지 pre-load...${NC}"
IMG_COUNT=0
for tar_file in "$IMG_DIR"/*.tar; do
    [ -e "$tar_file" ] || continue
    echo "  → $(basename "$tar_file")"
    ctr -n k8s.io images import "$tar_file" >/dev/null
    IMG_COUNT=$((IMG_COUNT + 1))
done
[ "$IMG_COUNT" -eq 0 ] && echo -e "${YELLOW}[경고] $IMG_DIR 에 이미지 tar 가 없습니다.${NC}"

# ── [9] kubeadm init ────────────────────────────────────────
echo ""
echo -e "${CYAN}[9/10] kubeadm init...${NC}"
KUBEADM_ARGS=(
    --control-plane-endpoint "${CONTROL_PLANE_ENDPOINT}:6443"
    --pod-network-cidr "$POD_CIDR"
    --service-cidr "$SERVICE_CIDR"
    --kubernetes-version "$K8S_VERSION"
    --cri-socket "$CRI_SOCKET"
)
if [ "$CNI_CHOICE" = "cilium" ]; then
    KUBEADM_ARGS+=(--skip-phases=addon/kube-proxy)
fi

kubeadm init "${KUBEADM_ARGS[@]}"

# kubeconfig 설정 (실행 사용자 및 root 양쪽)
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config

if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    SUDO_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    mkdir -p "$SUDO_HOME/.kube"
    cp -f /etc/kubernetes/admin.conf "$SUDO_HOME/.kube/config"
    chown -R "$SUDO_USER:$SUDO_USER" "$SUDO_HOME/.kube"
fi

export KUBECONFIG=/etc/kubernetes/admin.conf

# 단일 노드(WSL2 포함)에서 컨트롤 플레인 taint 제거 옵션
if [ "$ENV_TYPE" = "wsl2" ]; then
    echo "WSL2 단일 노드 — control-plane taint 제거"
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
fi

# ── [10] CNI / Gateway 설치 (4 분기) ────────────────────────
echo ""
echo -e "${CYAN}[10/10] CNI / Gateway 처리...${NC}"

install_calico() {
    echo -e "${CYAN}  → Calico Tigera Operator 설치${NC}"
    kubectl create -f "$UTIL_DIR/tigera-operator.yaml"
    # Pod CIDR 반영
    sed "s|cidr: .*|cidr: ${POD_CIDR}|" "$UTIL_DIR/calico-custom-resources.yaml" \
        | kubectl create -f -
    echo "  → Calico Pod Ready 대기 (최대 5분)..."
    kubectl wait --for=condition=Ready pod -l k8s-app=calico-node \
        -n calico-system --timeout=300s || true
}

case "${CNI_CHOICE}::${CNI_INSTALL_MODE}" in
    calico::auto)
        install_calico
        if [ "$GATEWAY_INSTALL_MODE" = "auto" ]; then
            if [ -x "$ENVOY_COMPONENT_DIR/scripts/install.sh" ]; then
                echo -e "${CYAN}  → Envoy Gateway 자동 설치 호출${NC}"
                bash "$ENVOY_COMPONENT_DIR/scripts/install.sh"
            else
                echo -e "${YELLOW}[경고] $ENVOY_COMPONENT_DIR/scripts/install.sh 미존재 — 수동 설치 필요${NC}"
            fi
        else
            echo -e "${YELLOW}  → Envoy Gateway 는 수동 설치하세요: $ENVOY_COMPONENT_DIR/scripts/install.sh${NC}"
        fi
        ;;
    calico::manual)
        echo -e "${YELLOW}  → Calico/Envoy 는 수동 설치하세요.${NC}"
        echo "     Calico:  kubectl create -f $UTIL_DIR/tigera-operator.yaml"
        echo "              kubectl create -f $UTIL_DIR/calico-custom-resources.yaml"
        echo "     Envoy :  $ENVOY_COMPONENT_DIR/scripts/install.sh"
        ;;
    cilium::auto)
        if [ -x "$CILIUM_COMPONENT_DIR/scripts/install.sh" ]; then
            echo -e "${CYAN}  → Cilium 자동 설치 호출${NC}"
            # Cilium install.conf 에 K8S_SERVICE_HOST/PORT, POD_CIDR 주입 (cilium의 save_conf 포맷과 일치)
            CILIUM_CONF="$CILIUM_COMPONENT_DIR/install.conf"
            touch "$CILIUM_CONF"
            {
                grep -Ev "^(K8S_SERVICE_HOST|K8S_SERVICE_PORT|POD_CIDR)=" "$CILIUM_CONF" 2>/dev/null || true
                echo "K8S_SERVICE_HOST=\"${CONTROL_PLANE_ENDPOINT}\""
                echo "K8S_SERVICE_PORT=\"6443\""
                echo "POD_CIDR=\"${POD_CIDR}\""
            } > "${CILIUM_CONF}.tmp" && mv "${CILIUM_CONF}.tmp" "$CILIUM_CONF"

            bash "$CILIUM_COMPONENT_DIR/scripts/install.sh"
        else
            echo -e "${YELLOW}[경고] $CILIUM_COMPONENT_DIR/scripts/install.sh 미존재 — 수동 설치 필요${NC}"
        fi
        ;;
    cilium::manual)
        echo -e "${YELLOW}  → Cilium 은 수동 설치하세요: $CILIUM_COMPONENT_DIR/scripts/install.sh${NC}"
        ;;
esac

# ── 완료 ────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} ✅ Kubernetes ${K8S_VERSION} 설치 완료${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo " 워커 합류 토큰 생성:"
echo "   kubeadm token create --print-join-command"
echo ""
echo " 다른 노드에서 합류:"
echo "   sudo ./scripts/install.sh --join <token> <ca-hash> <endpoint>"
echo ""
kubectl get nodes
echo ""
kubectl get pods -A
