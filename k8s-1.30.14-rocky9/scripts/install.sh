#!/usr/bin/env bash

set -Eeuo pipefail

cd "$(dirname "$0")/.." || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

K8S_VERSION="v1.30.14"
CALICO_VERSION="v3.29.7"
CRI_SOCKET="unix:///run/containerd/containerd.sock"
ASSET_CONTAINERD_VERSION=""

BASE_DIR="$(pwd)"
K8S_DIR="${BASE_DIR}/k8s"
RPM_DIR="${K8S_DIR}/rpms"
BIN_DIR="${K8S_DIR}/binaries"
IMG_DIR="${K8S_DIR}/images"
UTIL_DIR="${K8S_DIR}/utils"
KEY_DIR="${K8S_DIR}/keys"
SECURITY_SOURCE_DIR="${BASE_DIR}/security"
SECURITY_RUNTIME_DIR="/etc/kubernetes/security"
AUDIT_LOG_DIR="/var/log/kubernetes/audit"
CONF_FILE="/etc/kubernetes/installer/install.conf"
RUNTIME_CONFIG="/run/kubeadm-v1.30.14.yaml"

MODE="${MODE:-}"
NODE_IP="${NODE_IP:-}"
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-}"
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
DNS_DOMAIN="${DNS_DOMAIN:-cluster.local}"
CNI_INSTALL_MODE="${CNI_INSTALL_MODE:-auto}"
COPY_ADMIN_KUBECONFIG="${COPY_ADMIN_KUBECONFIG:-false}"
NODE_NETWORK_CIDR="${NODE_NETWORK_CIDR:-}"
require_eol_acknowledgement() {
    if [ "${ALLOW_EOL_INSTALL:-}" != "YES" ]; then
        echo -e "${RED}[중단] Kubernetes ${K8S_VERSION}은 업스트림 지원 종료 버전입니다.${NC}"
        echo "신규 운영 환경에는 k8s-1.36.3 패키지를 사용하십시오."
        echo "불가피한 호환성 설치라면 위험을 승인한 뒤 ALLOW_EOL_INSTALL=YES를 명시하십시오."
        exit 1
    fi
}

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
    temp_conf=$(mktemp "$(dirname "$CONF_FILE")/.install.conf.XXXXXX")
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
    if [ "$os_id" != "rocky" ] || [[ "$os_version" != 9.* ]]; then
        echo -e "${RED}[오류] 이 패키지는 Rocky Linux 9 계열 전용입니다. 감지값: ${os_id} ${os_version}${NC}"
        exit 1
    fi

    if [ "$(uname -m)" != "x86_64" ]; then
        echo -e "${RED}[오류] 현재 패키지는 amd64(x86_64)만 지원합니다.${NC}"
        exit 1
    fi

    if ! command -v getenforce >/dev/null 2>&1; then
        echo -e "${RED}[오류] SELinux 도구가 없습니다.${NC}"
        exit 1
    fi
    if [ "$(getenforce)" = "Disabled" ]; then
        echo -e "${RED}[오류] SELinux가 Disabled 상태입니다.${NC}"
        echo "이 패키지는 SELinux Enforcing을 보안 기준으로 사용합니다."
        echo "/etc/selinux/config를 SELINUX=enforcing으로 바꾸고 재부팅한 후 다시 실행하십시오."
        exit 1
    fi
}

