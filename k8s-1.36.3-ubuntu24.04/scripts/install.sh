#!/usr/bin/env bash

set -Eeuo pipefail

cd "$(dirname "$0")/.." || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

K8S_VERSION="v1.36.3"
CALICO_VERSION="v3.32.1"
CRI_SOCKET="unix:///run/containerd/containerd.sock"
ASSET_CONTAINERD_VERSION=""

BASE_DIR="$(pwd)"
K8S_DIR="${BASE_DIR}/k8s"
DEB_DIR="${K8S_DIR}/debs"
BIN_DIR="${K8S_DIR}/binaries"
IMG_DIR="${K8S_DIR}/images"
UTIL_DIR="${K8S_DIR}/utils"
SECURITY_SOURCE_DIR="${BASE_DIR}/security"
SECURITY_RUNTIME_DIR="/etc/kubernetes/security"
AUDIT_LOG_DIR="/var/log/kubernetes/audit"
CONF_FILE="/etc/kubernetes/installer/install.conf"
RUNTIME_CONFIG="/run/kubeadm-v1.36.3.yaml"

MODE="${MODE:-}"
NODE_IP="${NODE_IP:-}"
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-}"
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
DNS_DOMAIN="${DNS_DOMAIN:-cluster.local}"
CNI_INSTALL_MODE="${CNI_INSTALL_MODE:-auto}"
COPY_ADMIN_KUBECONFIG="${COPY_ADMIN_KUBECONFIG:-false}"
NODE_NETWORK_CIDR="${NODE_NETWORK_CIDR:-}"

cleanup_runtime() {
    rm -f "$RUNTIME_CONFIG"
}

on_error() {
    local line="$1"
    echo -e "${RED}[오류] install.sh ${line}행에서 실패했습니다.${NC}" >&2
}

trap cleanup_runtime EXIT
trap 'on_error "$LINENO"' ERR

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

load_conf() {
    if [ -L "$CONF_FILE" ]; then
        echo -e "${RED}[오류] install.conf 심볼릭 링크는 허용하지 않습니다.${NC}"
        exit 1
    fi
    [ -f "$CONF_FILE" ] || return 0

    local key value
    while IFS='=' read -r key value; do
        key=$(trim "$key")
        value=$(trim "${value:-}")
        [[ -z "$key" || "$key" == \#* ]] && continue

        case "$key" in
            MODE|NODE_IP|CONTROL_PLANE_ENDPOINT|POD_CIDR|SERVICE_CIDR|\
            DNS_DOMAIN|CNI_INSTALL_MODE|COPY_ADMIN_KUBECONFIG|NODE_NETWORK_CIDR)
                printf -v "$key" '%s' "$value"
                ;;
            *)
                echo -e "${YELLOW}[경고] install.conf의 허용되지 않은 키를 무시합니다: ${key}${NC}"
                ;;
        esac
    done < "$CONF_FILE"
}

save_conf() {
    local temp_conf
    install -d -m 0700 "$(dirname "$CONF_FILE")"
    umask 077
    temp_conf=$(mktemp "${BASE_DIR}/.install.conf.XXXXXX")
    cat > "$temp_conf" <<EOF
# Kubernetes ${K8S_VERSION} 설치 설정. 비밀정보는 저장하지 않습니다.
MODE=${MODE}
NODE_IP=${NODE_IP}
CONTROL_PLANE_ENDPOINT=${CONTROL_PLANE_ENDPOINT}
POD_CIDR=${POD_CIDR}
SERVICE_CIDR=${SERVICE_CIDR}
DNS_DOMAIN=${DNS_DOMAIN}
CNI_INSTALL_MODE=${CNI_INSTALL_MODE}
COPY_ADMIN_KUBECONFIG=${COPY_ADMIN_KUBECONFIG}
NODE_NETWORK_CIDR=${NODE_NETWORK_CIDR}
EOF
    chmod 600 "$temp_conf"
    mv -f -- "$temp_conf" "$CONF_FILE"
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[오류] sudo로 실행해야 합니다.${NC}"
        exit 1
    fi
}

validate_value() {
    local value="$1"
    local pattern="$2"
    local label="$3"

    if [[ ! "$value" =~ $pattern ]]; then
        echo -e "${RED}[오류] ${label} 값이 허용 형식과 다릅니다: ${value}${NC}"
        exit 1
    fi
}

