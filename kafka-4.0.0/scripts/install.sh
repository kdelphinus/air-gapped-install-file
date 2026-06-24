#!/bin/bash
# ---------------------------------------------------------
# Apache Kafka v4.0.0 (KRaft Mode) Offline Installation Script
# [Target] General Air-gapped Kubernetes (Rocky Linux / Ubuntu)
# ---------------------------------------------------------
cd "$(dirname "$0")/.." || exit 1

# 기본 변수 설정
NAMESPACE="kafka"
RELEASE_NAME="kafka"
CHART_PATH="./charts/kafka"
CONF_FILE="./install.conf"
PV_HOSTPATH_FILE="./manifests/pv-hostpath.yaml"
PV_NAS_FILE="./manifests/pv-nas.yaml"

# 색상 코드
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# 임시 파일 자동 클린업 trap 설정
trap 'rm -f ./values-temp.yaml 2>/dev/null' EXIT

# ── install.conf 로드 / 저장 ──────────────────────────────
load_conf() {
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
    fi
}

save_conf() {
    cat > "$CONF_FILE" <<EOF
# Kafka 32.4.3 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
STORAGE_TYPE="${STORAGE_TYPE}"
HOSTPATH_MODE="${HOSTPATH_MODE}"
TARGET_NODE="${TARGET_NODE}"
NODE_0="${NODE_0}"
NODE_1="${NODE_1}"
NODE_2="${NODE_2}"
HOSTPATH_BASE_DIR="${HOSTPATH_BASE_DIR}"
NFS_SERVER="${NFS_SERVER}"
NFS_BASE_PATH="${NFS_BASE_PATH}"
STORAGE_CLASS="${STORAGE_CLASS}"
INSTALLED_VERSION="v4.0.0"
EOF
    echo -e "  ✅ 설정이 ${GREEN}${CONF_FILE}${NC} 에 저장되었습니다."
}

# ==========================================
# [함수] 클린업 로직
# ==========================================
cleanup_resources() {
    local RESET_MODE=$1
    echo ""
    echo -e "🧹 ${YELLOW}[Clean Up] 기존 Kafka 리소스 제거 시작...${NC}"

    # 1. 헬름 삭제
    if helm status $RELEASE_NAME -n $NAMESPACE >/dev/null 2>&1; then
        echo "⏳ Helm 차트 삭제 중..."
        helm uninstall $RELEASE_NAME -n $NAMESPACE --wait=false 2>/dev/null
        sleep 3
    fi

    # 2. PVC 삭제
    echo "🗑️  Kafka PVC 삭제 중..."
    kubectl delete pvc -n $NAMESPACE -l "app.kubernetes.io/instance=${RELEASE_NAME}" --timeout=10s --wait=false 2>/dev/null

    # 3. PV 삭제
    echo "🗑️  Kafka PV 삭제 중..."
    kubectl delete pv kafka-pv-0 kafka-pv-1 kafka-pv-2 --timeout=10s --wait=false 2>/dev/null

    # 4. 네임스페이스 삭제
    if kubectl get ns $NAMESPACE > /dev/null 2>&1; then
        echo "🗑️  네임스페이스($NAMESPACE) 삭제..."
        kubectl delete ns $NAMESPACE --timeout=15s --wait=false 2>/dev/null
    fi

    if [ "$RESET_MODE" == "reset" ]; then
        rm -f "$CONF_FILE"
        rm -f "./values-temp.yaml"
        echo -e "🗑️  설정 파일 및 임시 파일 삭제 완료 (Reset)."
    fi

    echo -e "${GREEN}✅ 초기화 작업이 완료되었습니다.${NC}"
    echo ""
}

# ==========================================
# [1] 기존 설치 감지 및 메뉴
# ==========================================
load_conf
EXIST_HELM=$(helm status $RELEASE_NAME -n $NAMESPACE > /dev/null 2>&1 && echo "yes" || echo "no")
DO_UPGRADE=false

