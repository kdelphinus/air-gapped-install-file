#!/bin/bash

# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1


# ==========================================
# [설정] 기본 변수
# ==========================================
NAMESPACE="argocd"
CHART_PATH="./charts/argo-cd"
CONF_FILE="./install.conf"
NAS_PV_FILE="./manifests/nas-pv.yaml"



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
# ArgoCD 3.4.3 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
STORAGE_TYPE="${STORAGE_TYPE}"
SVC_TYPE="${SVC_TYPE}"
TLS_ENABLED="${TLS_ENABLED}"
REDIS_HA_ENABLED="${REDIS_HA_ENABLED}"
DOMAIN="${DOMAIN}"
NODE_PORT="${NODE_PORT}"
REDIS_SIZE="${REDIS_SIZE}"
REPO_SIZE="${REPO_SIZE}"
NAS_SERVER="${NAS_SERVER}"
NAS_REDIS_PATH="${NAS_REDIS_PATH}"
NAS_REPO_PATH="${NAS_REPO_PATH}"
STORAGE_CLASS="${STORAGE_CLASS}"
HOSTPATH_REDIS="${HOSTPATH_REDIS}"
HOSTPATH_REPO="${HOSTPATH_REPO}"
TARGET_NODE="${TARGET_NODE}"
INSTALLED_VERSION="v3.4.3"
EOF
    echo -e "  ✅ 설정이 ${GREEN}${CONF_FILE}${NC} 에 저장되었습니다."
}