verify_host() {
    if [ ! -r /etc/os-release ]; then
        echo -e "${RED}[오류] /etc/os-release를 읽을 수 없습니다.${NC}"
        exit 1
    fi

    local os_id os_version
    os_id=$(awk -F= '$1 == "ID" {gsub(/"/, "", $2); print $2}' /etc/os-release)
    os_version=$(awk -F= '$1 == "VERSION_ID" {gsub(/"/, "", $2); print $2}' /etc/os-release)
    if [ "$os_id" != "ubuntu" ] || [[ "$os_version" != 24.04* ]]; then
        echo -e "${RED}[오류] 이 패키지는 Ubuntu 24.04 전용입니다. 감지값: ${os_id} ${os_version}${NC}"
        exit 1
    fi

    if [ "$(uname -m)" != "x86_64" ]; then
        echo -e "${RED}[오류] 현재 패키지는 amd64(x86_64)만 지원합니다.${NC}"
        exit 1
    fi
    if [ ! -r /sys/module/apparmor/parameters/enabled ] ||
       ! grep -qx 'Y' /sys/module/apparmor/parameters/enabled; then
        echo -e "${RED}[오류] AppArmor가 활성화되지 않았습니다.${NC}"
        exit 1
    fi
}

verify_assets() {
    local missing=0
    local required_paths=(
        "$SECURITY_SOURCE_DIR/audit-policy.yaml"
        "$SECURITY_SOURCE_DIR/pod-security-admission-config.yaml"
        "$UTIL_DIR/calico.yaml"
        "$K8S_DIR/ASSET_VERSIONS.txt"
    )
    local path

    if ! compgen -G "${DEB_DIR}/*.deb" >/dev/null; then
        echo -e "${RED}[누락] ${DEB_DIR}/*.deb${NC}"
        missing=1
    fi
    if ! compgen -G "${IMG_DIR}/*.tar" >/dev/null; then
        echo -e "${RED}[누락] ${IMG_DIR}/*.tar${NC}"
        missing=1
    fi
    for path in "${required_paths[@]}"; do
        if [ ! -f "$path" ]; then
            echo -e "${RED}[누락] ${path}${NC}"
            missing=1
        fi
    done

    if [ "$missing" -ne 0 ]; then
        echo "외부망 Ubuntu 24.04 호스트에서 scripts/download_assets_offline.sh를 먼저 실행하십시오."
        exit 1
    fi
    local asset_os asset_kubernetes asset_calico asset_arch
    asset_os=$(awk -F= '$1 == "OS" {print $2}' "$K8S_DIR/ASSET_VERSIONS.txt")
    asset_kubernetes=$(awk -F= '$1 == "KUBERNETES" {print $2}' "$K8S_DIR/ASSET_VERSIONS.txt")
    ASSET_CONTAINERD_VERSION=$(awk -F= '$1 == "CONTAINERD" {print $2}' "$K8S_DIR/ASSET_VERSIONS.txt")
    asset_calico=$(awk -F= '$1 == "CALICO" {print $2}' "$K8S_DIR/ASSET_VERSIONS.txt")
    asset_arch=$(awk -F= '$1 == "ARCH" {print $2}' "$K8S_DIR/ASSET_VERSIONS.txt")
    if [ -z "$ASSET_CONTAINERD_VERSION" ] ||
       [ "$asset_os" != "ubuntu-24.04" ] ||
       [ "$asset_kubernetes" != "$K8S_VERSION" ] ||
       [ "$asset_calico" != "$CALICO_VERSION" ] ||
       [ "$asset_arch" != "amd64" ]; then
        echo -e "${RED}[오류] 오프라인 자산 메타데이터가 패키지 기준과 다릅니다.${NC}"
        echo "  OS=${asset_os:-missing} Kubernetes=${asset_kubernetes:-missing}"
        echo "  containerd=${ASSET_CONTAINERD_VERSION:-missing} Calico=${asset_calico:-missing} Arch=${asset_arch:-missing}"
        exit 1
    fi

    if [ -f "${K8S_DIR}/SHA256SUMS" ]; then
        echo -e "${CYAN}[검증] 오프라인 자산 SHA-256 확인...${NC}"
        if find "$DEB_DIR" "$BIN_DIR" "$IMG_DIR" "$UTIL_DIR" -type l -print -quit | grep -q .; then
            echo -e "${RED}[오류] 오프라인 자산 디렉토리의 심볼릭 링크는 허용하지 않습니다.${NC}"
            exit 1
        fi
        if [ -L "$K8S_DIR/ASSET_VERSIONS.txt" ] || [ -L "$K8S_DIR/SHA256SUMS" ] ||
           grep -Ev '^[0-9a-f]{64}  (ASSET_VERSIONS\.txt|(debs|binaries|images|utils)/[^/]+)$' \
               "$K8S_DIR/SHA256SUMS" | grep -q .; then
            echo -e "${RED}[오류] SHA256SUMS에 허용되지 않은 경로가 있습니다.${NC}"
            exit 1
        fi
        (
            cd "$K8S_DIR"
            sha256sum -c SHA256SUMS
            while IFS= read -r asset; do
                grep -Fq "  ${asset}" SHA256SUMS || {
                    echo "[오류] SHA256SUMS에 없는 추가 자산: ${asset}" >&2
                    exit 1
                }
            done < <(
                find debs binaries images utils -type f ! -name '.gitkeep' -print | sort
            )
        )
    else
        echo -e "${RED}[오류] k8s/SHA256SUMS가 없습니다. 무결성이 검증되지 않은 자산은 설치하지 않습니다.${NC}"
        exit 1
    fi
}

