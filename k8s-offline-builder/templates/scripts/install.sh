#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

if [ "$EUID" -ne 0 ]; then
    echo "[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다."
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

BASE_DIR="$(pwd)"
CONF_FILE="${BASE_DIR}/install.conf"
DEB_DIR="${BASE_DIR}/k8s/debs"
BIN_DIR="${BASE_DIR}/k8s/binaries"
IMG_DIR="${BASE_DIR}/k8s/images"
UTIL_DIR="${BASE_DIR}/k8s/utils"

if [ ! -f "$CONF_FILE" ]; then
    echo -e "${RED}[오류] install.conf 파일이 없습니다.${NC}"
    exit 1
fi

source "$CONF_FILE"

: "${K8S_VERSION:=}"
: "${TARGET_OS:=ubuntu24.04}"
: "${ARCH:=amd64}"
: "${CONTAINER_RUNTIME:=containerd}"
: "${CNI_CHOICE:=calico}"
: "${CALICO_INSTALL_METHOD:=manifest}"
: "${ENV_TYPE:=}"
: "${NODE_ROLE:=}"
: "${CNI_INSTALL_MODE:=auto}"
: "${POD_CIDR:=}"
: "${SERVICE_CIDR:=}"
: "${CONTROL_PLANE_ENDPOINT:=}"
: "${CRI_SOCKET:=unix:///run/containerd/containerd.sock}"

if [[ "$K8S_VERSION" != v* ]]; then
    K8S_VERSION="v${K8S_VERSION}"
fi

if [ "$TARGET_OS" != "ubuntu24.04" ]; then
    echo -e "${RED}[오류] 현재 생성 번들 설치 스크립트는 ubuntu24.04 대상만 지원합니다: $TARGET_OS${NC}"
    exit 1
fi

if [ "$CONTAINER_RUNTIME" != "containerd" ]; then
    echo -e "${RED}[오류] 현재 생성 번들 설치 스크립트는 containerd 런타임만 지원합니다: $CONTAINER_RUNTIME${NC}"
    exit 1
fi

save_conf() {
    cat > "$CONF_FILE" <<EOF
# Generated Kubernetes offline bundle install configuration.
K8S_VERSION="${K8S_VERSION}"
TARGET_OS="${TARGET_OS}"
ARCH="${ARCH}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-auto}"
CNI_CHOICE="${CNI_CHOICE}"
CALICO_VERSION="${CALICO_VERSION:-}"
CALICO_INSTALL_METHOD="${CALICO_INSTALL_METHOD}"
CILIUM_VERSION="${CILIUM_VERSION:-}"
ENV_TYPE="${ENV_TYPE}"
NODE_ROLE="${NODE_ROLE}"
CNI_INSTALL_MODE="${CNI_INSTALL_MODE}"
POD_CIDR="${POD_CIDR}"
SERVICE_CIDR="${SERVICE_CIDR}"
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT}"
CRI_SOCKET="${CRI_SOCKET}"
INSTALLED_VERSION="${K8S_VERSION}"
EOF
    echo -e "  ${GREEN}설정 저장 완료: ${CONF_FILE}${NC}"
}

reset_runtime_conf() {
    ENV_TYPE=""
    NODE_ROLE=""
    CNI_INSTALL_MODE="auto"
    POD_CIDR=""
    SERVICE_CIDR=""
    CONTROL_PLANE_ENDPOINT=""
}

disable_swap_completely() {
    echo -e "${YELLOW}Swap 비활성화 및 영구 설정 정리...${NC}"
    swapoff -a || true

    if [ -f /etc/fstab ]; then
        sed -i.bak -E '/^[[:space:]]*[^#[:space:]]+[[:space:]]+[^#[:space:]]+[[:space:]]+swap[[:space:]]+/ s/^/#/' /etc/fstab
    fi

    local swap_units swap_unit_files unit state
    swap_units=$(systemctl list-units --type=swap --all --no-legend --no-pager 2>/dev/null | grep -oE '\S+\.swap' || true)
    for unit in $swap_units; do
        systemctl mask "$unit" >/dev/null 2>&1 || true
    done

    swap_unit_files=$(systemctl list-unit-files --type=swap --no-legend --no-pager 2>/dev/null | grep -oE '\S+\.swap' || true)
    for unit in $swap_unit_files; do
        state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
        [ "$state" = "masked" ] || systemctl mask "$unit" >/dev/null 2>&1 || true
    done

    if systemctl is-active zram-generator >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q zram; then
        systemctl disable --now zram-generator 2>/dev/null || true
        systemctl disable --now zram-config 2>/dev/null || true
    fi

    systemctl daemon-reload
    if swapon --show | grep -q .; then
        echo -e "${YELLOW}[경고] Swap이 아직 활성 상태입니다. 수동 확인이 필요합니다.${NC}"
    fi
}