# ==========================================
# [함수] 클린업 로직
# ==========================================
function cleanup_resources() {
  local RESET_MODE=$1 # "reset" 이면 install.conf 도 삭제
  echo ""
  echo -e "🧹 ${YELLOW}[Clean Up] 기존 ArgoCD 리소스 제거 시작...${NC}"

  # Helm Uninstall
  if helm status argocd -n $NAMESPACE >/dev/null 2>&1; then
      echo "⏳ Helm 차트 삭제 중..."
      helm uninstall argocd -n $NAMESPACE --wait=false 2>/dev/null
      sleep 3
  fi

  # PVC 삭제
  echo "🗑️  ArgoCD PVC 삭제 중..."
  kubectl delete pvc -n $NAMESPACE argocd-redis-pvc argocd-repo-pvc --timeout=10s --wait=false 2>/dev/null

  # Static PV 삭제
  echo "🗑️  ArgoCD PV 삭제 중..."
  kubectl delete pv argocd-redis-pv argocd-repo-pv --timeout=10s --wait=false 2>/dev/null

  # 네임스페이스 삭제
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
EXIST_HELM=$(helm status argocd -n $NAMESPACE > /dev/null 2>&1 && echo "yes" || echo "no")
DO_UPGRADE=false

if [ "$EXIST_HELM" == "yes" ] || [ -f "$CONF_FILE" ]; then
    echo ""
    echo -e "⚠️  ${YELLOW}기존 설치 또는 설정이 감지되었습니다.${NC}"
    [ -f "$CONF_FILE" ] && echo "  📋 저장된 설정 정보:"
    [ -n "$IMAGE_SOURCE" ] && echo "     - 이미지 소스  : $IMAGE_SOURCE"
    [ -n "$STORAGE_TYPE" ] && echo "     - 스토리지 타입: $STORAGE_TYPE"
    [ -n "$SVC_TYPE" ] && echo "     - 서비스 노출  : $SVC_TYPE"
    [ "$SVC_TYPE" == "NodePort" ] && [ -n "$NODE_PORT" ] && echo "     - NodePort 포트 : $NODE_PORT"
    [ -n "$DOMAIN" ] && echo "     - 도메인 주소  : $DOMAIN"
    [ -n "$REDIS_HA_ENABLED" ] && echo "     - Redis HA 활성: $REDIS_HA_ENABLED"
    [ -n "$TARGET_NODE" ] && echo "     - 노드 고정 배치: $TARGET_NODE"

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
    echo "  1) 사용 안 함 (none - 재시작 시 캐시/데이터가 유실됨)"
    echo "  2) HostPath   (특정 노드 디렉토리 지정)"
    echo "  3) NFS NAS    (정적 PV / PVC 구성)"
    echo "  4) Dynamic    (StorageClass 기반 동적 프로비저닝)"
    read -p "선택 [1/2/3/4, 기본값 2]: " _STORAGE_SEL
    _STORAGE_SEL="${_STORAGE_SEL:-2}"

    case "$_STORAGE_SEL" in
        1) STORAGE_TYPE="none" ;;
        2) 
            STORAGE_TYPE="hostpath"
            read -p "HostPath - Redis 데이터 경로 (기본 /var/lib/argocd/redis): " HOSTPATH_REDIS
            HOSTPATH_REDIS="${HOSTPATH_REDIS:-/var/lib/argocd/redis}"
            read -p "HostPath - Repository 캐시 경로 (기본 /var/lib/argocd/repo): " HOSTPATH_REPO
            HOSTPATH_REPO="${HOSTPATH_REPO:-/var/lib/argocd/repo}"
            ;;
        3) 
            STORAGE_TYPE="nas"
            read -p "NFS 서버 IP (예: 192.168.1.100): " NAS_SERVER
            read -p "NFS Redis 마운트 디렉토리 경로 (예: /nas/argocd/redis): " NAS_REDIS_PATH
            read -p "NFS Repo 마운트 디렉토리 경로 (예: /nas/argocd/repo): " NAS_REPO_PATH
            read -p "Redis 볼륨 크기 (기본 8Gi): " REDIS_SIZE
            REDIS_SIZE="${REDIS_SIZE:-8Gi}"
            read -p "Repo 볼륨 크기 (기본 10Gi): " REPO_SIZE
            REPO_SIZE="${REPO_SIZE:-10Gi}"
            ;;
        4) 
            STORAGE_TYPE="nfs-dynamic"
            read -p "StorageClass 이름 입력 (예: nfs-client): " STORAGE_CLASS
            read -p "Redis 볼륨 크기 (기본 8Gi): " REDIS_SIZE
            REDIS_SIZE="${REDIS_SIZE:-8Gi}"
            read -p "Repo 볼륨 크기 (기본 10Gi): " REPO_SIZE
            REPO_SIZE="${REPO_SIZE:-10Gi}"
            ;;
    esac

    # 2-3. 서비스 타입 및 도메인 설정
    echo ""
    echo "ArgoCD Server 노출 방식을 선택하세요:"
    echo "  1) ClusterIP    (Envoy Gateway 또는 Ingress 연동 권장)"
    echo "  2) NodePort     (독립 노출)"
    read -p "선택 [1/2, 기본값 2]: " _SVC_SEL
    if [ "${_SVC_SEL:-2}" == "1" ]; then
        SVC_TYPE="ClusterIP"
    else
        SVC_TYPE="NodePort"
        read -p "ArgoCD Server NodePort 포트 지정 (기본 30001): " NODE_PORT
        NODE_PORT="${NODE_PORT:-30001}"
    fi

    # TLS 활성화 여부
    read -p "TLS(HTTPS) 접속을 활성화하시겠습니까? (y/n, 기본값 y): " _TLS_YN
    if [[ "${_TLS_YN:-y}" =~ ^[Yy]$ ]]; then
        TLS_ENABLED="true"
    else
        TLS_ENABLED="false"
    fi

    # 도메인 입력
    read -p "ArgoCD 접속 도메인 (기본: argocd.devops.internal): " DOMAIN
    DOMAIN="${DOMAIN:-argocd.devops.internal}"

    # 2-4. 노드 고정 배치 지정
    echo ""
    kubectl get nodes -o wide
    read -p "ArgoCD를 고정 배치할 노드 이름 (없으면 비워둠): " TARGET_NODE

    # 2-5. Redis HA (Sentinel) 활성화 여부
    echo ""
    read -p "Redis HA (Sentinel 고가용성) 구성을 활성화하시겠습니까? (y/n, 기본 n): " _HA_YN
    if [[ "${_HA_YN:-n}" =~ ^[Yy]$ ]]; then
        REDIS_HA_ENABLED="true"
    else
        REDIS_HA_ENABLED="false"
    fi
fi

save_conf

# ==========================================
# [3] YAML 동기화 (Single Source of Truth)
# ==========================================
echo ""
echo "🔧 설정 파일(values.yaml, values-infra.yaml) 업데이트 중..."

# 1. values.yaml 원본 백업 및 복사 처리
if [ ! -f "./values.yaml.orig" ]; then
    cp -f ./values.yaml ./values.yaml.orig
    echo "   → 원본 values.yaml 백업 생성 완료 (values.yaml.orig)"
fi
cp -f ./values.yaml.orig ./values.yaml

# 2. 이미지 소스에 따른 values.yaml 치환 및 values-infra.yaml 초기화
if [ "${IMAGE_SOURCE}" = "harbor" ]; then
    # Harbor 사용 시 values.yaml 내의 플레이스홀더 치환
    sed -i \
        -e "s|<HARBOR_REGISTRY>|${HARBOR_REGISTRY}|g" \
        -e "s|<HARBOR_PROJECT>|${HARBOR_PROJECT}|g" \
        ./values.yaml