choose_mode() {
    if [ -n "$MODE" ]; then
        case "$MODE" in
            init|join-worker|join-control-plane) return ;;
            *) echo -e "${RED}[오류] install.conf의 MODE가 올바르지 않습니다: ${MODE}${NC}"; exit 1 ;;
        esac
    fi

    echo "설치 역할을 선택하십시오."
    echo "  1) 첫 Control Plane 초기화"
    echo "  2) Worker 노드 Join"
    echo "  3) 추가 Control Plane Join"
    read -r -p "선택 [1-3]: " choice
    case "$choice" in
        1) MODE="init" ;;
        2) MODE="join-worker" ;;
        3) MODE="join-control-plane" ;;
        *)
            echo -e "${RED}[오류] 잘못된 선택입니다.${NC}"
            exit 1
            ;;
    esac
}

guard_existing_state() {
    if [ -f /etc/kubernetes/kubelet.conf ] ||
       [ -f /etc/kubernetes/admin.conf ] ||
       compgen -G '/etc/kubernetes/manifests/*.yaml' >/dev/null; then
        echo -e "${RED}[중단] 기존 또는 부분 구성된 Kubernetes 노드가 감지되었습니다.${NC}"
        echo "자동 덮어쓰기와 in-place 보안 전환은 지원하지 않습니다."
        echo "현재 상태는 scripts/security_audit.sh로 점검하고, 재구축이 승인된 경우에만"
        echo "scripts/uninstall.sh --reset으로 초기화한 후 다시 실행하십시오."
        exit 1
    fi
}

