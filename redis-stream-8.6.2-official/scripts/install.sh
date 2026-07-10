#!/bin/bash
set -e

# 스크립트 위치 기준으로 컴포넌트 루트로 이동
COMPONENT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$COMPONENT_ROOT" || exit 1

# =================================================================
# --- 설정 변수 ---
# =================================================================
CONF_FILE="./install.conf"
NAMESPACE="redis-stream-official"
RELEASE_NAME="redis-stream-official"
MANIFEST_DIR="./manifests"

# 색상 코드
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ── install.conf 로드 / 저장 ──────────────────────────────
load_conf() {
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
    fi
}

save_conf() {
    cat > "$CONF_FILE" <<EOF
# Redis Stream v8.6.2 설치 설정 — install.sh 에 의해 자동 관리됩니다.
# 보안 규정 준수: REDIS_PASSWORD는 절대 기재하지 않습니다.
NAMESPACE="${NAMESPACE}"
IMAGE_SOURCE="${IMAGE_SOURCE}"
IMAGE_REGISTRY="${IMAGE_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
STORAGE_TYPE="${STORAGE_TYPE}"
STORAGE_SIZE="${STORAGE_SIZE}"
NODE_NAME="${NODE_NAME}"
HOST_BASE_PATH="${HOST_BASE_PATH}"
NFS_SERVER="${NFS_SERVER}"
NFS_BASE_PATH="${NFS_BASE_PATH}"
INSTALLED_VERSION="v8.6.2"
EOF
    echo -e "  ✅ 설정이 ${GREEN}${CONF_FILE}${NC} 에 저장되었습니다."
}

save_values_infra() {
    if [ "${IMAGE_SOURCE}" = "1" ]; then
        cat > "values-infra.yaml" <<EOF
# Redis Stream v8.6.2-official 인프라 설정 — install.sh 에 의해 자동 생성됩니다.
# 보안 규정 준수: 비밀번호는 values-infra.yaml에 기록하지 않습니다.
global:
  imageRegistry: "${IMAGE_REGISTRY}"
image:
  repository: "${HARBOR_PROJECT}/redis"
storage:
  type: "${STORAGE_TYPE}"
  size: "${STORAGE_SIZE}"
EOF
    else
        cat > "values-infra.yaml" <<EOF
# Redis Stream v8.6.2-official 인프라 설정 — install.sh 에 의해 자동 생성됩니다.
# 보안 규정 준수: 비밀번호는 values-infra.yaml에 기록하지 않습니다.
global:
  imageRegistry: ""
image:
  repository: "library/redis"
storage:
  type: "${STORAGE_TYPE}"
  size: "${STORAGE_SIZE}"
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

recover_password() {
    local SECRET_NAME="redis-secret"
    if ! kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" &>/dev/null; then
        SECRET_NAME="${RELEASE_NAME}-secret"
    fi

    local PWD_B64=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.redis-password}' 2>/dev/null || echo "")
    if [ -n "${PWD_B64}" ]; then
        REDIS_PASSWORD=$(echo "${PWD_B64}" | base64 --decode)
        echo -e "  🔐 기존 비밀번호를 Secret(${SECRET_NAME})에서 성공적으로 복구했습니다."
    else
        REDIS_PASSWORD=""
    fi
}