configure_system_limits() {
    echo -e "${YELLOW}파일 디스크립터 및 systemd limits 설정...${NC}"

    cat > /etc/sysctl.d/99-kubernetes-limits.conf <<EOF
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192
EOF
    sysctl --system >/dev/null 2>&1 || true

    mkdir -p /etc/security/limits.d
    cat > /etc/security/limits.d/99-kubernetes-limits.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

    mkdir -p /etc/systemd/system/containerd.service.d
    cat > /etc/systemd/system/containerd.service.d/limits.conf <<EOF
[Service]
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
EOF

    mkdir -p /etc/systemd/system/kubelet.service.d
    cat > /etc/systemd/system/kubelet.service.d/limits.conf <<EOF
[Service]
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
EOF
    systemctl daemon-reload
}

check_time_sync() {
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN} 시간 동기화 상태 확인${NC}"
    echo -e "${CYAN}============================================================${NC}"

    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl status || true
    else
        date
    fi

    local synced=0
    if command -v timedatectl >/dev/null 2>&1 && timedatectl status 2>/dev/null | grep -qi "System clock synchronized: yes"; then
        synced=1
    fi

    if [ "$synced" -eq 0 ]; then
        local svc
        for svc in chrony chronyd systemd-timesyncd ntp ntpd; do
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                synced=1
                break
            fi
        done
    fi

    if [ "$synced" -eq 1 ]; then
        echo -e "${GREEN}시간 동기화 서비스가 감지되었습니다.${NC}"
        read -p "동기화 상태를 확인했으면 Enter를 누르세요..." _DUMMY
    else
        echo -e "${YELLOW}[경고] 시간 동기화 상태를 자동 확인하지 못했습니다.${NC}"
        read -p "수동으로 확인했으며 계속 진행할까요? [y/N]: " _TIME_CONTINUE
        _TIME_CONTINUE="${_TIME_CONTINUE:-N}"
        [[ "$_TIME_CONTINUE" =~ ^[Yy]$ ]] || exit 1
    fi
}

install_debs_and_prepare_node() {
    echo -e "${CYAN}DEB 설치 및 OS 사전 설정...${NC}"
    if ! ls "$DEB_DIR"/*.deb >/dev/null 2>&1; then
        echo -e "${RED}[오류] $DEB_DIR 에 DEB 파일이 없습니다.${NC}"
        exit 1
    fi

    dpkg -i "$DEB_DIR"/*.deb 2>/dev/null || apt-get install -f -y --no-download || true
    systemctl enable kubelet

    modprobe overlay || true
    modprobe br_netfilter || true
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

    disable_swap_completely
    configure_system_limits

    if [ "$ENV_TYPE" = "wsl2" ]; then
        update-alternatives --set iptables /usr/sbin/iptables-legacy >/dev/null 2>&1 || true
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >/dev/null 2>&1 || true
    fi
}

configure_containerd() {
    echo -e "${CYAN}containerd 설정...${NC}"
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10"|' /etc/containerd/config.toml
    sed -i "s|config_path = '/etc/containerd/certs.d:/etc/docker/certs.d'|config_path = '/etc/containerd/certs.d'|g" /etc/containerd/config.toml
    systemctl enable --now containerd
    systemctl restart containerd
    sleep 2
}

load_images() {
    echo -e "${CYAN}컨테이너 이미지 pre-load...${NC}"
    local count=0 tar_file
    for tar_file in "$IMG_DIR"/*.tar; do
        [ -e "$tar_file" ] || continue
        echo "  → $(basename "$tar_file")"
        ctr -n k8s.io images import "$tar_file" >/dev/null
        count=$((count + 1))
    done
    [ "$count" -eq 0 ] && echo -e "${YELLOW}[경고] $IMG_DIR 에 이미지 tar 파일이 없습니다.${NC}"
}

setup_kubeconfig() {
    mkdir -p /root/.kube
    cp -f /etc/kubernetes/admin.conf /root/.kube/config

    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        local sudo_home
        sudo_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        mkdir -p "$sudo_home/.kube"
        cp -f /etc/kubernetes/admin.conf "$sudo_home/.kube/config"
        chown -R "$SUDO_USER:$SUDO_USER" "$sudo_home/.kube"
    fi
}

install_calico_manifest() {
    [ -f "$UTIL_DIR/calico.yaml" ] || { echo -e "${RED}[오류] calico.yaml 파일이 없습니다.${NC}"; exit 1; }

    echo -e "${CYAN}Calico manifest 설치...${NC}"
    if [ "$POD_CIDR" = "192.168.0.0/16" ]; then
        kubectl apply -f "$UTIL_DIR/calico.yaml"
    else
        awk -v cidr="$POD_CIDR" '
            /# - name: CALICO_IPV4POOL_CIDR/ {
                sub(/# -/, "-")
                print
                getline
                sub(/#   value:.*/, "  value: \"" cidr "\"")
                print
                next
            }
            { print }
        ' "$UTIL_DIR/calico.yaml" | kubectl apply -f -
    fi
    kubectl wait --for=condition=Ready pod -l k8s-app=calico-node \
        -n kube-system --timeout=300s 2>/dev/null || true
}