collect_common_settings() {
    local input=""
    if [ -z "$NODE_IP" ]; then
        local detected_ip
        detected_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        read -r -p "이 노드의 Kubernetes 통신 IP [${detected_ip}]: " NODE_IP
        NODE_IP="${NODE_IP:-$detected_ip}"
    fi
    validate_value "$NODE_IP" '^[0-9a-fA-F:.]+$' "노드 IP"
    if [ -z "$NODE_NETWORK_CIDR" ]; then
        read -r -p "노드 간 통신을 허용할 CIDR (예: 192.168.10.0/24): " NODE_NETWORK_CIDR
    fi
    validate_value "$NODE_NETWORK_CIDR" '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' "노드 네트워크 CIDR"

    if [ "$MODE" = "init" ]; then
        if [ -z "$CONTROL_PLANE_ENDPOINT" ]; then
            read -r -p "Control Plane endpoint [${NODE_IP}:6443]: " CONTROL_PLANE_ENDPOINT
            CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-${NODE_IP}:6443}"
        fi
        read -r -p "Pod CIDR [${POD_CIDR}]: " input
        POD_CIDR="${input:-$POD_CIDR}"
        read -r -p "Service CIDR [${SERVICE_CIDR}]: " input
        SERVICE_CIDR="${input:-$SERVICE_CIDR}"
        read -r -p "DNS domain [${DNS_DOMAIN}]: " input
        DNS_DOMAIN="${input:-$DNS_DOMAIN}"

        echo "Calico ${CALICO_VERSION} 설치 방식:"
        echo "  1) 자동 적용"
        echo "  2) kubeadm까지만 설치하고 CNI 수동 적용"
        read -r -p "선택 [1]: " input
        case "${input:-1}" in
            1) CNI_INSTALL_MODE="auto" ;;
            2) CNI_INSTALL_MODE="manual" ;;
            *) echo -e "${RED}[오류] 잘못된 CNI 선택입니다.${NC}"; exit 1 ;;
        esac

        echo ""
        echo -e "${YELLOW}[보안] admin.conf는 cluster-admin 인증정보입니다.${NC}"
        read -r -p "sudo 실행 사용자 홈에도 admin.conf를 복사할까요? [y/N]: " input
        if [[ "$input" =~ ^[Yy]$ ]]; then
            COPY_ADMIN_KUBECONFIG="true"
        else
            COPY_ADMIN_KUBECONFIG="false"
        fi
    elif [ -z "$CONTROL_PLANE_ENDPOINT" ]; then
        read -r -p "기존 Control Plane endpoint (예: 10.0.0.10:6443): " CONTROL_PLANE_ENDPOINT
    fi

    validate_value "$CONTROL_PLANE_ENDPOINT" '^[A-Za-z0-9._:-]+:[0-9]{1,5}$' "Control Plane endpoint"
    validate_value "$POD_CIDR" '^[0-9a-fA-F:.]+/[0-9]{1,3}$' "Pod CIDR"
    validate_value "$SERVICE_CIDR" '^[0-9a-fA-F:.]+/[0-9]{1,3}$' "Service CIDR"
    validate_value "$DNS_DOMAIN" '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$' "DNS domain"
    case "$CNI_INSTALL_MODE" in
        auto|manual) ;;
        *) echo -e "${RED}[오류] CNI_INSTALL_MODE 값이 올바르지 않습니다.${NC}"; exit 1 ;;
    esac
    case "$COPY_ADMIN_KUBECONFIG" in
        true|false) ;;
        *) echo -e "${RED}[오류] COPY_ADMIN_KUBECONFIG 값이 올바르지 않습니다.${NC}"; exit 1 ;;
    esac
}

confirm_plan() {
    echo ""
    echo "설치 계획"
    echo "  Kubernetes  : ${K8S_VERSION}"
    echo "  역할        : ${MODE}"
    echo "  노드 IP     : ${NODE_IP}"
    echo "  API endpoint: ${CONTROL_PLANE_ENDPOINT}"
    echo "  Trusted CIDR: ${NODE_NETWORK_CIDR}"
    if [ "$MODE" = "init" ]; then
        echo "  Pod CIDR    : ${POD_CIDR}"
        echo "  Service CIDR: ${SERVICE_CIDR}"
        echo "  CNI         : Calico ${CALICO_VERSION} (${CNI_INSTALL_MODE})"
        echo "  보안        : audit + encryption at rest + PSA + hardened kubelet"
    fi
    echo ""
    read -r -p "계속할까요? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || exit 0
}

install_packages() {
    echo -e "${CYAN}[1/8] 오프라인 DEB 및 도구 설치...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    dpkg -i "${DEB_DIR}"/*.deb || apt-get install -f -y --no-download
    local package version expected_version="${K8S_VERSION#v}-1.1"
    for package in kubelet kubeadm kubectl; do
        version=$(dpkg-query -W -f='${Version}' "$package")
        if [ "$version" != "$expected_version" ]; then
            echo -e "${RED}[오류] ${package} 버전 검증 실패: ${version}${NC}"
            exit 1
        fi
    done
    version=$(dpkg-query -W -f='${Version}' containerd.io)
    if [ "$version" != "$ASSET_CONTAINERD_VERSION" ]; then
        echo -e "${RED}[오류] containerd.io 버전 검증 실패: ${version}${NC}"
        exit 1
    fi
    apt-mark hold kubelet kubeadm kubectl >/dev/null

    local archive
    archive=$(find "$BIN_DIR" -maxdepth 1 -name 'helm-*-linux-amd64.tar.gz' | sort | tail -1)
    if [ -n "$archive" ]; then
        tar -xzf "$archive" -C /tmp
        install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
        rm -rf /tmp/linux-amd64
    fi
}

