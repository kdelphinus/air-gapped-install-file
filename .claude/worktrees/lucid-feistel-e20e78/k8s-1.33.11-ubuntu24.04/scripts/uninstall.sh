#!/bin/bash

# ==========================================
# k8s-1.33.11-ubuntu24.04 언인스톨 스크립트
#   - kubeadm reset + CNI 잔재 + iptables/ipvs 정리
#
# 사용법:
#   sudo ./scripts/uninstall.sh          # 대화형 확인
#   sudo ./scripts/uninstall.sh --yes    # 확인 생략 (install.sh 재설치 경로에서 호출)
#   sudo ./scripts/uninstall.sh --purge  # 추가로 DEB 패키지까지 제거
# ==========================================

cd "$(dirname "$0")/.." || exit 1

if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

BASE_DIR="$(pwd)"
CONF_FILE="${BASE_DIR}/install.conf"

AUTO_YES=0
PURGE=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y) AUTO_YES=1 ;;
        --purge)  PURGE=1 ;;
    esac
done

# ── 확인 ────────────────────────────────────────────────────
if [ "$AUTO_YES" -ne 1 ]; then
    echo -e "${YELLOW}[주의] Kubernetes 클러스터와 CNI/containerd 설정을 삭제합니다.${NC}"
    echo "  - kubeadm reset -f"
    echo "  - /etc/cni /var/lib/cni /var/lib/kubelet /var/lib/etcd 삭제"
    echo "  - iptables/ipvs 플러시"
    echo "  - CNI 인터페이스 제거 (cni0, flannel.1, cilium_*)"
    [ "$PURGE" -eq 1 ] && echo -e "${RED}  - DEB 패키지 제거 (--purge)${NC}"
    echo ""
    read -p "계속할까요? [y/N]: " _C
    [[ ! "$_C" =~ ^[Yy]$ ]] && { echo "취소합니다."; exit 0; }
fi

# ── [1] kubeadm reset ───────────────────────────────────────
echo ""
echo -e "${CYAN}[1/7] kubeadm reset...${NC}"
if command -v kubeadm >/dev/null 2>&1; then
    kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock 2>/dev/null || true
else
    echo "  → kubeadm 미존재 (skip)"
fi

# ── [2] kubelet/containerd 중지 ─────────────────────────────
echo ""
echo -e "${CYAN}[2/7] kubelet / containerd 중지...${NC}"
systemctl stop kubelet 2>/dev/null || true
systemctl disable kubelet 2>/dev/null || true

# ── [3] iptables / ipvs 플러시 ──────────────────────────────
echo ""
echo -e "${CYAN}[3/7] iptables / ipvs 플러시...${NC}"
iptables -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -X 2>/dev/null || true

ip6tables -F 2>/dev/null || true
ip6tables -t nat -F 2>/dev/null || true
ip6tables -t mangle -F 2>/dev/null || true
ip6tables -X 2>/dev/null || true

if command -v ipvsadm >/dev/null 2>&1; then
    ipvsadm --clear 2>/dev/null || true
fi

# ── [4] CNI 인터페이스 제거 ─────────────────────────────────
echo ""
echo -e "${CYAN}[4/7] CNI 인터페이스 제거...${NC}"
for iface in cni0 flannel.1 cilium_host cilium_net cilium_vxlan vxlan.calico; do
    if ip link show "$iface" >/dev/null 2>&1; then
        ip link del "$iface" 2>/dev/null && echo "  → $iface 제거" || true
    fi
done

# ── [5] 설정/데이터 디렉토리 삭제 ───────────────────────────
echo ""
echo -e "${CYAN}[5/7] 설정 및 데이터 디렉토리 삭제...${NC}"
rm -rf /etc/cni/net.d
rm -rf /var/lib/cni
rm -rf /var/lib/kubelet
rm -rf /var/lib/etcd
rm -rf /etc/kubernetes
rm -rf /root/.kube

# sudo 사용자의 kubeconfig도 정리
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    SUDO_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    rm -rf "$SUDO_HOME/.kube"
fi

# Cilium 호스트 잔재
rm -rf /var/run/cilium /var/lib/cilium 2>/dev/null || true

# ── [6] containerd 재시작 (config 복원) ─────────────────────
echo ""
echo -e "${CYAN}[6/7] containerd 재시작...${NC}"
if systemctl list-unit-files | grep -q containerd.service; then
    systemctl restart containerd 2>/dev/null || true
fi

# ── [7] install.conf 삭제 + (옵션) DEB 퍼지 ─────────────────
echo ""
echo -e "${CYAN}[7/7] install.conf 정리...${NC}"
[ -f "$CONF_FILE" ] && rm -f "$CONF_FILE" && echo "  → $CONF_FILE 삭제"

if [ "$PURGE" -eq 1 ]; then
    echo ""
    echo -e "${CYAN}[추가] DEB 패키지 제거...${NC}"
    apt-get remove -y --purge \
        kubeadm kubelet kubectl cri-tools containerd.io \
        2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
fi

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} ✅ 언인스톨 완료${NC}"
echo -e "${GREEN}============================================================${NC}"
if [ "$PURGE" -eq 0 ]; then
    echo " DEB 패키지는 유지되었습니다. 완전 제거하려면 --purge 옵션 사용."
fi
