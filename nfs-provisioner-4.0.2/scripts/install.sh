#!/bin/bash
# ---------------------------------------------------------
# NFS Provisioner Installation Script
# [Chart Version] 4.0.18
# [App/Image Version] v4.0.2
# [Target] Rocky Linux / Ubuntu (Online/Offline)
# ---------------------------------------------------------
set -e

# 스크립트 위치 기준으로 컴포넌트 루트로 이동
COMPONENT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$COMPONENT_ROOT" || exit 1

# 기본 변수
RELEASE_NAME="nfs-provisioner"
NAMESPACE="kube-system"
CHART_PATH="./charts/nfs-subdir-external-provisioner"
CONF_FILE="./install.conf"

# 색상 코드
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# ── 1. 오프라인 자산 디렉토리 사전 검증 ──────────────────────────────
validate_assets() {
    if [ ! -d "$CHART_PATH" ]; then
        echo -e "${RED}[오류] 오프라인 Helm 차트 디렉토리(${CHART_PATH})가 존재하지 않습니다.${NC}"
        echo "       인터넷이 연결된 환경에서 먼저 scripts/download_assets_offline.sh를 실행하여 차트를 내려받으십시오."
        exit 1
    fi

    # 로컬 모드 혹은 Harbor 업로드 모드를 위해 images 디렉토리도 확인
    if [ ! -d "./images" ]; then
        echo -e "${RED}[오류] 오프라인 이미지 디렉토리(./images)가 존재하지 않습니다.${NC}"
        echo "       인터넷이 연결된 환경에서 먼저 scripts/download_assets_offline.sh를 실행하여 이미지를 내려받으십시오."
        exit 1
    fi
}

# ── 2. 설정 로드 / 저장 ──────────────────────────────
load_conf() {
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
    fi
}

save_conf() {
    cat > "$CONF_FILE" <<EOF
# NFS Provisioner 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
NFS_SERVER_IP="${NFS_SERVER_IP}"
NFS_SHARE_PATH="${NFS_SHARE_PATH}"
INSTALLED_CHART_VERSION="4.0.18"
INSTALLED_APP_VERSION="v4.0.2"
EOF
    echo -e "  ✅ 설정이 ${GREEN}${CONF_FILE}${NC} 에 저장되었습니다."
}

save_values_infra() {
    if [ "${IMAGE_SOURCE}" = "1" ] || [ "${IMAGE_SOURCE}" = "harbor" ]; then
        cat > "values-infra.yaml" <<EOF
# NFS Provisioner 인프라 설정 — install.sh 에 의해 자동 생성됩니다.
image:
  repository: "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/nfs-subdir-external-provisioner"
nfs:
  server: "${NFS_SERVER_IP}"
  path: "${NFS_SHARE_PATH}"
EOF
    else
        cat > "values-infra.yaml" <<EOF
# NFS Provisioner 인프라 설정 — install.sh 에 의해 자동 생성됩니다.
image:
  repository: "registry.k8s.io/sig-storage/nfs-subdir-external-provisioner"
nfs:
  server: "${NFS_SERVER_IP}"
  path: "${NFS_SHARE_PATH}"
EOF
    fi
    echo -e "  ✅ 인프라 값이 ${GREEN}values-infra.yaml${NC} 에 저장되었습니다."
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}[오류] '$1' 명령어를 찾을 수 없습니다.${NC}"
        exit 1
    fi
}