configure_host() {
    echo -e "${CYAN}[2/8] 커널, swap, containerd 보안 설정...${NC}"
    swapoff -a
    if grep -Eq '^[^#].+[[:space:]]swap[[:space:]]' /etc/fstab; then
        cp -a /etc/fstab "/etc/fstab.k8s-${K8S_VERSION}.bak"
        sed -Ei '/^[^#].+[[:space:]]swap[[:space:]]/s/^/# k8s-disabled: /' /etc/fstab
    fi

    cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
    modprobe overlay
    modprobe br_netfilter

    cat > /etc/sysctl.d/99-kubernetes-security.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
vm.overcommit_memory = 1
vm.panic_on_oom = 0
kernel.panic = 10
kernel.panic_on_oops = 1
kernel.keys.root_maxkeys = 1000000
kernel.keys.root_maxbytes = 25000000
EOF
    sysctl --system >/dev/null
    ufw allow from "$NODE_NETWORK_CIDR" comment 'k8s-node-network'
    ufw route allow from "$POD_CIDR" comment 'k8s-pod-network'
    ufw --force enable
    install -d -m 0700 /etc/kubernetes/installer
    cat > /etc/kubernetes/installer/ufw-rules <<EOF
ALLOW ${NODE_NETWORK_CIDR}
ROUTE ${POD_CIDR}
EOF
    chmod 600 /etc/kubernetes/installer/ufw-rules

    mkdir -p /etc/containerd
    if [ -s /etc/containerd/config.toml ]; then
        cp -a /etc/containerd/config.toml "/etc/containerd/config.toml.k8s-${K8S_VERSION}.bak"
    fi
    containerd config default > /etc/containerd/config.toml
    sed -Ei 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

    systemctl enable containerd
    systemctl restart containerd
    if ! crictl --runtime-endpoint "$CRI_SOCKET" info >/dev/null 2>&1; then
        echo -e "${RED}[오류] containerd CRI v1 응답을 확인하지 못했습니다.${NC}"
        exit 1
    fi
    systemctl enable kubelet
}