fi

# 3. values-infra.yaml 생성 시작
PROTOCOL="http"
SERVER_INSECURE="true"
if [ "$TLS_ENABLED" == "true" ]; then
    PROTOCOL="https"
    SERVER_INSECURE="false"
fi
ARGOCD_URL="${PROTOCOL}://${DOMAIN}"

# 3-1. global 설정 조립 (노드 고정 및 로컬 이미지)
GLOBAL_CONTENT=""
if [ -n "$TARGET_NODE" ] || [ "${IMAGE_SOURCE}" = "local" ]; then
    GLOBAL_CONTENT="global:"
    if [ -n "$TARGET_NODE" ]; then
        GLOBAL_CONTENT="${GLOBAL_CONTENT}
  nodeSelector:
    kubernetes.io/os: linux
    kubernetes.io/hostname: \"${TARGET_NODE}\""
    fi
    if [ "${IMAGE_SOURCE}" = "local" ]; then
        GLOBAL_CONTENT="${GLOBAL_CONTENT}
  image:
    repository: quay.io/argoproj/argocd"
    fi
fi

# 3-2. redis 활성화 상태 및 이미지 오버라이드 조립
REDIS_EN_VAL="true"
REDIS_HA_VAL="false"
if [ "$REDIS_HA_ENABLED" == "true" ]; then
    REDIS_EN_VAL="false"
    REDIS_HA_VAL="true"
fi

REDIS_VOLUMES="[]"
REDIS_MOUNTS="[]"
REPO_VOLUMES="[]"
REPO_MOUNTS="[]"

if [ "$STORAGE_TYPE" == "hostpath" ]; then
    REDIS_VOLUMES="[{\"name\":\"redis-data\",\"hostPath\":{\"path\":\"${HOSTPATH_REDIS}\",\"type\":\"DirectoryOrCreate\"}}]"
    REDIS_MOUNTS="[{\"name\":\"redis-data\",\"mountPath\":\"/data\"}]"
    REPO_VOLUMES="[{\"name\":\"argocd-repo-cache\",\"hostPath\":{\"path\":\"${HOSTPATH_REPO}\",\"type\":\"DirectoryOrCreate\"}}]"
    REPO_MOUNTS="[{\"name\":\"argocd-repo-cache\",\"mountPath\":\"/home/argocd/cmp-server/cache\"}]"
elif [ "$STORAGE_TYPE" == "nas" ] || [ "$STORAGE_TYPE" == "nfs-dynamic" ]; then
    REDIS_VOLUMES="[{\"name\":\"redis-data\",\"persistentVolumeClaim\":{\"claimName\":\"argocd-redis-pvc\"}}]"
    REDIS_MOUNTS="[{\"name\":\"redis-data\",\"mountPath\":\"/data\"}]"
    REPO_VOLUMES="[{\"name\":\"argocd-repo-cache\",\"persistentVolumeClaim\":{\"claimName\":\"argocd-repo-pvc\"}}]"
    REPO_MOUNTS="[{\"name\":\"argocd-repo-cache\",\"mountPath\":\"/home/argocd/cmp-server/cache\"}]"
fi

# 로컬 이미지 모드일 때 redis 및 기타 컴포넌트 오버라이드 준비
REDIS_IMAGE_OVERRIDE=""
DEX_IMAGE_OVERRIDE=""
REDIS_HA_IMAGE_OVERRIDE=""
NOTI_IMAGE_OVERRIDE=""

if [ "${IMAGE_SOURCE}" = "local" ]; then
    REDIS_IMAGE_OVERRIDE="  image:
    repository: ecr-public.aws.com/docker/library/redis
  metrics:
    image:
      repository: ghcr.io/oliver006/redis_exporter"

    DEX_IMAGE_OVERRIDE="dex:
  image:
    repository: ghcr.io/dexidp/dex"

    REDIS_HA_IMAGE_OVERRIDE="redis-ha:
  haproxy:
    image:
      repository: ecr-public.aws.com/docker/library/haproxy"

    NOTI_IMAGE_OVERRIDE="notifications:
  argocdExtensionInstaller:
    image:
      repository: quay.io/argoprojlabs/argocd-extension-installer"
fi

# NodePort 설정 시 포트 상세 매핑
NODE_PORT_HTTP="null"
NODE_PORT_HTTPS="null"
if [ "$SVC_TYPE" == "NodePort" ]; then
    if [ "$TLS_ENABLED" == "true" ]; then
        NODE_PORT_HTTPS="${NODE_PORT}"
    else
        NODE_PORT_HTTP="${NODE_PORT}"
    fi