# ==========================================
# [함수] 리소스 제거 로직 (재설치/초기화 시)
# ==========================================
cleanup_resources() {
    local RESET_MODE=$1
    echo ""
    echo -e "🧹 ${YELLOW}[Clean Up] 기존 NFS Provisioner 리소스 제거 시작...${NC}"

    # 2차 정밀 y/N 프롬프트 데이터 소거 확인 (P4 준수)
    if [ "${RESET_MODE}" == "reset" ]; then
        echo -e "${RED}⚠️  [주의] 초기화 선택 시 모든 인프라 설정 파일이 완전히 삭제됩니다.${NC}"
        read -p "❓ 정말 모든 설정을 삭제하시겠습니까? (y/N): " RESET_CONFIRM
        if [[ ! "${RESET_CONFIRM}" =~ ^[Yy]$ ]]; then
            echo "취소되었습니다."
            exit 0
        fi
    else
        read -p "❓ NFS Provisioner 릴리즈를 삭제하고 새로 설치하시겠습니까? (y/N): " REINSTALL_CONFIRM
        if [[ ! "${REINSTALL_CONFIRM}" =~ ^[Yy]$ ]]; then
            echo "취소되었습니다."
            exit 0
        fi
    fi

    # 1. 추가 StorageClass 삭제
    if [ -f "./manifests/additional-sc.yaml" ]; then
        echo "   - 추가 StorageClass 삭제 중..."
        kubectl delete -f ./manifests/additional-sc.yaml --ignore-not-found=true 2>/dev/null || true
    fi

    # 2. Helm Uninstall
    echo "   - Helm Release 삭제 중..."
    helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait 2>/dev/null || true

    # 3. 설정 파일들 삭제 (Reset 시에만)
    if [ "${RESET_MODE}" == "reset" ]; then
        rm -f "$CONF_FILE" "values-infra.yaml"
        echo -e "   🗑️  설정 파일(install.conf, values-infra.yaml) 삭제 완료."
    fi

    echo -e "${GREEN}✅ Clean Up 완료.${NC}"
    echo ""
}

# ==========================================
# [1] 기존 설치 감지 및 메뉴
# ==========================================
validate_assets
load_conf
check_command kubectl
check_command helm

EXIST_RELEASE=$(helm list -n "$NAMESPACE" -q | grep "^${RELEASE_NAME}$" || echo "")
DO_UPGRADE=false
_FORCE_REINPUT=false

if [ -n "$EXIST_RELEASE" ] || [ -f "$CONF_FILE" ]; then
    echo ""
    echo -e "⚠️  ${YELLOW}기존 설치 또는 설정이 감지되었습니다.${NC}"
    [ -f "$CONF_FILE" ] && echo "  📋 저장된 설정 정보:"
    [ -n "$IMAGE_SOURCE" ] && echo "     - 이미지 소스 : $IMAGE_SOURCE"
    [ -n "$NFS_SERVER_IP" ] && echo "     - NFS 서버 IP : $NFS_SERVER_IP"
    [ -n "$NFS_SHARE_PATH" ] && echo "     - NFS 공유 경로: $NFS_SHARE_PATH"

    echo ""
    echo "동작을 선택하세요:"
    echo "  1) 업그레이드 (저장된 설정 유지, 멱등 릴리즈 재구동)"
    echo "  2) 재설치     (기존 릴리즈 삭제 후 새로 설치)"
    echo "  3) 초기화     (설정 파일 및 릴리즈 완전 삭제)"
    echo "  4) 취소"
    read -p "선택 [1/2/3/4]: " ACTION

    case "$ACTION" in
        1)
            DO_UPGRADE=true
            _IS_INVALID="false"
            if [ -z "$IMAGE_SOURCE" ] || [ -z "$NFS_SERVER_IP" ] || [ -z "$NFS_SHARE_PATH" ]; then
                _IS_INVALID="true"
            elif { [ "$IMAGE_SOURCE" == "1" ] || [ "$IMAGE_SOURCE" == "harbor" ]; } && { [ -z "$HARBOR_REGISTRY" ] || [ -z "$HARBOR_PROJECT" ]; }; then
                _IS_INVALID="true"
            fi

            if [ "$_IS_INVALID" == "true" ]; then
                echo -e "${YELLOW}  ℹ️  저장된 설정 정보가 불완전합니다. 설치 설정을 다시 입력해 주십시오.${NC}"
                _FORCE_REINPUT="true"
            fi
            ;;
        2) cleanup_resources "reinstall" ;;
        3) cleanup_resources "reset"; exit 0 ;;
        *) echo "취소되었습니다."; exit 0 ;;
    esac
fi