verify_assets() {
    local missing=0
    local required_paths=(
        "$SECURITY_SOURCE_DIR/audit-policy.yaml"
        "$SECURITY_SOURCE_DIR/pod-security-admission-config.yaml"
        "$UTIL_DIR/calico.yaml"
        "$KEY_DIR/kubernetes-rpm-signing-key.asc"
        "$KEY_DIR/docker-rpm-signing-key.asc"
        "$K8S_DIR/ASSET_VERSIONS.txt"
    )
    local path

    if ! compgen -G "${RPM_DIR}/*.rpm" >/dev/null; then
        echo -e "${RED}[누락] ${RPM_DIR}/*.rpm${NC}"
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
        echo "인터넷 연결이 가능한 최신 Rocky Linux 9 호스트에서"
        echo "scripts/download_assets_offline.sh를 먼저 실행하십시오."
        exit 1
    fi

    local host_minor asset_os asset_minor asset_kubernetes asset_calico asset_arch
    host_minor=$(awk -F= '$1 == "VERSION_ID" {gsub(/"/, "", $2); print $2}' /etc/os-release)
    asset_os=$(awk -F= '$1 == "OS" {print $2}' "$K8S_DIR/ASSET_VERSIONS.txt")
    asset_kubernetes=$(awk -F= '$1 == "KUBERNETES" {print $2}' "$K8S_DIR/ASSET_VERSIONS.txt")
    ASSET_CONTAINERD_VERSION=$(awk -F= '$1 == "CONTAINERD" {print $2}' "$K8S_DIR/ASSET_VERSIONS.txt")
    asset_calico=$(awk -F= '$1 == "CALICO" {print $2}' "$K8S_DIR/ASSET_VERSIONS.txt")
    asset_arch=$(awk -F= '$1 == "ARCH" {print $2}' "$K8S_DIR/ASSET_VERSIONS.txt")
    asset_minor="${asset_os#rocky-}"
    if [ -z "$ASSET_CONTAINERD_VERSION" ] ||
       [ "$asset_kubernetes" != "$K8S_VERSION" ] ||
       [ "$asset_calico" != "$CALICO_VERSION" ] ||
       [ "$asset_arch" != "amd64" ]; then
        echo -e "${RED}[오류] 오프라인 자산 버전 정보가 패키지 기준과 다릅니다.${NC}"
        echo "  Kubernetes: ${asset_kubernetes:-missing}"
        echo "  containerd: ${ASSET_CONTAINERD_VERSION:-missing}"
        echo "  Calico   : ${asset_calico:-missing}"
        echo "  Arch     : ${asset_arch:-missing}"
        exit 1
    fi
    if [[ ! "$asset_os" =~ ^rocky-9\.[0-9]+$ ]]; then
        echo -e "${RED}[오류] ASSET_VERSIONS.txt의 OS 값이 올바르지 않습니다: ${asset_os}${NC}"
        exit 1
    fi
    if [ "$host_minor" != "$asset_minor" ]; then
        echo -e "${RED}[오류] 오프라인 RPM 수집 마이너와 대상 노드가 다릅니다.${NC}"
        echo "  자산 수집 기준: Rocky Linux ${asset_minor}"
        echo "  대상 노드     : Rocky Linux ${host_minor}"
        echo "대상 노드를 동일한 Rocky 9 마이너로 오프라인 업데이트한 후 다시 실행하십시오."
        exit 1
    fi

    if [ -f "${K8S_DIR}/SHA256SUMS" ]; then
        echo -e "${CYAN}[검증] 오프라인 자산 SHA-256 확인...${NC}"
        if find "$RPM_DIR" "$BIN_DIR" "$IMG_DIR" "$UTIL_DIR" "$KEY_DIR" \
            -type l -print -quit | grep -q . ||
           [ -L "$K8S_DIR/ASSET_VERSIONS.txt" ] ||
           [ -L "$K8S_DIR/SHA256SUMS" ]; then
            echo -e "${RED}[오류] 오프라인 자산의 심볼릭 링크는 허용하지 않습니다.${NC}"
            exit 1
        fi
        if grep -Ev '^[0-9a-f]{64}  (ASSET_VERSIONS\.txt|(rpms|binaries|images|utils|keys)/[^/]+)$' \
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
                find rpms binaries images utils keys -type f ! -name '.gitkeep' -print | sort
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
       [ -d /etc/kubernetes/manifests ]; then
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
        read -r -p "노드 간 통신을 허용할 trusted CIDR (예: 192.168.10.0/24): " NODE_NETWORK_CIDR
    fi
    validate_value "$NODE_NETWORK_CIDR" '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' "노드 네트워크 CIDR"

    if [ "$MODE" != "init" ]; then
        read -r -p "클러스터 Pod CIDR [${POD_CIDR}]: " input
        POD_CIDR="${input:-$POD_CIDR}"
    fi

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
    echo -e "${CYAN}[1/8] 오프라인 RPM 및 도구 설치...${NC}"
    rpm --import "$KEY_DIR/kubernetes-rpm-signing-key.asc"
    rpm --import "$KEY_DIR/docker-rpm-signing-key.asc"

    local rpm_file
    for rpm_file in "${RPM_DIR}"/*.rpm; do
        rpm --checksig "$rpm_file"
    done

    dnf install -y --disablerepo='*' "${RPM_DIR}"/*.rpm

    local package version
    for package in kubelet kubeadm kubectl; do
        version=$(rpm -q --qf '%{VERSION}' "$package")
        if [[ "$version" != 1.30.14* ]]; then
            echo -e "${RED}[오류] ${package} 버전 검증 실패: ${version}${NC}"
            exit 1
        fi
    done
    version=$(rpm -q --qf '%{EPOCHNUM}:%{VERSION}-%{RELEASE}' containerd.io)
    if [ "$version" != "$ASSET_CONTAINERD_VERSION" ]; then
        echo -e "${RED}[??] containerd.io ?? ?? ??: ${version}${NC}"
        exit 1
    fi

    if ! dnf versionlock --help >/dev/null 2>&1; then
        echo -e "${RED}[오류] dnf versionlock 플러그인이 설치되지 않았습니다.${NC}"
        exit 1
    fi
    dnf versionlock add kubelet kubeadm kubectl containerd.io >/dev/null

    local archive
    archive=$(find "$BIN_DIR" -maxdepth 1 -name 'helm-*-linux-amd64.tar.gz' | sort | tail -1)
    if [ -n "$archive" ]; then
        tar -xzf "$archive" -C /tmp
        install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
        rm -rf /tmp/linux-amd64
    fi
}

configure_host() {
    echo -e "${CYAN}[2/8] SELinux, firewalld, 커널, containerd 보안 설정...${NC}"

    if [ "$(getenforce)" = "Permissive" ]; then
        setenforce 1
    fi
    sed -Ei 's/^SELINUX=(disabled|permissive)$/SELINUX=enforcing/' /etc/selinux/config
    if [ "$(getenforce)" != "Enforcing" ]; then
        echo -e "${RED}[오류] SELinux Enforcing 전환에 실패했습니다.${NC}"
        exit 1
    fi

    swapoff -a
    if grep -Eq '^[^#].+[[:space:]]swap[[:space:]]' /etc/fstab; then
        cp -a /etc/fstab "/etc/fstab.k8s-${K8S_VERSION}.bak"
        sed -Ei '/^[^#].+[[:space:]]swap[[:space:]]/s/^/# k8s-disabled: /' /etc/fstab
    fi
    while IFS= read -r swap_unit; do
        [ -n "$swap_unit" ] && systemctl mask "$swap_unit" >/dev/null
    done < <(systemctl list-unit-files --type=swap --no-legend | awk '{print $1}')

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

    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/99-calico.conf <<'EOF'
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:tunl*;interface-name:vxlan.calico
EOF
    restorecon -F /etc/NetworkManager/conf.d/99-calico.conf
    nmcli general reload >/dev/null 2>&1 || true

    systemctl enable --now firewalld
    for source_cidr in "$NODE_NETWORK_CIDR" "$POD_CIDR"; do
        if ! firewall-cmd --permanent --zone=trusted --query-source="$source_cidr" >/dev/null; then
            firewall-cmd --permanent --zone=trusted --add-source="$source_cidr"
        fi
    done
    firewall-cmd --reload

    install -d -m 0700 /etc/kubernetes/installer
    cat > /etc/kubernetes/installer/firewalld-sources <<EOF
${NODE_NETWORK_CIDR}
${POD_CIDR}
EOF
    chmod 600 /etc/kubernetes/installer/firewalld-sources

    mkdir -p /etc/containerd
    if [ ! -s /etc/containerd/config.toml ]; then
        containerd config default > /etc/containerd/config.toml
    else
        cp -a /etc/containerd/config.toml "/etc/containerd/config.toml.k8s-${K8S_VERSION}.bak"
    fi
    sed -Ei 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    sed -Ei 's/enable_selinux = false/enable_selinux = true/' /etc/containerd/config.toml
    if ! grep -Eq '^[[:space:]]*SystemdCgroup[[:space:]]*=[[:space:]]*true' \
        /etc/containerd/config.toml ||
       ! grep -Eq '^[[:space:]]*enable_selinux[[:space:]]*=[[:space:]]*true' \
        /etc/containerd/config.toml; then
        echo -e "${RED}[오류] containerd 보안 설정 반영에 실패했습니다.${NC}"
        exit 1
    fi
    restorecon -RF /etc/containerd

    systemctl enable --now containerd
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
    sed \
        -e "s|__NODE_IP__|${NODE_IP}|g" \
        -e "s|__CONTROL_PLANE_ENDPOINT__|${CONTROL_PLANE_ENDPOINT}|g" \
        -e "s|__ENDPOINT_HOST__|${endpoint_host}|g" \
        -e "s|__DNS_DOMAIN__|${DNS_DOMAIN}|g" \
        -e "s|__POD_CIDR__|${POD_CIDR}|g" \
        -e "s|__SERVICE_CIDR__|${SERVICE_CIDR}|g" \
        "${SECURITY_SOURCE_DIR}/kubeadm-config.example.yaml" > "$RUNTIME_CONFIG"
    chmod 600 "$RUNTIME_CONFIG"
}

initialize_cluster() {
    if [ -f /etc/kubernetes/admin.conf ] || [ -d /etc/kubernetes/manifests ]; then
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
        echo "Worker join 명령 생성:"
        echo "  sudo kubeadm token create --print-join-command"
        echo "추가 Control Plane용 인증서 키 생성:"
        echo "  sudo kubeadm init phase upload-certs --upload-certs"
        echo ""
        echo -e "${YELLOW}kubelet serving CSR은 자동 승인하지 않습니다.${NC}"
        echo "요청자와 SAN을 검증한 뒤 개별 승인하십시오:"
        echo "  sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get csr"
        echo "  sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl certificate approve <csr-name>"
    fi
    echo "재점검:"
    echo "  sudo ./scripts/security_audit.sh"
}

main() {
    require_eol_acknowledgement
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