import_images() {
    echo -e "${CYAN}[3/8] 컨테이너 이미지 import...${NC}"
    local tar_file
    for tar_file in "${IMG_DIR}"/*.tar; do
        ctr -n k8s.io images import "$tar_file"
    done
}

prepare_security_assets() {
    if [ "$MODE" = "join-worker" ]; then
        echo -e "${CYAN}[4/8] Worker 노드는 Control Plane 보안 파일을 생성하지 않습니다.${NC}"
        return
    fi

    echo -e "${CYAN}[4/8] Control Plane 보안 정책 및 암호화 키 준비...${NC}"
    install -d -m 0700 "$SECURITY_RUNTIME_DIR" "$AUDIT_LOG_DIR"
    install -m 0600 "$SECURITY_SOURCE_DIR/audit-policy.yaml" \
        "$SECURITY_RUNTIME_DIR/audit-policy.yaml"
    install -m 0600 "$SECURITY_SOURCE_DIR/pod-security-admission-config.yaml" \
        "$SECURITY_RUNTIME_DIR/pod-security-admission-config.yaml"

    local encryption_file="${SECURITY_RUNTIME_DIR}/encryption-config.yaml"
    if [ "$MODE" = "init" ]; then
        if [ ! -f "$encryption_file" ]; then
            local encryption_key
            encryption_key=$(openssl rand -base64 32)
            umask 077
            cat > "$encryption_file" <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
      - configmaps
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${encryption_key}
      - identity: {}
EOF
        fi
    elif [ ! -f "$encryption_file" ]; then
        echo -e "${RED}[오류] 추가 Control Plane에는 기존 암호화 설정이 필요합니다.${NC}"
        echo "첫 Control Plane의 /etc/kubernetes/security/encryption-config.yaml을"
        echo "보안 매체로 같은 경로에 사전 반입하고 SHA-256을 대조한 후 다시 실행하십시오."
        exit 1
    fi

    chown root:root "$encryption_file"
    chmod 600 "$encryption_file"
}

generate_init_config() {
    local endpoint_host="${CONTROL_PLANE_ENDPOINT%:*}"
    umask 077
    cat > "$RUNTIME_CONFIG" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${NODE_IP}"
  bindPort: 6443
nodeRegistration:
  criSocket: "${CRI_SOCKET}"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "${K8S_VERSION}"
controlPlaneEndpoint: "${CONTROL_PLANE_ENDPOINT}"
imageRepository: "registry.k8s.io"
networking:
  dnsDomain: "${DNS_DOMAIN}"
  podSubnet: "${POD_CIDR}"
  serviceSubnet: "${SERVICE_CIDR}"
apiServer:
  certSANs:
    - "${NODE_IP}"
    - "${endpoint_host}"
  extraArgs:
    - name: anonymous-auth
      value: "false"
    - name: authorization-mode
      value: "Node,RBAC"
    - name: enable-admission-plugins
      value: "NodeRestriction"
    - name: service-account-lookup
      value: "true"
    - name: profiling
      value: "false"
    - name: tls-min-version
      value: "VersionTLS12"
    - name: tls-cipher-suites
      value: "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
    - name: audit-policy-file
      value: "/etc/kubernetes/security/audit-policy.yaml"
    - name: audit-log-path
      value: "/var/log/kubernetes/audit/audit.log"
    - name: audit-log-maxage
      value: "30"
    - name: audit-log-maxbackup
      value: "10"
    - name: audit-log-maxsize
      value: "100"
    - name: encryption-provider-config
      value: "/etc/kubernetes/security/encryption-config.yaml"
    - name: admission-control-config-file
      value: "/etc/kubernetes/security/pod-security-admission-config.yaml"
  extraVolumes:
    - name: kubernetes-security
      hostPath: "/etc/kubernetes/security"
      mountPath: "/etc/kubernetes/security"
      readOnly: true
      pathType: Directory
    - name: kubernetes-audit
      hostPath: "/var/log/kubernetes/audit"
      mountPath: "/var/log/kubernetes/audit"
      readOnly: false
      pathType: Directory
controllerManager:
  extraArgs:
    - name: bind-address
      value: "127.0.0.1"
    - name: profiling
      value: "false"
    - name: use-service-account-credentials
      value: "true"
scheduler:
  extraArgs:
    - name: bind-address
      value: "127.0.0.1"
    - name: profiling
      value: "false"
etcd:
  local:
    extraArgs:
      - name: auto-tls
        value: "false"
      - name: client-cert-auth
        value: "true"
      - name: peer-auto-tls
        value: "false"
      - name: peer-client-cert-auth
        value: "true"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
readOnlyPort: 0
protectKernelDefaults: true
rotateCertificates: true
serverTLSBootstrap: true
tlsMinVersion: VersionTLS12
tlsCipherSuites:
  - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
  - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
seccompDefault: true
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
metricsBindAddress: 127.0.0.1:10249
EOF
    chmod 600 "$RUNTIME_CONFIG"
}

initialize_cluster() {
    if [ -f /etc/kubernetes/admin.conf ] ||
       compgen -G '/etc/kubernetes/manifests/*.yaml' >/dev/null; then
        echo -e "${RED}[중단] 기존 Kubernetes Control Plane이 감지되었습니다.${NC}"
        echo "기존 클러스터에 이 보안 기준을 덮어쓰지 않습니다."
        echo "먼저 scripts/security_audit.sh로 현재 상태를 점검하거나 별도 마이그레이션 계획을 수립하십시오."
        exit 1
    fi

    generate_init_config
    echo -e "${CYAN}[5/8] kubeadm init (${K8S_VERSION})...${NC}"
    kubeadm init --config "$RUNTIME_CONFIG" --upload-certs

    install -d -m 0700 /root/.kube
    install -m 0600 /etc/kubernetes/admin.conf /root/.kube/config
    export KUBECONFIG=/etc/kubernetes/admin.conf

    if [ "$COPY_ADMIN_KUBECONFIG" = "true" ] &&
       [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        local user_home
        user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        install -d -m 0700 -o "$SUDO_USER" -g "$SUDO_USER" "${user_home}/.kube"
        install -m 0600 -o "$SUDO_USER" -g "$SUDO_USER" \
            /etc/kubernetes/admin.conf "${user_home}/.kube/config"
        printf '%s\n' "${user_home}/.kube/config" > "${SECURITY_RUNTIME_DIR}/copied-admin-kubeconfig"
        chmod 600 "${SECURITY_RUNTIME_DIR}/copied-admin-kubeconfig"
    fi
}

join_cluster() {
    if [ -f /etc/kubernetes/kubelet.conf ]; then
        echo -e "${RED}[중단] 이 노드는 이미 Kubernetes 클러스터에 가입되어 있습니다.${NC}"
        exit 1
    fi

    local token ca_hash certificate_key=""
    read -r -p "Bootstrap token: " token
    read -r -p "CA cert hash (sha256:...): " ca_hash
    validate_value "$token" '^[a-z0-9]{6}\.[a-z0-9]{16}$' "Bootstrap token"
    validate_value "$ca_hash" '^sha256:[a-f0-9]{64}$' "CA cert hash"

    local args=(
        "$CONTROL_PLANE_ENDPOINT"
        --token "$token"
        --discovery-token-ca-cert-hash "$ca_hash"
        --cri-socket "$CRI_SOCKET"
    )
    if [ "$MODE" = "join-control-plane" ]; then
        read -r -s -p "Certificate key: " certificate_key
        echo ""
        validate_value "$certificate_key" '^[a-f0-9]{64}$' "Certificate key"
        args+=(--control-plane --certificate-key "$certificate_key" --apiserver-advertise-address "$NODE_IP")
    fi

    echo -e "${CYAN}[5/8] kubeadm join...${NC}"
    kubeadm join "${args[@]}"
}

install_calico() {
    echo -e "${CYAN}[6/8] CNI 적용...${NC}"
    if [ "$MODE" != "init" ]; then
        echo "  → Join 노드는 Control Plane의 CNI를 사용합니다."
        return
    fi
    if [ "$CNI_INSTALL_MODE" = "manual" ]; then
        echo -e "${YELLOW}  → CNI 자동 적용을 생략했습니다. 노드 Ready 전에 Calico를 적용하십시오.${NC}"
        return
    fi

    sed "s#192\\.168\\.0\\.0/16#${POD_CIDR}#g" "$UTIL_DIR/calico.yaml" | kubectl apply -f -
    kubectl rollout status daemonset/calico-node -n kube-system --timeout=5m
}

apply_psa_labels() {
    if [ "$MODE" != "init" ]; then
        return
    fi
    echo -e "${CYAN}[7/8] 기본 Namespace Pod Security 레이블 적용...${NC}"
    kubectl label namespace default \
        pod-security.kubernetes.io/enforce=baseline \
        pod-security.kubernetes.io/enforce-version=latest \
        pod-security.kubernetes.io/audit=restricted \
        pod-security.kubernetes.io/audit-version=latest \
        pod-security.kubernetes.io/warn=restricted \
        pod-security.kubernetes.io/warn-version=latest \
        --overwrite
}

run_security_audit() {
    echo -e "${CYAN}[8/8] 설치 후 보안 기준 점검...${NC}"
    if ! bash "${BASE_DIR}/scripts/security_audit.sh"; then
        echo -e "${RED}[오류] 보안 기준 점검에서 FAIL이 발견되었습니다.${NC}"
        return 1
    fi
}

print_next_steps() {
    echo ""
    echo -e "${GREEN}Kubernetes ${K8S_VERSION} 설치가 완료되었습니다.${NC}"
    if [ "$MODE" = "init" ]; then
        echo "Join 전 첫 Control Plane에서 가입 창 열기:"
        echo "  sudo ./scripts/join_window.sh open"
        echo "Worker join 명령 생성:"
        echo "  sudo kubeadm token create --print-join-command"
        echo "추가 Control Plane용 인증서 키 생성:"
        echo "  sudo kubeadm init phase upload-certs --upload-certs"
        echo ""
        echo "추가 Control Plane에는 암호화 설정을 같은 경로로 복사:"
        echo "  /etc/kubernetes/security/encryption-config.yaml"
        echo "모든 Join 완료 후 첫 Control Plane에서 가입 창 닫기:"
        echo "  sudo ./scripts/join_window.sh close"
        echo -e "${YELLOW}kubelet serving CSR은 자동 승인하지 않습니다.${NC}"
        echo "요청자와 SAN을 검증한 뒤 개별 승인하십시오:"
        echo "  sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get csr"
        echo "  sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl certificate approve <csr-name>"
    fi
    echo "재점검:"
    echo "  sudo ./scripts/security_audit.sh"
}

main() {
    require_root
    verify_host
    load_conf
    choose_mode
    guard_existing_state
    collect_common_settings
    confirm_plan
    verify_assets
    save_conf
    install_packages
    configure_host
    import_images
    prepare_security_assets

    case "$MODE" in
        init) initialize_cluster ;;
        join-worker|join-control-plane) join_cluster ;;
        *) echo -e "${RED}[오류] 지원하지 않는 MODE: ${MODE}${NC}"; exit 1 ;;
    esac

    install_calico
    apply_psa_labels
    run_security_audit
    print_next_steps
}

main "$@"