# ==========================================
# [2] 설치 설정 입력 (새로 설치 시에만)
# ==========================================
if [ "$DO_UPGRADE" != "true" ] || [ ! -f "$CONF_FILE" ] || [ "$_FORCE_REINPUT" == "true" ]; then
    echo -e "${CYAN}===========================================${NC}"
    echo -e "${CYAN}   NFS Provisioner 설치 설정 입력          ${NC}"
    echo -e "   [Chart Version] 4.0.18 / [App] v4.0.2"
    echo -e "${CYAN}===========================================${NC}"

    # 2-1. 이미지 소스 선택
    echo ""
    echo "이미지 소스를 선택하세요:"
    echo "  1) Harbor 레지스트리 사용 (사전에 images/upload_images_to_harbor_v3-lite.sh 실행 필요)"
    echo "  2) 로컬 tar 직접 import (이미 이미지가 로드된 경우 건너뜀)"
    read -p "선택 [1/2, 기본값: 1]: " _IMG_SRC
    _IMG_SRC="${_IMG_SRC:-1}"

    if [ "$_IMG_SRC" = "1" ]; then
        IMAGE_SOURCE="harbor"
        read -p "Harbor 레지스트리 주소 (예: 192.168.1.10:30002): " HARBOR_REGISTRY
        if [ -z "${HARBOR_REGISTRY}" ]; then
            echo -e "${RED}[오류] Harbor 레지스트리 주소가 필요합니다.${NC}"; exit 1
        fi
        read -p "Harbor 프로젝트 (예: library): " HARBOR_PROJECT
        if [ -z "${HARBOR_PROJECT}" ]; then
            echo -e "${RED}[오류] Harbor 프로젝트가 필요합니다.${NC}"; exit 1
        fi
    elif [ "$_IMG_SRC" = "2" ]; then
        IMAGE_SOURCE="local"
        echo "로컬 tar 파일을 containerd(k8s.io)에 import 중..."
        IMPORT_COUNT=0
        for tar_file in ./images/*.tar*; do
            [ -e "${tar_file}" ] || continue
            echo "  → $(basename "${tar_file}")"
            sudo ctr -n k8s.io images import "${tar_file}" 2>/dev/null || true
            IMPORT_COUNT=$((IMPORT_COUNT + 1))
        done
        [ "${IMPORT_COUNT}" -eq 0 ] && echo -e "${YELLOW}[경고] ./images/ 에 tar 파일이 없습니다.${NC}"
        echo "  ${IMPORT_COUNT}개 이미지 import 완료"
        HARBOR_REGISTRY=""
        HARBOR_PROJECT=""
    else
        echo -e "${RED}[오류] 1 또는 2를 선택하세요.${NC}"; exit 1
    fi

    # 2-2. NFS 정보 입력
    echo ""
    read -p "NFS 서버 IP (예: 192.168.1.100): " NFS_SERVER_IP
    if [ -z "${NFS_SERVER_IP}" ]; then
        echo -e "${RED}[오류] NFS 서버 IP가 필요합니다.${NC}"; exit 1
    fi
    read -p "NFS 공유 경로 (예: /data/nfs-share): " NFS_SHARE_PATH
    if [ -z "${NFS_SHARE_PATH}" ]; then
        echo -e "${RED}[오류] NFS 공유 경로가 필요합니다.${NC}"; exit 1
    fi
fi

# 설정 저장
save_conf
save_values_infra

# ==========================================
# [3] Helm 배포 기동
# ==========================================
echo ""
echo "🚀 Helm Chart 배포 중..."

helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" \
    --namespace "$NAMESPACE" --create-namespace \
    -f values.yaml \
    -f values-infra.yaml \
    --wait

# ── 추가 StorageClass 적용 ─────────────────────────────
if [ -f "./manifests/additional-sc.yaml" ]; then
    echo ""
    echo -e "${YELLOW}🚀 추가 StorageClass(nfs-backup, nfs-test) 적용 중...${NC}"
    kubectl apply -f ./manifests/additional-sc.yaml
fi

# 최종 상태 확인
echo ""
echo "======================================================"
echo -e " ${GREEN}✅ NFS Provisioner 배포 완료 — StorageClass 상태${NC}"
echo "======================================================"
kubectl get sc
echo ""