# ==========================================
# [함수] 리소스 제거 로직 (재설치/초기화 시)
# ==========================================
cleanup_resources() {
    local RESET_MODE=$1
    echo ""
    echo -e "🧹 ${YELLOW}[Clean Up] 기존 Redis Stream 리소스 제거 시작...${NC}"

    # 2차 정밀 y/N 프롬프트 데이터 소거 확인 (P4 준수)
    if [ "${RESET_MODE}" == "reset" ]; then
        echo -e "${RED}⚠️  [주의] 초기화 선택 시 모든 영구 데이터 볼륨(PVC/PV)과 설정 파일이 완전히 삭제됩니다.${NC}"
        read -p "❓ 정말 모든 데이터와 설정을 삭제하시겠습니까? (y/N): " RESET_CONFIRM
        if [[ ! "${RESET_CONFIRM}" =~ ^[Yy]$ ]]; then
            echo "취소되었습니다."
            exit 0
        fi
    else
        read -p "❓ Redis Stream 릴리즈를 삭제하고 새로 설치하시겠습니까? (기존 데이터 보존 원칙) (y/N): " REINSTALL_CONFIRM
        if [[ ! "${REINSTALL_CONFIRM}" =~ ^[Yy]$ ]]; then
            echo "취소되었습니다."
            exit 0
        fi
    fi

    # 1. Helm Uninstall
    echo "   - Helm Release 삭제 중..."
    helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait 2>/dev/null || true

    # 2. PV 및 PVC, Namespace 삭제 (Reset 시에만!)
    if [ "${RESET_MODE}" == "reset" ]; then
        echo "   - PersistentVolumeClaim 삭제 중..."
        local PVCLIST=$(kubectl get pvc -n "${NAMESPACE}" --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep "^redis-data-" || true)
        if [ -n "${PVCLIST}" ]; then
            echo "${PVCLIST}" | xargs kubectl delete pvc -n "${NAMESPACE}" --ignore-not-found=true --timeout=30s 2>/dev/null || true
        fi

        echo "   - PersistentVolume 삭제 중..."
        for i in 0 1 2; do
            kubectl delete pv "redis-official-node-${i}-pv" --ignore-not-found=true --timeout=30s 2>/dev/null || true
        done

        echo "   - Namespace '${NAMESPACE}' 삭제 중..."
        kubectl delete ns "${NAMESPACE}" --ignore-not-found=true --timeout=30s 2>/dev/null || true

        # 설정 파일들 소거
        rm -f "$CONF_FILE" "values-infra.yaml"
        echo -e "   🗑️  설정 파일(install.conf, values-infra.yaml) 삭제 완료."
    fi

    echo -e "${GREEN}✅ Clean Up 완료.${NC}"
    echo ""
}

# ==========================================
# [1] 기존 설치 감지 및 메뉴
# ==========================================
load_conf
check_command kubectl
check_command helm

EXIST_NS=$(kubectl get ns "$NAMESPACE" > /dev/null 2>&1 && echo "yes" || echo "no")
DO_UPGRADE=false
_FORCE_REINPUT=false