install_calico_operator() {
    [ -f "$UTIL_DIR/tigera-operator.yaml" ] || { echo -e "${RED}[오류] tigera-operator.yaml 파일이 없습니다.${NC}"; exit 1; }
    [ -f "$UTIL_DIR/calico-custom-resources.yaml" ] || { echo -e "${RED}[오류] calico-custom-resources.yaml 파일이 없습니다.${NC}"; exit 1; }

    echo -e "${CYAN}Calico Tigera Operator 설치...${NC}"
    kubectl create -f "$UTIL_DIR/tigera-operator.yaml"
    local elapsed=0
    until kubectl get crd installations.operator.tigera.io >/dev/null 2>&1; do
        [ "$elapsed" -ge 180 ] && { echo -e "${RED}[오류] Tigera CRD 등록 타임아웃${NC}"; exit 1; }
        sleep 5
        elapsed=$((elapsed + 5))
    done
    kubectl wait --for=condition=established crd/installations.operator.tigera.io --timeout=60s
    sed "s|cidr: .*|cidr: ${POD_CIDR}|" "$UTIL_DIR/calico-custom-resources.yaml" | kubectl create -f -
    kubectl wait --for=condition=Ready pod -l k8s-app=calico-node \
        -n calico-system --timeout=300s 2>/dev/null || true
}

install_cni() {
    case "$CNI_CHOICE" in
        calico)
            if [ "$CALICO_INSTALL_METHOD" = "operator" ]; then
                install_calico_operator
            else
                install_calico_manifest
            fi
            ;;
        cilium)
            echo -e "${RED}[오류] Cilium 번들 내장 설치는 아직 구현되지 않았습니다.${NC}"
            echo "       Cilium 자산 수집/설치 연계 구현 후 사용하세요."
            exit 1
            ;;
        *)
            echo -e "${RED}[오류] 지원하지 않는 CNI: $CNI_CHOICE${NC}"
            exit 1
            ;;
    esac
}

run_join() {
    local join_token="$1"
    local join_hash="$2"
    local join_endpoint="$3"
    local join_is_cp=0
    local join_cert_key=""

    if [ -n "$join_endpoint" ] && [[ "$join_endpoint" != *:* ]]; then
        join_endpoint="${join_endpoint}:6443"
    fi

    if [ "${4:-}" = "--control-plane" ]; then
        join_is_cp=1
        join_cert_key="${5:-}"
        [ -n "$join_cert_key" ] || { echo -e "${RED}[오류] certificate-key 가 필요합니다.${NC}"; exit 1; }
    fi

    [ -n "$join_token" ] && [ -n "$join_hash" ] && [ -n "$join_endpoint" ] || {
        echo "사용법:"
        echo "  Worker: $0 --join <token> <ca-hash> <endpoint>"
        echo "  Control-plane: $0 --join <token> <ca-hash> <endpoint> --control-plane <cert-key>"
        exit 1
    }

    NODE_ROLE=$([ "$join_is_cp" -eq 1 ] && echo "control-plane" || echo "worker")
    check_time_sync
    install_debs_and_prepare_node
    configure_containerd
    load_images

    if [ "$join_is_cp" -eq 1 ]; then
        local haproxy_was_active=0
        if systemctl is-active haproxy >/dev/null 2>&1 && grep -q ":6443" /etc/haproxy/haproxy.cfg 2>/dev/null; then
            systemctl stop haproxy
            haproxy_was_active=1
        fi
        kubeadm join "$join_endpoint" \
            --token "$join_token" \
            --discovery-token-ca-cert-hash "sha256:$join_hash" \
            --control-plane \
            --certificate-key "$join_cert_key"
        [ "$haproxy_was_active" -eq 1 ] && systemctl start haproxy
        setup_kubeconfig
    else
        kubeadm join "$join_endpoint" \
            --token "$join_token" \
            --discovery-token-ca-cert-hash "sha256:$join_hash"
    fi

    save_conf
    echo -e "${GREEN}노드 합류 완료${NC}"
}

