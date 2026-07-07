#!/bin/bash
# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

# ==========================================
# [설정] 기본 변수
# ==========================================
HARBOR_NAMESPACE="harbor"
HARBOR_RELEASE_NAME="harbor"
PV_NAME="harbor-pv"
PVC_NAME="harbor-pvc"
HELM_CHART_PATH="./charts/harbor"
CONF_FILE="./install.conf"
PV_PVC_FILE="./manifests/harbor-persistence-infra.yaml"

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
# Harbor 2.10.3 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_LOAD_CHOICE="${IMAGE_LOAD_CHOICE}"
EXPOSE_CHOICE="${EXPOSE_CHOICE}"
EXPOSE_TYPE="${EXPOSE_TYPE}"
EXTERNAL_HOSTNAME="${EXTERNAL_HOSTNAME}"
EXTERNAL_URL="${EXTERNAL_URL}"
PROTOCOL="${PROTOCOL}"
HTTP_NODEPORT="${HTTP_NODEPORT}"
HTTPS_NODEPORT="${HTTPS_NODEPORT}"
TLS_ENABLED="${TLS_ENABLED}"
TLS_CERT_SOURCE="${TLS_CERT_SOURCE}"
TLS_SECRET_NAME="${TLS_SECRET_NAME}"
STORAGE_MODE="${STORAGE_MODE}"
STORAGE_SIZE="${STORAGE_SIZE}"
SAVE_PATH="${SAVE_PATH}"
NODE_NAME="${NODE_NAME}"
NFS_SERVER="${NFS_SERVER}"
NFS_PATH="${NFS_PATH}"
STORAGE_CLASS="${STORAGE_CLASS}"
DATABASE_SIZE="${DATABASE_SIZE}"
REDIS_SIZE="${REDIS_SIZE}"
JOBLOG_SIZE="${JOBLOG_SIZE}"
TRIVY_SIZE="${TRIVY_SIZE}"
ALLOW_CP_TAINT="${ALLOW_CP_TAINT}"
ENABLE_CP_TOLERATIONS="${ENABLE_CP_TOLERATIONS}"
TARGET_NODE_NAME="${TARGET_NODE_NAME}"
MINIMIZE_RESOURCES="${MINIMIZE_RESOURCES}"
INSTALLED_VERSION="v2.10.3"
EOF
    echo -e "  ✅ 설정이 ${GREEN}${CONF_FILE}${NC} 에 저장되었습니다."
}

