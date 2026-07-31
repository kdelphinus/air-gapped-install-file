#!/usr/bin/env bash

set -Eeuo pipefail

cd "$(dirname "$0")/.." || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CONF_FILE="/etc/kubernetes/installer/install.conf"
FIREWALL_MARKER="/etc/kubernetes/installer/firewalld-sources"
RESET=false
PURGE_PACKAGES=false

for arg in "$@"; do
    case "$arg" in
        --reset|reset) RESET=true ;;
        --purge-packages) PURGE_PACKAGES=true ;;
        -h|--help)
            echo "사용법: sudo ./scripts/uninstall.sh --reset [--purge-packages]"
            exit 0
            ;;
        *)
            echo -e "${RED}[오류] 알 수 없는 옵션: ${arg}${NC}"
            exit 1
            ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[오류] sudo로 실행해야 합니다.${NC}"
    exit 1
fi

if [ "$RESET" != "true" ]; then
    echo -e "${YELLOW}Kubernetes에는 데이터 보존형 일반 uninstall이 없습니다.${NC}"
    echo "클러스터와 etcd 데이터를 제거하려면 --reset을 명시하십시오."
    echo "현재 상태 점검: sudo ./scripts/security_audit.sh"
    exit 0
fi

echo -e "${RED}[위험] 이 노드의 Kubernetes 상태를 완전히 초기화합니다.${NC}"
echo "  - kubeadm reset"
echo "  - /etc/kubernetes 및 런타임 암호화 키 삭제"
echo "  - /var/lib/etcd, /var/lib/kubelet, CNI 상태 삭제"
echo "  - 설치기가 추가한 firewalld trusted source와 NetworkManager 설정 삭제"
echo "  - 이 노드가 단일 Control Plane이면 클러스터 복구가 불가능할 수 있음"
echo "  - containerd 이미지와 호스트 방화벽 서비스는 보존"
[ "$PURGE_PACKAGES" = "true" ] && echo "  - kubeadm/kubelet/kubectl/containerd RPM도 제거"
echo ""
read -r -p "첫 번째 확인: 계속할까요? [y/N]: " answer
[[ "$answer" =~ ^[Yy]$ ]] || exit 0
read -r -p "두 번째 확인: RESET을 입력하십시오: " answer
[ "$answer" = "RESET" ] || { echo "취소합니다."; exit 0; }

copied_admin=""
marker="/etc/kubernetes/security/copied-admin-kubeconfig"
if [ -f "$marker" ]; then
    copied_admin=$(head -n 1 "$marker")
fi

firewall_sources=()
if [ -f "$FIREWALL_MARKER" ]; then
    mapfile -t firewall_sources < "$FIREWALL_MARKER"
fi

echo -e "${CYAN}[1/6] kubeadm reset...${NC}"
if command -v kubeadm >/dev/null 2>&1; then
    kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock
fi

systemctl stop kubelet 2>/dev/null || true

if command -v ip >/dev/null 2>&1; then
    for iface in cni0 flannel.1 cilium_host cilium_net cilium_vxlan vxlan.calico tunl0; do
        if ip link show "$iface" >/dev/null 2>&1; then
            ip link delete "$iface" 2>/dev/null || true
        fi
    done
fi

echo -e "${CYAN}[2/6] 설치기가 추가한 네트워크 설정 삭제...${NC}"
if command -v firewall-cmd >/dev/null 2>&1; then
    for source_cidr in "${firewall_sources[@]}"; do
        [ -n "$source_cidr" ] || continue
        firewall-cmd --permanent --zone=trusted --remove-source="$source_cidr" \
            >/dev/null 2>&1 || true
    done
    firewall-cmd --reload >/dev/null 2>&1 || true
fi
rm -f /etc/NetworkManager/conf.d/99-calico.conf
restorecon -F /etc/NetworkManager/conf.d >/dev/null 2>&1 || true
nmcli general reload >/dev/null 2>&1 || true

echo -e "${CYAN}[3/6] Kubernetes 및 CNI 상태 삭제...${NC}"
rm -rf /etc/cni/net.d
rm -rf /var/lib/cni
rm -rf /var/lib/kubelet
rm -rf /var/lib/etcd
rm -rf /etc/kubernetes
rm -rf /var/log/kubernetes/audit
rm -f /etc/modules-load.d/k8s.conf
rm -f /etc/sysctl.d/99-kubernetes-security.conf
sysctl --system >/dev/null 2>&1 || true

if command -v semanage >/dev/null 2>&1; then
    selinux_paths=(
        '/etc/kubernetes(/.*)?'
        '/var/lib/etcd(/.*)?'
        '/var/log/kubernetes(/.*)?'
    )
    for selinux_path in "${selinux_paths[@]}"; do
        semanage fcontext -d "$selinux_path" >/dev/null 2>&1 || true
    done
fi

if [ -n "$copied_admin" ] &&
   [[ "$copied_admin" =~ ^/(home/[^/]+|root)/\.kube/config$ ]]; then
    rm -f -- "$copied_admin"
fi
rm -f /root/.kube/config
rmdir /root/.kube 2>/dev/null || true

echo -e "${CYAN}[4/6] install.conf 삭제...${NC}"
rm -f "$CONF_FILE"

echo -e "${CYAN}[5/6] containerd 재시작...${NC}"
if systemctl list-unit-files containerd.service >/dev/null 2>&1; then
    systemctl restart containerd 2>/dev/null || true
fi

if [ "$PURGE_PACKAGES" = "true" ]; then
    echo -e "${CYAN}[6/6] Kubernetes RPM 제거...${NC}"
    if dnf versionlock --help >/dev/null 2>&1; then
        dnf versionlock delete kubelet kubeadm kubectl containerd.io \
            >/dev/null 2>&1 || true
    fi
    dnf remove -y kubeadm kubelet kubectl cri-tools containerd.io
else
    echo -e "${CYAN}[6/6] RPM 보존${NC}"
fi

echo -e "${GREEN}초기화가 완료되었습니다.${NC}"
echo "SELinux Enforcing과 firewalld 서비스는 보안 기준에 따라 유지했습니다."
echo "다른 서비스 보호를 위해 호스트 방화벽/iptables 전체 flush는 수행하지 않았습니다."