fi

# 3-3. 단일 values-infra.yaml 작성 (중복 최상위 키 제거)
cat > ./values-infra.yaml <<EOF
# ArgoCD 3.4.3 인프라 및 가변 설정 — install.sh 에 의해 자동 관리됩니다.
${GLOBAL_CONTENT}

configs:
  cm:
    url: "${ARGOCD_URL}"
  params:
    server.insecure: "${SERVER_INSECURE}"

server:
  service:
    type: "${SVC_TYPE}"
    nodePortHttp: ${NODE_PORT_HTTP}
    nodePortHttps: ${NODE_PORT_HTTPS}

redis:
  enabled: ${REDIS_EN_VAL}
  volumes: ${REDIS_VOLUMES}
  volumeMounts: ${REDIS_MOUNTS}
${REDIS_IMAGE_OVERRIDE}

redis-ha:
  enabled: ${REDIS_HA_VAL}
${REDIS_HA_IMAGE_OVERRIDE}

repoServer:
  volumes: ${REPO_VOLUMES}
  volumeMounts: ${REPO_MOUNTS}

${DEX_IMAGE_OVERRIDE}
${NOTI_IMAGE_OVERRIDE}
EOF

# ==========================================
# [4] Kubernetes 리소스 준비 및 설치
# ==========================================
echo ""
echo "🚀 [1/3] Kubernetes 네임스페이스 및 스토리지 구성 중..."

# 네임스페이스 생성
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Static NAS PV/PVC 생성
if [ "$STORAGE_TYPE" == "nas" ]; then
    echo "   → NFS NAS 정적 PV/PVC 매니페스트 배포..."
    sed \
        -e "s|192.168.1.100|${NAS_SERVER}|g" \
        -e "s|/nas/argocd/redis|${NAS_REDIS_PATH}|g" \
        -e "s|/nas/argocd/repo|${NAS_REPO_PATH}|g" \
        -e "s|<REDIS_SIZE>|${REDIS_SIZE}|g" \
        -e "s|<REPO_SIZE>|${REPO_SIZE}|g" \
        "$NAS_PV_FILE" | kubectl apply -n $NAMESPACE -f -

# Dynamic StorageClass PVC 생성
elif [ "$STORAGE_TYPE" == "nfs-dynamic" ]; then
    echo "   → StorageClass(${STORAGE_CLASS}) 동적 PVC 리소스 배포..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: argocd-redis-pvc
  namespace: ${NAMESPACE}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: "${STORAGE_CLASS}"
  resources:
    requests:
      storage: ${REDIS_SIZE}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: argocd-repo-pvc
  namespace: ${NAMESPACE}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: "${STORAGE_CLASS}"
  resources:
    requests:
      storage: ${REPO_SIZE}
EOF
fi

# 3. CRD 우선 적용
echo ""
echo "🚀 [2/3] CRD(Custom Resource Definitions) 사전 적용 중..."
kubectl apply -f ${CHART_PATH}/templates/crds/ -n $NAMESPACE

# 4. Helm 배포
echo ""
echo -e "🚀 [3/3] ArgoCD Helm 차트 배포 중... (${DO_UPGRADE:+업그레이드}${DO_UPGRADE:-설치})"
if [ -d "$CHART_PATH" ]; then
    helm upgrade --install argocd "$CHART_PATH" \
        -n "$NAMESPACE" \
        -f ./values.yaml \
        -f ./values-infra.yaml
else
    echo -e "${RED}[오류] Helm 차트 디렉토리('${CHART_PATH}')가 존재하지 않습니다.${NC}"
    exit 1
fi

echo ""
echo "========================================================"
echo -e "🎉 구성 완료! (ArgoCD v3.4.3 / Chart v9.5.21)"
echo "설정 파일 : $CONF_FILE"
echo "도메인    : $PROTOCOL://$DOMAIN"
if [ "$SVC_TYPE" == "NodePort" ]; then
    echo "접속 포트 : ${NODE_PORT} (NodePort)"
else
    echo "노출 방식 : ClusterIP (Envoy HTTPRoute 수동 적용 필요)"
    echo "HTTPRoute 적용:"
    echo "  sed \"s|argocd.devops.internal|${DOMAIN}|g\" ./manifests/argocd-httproute.yaml | kubectl apply -f -"
    echo "  kubectl get httproute argocd-route -n ${NAMESPACE}"
fi
echo "========================================================"
echo "⏳ 초기 관리자(admin) 비밀번호 확인 방법:"
echo "👉 kubectl -n $NAMESPACE get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d"
echo ""
kubectl get pods -n $NAMESPACE
