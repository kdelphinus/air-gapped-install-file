#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

if [ "$EUID" -ne 0 ]; then
    echo "[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다."
    exit 1
fi

AUTO_YES=0
PURGE=0
TARGET_OS="ubuntu24.04"
[ -f install.conf ] && source install.conf
for arg in "$@"; do
    case "$arg" in
        --yes|-y) AUTO_YES=1 ;;
        --purge) PURGE=1 ;;
    esac
done

if [ "$AUTO_YES" -ne 1 ]; then
    echo "[주의] Kubernetes 클러스터와 CNI/containerd 설정을 삭제합니다."
    [ "$PURGE" -eq 1 ] && echo "[주의] --purge 옵션으로 DEB 패키지도 제거합니다."
    read -p "계속할까요? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "취소합니다."; exit 0; }
fi

echo "[1/7] kubeadm reset..."
if command -v kubeadm >/dev/null 2>&1; then
    kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock 2>/dev/null || true
fi

echo "[2/7] kubelet/containerd 중지..."
systemctl stop kubelet 2>/dev/null || true
systemctl disable kubelet 2>/dev/null || true

echo "[3/7] iptables/ipvs 정리..."
iptables -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -X 2>/dev/null || true
ip6tables -F 2>/dev/null || true
ip6tables -t nat -F 2>/dev/null || true
ip6tables -t mangle -F 2>/dev/null || true
ip6tables -X 2>/dev/null || true
command -v ipvsadm >/dev/null 2>&1 && ipvsadm --clear 2>/dev/null || true

echo "[4/7] CNI 인터페이스 제거..."
for iface in cni0 flannel.1 cilium_host cilium_net cilium_vxlan vxlan.calico; do
    if ip link show "$iface" >/dev/null 2>&1; then
        ip link del "$iface" 2>/dev/null || true
    fi
done

echo "[5/7] 설정 및 데이터 디렉터리 삭제..."
rm -rf /etc/cni/net.d /var/lib/cni /var/lib/kubelet /var/lib/etcd /etc/kubernetes /root/.kube
rm -rf /var/run/cilium /var/lib/cilium 2>/dev/null || true

if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    SUDO_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    rm -rf "$SUDO_HOME/.kube"
fi

echo "[6/7] containerd 재시작..."
if systemctl list-unit-files 2>/dev/null | grep -q containerd.service; then
    systemctl restart containerd 2>/dev/null || true
fi

echo "[7/7] install.conf 보존..."
echo "번들 재사용을 위해 install.conf 파일은 삭제하지 않습니다."

if [ "$PURGE" -eq 1 ]; then
    case "$TARGET_OS" in
        ubuntu24.04)
            apt-get remove -y --purge kubeadm kubelet kubectl cri-tools containerd.io 2>/dev/null || true
            apt-get autoremove -y 2>/dev/null || true
            ;;
        rocky9.6)
            dnf remove -y kubeadm kubelet kubectl cri-tools containerd.io 2>/dev/null || true
            dnf autoremove -y 2>/dev/null || true
            ;;
    esac
fi

echo "언인스톨 완료"
