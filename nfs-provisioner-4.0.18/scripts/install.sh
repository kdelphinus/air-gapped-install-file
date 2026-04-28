#!/bin/bash
# ---------------------------------------------------------
# NFS Provisioner v4.0.18 Installation Script
# [Target] Rocky Linux 9.6 / Ubuntu 24.04 (Online/Offline)
# ---------------------------------------------------------
cd "$(dirname "$0")/.." || exit 1

# 기본 변수
RELEASE_NAME="nfs-provisioner"
NAMESPACE="kube-system"
CHART_PATH="./charts/nfs-subdir-external-provisioner"
VALUES_FILE="./values.yaml"
CONF_FILE="./install.conf"

# 색상 코드
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── 설정 로드 / 저장 ──────────────────────────────
load_conf() {
    [ -f "$CONF_FILE" ] && source "$CONF_FILE"
}

save_conf() {
    cat > "$CONF_FILE" <<EOF
# NFS Provisioner 설치 설정
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
NFS_SERVER_IP="${NFS_SERVER_IP}"
NFS_SHARE_PATH="${NFS_SHARE_PATH}"
EOF
}

load_conf

echo -e "${CYAN}===========================================${NC}"
echo -e "${CYAN}   NFS Provisioner v4.0.18 설치 시작       ${NC}"
echo -e "${CYAN}===========================================${NC}"

# ── 이미지 소스 선택 ──────────────────────────────────────
if [ -z "${IMAGE_SOURCE}" ]; then
    echo "이미지 소스를 선택하세요:"
    echo "  1) Harbor 레지스트리 사용"
    echo "  2) 인터넷 공식 레지스트리 사용"
    read -p "선택 [1/2, 기본값: 2]: " _IMG_SRC
    _IMG_SRC="${_IMG_SRC:-2}"
    IMAGE_SOURCE=$([ "$_IMG_SRC" = "1" ] && echo "harbor" || echo "online")
fi

if [ "${IMAGE_SOURCE}" = "harbor" ]; then
    [ -z "${HARBOR_REGISTRY}" ] && read -p "Harbor 주소: " HARBOR_REGISTRY
    [ -z "${HARBOR_PROJECT}" ] && read -p "Harbor 프로젝트: " HARBOR_PROJECT
fi

# ── NFS 정보 입력 ─────────────────────────────────────────
if [ -z "${NFS_SERVER_IP}" ]; then
    read -p "NFS 서버 IP (예: 172.30.x.x): " NFS_SERVER_IP
fi
if [ -z "${NFS_SHARE_PATH}" ]; then
    read -p "NFS 공유 경로 (예: /k8s/data): " NFS_SHARE_PATH
fi

save_conf

# ── 매니페스트 준비 ──────────────────────────────────────
echo -e "\n${YELLOW}🔧 설정을 values-temp.yaml에 반영 중...${NC}"
cp "$VALUES_FILE" ./values-temp.yaml

sed -i "s|<NFS_SERVER_IP>|${NFS_SERVER_IP}|g" ./values-temp.yaml
sed -i "s|<NFS_SHARE_PATH>|${NFS_SHARE_PATH}|g" ./values-temp.yaml

if [ "${IMAGE_SOURCE}" = "harbor" ]; then
    sed -i "s|repository: .*|repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/nfs-subdir-external-provisioner|g" ./values-temp.yaml
fi

# ── Helm 설치 ────────────────────────────────────────────
echo -e "${YELLOW}🚀 Helm 설치 진행 중...${NC}"
helm upgrade --install $RELEASE_NAME "$CHART_PATH" \
    --namespace $NAMESPACE --create-namespace \
    -f ./values-temp.yaml \
    --wait

# ── 추가 StorageClass 적용 ─────────────────────────────
if [ -f "./manifests/additional-sc.yaml" ]; then
    echo -e "${YELLOW}🚀 추가 StorageClass(backup, test) 적용 중...${NC}"
    kubectl apply -f ./manifests/additional-sc.yaml
fi

rm -f ./values-temp.yaml
echo -e "\n${GREEN}✅ NFS Provisioner 설치가 완료되었습니다.${NC}"
kubectl get sc