if [ "${1:-}" = "--join" ]; then
    run_join "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}"
    exit 0
fi

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} Kubernetes ${K8S_VERSION} 오프라인 설치${NC}"
echo -e "${CYAN}============================================================${NC}"

DETECTED_ENV="vm"
if grep -qi "microsoft" /proc/version 2>/dev/null; then
    DETECTED_ENV="wsl2"
fi

if [ -z "$ENV_TYPE" ]; then
    read -p "환경이 '${DETECTED_ENV}' 로 감지되었습니다. 이대로 진행할까요? [Y/n]: " _ENV_OK
    _ENV_OK="${_ENV_OK:-Y}"
    if [[ "$_ENV_OK" =~ ^[Yy]$ ]]; then
        ENV_TYPE="$DETECTED_ENV"
    else
        read -p "환경을 직접 지정하세요 (wsl2/vm): " ENV_TYPE
        [[ "$ENV_TYPE" != "wsl2" && "$ENV_TYPE" != "vm" ]] && { echo -e "${RED}[오류] wsl2 또는 vm 이어야 합니다.${NC}"; exit 1; }
    fi
fi

if [ "$ENV_TYPE" = "wsl2" ] && ! pidof systemd >/dev/null 2>&1; then
    echo -e "${RED}[오류] WSL2 systemd 가 활성화되어 있지 않습니다.${NC}"
    echo "       먼저 sudo ./scripts/wsl2_prep.sh 실행 후 wsl --shutdown 재기동하세요."
    exit 1
fi

if command -v kubectl >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1 || [ -f /etc/kubernetes/admin.conf ]; then
    echo -e "${YELLOW}[알림] 기존 Kubernetes 설치가 감지되었습니다.${NC}"
    echo "  1) 재설치"
    echo "  2) 초기화"
    echo "  3) 취소"
    read -p "선택 [1/2/3, 기본값 3]: " _ACT
    _ACT="${_ACT:-3}"
    case "$_ACT" in
        1) bash "$BASE_DIR/scripts/uninstall.sh" --yes || true; reset_runtime_conf ;;
        2) bash "$BASE_DIR/scripts/uninstall.sh"; exit 0 ;;
        *) echo "취소합니다."; exit 0 ;;
    esac
fi

NODE_ROLE="control-plane"

if [ -z "$POD_CIDR" ]; then
    case "$CNI_CHOICE" in
        calico) DEFAULT_POD_CIDR="192.168.0.0/16" ;;
        cilium) DEFAULT_POD_CIDR="10.0.0.0/16" ;;
        *) echo -e "${RED}[오류] 지원하지 않는 CNI: $CNI_CHOICE${NC}"; exit 1 ;;
    esac
    read -p "Pod CIDR [기본: ${DEFAULT_POD_CIDR}]: " POD_CIDR
    POD_CIDR="${POD_CIDR:-$DEFAULT_POD_CIDR}"
fi

if [ -z "$CNI_INSTALL_MODE" ]; then
    CNI_INSTALL_MODE="auto"
fi

if [ -z "$SERVICE_CIDR" ]; then
    read -p "Service CIDR [기본: 10.96.0.0/12]: " SERVICE_CIDR
    SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
fi