if [ "$EXIST_HELM" == "yes" ] || [ -f "$CONF_FILE" ]; then
    echo ""
    echo -e "⚠️  ${YELLOW}기존 설치 또는 설정이 감지되었습니다.${NC}"
    [ -f "$CONF_FILE" ] && echo "  📋 저장된 설정 정보:"
    [ -n "$IMAGE_SOURCE" ] && echo "     - 이미지 소스  : $IMAGE_SOURCE"
    [ -n "$STORAGE_TYPE" ] && echo "     - 스토리지 타입: $STORAGE_TYPE"
    [ "$STORAGE_TYPE" == "hostpath" ] && echo "     - HostPath 모드: ${HOSTPATH_MODE:-단일 노드}"
    [ -n "$TARGET_NODE" ] && echo "     - 단일 타겟 노드: $TARGET_NODE"
    [ -n "$NODE_0" ] && echo "     - 분산 타겟 노드: $NODE_0, $NODE_1, $NODE_2"

    echo ""
    echo "동작을 선택하세요:"
    echo "  1) 업그레이드 (저장된 설정 유지, Helm upgrade)"
    echo "  2) 재설치     (기존 리소스 삭제 후 새로 설치)"
    echo "  3) 초기화     (모든 리소스 및 설정 파일 완전 삭제)"
    echo "  4) 취소"
    read -p "선택 [1/2/3/4]: " ACTION

    case "$ACTION" in
        1) DO_UPGRADE=true ;;
        2) cleanup_resources "reinstall" ;;
        3) cleanup_resources "reset"; exit 0 ;;
        *) echo "취소되었습니다."; exit 0 ;;
    esac
fi