# ==========================================
# [함수] 클린업 로직
# ==========================================
function cleanup_resources() {
  local RESET_MODE=$1 # "reset" 이면 install.conf 도 삭제
  echo ""
  echo -e "🧹 ${YELLOW}[Clean Up] 기존 Harbor 리소스 제거 시작...${NC}"

  # Helm Uninstall
  if helm status "$HARBOR_RELEASE_NAME" -n "$HARBOR_NAMESPACE" >/dev/null 2>&1; then
      echo "⏳ Helm 차트 삭제 중..."
      helm uninstall "$HARBOR_RELEASE_NAME" -n "$HARBOR_NAMESPACE" --wait=false 2>/dev/null
      sleep 3
  fi

  # PVC 및 PV 삭제 여부 통합 프롬프트 (데이터 보호)
  echo ""
  read -p "⚠️  볼륨(PVC 및 PV)을 완전히 삭제하시겠습니까? (Harbor 저장 이미지 데이터 전체 유실 주의) (y/n): " DELETE_VOLUMES
  if [[ "$DELETE_VOLUMES" =~ ^[Yy]$ ]]; then
      echo "🗑️  Harbor PVC 삭제 중..."
      kubectl delete pvc -n "$HARBOR_NAMESPACE" --all --timeout=15s --wait=false 2>/dev/null

      echo "🗑️  PV 물리적 삭제 중..."
      kubectl delete pv "$PV_NAME" --ignore-not-found=true 2>/dev/null
      kubectl get pv 2>/dev/null | grep "$HARBOR_NAMESPACE" | awk '{print $1}' | xargs -r kubectl delete pv 2>/dev/null
  else
      echo "➡️  PVC 및 PV 볼륨 데이터가 보존되었습니다."
  fi

  # 네임스페이스 삭제 (볼륨 보존 시 namespace 삭제로 인한 namespaced PVC cascade delete 방지)
  if [[ "$DELETE_VOLUMES" =~ ^[Yy]$ ]]; then
      if kubectl get ns "$HARBOR_NAMESPACE" > /dev/null 2>&1; then
          echo "🗑️  네임스페이스($HARBOR_NAMESPACE) 삭제..."
          kubectl delete ns "$HARBOR_NAMESPACE" --timeout=15s --wait=false 2>/dev/null
      fi
  else
      echo "➡️  볼륨 보존 선택에 따라 네임스페이스($HARBOR_NAMESPACE) 삭제 단계를 생략합니다."
  fi

  # 리셋 모드 시 설정 및 런타임 파일 제거
  if [ "$RESET_MODE" == "reset" ]; then
      rm -f "$CONF_FILE"
      rm -f "./values-infra.yaml"
      rm -f "$PV_PVC_FILE"
      echo -e "🗑️  설정 파일 및 생성된 인프라 파일 삭제 완료 (Reset)."
  fi

  echo -e "${GREEN}✅ 초기화 작업이 완료되었습니다.${NC}"
  echo ""
}

# 쉘 명령어 사전 체크
check_command() {
    if ! command -v "$1" &> /dev/null; then 
        echo -e "${RED}[오류] '$1' 명령어를 찾을 수 없습니다. 설치 후 다시 진행하십시오.${NC}"
        exit 1
    fi
}

# 접속 URL 기본값 파싱
parse_harbor_url() {
    local raw_url="$1"
    URL_PROTOCOL="http"
    URL_HOSTPORT="$raw_url"

    if [[ "$raw_url" == *"://"* ]]; then
        URL_PROTOCOL="${raw_url%%://*}"
        URL_HOSTPORT="${raw_url#*://}"
    fi

    URL_HOSTPORT="${URL_HOSTPORT%%/*}"
    URL_HOST="${URL_HOSTPORT%%:*}"
    URL_PORT=""
    if [[ "$URL_HOSTPORT" == *":"* ]]; then
        URL_PORT="${URL_HOSTPORT##*:}"
    fi
    URL_NORMALIZED="${URL_PROTOCOL}://${URL_HOSTPORT}"
}

# ==========================================
# [1] 기존 설치 감지 및 메뉴
# ==========================================
load_conf
check_command kubectl
check_command helm

EXIST_HELM=$(helm status "$HARBOR_RELEASE_NAME" -n "$HARBOR_NAMESPACE" > /dev/null 2>&1 && echo "yes" || echo "no")
DO_UPGRADE=false