if [ -z "$CONTROL_PLANE_ENDPOINT" ]; then
    if [ "$ENV_TYPE" = "wsl2" ]; then
        DEFAULT_IP=$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
        read -p "컨트롤 플레인 엔드포인트 [기본: ${DEFAULT_IP}]: " CONTROL_PLANE_ENDPOINT
        CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-$DEFAULT_IP}"
    else
        read -p "컨트롤 플레인 엔드포인트 (단일: 노드 IP / HA: VIP 또는 FQDN): " CONTROL_PLANE_ENDPOINT
        [ -n "$CONTROL_PLANE_ENDPOINT" ] || { echo -e "${RED}[오류] 엔드포인트가 필요합니다.${NC}"; exit 1; }
    fi
fi

echo ""
echo -e "${CYAN}설정 요약${NC}"
echo "  환경      : $ENV_TYPE"
echo "  CNI       : $CNI_CHOICE"
[ "$CNI_CHOICE" = "calico" ] && echo "  Calico    : $CALICO_INSTALL_METHOD"
echo "  Pod CIDR  : $POD_CIDR"
echo "  Svc CIDR  : $SERVICE_CIDR"
echo "  Endpoint  : $CONTROL_PLANE_ENDPOINT"
read -p "위 설정으로 진행할까요? [Y/n]: " _GO
_GO="${_GO:-Y}"
[[ "$_GO" =~ ^[Yy]$ ]] || { echo "취소합니다."; exit 0; }

save_conf
check_time_sync
install_debs_and_prepare_node
configure_containerd
load_images

API_ENDPOINT="$CONTROL_PLANE_ENDPOINT"
if [[ "$API_ENDPOINT" != *:* ]]; then
    API_ENDPOINT="${API_ENDPOINT}:6443"
fi
API_HOST="${API_ENDPOINT%:*}"
API_PORT="${API_ENDPOINT##*:}"

KUBEADM_ARGS=(
    --control-plane-endpoint "$API_ENDPOINT"
    --pod-network-cidr "$POD_CIDR"
    --service-cidr "$SERVICE_CIDR"
    --kubernetes-version "$K8S_VERSION"
    --cri-socket "$CRI_SOCKET"
    --upload-certs
)
if [ "$CNI_CHOICE" = "cilium" ]; then
    KUBEADM_ARGS+=(--skip-phases=addon/kube-proxy)
fi

HAPROXY_WAS_ACTIVE=0
if systemctl is-active haproxy >/dev/null 2>&1 && grep -q ":6443" /etc/haproxy/haproxy.cfg 2>/dev/null; then
    systemctl stop haproxy
    HAPROXY_WAS_ACTIVE=1
fi

kubeadm init "${KUBEADM_ARGS[@]}"
setup_kubeconfig
export KUBECONFIG=/etc/kubernetes/admin.conf

if [ "$HAPROXY_WAS_ACTIVE" -eq 1 ]; then
    systemctl start haproxy
    echo -e "${YELLOW}[수동 필요] kube-apiserver bind-address 설정 후 HAProxy 상태를 확인하세요.${NC}"
fi

if [ "$ENV_TYPE" = "wsl2" ]; then
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
fi

if [ "$CNI_INSTALL_MODE" = "auto" ]; then
    install_cni
else
    echo -e "${YELLOW}CNI 수동 설치 모드입니다.${NC}"
fi

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} Kubernetes ${K8S_VERSION} 설치 완료${NC}"
echo -e "${GREEN}============================================================${NC}"

JOIN_CMD=$(kubeadm token create --print-join-command 2>/dev/null || true)
JOIN_TOKEN=$(echo "$JOIN_CMD" | grep -oP '(?<=--token )\S+' || true)
JOIN_HASH=$(echo "$JOIN_CMD" | grep -oP '(?<=sha256:)\S+' || true)
CERT_KEY=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1 || true)

echo "워커 노드:"
echo "  sudo ./scripts/install.sh --join ${JOIN_TOKEN} ${JOIN_HASH} ${API_ENDPOINT}"
if [ -n "$CERT_KEY" ]; then
    echo ""
    echo "추가 마스터 노드:"
    echo "  sudo ./scripts/install.sh --join ${JOIN_TOKEN} ${JOIN_HASH} ${API_ENDPOINT} --control-plane ${CERT_KEY}"
    echo "  (certificate-key 는 1시간 후 만료됩니다)"
fi

kubectl get nodes || true
kubectl get pods -A || true