# ==========================================
# [2] 설치 설정 입력 (새로 설치 시에만)
# ==========================================
if [ "$DO_UPGRADE" != "true" ]; then
    # 2-1. 이미지 소스 선택
    echo ""
    echo "이미지 소스를 선택하세요:"
    echo "  1) Harbor 레지스트리 사용"
    echo "  2) 로컬 이미지 직접 사용 (k8s containerd 또는 docker daemon 로드)"
    read -p "선택 [1/2, 기본값 1]: " _IMG_SRC
    if [ "${_IMG_SRC:-1}" == "1" ]; then
        IMAGE_SOURCE="harbor"
        read -p "Harbor 주소 (예: 192.168.1.10:30002): " HARBOR_REGISTRY
        read -p "Harbor 프로젝트 (예: library): " HARBOR_PROJECT
    else
        IMAGE_SOURCE="local"
        
        # CLI 감지
        if command -v docker >/dev/null 2>&1; then
            LOCAL_CLI="docker"
        elif command -v ctr >/dev/null 2>&1; then
            LOCAL_CLI="ctr"
        else
            echo -e "${RED}[오류] 로컬 이미지를 로드할 수 있는 docker 또는 ctr이 설치되어 있지 않습니다.${NC}"
            exit 1
        fi

        echo -e "📦 ${GREEN}${LOCAL_CLI}${NC}를 사용하여 로컬 이미지를 containerd/docker에 로드 중..."
        for tar_file in ./images/*.tar*; do
            [ -e "$tar_file" ] || continue
            echo "  → $(basename "$tar_file") 임포트 중"
            if [ "$LOCAL_CLI" == "docker" ]; then
                docker load -i "$tar_file" 2>/dev/null
            else
                sudo ctr -n k8s.io images import "$tar_file" 2>/dev/null
            fi
        done
    fi

    # 2-2. 스토리지 타입 선택
    echo ""
    echo "사용할 스토리지 유형을 선택하세요:"
    echo "  1) HostPath   (정적 로컬 PV/PVC 구성 - 테스트/개발용)"
    echo "  2) 정적 NAS   (NFS 서버 내 공유 디렉토리 직접 매핑)"
    echo "  3) Dynamic    (StorageClass 기반 동적 프로비저닝)"
    read -p "선택 [1/2/3, 기본값 1]: " _STORAGE_SEL
    _STORAGE_SEL="${_STORAGE_SEL:-1}"

    case "$_STORAGE_SEL" in
        1)
            STORAGE_TYPE="hostpath"
            echo -e "\n${YELLOW}💡 HostPath 스토리지 배치 모드 선택:${NC}"
            echo "  1) 단일 노드 테스트 모드 (Single-Node HA)"
            echo "     - 모든 3개 카프카 파드를 1개의 지정 노드에 모아서 실행합니다."
            echo "  2) 다중 노드 분산 배치 모드 (Multi-Node HA - 테스트용)"
            echo "     - 3개의 서로 다른 지정 노드에 파드를 1개씩 찢어 배치합니다."
            echo "     - *주의: HostPath는 노드 로컬 스토리지이므로 물리적인 노드 장애 복구는 어렵습니다.*"
            read -p "선택 [1/2, 기본값 1]: " _HP_MODE
            if [ "${_HP_MODE:-1}" == "2" ]; then
                HOSTPATH_MODE="multi"
                echo ""
                kubectl get nodes -o wide
                read -p "카프카 브로커 0번(kafka-0)을 배치할 노드 이름: " NODE_0
                read -p "카프카 브로커 1번(kafka-1)을 배치할 노드 이름: " NODE_1
                read -p "카프카 브로커 2번(kafka-2)을 배치할 노드 이름: " NODE_2
            else
                HOSTPATH_MODE="single"
                echo ""
                kubectl get nodes -o wide
                read -p "ArgoCD/Kafka를 고정 배치할 단일 노드 이름: " TARGET_NODE
            fi
            read -p "HostPath 기본 저장 디렉토리 경로 (기본 /var/lib/kafka): " HOSTPATH_BASE_DIR
            HOSTPATH_BASE_DIR="${HOSTPATH_BASE_DIR:-/var/lib/kafka}"
            ;;
        2)
            STORAGE_TYPE="nas"
            read -p "NFS 서버 IP (예: 192.168.1.100): " NFS_SERVER
            read -p "NFS 카프카 공유 기본 디렉토리 경로 (예: /nfs/kafka): " NFS_BASE_PATH
            NFS_BASE_PATH="${NFS_BASE_PATH:-/nfs/kafka}"
            ;;
        3)
            STORAGE_TYPE="nfs-dynamic"
            read -p "StorageClass 이름 입력 (예: nfs-client): " STORAGE_CLASS
            ;;
    esac
fi

save_conf

# ==========================================
# [3] YAML 동기화 (Single Source of Truth)
# ==========================================
echo ""
echo "🔧 임시 설정 파일(values-temp.yaml) 생성 및 치환 중..."

# 1. 템플릿 복사 분기
if [ "${IMAGE_SOURCE}" = "local" ]; then
    cp -f ./values-local.yaml ./values-temp.yaml
else
    cp -f ./values.yaml ./values-temp.yaml
    # Harbor 사용 시 이미지 레지스트리 주소 치환
    sed -i \
        -e "s|<HARBOR_REGISTRY>|${HARBOR_REGISTRY}|g" \
        -e "s|<HARBOR_PROJECT>|${HARBOR_PROJECT}|g" \
        ./values-temp.yaml
fi

# 2. 고가용성 기본 변수 오버라이드 덧붙이기
# ZooKeeper 없이 고가용성을 유지하기 위해 KRaft 모드 활성화 및 브로커 3개 고정 배포
cat >> ./values-temp.yaml <<EOF

# ---------------------------------------------
# Dynamic Configurations Added by install.sh
# ---------------------------------------------
kraft:
  enabled: true

broker:
  replicaCount: 0 # 별도의 broker-only 노드는 사용 안 함

controller:
  replicaCount: 3 # co-located (broker + controller) 노드 3개 사용
  controllerOnly: false
  persistence:
    enabled: true
    size: 20Gi
    storageClass: "manual"
EOF

# 스토리지 세부 분기에 따른 values-temp.yaml 덧붙이기
if [ "$STORAGE_TYPE" == "nfs-dynamic" ]; then
    # Dynamic SC 인 경우 storageClass 덮어쓰기 및 Anti-Affinity 활성화
    sed -i "s|storageClass: \"manual\"|storageClass: \"${STORAGE_CLASS}\"|g" ./values-temp.yaml
    
    cat >> ./values-temp.yaml <<EOF
  podAntiAffinityPreset: soft
EOF
elif [ "$STORAGE_TYPE" == "nas" ]; then
    # 정적 NFS 인 경우 Anti-Affinity 활성화
    cat >> ./values-temp.yaml <<EOF
  podAntiAffinityPreset: soft
EOF
elif [ "$STORAGE_TYPE" == "hostpath" ]; then
    if [ "$HOSTPATH_MODE" == "single" ]; then
        # 단일 노드 고정인 경우 Anti-Affinity 비활성화 및 nodeSelector 추가
        cat >> ./values-temp.yaml <<EOF
  podAntiAffinityPreset: ""
  nodeSelector:
    kubernetes.io/os: linux
    kubernetes.io/hostname: "${TARGET_NODE}"
EOF
    else
        # 다중 노드 고가용성 테스트인 경우 Anti-Affinity 활성화 및 nodeSelector 생략
        cat >> ./values-temp.yaml <<EOF
  podAntiAffinityPreset: soft
EOF
    fi
fi

# ==========================================
# [4] Kubernetes 리소스 준비 및 설치
# ==========================================
echo ""
echo "🚀 [1/2] Kubernetes 네임스페이스 및 정적 영구볼륨(PV) 구성 중..."

# 네임스페이스 생성
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# 정적 스토리지용 PV 배포 처리
if [ "$STORAGE_TYPE" == "hostpath" ]; then
    echo "   → HostPath 정적 PV 매니페스트 배포..."
    if [ "$HOSTPATH_MODE" == "single" ]; then
        # 단일 노드인 경우 모든 3개 PV를 하나의 노드와 경로 하위로 지정
        sed \
            -e "s|<PATH_0>|${HOSTPATH_BASE_DIR}/data-0|g" \
            -e "s|<PATH_1>|${HOSTPATH_BASE_DIR}/data-1|g" \
            -e "s|<PATH_2>|${HOSTPATH_BASE_DIR}/data-2|g" \
            -e "s|<NODE_0>|${TARGET_NODE}|g" \
            -e "s|<NODE_1>|${TARGET_NODE}|g" \
            -e "s|<NODE_2>|${TARGET_NODE}|g" \
            "$PV_HOSTPATH_FILE" | kubectl apply -f -
    else
        # 다중 노드 분산 배치 모드인 경우 입력받은 3개 노드를 각각 할당
        sed \
            -e "s|<PATH_0>|${HOSTPATH_BASE_DIR}/data-0|g" \
            -e "s|<PATH_1>|${HOSTPATH_BASE_DIR}/data-1|g" \
            -e "s|<PATH_2>|${HOSTPATH_BASE_DIR}/data-2|g" \
            -e "s|<NODE_0>|${NODE_0}|g" \
            -e "s|<NODE_1>|${NODE_1}|g" \
            -e "s|<NODE_2>|${NODE_2}|g" \
            "$PV_HOSTPATH_FILE" | kubectl apply -f -
    fi
elif [ "$STORAGE_TYPE" == "nas" ]; then
    echo "   → 정적 NFS NAS PV 매니페스트 배포..."
    sed \
        -e "s|<NFS_SERVER>|${NFS_SERVER}|g" \
        -e "s|<NFS_PATH_0>|${NFS_BASE_PATH}/data-0|g" \
        -e "s|<NFS_PATH_1>|${NFS_BASE_PATH}/data-1|g" \
        -e "s|<NFS_PATH_2>|${NFS_BASE_PATH}/data-2|g" \
        "$PV_NAS_FILE" | kubectl apply -f -
fi

# 2. Helm 배포
echo ""
echo -e "🚀 [2/2] Kafka Helm 차트 배포 중... (${DO_UPGRADE:+업그레이드}${DO_UPGRADE:-설치})"
if [ -d "$CHART_PATH" ]; then
    helm upgrade --install $RELEASE_NAME "$CHART_PATH" \
        -n "$NAMESPACE" \
        -f ./values-temp.yaml
else
    echo -e "${RED}[오류] Helm 차트 디렉토리('${CHART_PATH}')가 존재하지 않습니다.${NC}"
    exit 1
fi

echo ""
echo "========================================================"
echo -e "🎉 구성 완료! (Kafka v4.0.0 / KRaft 3-Nodes HA)"
echo "설정 파일 : $CONF_FILE"
echo "네임스페이스: $NAMESPACE"
echo "========================================================"
echo "⏳ 카프카 브로커 노드 정상 기동 상태 확인:"
echo "👉 kubectl get pods -n $NAMESPACE -w"
echo ""
kubectl get pods -n $NAMESPACE