if [ "$EXIST_HELM" == "yes" ] || [ -f "$CONF_FILE" ]; then
    echo ""
    echo -e "⚠️  ${YELLOW}기존 설치 또는 설정이 감지되었습니다.${NC}"
    [ -f "$CONF_FILE" ] && echo "  📋 저장된 설정 정보:"
    [ -n "$EXTERNAL_HOSTNAME" ] && echo "     - 접속 호스트  : $EXTERNAL_HOSTNAME"
    [ -n "$STORAGE_MODE" ] && echo "     - 스토리지 모드: $STORAGE_MODE (크기: $STORAGE_SIZE)"
    [ "$STORAGE_MODE" == "hostpath" ] && echo "       · HostPath: ${SAVE_PATH:-미설정} (PV node: ${NODE_NAME:-미설정})"
    [ "$STORAGE_MODE" == "nfs" ] && echo "       · NFS 정적 PV: ${NFS_SERVER:-미설정}:${NFS_PATH:-미설정}"
    [ "$STORAGE_MODE" == "nfs-dynamic" ] && echo "       · Dynamic StorageClass: ${STORAGE_CLASS:-미설정}"
    [ -n "$TLS_ENABLED" ] && echo "     - TLS 활성화   : $TLS_ENABLED"
    [ -n "$MINIMIZE_RESOURCES" ] && echo "     - 리소스 최소화: $MINIMIZE_RESOURCES"

    echo ""
    echo -e "${YELLOW}[주의] 업그레이드는 위 저장 설정을 그대로 사용합니다.${NC}"
    echo -e "       HostPath/NFS 정적/NFS SC 등 스토리지 백엔드를 바꾸려면 '재설치' 또는 '초기화'를 선택하세요."
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
    echo ""
    echo "0. 이미지 로드 방식 선택:"
    echo "  1) 로컬 tar 직접 import (images/*.tar 파일들 containerd에 로딩)"
    echo "  2) 로컬 이미지 수동 로드 완료 (이미 이미지가 로드된 경우)"
    read -p "선택 [1/2, 기본값 1]: " IMAGE_LOAD_CHOICE
    IMAGE_LOAD_CHOICE="${IMAGE_LOAD_CHOICE:-1}"

    if [ "$IMAGE_LOAD_CHOICE" == "1" ]; then
        echo -e "📦 containerd(k8s.io)에 로컬 이미지를 로드 중..."
        for tar_file in ./images/*.tar*; do
            [ -e "$tar_file" ] || continue
            echo "  → $(basename "$tar_file") 임포트 중"
            sudo ctr -n k8s.io images import "$tar_file" 2>/dev/null || true
        done
    fi

    DETECTED_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null | awk '{print $1}')
    if [ -z "$DETECTED_IP" ]; then
        DETECTED_IP=$(hostname -I | awk '{print $1}')
    fi
    DETECTED_IP="${DETECTED_IP:-127.0.0.1}"

    echo ""
    echo "Harbor 노출 방식을 선택하세요:"
    echo "  1) Envoy Gateway (기본, HTTPRoute로 도메인 라우팅)"
    echo "  2) NodePort 직접 접속"
    echo "  3) nginx Ingress"
    read -p "선택 [1/2/3, 기본값 1]: " EXPOSE_CHOICE
    EXPOSE_CHOICE="${EXPOSE_CHOICE:-1}"

    PROTOCOL="http"
    TLS_SECRET_NAME=""
    TLS_ENABLED="false"

    case "$EXPOSE_CHOICE" in
        1)
            EXPOSE_TYPE="clusterIP"
            DEFAULT_HARBOR_URL="http://${EXTERNAL_HOSTNAME:-harbor.devops.internal}"
            read -p "Harbor Envoy 접속 URL [${DEFAULT_HARBOR_URL}]: " INPUT_HARBOR_URL
            EXTERNAL_URL="${INPUT_HARBOR_URL:-$DEFAULT_HARBOR_URL}"
            parse_harbor_url "$EXTERNAL_URL"
            PROTOCOL="$URL_PROTOCOL"
            EXTERNAL_HOSTNAME="$URL_HOST"
            EXTERNAL_URL="$URL_NORMALIZED"
            ;;
        2)
            EXPOSE_TYPE="nodePort"
            HTTP_NODEPORT="${HTTP_NODEPORT:-30002}"
            HTTPS_NODEPORT="${HTTPS_NODEPORT:-30003}"
            DEFAULT_HARBOR_URL="http://${EXTERNAL_HOSTNAME:-$DETECTED_IP}:${HTTP_NODEPORT}"
            read -p "Harbor NodePort 접속 URL [${DEFAULT_HARBOR_URL}]: " INPUT_HARBOR_URL
            EXTERNAL_URL="${INPUT_HARBOR_URL:-$DEFAULT_HARBOR_URL}"
            parse_harbor_url "$EXTERNAL_URL"
            PROTOCOL="$URL_PROTOCOL"
            EXTERNAL_HOSTNAME="$URL_HOST"
            EXTERNAL_URL="$URL_NORMALIZED"
            if [ -n "$URL_PORT" ]; then
                if [[ "$PROTOCOL" == "https" ]]; then
                    HTTPS_NODEPORT="$URL_PORT"
                else
                    HTTP_NODEPORT="$URL_PORT"
                fi
            elif [[ "$PROTOCOL" == "https" ]]; then
                EXTERNAL_URL="${EXTERNAL_URL}:${HTTPS_NODEPORT}"
            else
                EXTERNAL_URL="${EXTERNAL_URL}:${HTTP_NODEPORT}"
            fi
            if [[ "$PROTOCOL" == "https" ]]; then
                TLS_ENABLED="true"
                read -p "미리 생성해 둔 TLS 시크릿의 이름을 입력하세요: " TLS_SECRET_NAME
                if [ -z "$TLS_SECRET_NAME" ]; then echo "오류: TLS 시크릿 이름은 비워둘 수 없습니다."; exit 1; fi
            fi
            ;;
        3)
            EXPOSE_TYPE="ingress"
            DEFAULT_HARBOR_URL="http://${EXTERNAL_HOSTNAME:-harbor.devops.internal}"
            read -p "Harbor Ingress 접속 URL [${DEFAULT_HARBOR_URL}]: " INPUT_HARBOR_URL
            EXTERNAL_URL="${INPUT_HARBOR_URL:-$DEFAULT_HARBOR_URL}"
            parse_harbor_url "$EXTERNAL_URL"
            PROTOCOL="$URL_PROTOCOL"
            EXTERNAL_HOSTNAME="$URL_HOST"
            EXTERNAL_URL="$URL_NORMALIZED"
            if [[ "$PROTOCOL" == "https" ]]; then
                TLS_ENABLED="true"
                read -p "Ingress용 TLS 시크릿 이름 입력: " TLS_SECRET_NAME
                if [ -z "$TLS_SECRET_NAME" ]; then echo "오류: TLS 시크릿 이름은 필수입니다."; exit 1; fi
            fi
            ;;
    esac

    echo ""
    read -p "Control Plane(Master) 노드의 Taint를 허용하여 Pod을 배치하겠습니까? (y/N): " ALLOW_CP_TAINT
    ENABLE_CP_TOLERATIONS="false"
    if [[ "$ALLOW_CP_TAINT" =~ ^[yY]([eE][sS])?$ ]]; then
        ENABLE_CP_TOLERATIONS="true"
    fi

    echo ""
    read -p "모든 Harbor 파드를 특정 노드에 고정하여 배포하시겠습니까? (y/N): " FORCE_NODE_PIN
    TARGET_NODE_NAME=""
    if [[ "$FORCE_NODE_PIN" =~ ^[yY]([eE][sS])?$ ]]; then
        DEFAULT_NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        read -p "고정할 노드 이름 입력 [기본값: ${DEFAULT_NODE}]: " INPUT_NODE
        TARGET_NODE_NAME="${INPUT_NODE:-$DEFAULT_NODE}"
    fi

    echo ""
    read -p "로컬 개발 환경을 위해 리소스 사용량(CPU/Memory 제한)을 최소화하시겠습니까? (y/N): " _MIN_RES
    if [[ "$_MIN_RES" =~ ^[yY]$ ]]; then
        MINIMIZE_RESOURCES="true"
    else
        MINIMIZE_RESOURCES="false"
    fi

    echo ""
    echo "스토리지 타입을 선택하세요:"
    echo "  1) HostPath (특정 단일 노드 디렉토리를 정적 PV로 사용)"
    echo "  2) NFS 정적 할당 (NFS 서버/경로를 정적 PV로 사용)"
    echo "  3) NFS SC 동적 할당 (StorageClass 기반 동적 프로비저닝)"
    read -p "선택 [1/2/3, 기본 1]: " STORAGE_CHOICE
    STORAGE_CHOICE="${STORAGE_CHOICE:-1}"

    STORAGE_SIZE="${STORAGE_SIZE:-50Gi}"
    read -p "Registry 이미지 저장용량 크기 지정 [${STORAGE_SIZE}]: " USER_STORAGE_SIZE
    STORAGE_SIZE="${USER_STORAGE_SIZE:-$STORAGE_SIZE}"

    case "$STORAGE_CHOICE" in
        1)
            STORAGE_MODE="hostpath"
            NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
            SAVE_PATH="${SAVE_PATH:-/data/harbor}"
            read -p "호스트 저장 절대 경로 [${SAVE_PATH}]: " USER_SAVE_PATH
            SAVE_PATH="${USER_SAVE_PATH:-$SAVE_PATH}"
            read -p "PV를 핀할 노드 이름 [${NODE_NAME}]: " USER_NODE_NAME
            NODE_NAME="${USER_NODE_NAME:-$NODE_NAME}"
            if [ -z "$NODE_NAME" ]; then echo "오류: 노드 이름이 필요합니다."; exit 1; fi
            ;;
        2)
            STORAGE_MODE="nfs"
            read -p "NFS 서버 주소 (예: 192.168.1.100): " NFS_SERVER
            if [ -z "$NFS_SERVER" ]; then echo "오류: NFS 서버 주소는 필수입니다."; exit 1; fi
            read -p "NFS 익스포트 경로 (예: /nfs/harbor): " NFS_PATH
            if [ -z "$NFS_PATH" ]; then echo "오류: NFS 경로는 필수입니다."; exit 1; fi
            ;;
        3)
            STORAGE_MODE="nfs-dynamic"
            DATABASE_SIZE="${DATABASE_SIZE:-5Gi}"
            REDIS_SIZE="${REDIS_SIZE:-1Gi}"
            JOBLOG_SIZE="${JOBLOG_SIZE:-1Gi}"
            TRIVY_SIZE="${TRIVY_SIZE:-5Gi}"
            read -p "Database 용량  [${DATABASE_SIZE}]: " _DB; DATABASE_SIZE="${_DB:-$DATABASE_SIZE}"
            read -p "Redis 용량     [${REDIS_SIZE}]: " _RD; REDIS_SIZE="${_RD:-$REDIS_SIZE}"
            read -p "JobService 로그 [${JOBLOG_SIZE}]: " _JL; JOBLOG_SIZE="${_JL:-$JOBLOG_SIZE}"
            read -p "Trivy 스캔 용량 [${TRIVY_SIZE}]: " _TV; TRIVY_SIZE="${_TV:-$TRIVY_SIZE}"
            
            echo ""
            kubectl get sc || echo "(StorageClass 조회 실패)"
            read -p "사용할 StorageClass 이름 [nfs-client]: " USER_STORAGE_CLASS
            STORAGE_CLASS="${USER_STORAGE_CLASS:-nfs-client}"
            ;;
    esac
fi

# ==========================================
# [3] 관리자 비밀번호 수집 및 업그레이드 복원
# ==========================================
if [ "$DO_UPGRADE" == "true" ]; then
    echo "🔐 기존 Harbor Secret에서 admin 비밀번호 복원 시도 중..."
    ADMIN_PASSWORD=$(kubectl get secret -n "$HARBOR_NAMESPACE" harbor-core -o jsonpath="{.data.harborAdminPassword}" | base64 -d 2>/dev/null || \
                     kubectl get secret -n "$HARBOR_NAMESPACE" harbor-harbor-core -o jsonpath="{.data.harborAdminPassword}" | base64 -d 2>/dev/null || \
                     echo "")
    if [ -z "$ADMIN_PASSWORD" ]; then
        echo -e "${YELLOW}⚠️  기존 비밀번호를 K8s Secret에서 가져오지 못했습니다.${NC}"
        read -sp "Harbor admin 비밀번호를 다시 입력해 주세요: " ADMIN_PASSWORD
        echo
    else
        echo "✅ 비밀번호가 K8s Secret에서 성공적으로 자동 복원되었습니다."
    fi
else
    while true; do
        read -sp "Harbor 관리자('admin') 신규 비밀번호 입력 (최소 8자): " ADMIN_PASSWORD
        echo
        read -sp "비밀번호 확인 입력: " ADMIN_PASSWORD_CONFIRM
        echo
        if [ -z "$ADMIN_PASSWORD" ] || [ ${#ADMIN_PASSWORD} -lt 8 ] || [ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]; then
            echo -e "${RED}❌ 비밀번호 조건이 맞지 않거나 일치하지 않습니다. 다시 입력하십시오.${NC}"
        else
            break
        fi
    done
fi

save_conf

# ==========================================
# [4] YAML 및 볼륨 매니페스트 동기화
# ==========================================
echo -e "🔧 ${GREEN}설정 파일(values-infra.yaml, persistence) 생성 중...${NC}"

if [ "$STORAGE_MODE" == "hostpath" ]; then
    cat > "$PV_PVC_FILE" <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${PV_NAME}
spec:
  capacity:
    storage: ${STORAGE_SIZE}
  volumeMode: Filesystem
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: harbor-hostpath-sc
  hostPath:
    path: ${SAVE_PATH}
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - "${NODE_NAME}"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${HARBOR_NAMESPACE}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: harbor-hostpath-sc
  resources:
    requests:
      storage: ${STORAGE_SIZE}
EOF
elif [ "$STORAGE_MODE" == "nfs" ]; then
    cat > "$PV_PVC_FILE" <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${PV_NAME}
spec:
  capacity:
    storage: ${STORAGE_SIZE}
  volumeMode: Filesystem
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: harbor-nfs-sc
  nfs:
    server: ${NFS_SERVER}
    path: ${NFS_PATH}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${HARBOR_NAMESPACE}
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: harbor-nfs-sc
  resources:
    requests:
      storage: ${STORAGE_SIZE}
EOF
fi

COMPONENTS_OVERRIDE_BLOCK=""
for COMP in nginx portal core jobservice registry trivy exporter; do
    COMP_SCHED=""
    if [ -n "$TARGET_NODE_NAME" ]; then
        COMP_SCHED="${COMP_SCHED}  nodeSelector:
    kubernetes.io/hostname: \"${TARGET_NODE_NAME}\"
"
    fi
    if [ "$ENABLE_CP_TOLERATIONS" == "true" ]; then
        COMP_SCHED="${COMP_SCHED}  tolerations:
    - key: \"node-role.kubernetes.io/control-plane\"
      operator: \"Exists\"
      effect: \"NoSchedule\"
    - key: \"node-role.kubernetes.io/master\"
      operator: \"Exists\"
      effect: \"NoSchedule\"
"
    fi

    COMP_RES=""
    if [ "$MINIMIZE_RESOURCES" == "true" ]; then
        REQ_CPU="50m"
        REQ_MEM="128Mi"
        LIM_CPU="500m"
        LIM_MEM="512Mi"
        if [ "$COMP" == "nginx" ] || [ "$COMP" == "portal" ]; then
            REQ_MEM="64Mi"
            LIM_CPU="200m"
            LIM_MEM="256Mi"
        elif [ "$COMP" == "jobservice" ]; then
            LIM_CPU="200m"
            LIM_MEM="256Mi"
        fi
        COMP_RES="  resources:
    requests:
      cpu: ${REQ_CPU}
      memory: ${REQ_MEM}
    limits:
      cpu: ${LIM_CPU}
      memory: ${LIM_MEM}
"
    fi

    if [ -n "$COMP_SCHED" ] || [ -n "$COMP_RES" ]; then
        COMPONENTS_OVERRIDE_BLOCK="${COMPONENTS_OVERRIDE_BLOCK}
${COMP}:
${COMP_SCHED}${COMP_RES}"
    fi
done

for COMP in database redis; do
    COMP_SCHED=""
    if [ -n "$TARGET_NODE_NAME" ]; then
        COMP_SCHED="${COMP_SCHED}    nodeSelector:
      kubernetes.io/hostname: \"${TARGET_NODE_NAME}\"
"
    fi
    if [ "$ENABLE_CP_TOLERATIONS" == "true" ]; then
        COMP_SCHED="${COMP_SCHED}    tolerations:
      - key: \"node-role.kubernetes.io/control-plane\"
        operator: \"Exists\"
        effect: \"NoSchedule\"
      - key: \"node-role.kubernetes.io/master\"
        operator: \"Exists\"
        effect: \"NoSchedule\"
"
    fi

    COMP_RES=""
    if [ "$MINIMIZE_RESOURCES" == "true" ]; then
        REQ_CPU="50m"
        REQ_MEM="128Mi"
        LIM_CPU="200m"
        LIM_MEM="512Mi"
        if [ "$COMP" == "redis" ]; then
            REQ_MEM="64Mi"
            LIM_CPU="100m"
            LIM_MEM="128Mi"
        elif [ "$COMP" == "database" ]; then
            LIM_MEM="512Mi"
        fi
        COMP_RES="    resources:
      requests:
        cpu: ${REQ_CPU}
        memory: ${REQ_MEM}
      limits:
        cpu: ${LIM_CPU}
        memory: ${LIM_MEM}
"
    fi

    if [ -n "$COMP_SCHED" ] || [ -n "$COMP_RES" ]; then
        COMPONENTS_OVERRIDE_BLOCK="${COMPONENTS_OVERRIDE_BLOCK}
${COMP}:
  internal:
${COMP_SCHED}${COMP_RES}"
    fi
done

TLS_CERT_SOURCE="none"
if [ "$TLS_ENABLED" == "true" ]; then
    TLS_CERT_SOURCE="secret"
fi

PERSISTENCE_CONFIG=""
if [ "$STORAGE_MODE" == "nfs-dynamic" ]; then
    PERSISTENCE_CONFIG="persistence:
  enabled: true
  resourcePolicy: \"keep\"
  persistentVolumeClaim:
    registry:
      storageClass: \"${STORAGE_CLASS}\"
      subPath: registry
      size: ${STORAGE_SIZE}
    database:
      storageClass: \"${STORAGE_CLASS}\"
      subPath: database
      size: ${DATABASE_SIZE}
    jobservice:
      jobLog:
        storageClass: \"${STORAGE_CLASS}\"
        subPath: jobservice-logs
        size: ${JOBLOG_SIZE}
    redis:
      storageClass: \"${STORAGE_CLASS}\"
      subPath: redis
      size: ${REDIS_SIZE}
    trivy:
      storageClass: \"${STORAGE_CLASS}\"
      subPath: trivy
      size: ${TRIVY_SIZE}"
else
    PERSISTENCE_CONFIG="persistence:
  enabled: true
  resourcePolicy: \"keep\"
  persistentVolumeClaim:
    registry:
      existingClaim: \"${PVC_NAME}\"
      subPath: registry
    database:
      existingClaim: \"${PVC_NAME}\"
      subPath: database
    jobservice:
      jobLog:
        existingClaim: \"${PVC_NAME}\"
        subPath: jobservice-logs
    redis:
      existingClaim: \"${PVC_NAME}\"
      subPath: redis
    trivy:
      existingClaim: \"${PVC_NAME}\"
      subPath: trivy"
fi

cat > ./values-infra.yaml <<EOF
# Harbor 2.10.3 인프라 설정 — install.sh 에 의해 자동 관리됩니다.
externalURL: ${EXTERNAL_URL}

expose:
  type: ${EXPOSE_TYPE}
  nodePort:
    name: harbor
    ports:
      http:
        port: 80
        nodePort: ${HTTP_NODEPORT}
      https:
        port: 443
        nodePort: ${HTTPS_NODEPORT}
  tls:
    enabled: ${TLS_ENABLED}
    certSource: ${TLS_CERT_SOURCE}
    secret:
      secretName: "${TLS_SECRET_NAME}"

${PERSISTENCE_CONFIG}

${COMPONENTS_OVERRIDE_BLOCK}
EOF

# ==========================================
# [5] K8s 볼륨 배포 및 Helm 설치 진행
# ==========================================
echo ""
echo -e "🚀 ${GREEN}[1/2] K8s 네임스페이스 및 볼륨 리소스 적용 중...${NC}"
kubectl create namespace "$HARBOR_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if [ "$STORAGE_MODE" != "nfs-dynamic" ]; then
    kubectl apply -f "$PV_PVC_FILE"
fi

echo ""
echo -e "🚀 ${GREEN}[2/2] Harbor Helm 차트 릴리스 배포 중... (${DO_UPGRADE:+업그레이드}${DO_UPGRADE:-설치})${NC}"
helm upgrade --install "$HARBOR_RELEASE_NAME" "$HELM_CHART_PATH" \
    --namespace "$HARBOR_NAMESPACE" \
    -f ./values.yaml \
    -f ./values-infra.yaml \
    --set harborAdminPassword="${ADMIN_PASSWORD}" \
    --atomic \
    --wait

echo ""
echo "================================================================"
echo " Harbor 설치가 완료되었습니다!"
echo "================================================================"

if [[ "$EXPOSE_TYPE" == "nodePort" && "$EXPOSE_CHOICE" == "1" ]]; then
    echo " Harbor UI 접속 주소 (Envoy): ${PROTOCOL}://${EXTERNAL_HOSTNAME}"
    if [ -n "$NODE_NAME" ]; then
        NODE_IP=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
        [ -n "$NODE_IP" ] && echo " Harbor NodePort 직접 접속:   http://${NODE_IP}:30002"
    fi
    echo ""
    echo " Envoy HTTPRoute 설정:"
    echo "   kubectl apply -f manifests/route-harbor.yaml"
    echo "   (route-harbor.yaml의 hostnames를 '${EXTERNAL_HOSTNAME}'으로 수정 후 적용)"
elif [ "$EXPOSE_TYPE" = "nodePort" ]; then
    if [ -n "$NODE_NAME" ]; then
        NODE_IP=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
        [ -n "$NODE_IP" ] && echo " Harbor UI 접속 주소 (HTTP):  http://${NODE_IP}:30002"
    else
        echo " Harbor UI 접속 주소 (HTTP):  http://${EXTERNAL_HOSTNAME}:30002"
    fi
else
    echo " Harbor UI 접속 주소: ${PROTOCOL}://${EXTERNAL_HOSTNAME}"
fi

echo " 사용자명: admin"
echo " 비밀번호: (설치 시 입력한 비밀번호)"
echo "================================================================"

if [[ "$TLS_ENABLED" != "true" ]]; then
    echo ""
    echo "⚠️  [필수] Insecure Registry 등록 (TLS 미사용 시)"
    echo "  HTTP로 Harbor를 사용하려면 모든 K8s 노드에서 containerd에"
    echo "  insecure registry를 등록해야 이미지 push/pull이 가능합니다."
    echo ""
    echo "  sudo ./scripts/insecurity_registry_add.sh"
    echo ""
    echo "  이 스크립트는 아래 작업을 자동 수행합니다:"
    echo "    1) /etc/containerd/config.toml에 config_path 설정 추가"
    echo "    2) /etc/containerd/certs.d/<주소>/hosts.toml 생성"
    echo "    3) containerd 재시작"
    echo "================================================================"
fi
echo ""
