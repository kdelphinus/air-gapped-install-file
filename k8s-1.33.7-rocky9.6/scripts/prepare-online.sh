#!/bin/bash

# ==========================================
# k8s-1.33.7-rocky9.6 온라인 사전 준비 스크립트 (Phase 1~3)
#   - Phase 1: 저장소 등록 및 패키지 설치
#   - Phase 2: OS 사전 설정 (SELinux/방화벽/커널/swap)
#   - Phase 3: containerd 설정 및 kubelet 기동
#   - WSL 분기는 포함하지 않음 (VM / 베어메탈 전용)
#
# 사용법:
#   sudo ./scripts/prepare-online.sh
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

K8S_MINOR="v1.33"
K8S_PATCH="1.33.7"
CONTAINERD_LINE="2.1.*"

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} Kubernetes ${K8S_PATCH} 온라인 사전 준비 (Phase 1~3)${NC}"
echo -e "${CYAN} 대상 OS : Rocky Linux 9.6${NC}"
echo -e "${CYAN}============================================================${NC}"

# OS 확인 (Rocky/RHEL 9 계열 한정)
if [ -r /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        rocky|rhel|almalinux|centos) ;;
        *)
            echo -e "${YELLOW}[경고] Rocky/RHEL 계열이 아닙니다 (ID=${ID}). 계속 진행할까요?${NC}"
            read -p "[y/N]: " _CONT
            [[ ! "$_CONT" =~ ^[Yy]$ ]] && exit 1
            ;;
    esac
fi

# 인터넷 연결 확인
if ! curl -fsSL --max-time 5 https://download.docker.com >/dev/null 2>&1; then
    echo -e "${RED}[오류] 인터넷 연결을 확인할 수 없습니다. 본 스크립트는 온라인 환경 전용입니다.${NC}"
    exit 1
fi

# ============================================================
# Phase 1: 저장소 등록 및 패키지 설치
# ============================================================
echo ""
echo -e "${CYAN}[Phase 1] 저장소 등록 및 패키지 설치...${NC}"

echo -e "  → EPEL 등록"
dnf install -y epel-release

echo -e "  → 시스템 업데이트 및 선행 패키지 설치"
dnf update -y
dnf install -y socat conntrack-tools iproute-tc libseccomp curl tar jq chrony yum-utils

echo -e "  → Docker CE 저장소 등록 (containerd.io 획득용)"
if [ ! -f /etc/yum.repos.d/docker-ce.repo ]; then
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
fi

echo -e "  → Kubernetes ${K8S_MINOR} 저장소 등록"
cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

echo -e "  → containerd.io ${CONTAINERD_LINE} 설치"
dnf install -y "containerd.io-${CONTAINERD_LINE}"

echo -e "  → kubelet/kubeadm/kubectl ${K8S_PATCH} 설치"
dnf install -y --disableexcludes=kubernetes \
    "kubelet-${K8S_PATCH}-*" "kubeadm-${K8S_PATCH}-*" "kubectl-${K8S_PATCH}-*"

# ============================================================
# Phase 2: OS 사전 설정
# ============================================================
echo ""
echo -e "${CYAN}[Phase 2] OS 사전 설정...${NC}"

echo -e "  → SELinux Permissive"
setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

echo -e "  → 방화벽 비활성화"
systemctl stop firewalld 2>/dev/null || true
systemctl disable firewalld 2>/dev/null || true

echo -e "  → 커널 모듈 로드 (overlay, br_netfilter)"
modprobe overlay
modprobe br_netfilter
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

echo -e "  → 커널 파라미터 (브릿지/포워딩)"
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

echo -e "  → swap 비활성화"
swapoff -a
sed -i '/\sswap\s/s/^/#/' /etc/fstab

# ============================================================
# Phase 3: containerd 설정 및 kubelet 기동
# ============================================================
echo ""
echo -e "${CYAN}[Phase 3] containerd 설정 및 kubelet 기동...${NC}"

mkdir -p /etc/containerd
echo -e "  → 기본 config.toml 생성"
containerd config default > /etc/containerd/config.toml

echo -e "  → SystemdCgroup = true"
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

echo -e "  → sandbox_image = registry.k8s.io/pause:3.10"
sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10"|' /etc/containerd/config.toml

echo -e "  → registry config_path 단일화 (/etc/containerd/certs.d)"
sed -i "s|config_path = '/etc/containerd/certs.d:/etc/docker/certs.d'|config_path = '/etc/containerd/certs.d'|g" /etc/containerd/config.toml

echo -e "  → containerd enable & restart"
systemctl enable --now containerd
systemctl restart containerd
sleep 2

echo -e "  → /etc/crictl.yaml 생성"
cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

echo -e "  → CRI 동작 확인"
ctr version | head -5
crictl --runtime-endpoint=unix:///run/containerd/containerd.sock info 2>/dev/null | head -5 || true

echo -e "  → kubelet enable (containerd 가동 후)"
systemctl enable --now kubelet

# ============================================================
# 완료
# ============================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} ✅ Phase 1~3 완료${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "${YELLOW}다음 단계 (수동):${NC}"
echo "  • /etc/hosts 에 마스터/워커 노드 등록 (Phase 2-6)"
echo "  • (선택) Harbor insecure registry 등록 — install-guide-online.md '(선택) Harbor insecure registry 등록' 참조"
echo "  • (선택) containerd 데이터 경로 변경 — install-guide-online.md '(선택) containerd 데이터 경로 변경' 참조"
echo "  • HA 구성이면 Phase 4 (HAProxy/Keepalived)"
echo "  • Phase 5: kubeadm init (Master-1)"
echo ""
