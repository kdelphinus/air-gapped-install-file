#!/bin/bash
# ---------------------------------------------------------
# Cilium Uninstall & Complete Cleanup Script
# ---------------------------------------------------------
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="kube-system"
RELEASE_NAME="cilium"

# 색상 코드
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}🔥 Cilium 리소스 및 호스트 잔재를 완전 삭제합니다...${NC}"

# 1. Helm Uninstall
if helm status $RELEASE_NAME -n $NAMESPACE >/dev/null 2>&1; then
    echo "  - Helm 릴리스 삭제 중..."
    helm uninstall $RELEASE_NAME -n $NAMESPACE --wait=false
fi

# 2. Kubernetes 자원 강제 삭제 (잔여물 대비)
echo "  - Kubernetes 자원(DS/Deploy/ConfigMap) 강제 정리 중..."
kubectl delete ds cilium -n $NAMESPACE --ignore-not-found=true --force --grace-period=0
kubectl delete deployment hubble-relay hubble-ui -n $NAMESPACE --ignore-not-found=true --force --grace-period=0
kubectl delete cm cilium-config -n $NAMESPACE --ignore-not-found=true

# 3. Containerd 런타임 직접 클린업 (중요!)
echo "  - Containerd 런타임 작업(tasks) 및 컨테이너 강제 중지 중..."
# Cilium 관련 컨테이너 ID 추출 (여러 네임스페이스 고려)
for ns in k8s.io default; do
    CIDS=$(sudo ctr -n $ns containers list -q | grep -E "cilium|hubble")
    if [ -n "$CIDS" ]; then
        for cid in $CIDS; do
            echo "    * [$ns] 컨테이너 종료: $cid"
            sudo ctr -n $ns tasks kill -s SIGKILL "$cid" 2>/dev/null
            sudo ctr -n $ns containers rm "$cid" 2>/dev/null
        done
    fi
done

# 4. 호스트 포트 점유 프로세스 강제 종료
echo "  - 호스트 포트(9234, 9963, 4240 등) 점유 프로세스 확인 중..."
local_ports="9234 9963 4240 4244 9876 9890"
for port in $local_ports; do
    if sudo fuser "$port/tcp" >/dev/null 2>&1; then
        echo "    * 포트 ${port}번 프로세스 발견 및 종료"
        sudo fuser -k -9 "$port/tcp" >/dev/null 2>&1
    fi
done

# 5. BPF 파일 시스템 및 설정 파일 정리 (선택 사항)
if [ -d "/sys/fs/bpf/cilium" ]; then
    echo "  - BPF 파일 시스템(/sys/fs/bpf/cilium) 정리 중..."
    # 주의: 실제 운영 환경에서는 신중해야 하나, 완전 삭제를 위해 포함
    # sudo rm -rf /sys/fs/bpf/cilium/*
fi

if [ -f "./install.conf" ]; then
    read -p "❓ 설치 설정 파일(install.conf)도 삭제하시겠습니까? (y/n): " DEL_CONF
    if [[ "$DEL_CONF" =~ ^[Yy]$ ]]; then
        rm -f ./install.conf
        echo "  - install.conf 삭제됨"
    fi
fi

echo -e "\n${GREEN}✅ Cilium 클린업이 완료되었습니다.${NC}"