if [ "$EXIST_NS" == "yes" ] || [ -f "$CONF_FILE" ]; then
    echo ""
    echo -e "⚠️  ${YELLOW}기존 설치 또는 설정이 감지되었습니다.${NC}"
    [ -f "$CONF_FILE" ] && echo "  📋 저장된 설정 정보:"
    [ -n "$IMAGE_SOURCE" ] && echo "     - 이미지 소스 : $IMAGE_SOURCE"
    [ -n "$STORAGE_TYPE" ] && echo "     - 스토리지 타입: $STORAGE_TYPE"
    [ -n "$STORAGE_SIZE" ] && echo "     - 볼륨 크기   : $STORAGE_SIZE"

    echo ""
    echo "동작을 선택하세요:"
    echo "  1) 업그레이드 (저장된 설정 유지, 멱등 릴리즈 재구동)"
    echo "  2) 재설치     (기존 릴리즈 삭제 후 새로 설치, 데이터 보존)"
    echo "  3) 초기화     (모든 볼륨, 네임스페이스 및 설정 파일 완전 삭제)"
    echo "  4) 취소"
    read -p "선택 [1/2/3/4]: " ACTION

    case "$ACTION" in
        1)
            DO_UPGRADE=true
            _IS_INVALID="false"
            if [ -z "$IMAGE_SOURCE" ] || [ -z "$STORAGE_TYPE" ] || [ -z "$STORAGE_SIZE" ]; then
                _IS_INVALID="true"
            elif [ "$IMAGE_SOURCE" == "1" ] && { [ -z "$IMAGE_REGISTRY" ] || [ -z "$HARBOR_PROJECT" ]; }; then
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
    # 2-1. 이미지 소스 선택
    echo ""
    echo "이미지 소스를 선택하세요:"
    echo "  1) Harbor 레지스트리 사용 (사전에 images/upload_images_to_harbor_v3-lite.sh 실행 필요)"
    echo "  2) 로컬 tar 직접 import (이미 이미지가 로드된 경우 건너뜀)"
    read -p "선택 [1/2, 기본값: 1]: " IMAGE_SOURCE
    IMAGE_SOURCE="${IMAGE_SOURCE:-1}"

    if [ "${IMAGE_SOURCE}" = "1" ]; then
        read -p "Harbor 레지스트리 주소 (예: 192.168.1.10:30002): " IMAGE_REGISTRY
        if [ -z "${IMAGE_REGISTRY}" ]; then
            echo -e "${RED}[오류] Harbor 레지스트리 주소가 필요합니다.${NC}"; exit 1
        fi
        read -p "Harbor 프로젝트 (예: library): " HARBOR_PROJECT
        if [ -z "${HARBOR_PROJECT}" ]; then
            echo -e "${RED}[오류] Harbor 프로젝트가 필요합니다.${NC}"; exit 1
        fi
    elif [ "${IMAGE_SOURCE}" = "2" ]; then
        echo "로컬 tar 파일을 containerd(k8s.io)에 import 중..."
        IMPORT_COUNT=0
        for tar_file in ./images/*.tar; do
            [ -e "${tar_file}" ] || continue
            echo "  → $(basename "${tar_file}")"
            sudo ctr -n k8s.io images import "${tar_file}" 2>/dev/null || true
            IMPORT_COUNT=$((IMPORT_COUNT + 1))
        done
        [ "${IMPORT_COUNT}" -eq 0 ] && echo -e "${YELLOW}[경고] ./images/ 에 tar 파일이 없습니다.${NC}"
        echo "  ${IMPORT_COUNT}개 이미지 import 완료"
        IMAGE_REGISTRY=""
        HARBOR_PROJECT=""
    else
        echo -e "${RED}[오류] 1 또는 2를 선택하세요.${NC}"; exit 1
    fi

    # 2-2. 스토리지 타입 및 세부 경로 입력
    echo ""
    read -p "Storage Type 선택 (hostpath/nfs) [기본값: hostpath]: " STORAGE_TYPE
    STORAGE_TYPE="${STORAGE_TYPE:-hostpath}"

    if [ "${STORAGE_TYPE}" = "hostpath" ]; then
        echo "HostPath PV 설정 중..."
        NODES=($(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'))
        if [ ${#NODES[@]} -gt 0 ]; then
            echo "   사용 가능한 노드 목록:"
            for i in "${!NODES[@]}"; do echo "     $((i+1))) ${NODES[$i]}"; done
            read -p "   노드 번호 선택 [1-${#NODES[@]}, 기본값: 1]: " NODE_INDEX
            NODE_INDEX="${NODE_INDEX:-1}"
            NODE_NAME="${NODES[$((NODE_INDEX-1))]}"
        else
            NODE_NAME=$(hostname)
        fi
        read -p "   HostPath 기본 경로 [기본값: /data/redis-official]: " HOST_BASE_PATH
        HOST_BASE_PATH="${HOST_BASE_PATH:-/data/redis-official}"
        read -p "   PV 크기 [기본값: 10Gi]: " STORAGE_SIZE
        STORAGE_SIZE="${STORAGE_SIZE:-10Gi}"

        # 기존 PV 확인
        for i in 0 1 2; do
            PV_NAME="redis-official-node-${i}-pv"
            EXISTING_PATH=$(kubectl get pv "${PV_NAME}" -o jsonpath='{.spec.hostPath.path}' 2>/dev/null || echo "")
            if [ -n "${EXISTING_PATH}" ] && [ "${EXISTING_PATH}" != "${HOST_BASE_PATH}/node-${i}" ]; then
                echo "   [경고] 기존 PV(${PV_NAME})의 경로(${EXISTING_PATH})가 입력한 경로와 다릅니다."
                read -p "   기존 PV를 삭제하고 새로 생성하시겠습니까? [y/N]: " DELETE_PV_CONFIRM
                if [[ "${DELETE_PV_CONFIRM}" =~ ^[Yy]$ ]]; then
                    kubectl delete pv "${PV_NAME}" --wait=false 2>/dev/null || true
                fi
            fi
        done

        echo "   [주의] 노드(${NODE_NAME})에서 다음 명령을 미리 실행하세요:"
        echo "     mkdir -p ${HOST_BASE_PATH}/{node-0,node-1,node-2}"
        echo "     chmod 777 ${HOST_BASE_PATH}/{node-0,node-1,node-2}"
        echo ""
        read -p "   디렉토리 생성을 완료했으면 Enter를 눌러 계속..."

        NFS_SERVER=""
        NFS_BASE_PATH=""
    elif [ "${STORAGE_TYPE}" = "nfs" ]; then
        echo "NFS PV 설정 중..."
        read -p "   NFS 서버 IP: " NFS_SERVER
        if [ -z "${NFS_SERVER}" ]; then
            echo -e "${RED}[오류] NFS 서버 IP가 필요합니다.${NC}"; exit 1
        fi
        read -p "   NFS 기본 경로 [기본값: /nfs/redis-official]: " NFS_BASE_PATH
        NFS_BASE_PATH="${NFS_BASE_PATH:-/nfs/redis-official}"
        read -p "   PV 크기 [기본값: 10Gi]: " STORAGE_SIZE
        STORAGE_SIZE="${STORAGE_SIZE:-10Gi}"

        echo "   [주의] NFS 서버(${NFS_SERVER})에서 다음 명령을 미리 실행하세요:"
        echo "     mkdir -p ${NFS_BASE_PATH}/{node-0,node-1,node-2}"
        echo "     chmod 777 ${NFS_BASE_PATH}/{node-0,node-1,node-2}"
        echo ""
        read -p "   디렉토리 생성을 완료했으면 Enter를 눌러 계속..."

        NODE_NAME=""
        HOST_BASE_PATH=""
    else
        echo -e "${RED}[오류] 알 수 없는 스토리지 타입: ${STORAGE_TYPE}${NC}"; exit 1
    fi
fi

# ==========================================
# [3] 비밀번호 복구 및 입력 처리
# ==========================================
recover_password

if [ -z "${REDIS_PASSWORD}" ]; then
    echo ""
    read -s -p "Redis 비밀번호 입력: " REDIS_PASSWORD
    echo ""
    if [ -z "${REDIS_PASSWORD}" ]; then
        echo -e "${RED}[오류] 비밀번호가 비어 있습니다.${NC}"; exit 1
    fi
fi

# 설정 값 저장
save_conf
save_values_infra

# ==========================================
# [수명주기 보장] Namespace 및 PV 강제 보정 함수
# ==========================================
ensure_namespace_and_pv() {
    echo ""
    echo -e "🚀 [수명주기 보장] Namespace 및 PV 상태 점검 및 보장..."

    # 1. Namespace 보장
    kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    # 2. PV 생성 (기존 입력/저장된 설정을 기반으로 멱등하게 재생성/적용)
    if [ "${STORAGE_TYPE}" = "hostpath" ]; then
        if [ -n "${NODE_NAME}" ] && [ -n "${HOST_BASE_PATH}" ] && [ -n "${STORAGE_SIZE}" ]; then
            echo "   - HostPath PV 생성 중..."
            sed -e "s|__NODE_NAME__|${NODE_NAME}|g" \
                -e "s|__BASE_PATH__|${HOST_BASE_PATH}|g" \
                -e "s|__STORAGE_SIZE__|${STORAGE_SIZE}|g" \
                -e "s|__NAMESPACE__|${NAMESPACE}|g" \
                "${MANIFEST_DIR}/10-pv-hostpath.yaml" | kubectl apply -f -
        fi
    elif [ "${STORAGE_TYPE}" = "nfs" ]; then
        if [ -n "${NFS_SERVER}" ] && [ -n "${NFS_BASE_PATH}" ] && [ -n "${STORAGE_SIZE}" ]; then
            echo "   - NFS PV 생성 중..."
            sed -e "s|__NFS_SERVER__|${NFS_SERVER}|g" \
                -e "s|__NFS_BASE_PATH__|${NFS_BASE_PATH}|g" \
                -e "s|__STORAGE_SIZE__|${STORAGE_SIZE}|g" \
                -e "s|__NAMESPACE__|${NAMESPACE}|g" \
                "${MANIFEST_DIR}/10-pv-nfs.yaml" | kubectl apply -f -
        fi
    fi
}

ensure_namespace_and_pv

# ==========================================
# [4] Helm 배포 기동
# ==========================================
echo ""
echo "4. Helm Chart 배포 중..."

helm upgrade --install ${RELEASE_NAME} charts/redis-sentinel \
    --namespace ${NAMESPACE} \
    -f values.yaml \
    -f values-infra.yaml \
    --set redis.password="${REDIS_PASSWORD}" \
    --wait --timeout 300s

# 최종 상태 확인
echo ""
echo "======================================================"
echo -e " ${GREEN}✅ Redis Stream 배포 완료 — 현재 Pod 상태${NC}"
echo "======================================================"
kubectl get pods -n "${NAMESPACE}"

echo ""
echo "접속 정보:"
echo "  Redis:    redis.${NAMESPACE}.svc.cluster.local:6379"
echo "  Sentinel: redis-sentinel.${NAMESPACE}.svc.cluster.local:26379"
echo ""
echo "연결 테스트:"
echo "  kubectl exec -it redis-node-0 -n ${NAMESPACE} -- \\"
echo "    redis-cli -a <password> --no-auth-warning INFO replication"
echo ""
