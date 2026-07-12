#!/bin/bash
# ---------------------------------------------------------
# ArgoCD Installation Script
# [Chart Version] 7.4.1 (argo-cd)
# [App Version] v2.12.0
# [Image Version] v2.12.1
# [Target] Rocky Linux / Ubuntu (Online/Offline)
# ---------------------------------------------------------
set -e

# 스크립트 위치 기준으로 컴포넌트 루트로 이동
COMPONENT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$COMPONENT_ROOT" || exit 1

# 기본 변수
RELEASE_NAME="argocd"
NAMESPACE="argocd"
CHART_PATH="./charts/argo-cd"
CONF_FILE="./install.conf"

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
# ArgoCD 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
STORAGE_TYPE="${STORAGE_TYPE}"
HOSTPATH_REDIS="${HOSTPATH_REDIS}"
HOSTPATH_REPO="${HOSTPATH_REPO}"
NAS_SERVER="${NAS_SERVER}"
NAS_REDIS_PATH="${NAS_REDIS_PATH}"
NAS_REPO_PATH="${NAS_REPO_PATH}"
STORAGE_CLASS="${STORAGE_CLASS}"
REDIS_SIZE="${REDIS_SIZE}"
REPO_SIZE="${REPO_SIZE}"
NODEPORT="${NODEPORT}"
DOMAIN="${DOMAIN}"
TLS_ENABLED="${TLS_ENABLED}"
GATEWAY_NAME="${GATEWAY_NAME}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE}"
INSTALLED_CHART_VERSION="7.4.1"
INSTALLED_APP_VERSION="v2.12.0"
EOF
    echo -e "  ✅ 설정이 ${GREEN}${CONF_FILE}${NC} 에 저장되었습니다."
}

save_values_infra() {
    local PROTOCOL="http"
    [ "${TLS_ENABLED}" = "true" ] && PROTOCOL="https"

    # 기본 이미지 주소 (Local 모드 대비)
    local ARGOCD_REPO="quay.io/argoproj/argocd"
    local REDIS_REPO="public.ecr.aws/docker/library/redis"
    local HAPROXY_REPO="public.ecr.aws/docker/library/haproxy"

    if [ "${IMAGE_SOURCE}" = "harbor" ] || [ "${IMAGE_SOURCE}" = "1" ]; then
        ARGOCD_REPO="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/argocd"
        REDIS_REPO="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/redis"
        HAPROXY_REPO="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/haproxy"
    fi

    # values-infra.yaml 작성 시작
    cat > "values-infra.yaml" <<EOF
# ArgoCD 인프라 설정 — install.sh 에 의해 자동 생성됩니다.
global:
  image:
    repository: "${ARGOCD_REPO}"
server:
  image:
    repository: "${ARGOCD_REPO}"
repoServer:
  image:
    repository: "${ARGOCD_REPO}"
controller:
  image:
    repository: "${ARGOCD_REPO}"
applicationSet:
  image:
    repository: "${ARGOCD_REPO}"
notifications:
  image:
    repository: "${ARGOCD_REPO}"
redis:
  image:
    repository: "${REDIS_REPO}"
haproxy:
  image:
    repository: "${HAPROXY_REPO}"
configs:
  cm:
    url: "${PROTOCOL}://${DOMAIN}"
EOF

    # 볼륨 오버라이드 작성
    if [ "${STORAGE_TYPE}" = "nas" ] || [ "${STORAGE_TYPE}" = "nfs-dynamic" ]; then
        cat >> "values-infra.yaml" <<EOF
repoServer:
  volumes:
    - name: argocd-repo-cache
      persistentVolumeClaim:
        claimName: argocd-repo-pvc
  volumeMounts:
    - name: argocd-repo-cache
      mountPath: /home/argocd/cmp-server/cache
redis:
  volumes:
    - name: redis-data
      persistentVolumeClaim:
        claimName: argocd-redis-pvc
  volumeMounts:
    - name: redis-data
      mountPath: /data
EOF
    elif [ "${STORAGE_TYPE}" = "hostpath" ]; then
        cat >> "values-infra.yaml" <<EOF
repoServer:
  volumes:
    - name: argocd-repo-cache
      hostPath:
        path: "${HOSTPATH_REPO}"
        type: DirectoryOrCreate
  volumeMounts:
    - name: argocd-repo-cache
      mountPath: /home/argocd/cmp-server/cache
redis:
  volumes:
    - name: redis-data
      hostPath:
        path: "${HOSTPATH_REDIS}"
        type: DirectoryOrCreate
  volumeMounts:
    - name: redis-data
      mountPath: /data
EOF
    fi

    echo -e "  ✅ 인프라 값이 ${GREEN}values-infra.yaml${NC} 에 저장되었습니다."
}

add_coredns_host() {
    local ip="$1"
    local domain="$2"
    if kubectl get configmap coredns -n kube-system \
            -o jsonpath='{.data.NodeHosts}' 2>/dev/null | grep -qw "$domain"; then
        echo "  - CoreDNS: ${domain} 이미 등록됨, 건너뜁니다."
        return 0
    fi
    local current_hosts
    current_hosts=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.NodeHosts}' 2>/dev/null || echo "")
    local new_hosts
    new_hosts="${current_hosts}
${ip} ${domain}"
    kubectl get configmap coredns -n kube-system -o json 2>/dev/null \
        | jq --arg h "${new_hosts}" '.data.NodeHosts = $h' \
        | kubectl apply -f - 2>/dev/null || true
    echo "  - CoreDNS: ${ip} ${domain} 등록 시도 완료 (CoreDNS configmap 갱신)"
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}[오류] '$1' 명령어를 찾을 수 없습니다.${NC}"
        exit 1
    fi
}

cleanup_resources() {
    local RESET_MODE=$1
    echo ""
    echo -e "🧹 ${YELLOW}[Clean Up] 기존 ArgoCD 리소스 제거 시작...${NC}"

    # 2차 정밀 y/N 프롬프트 데이터 소거 확인
    if [ "${RESET_MODE}" == "reset" ]; then
        echo -e "${RED}⚠️  [주의] 초기화 선택 시 네임스페이스 '${NAMESPACE}' 및 모든 설정 파일이 완전히 삭제됩니다.${NC}"
        read -p "❓ 정말 모든 설정을 삭제하시겠습니까? (y/N): " RESET_CONFIRM
        if [[ ! "${RESET_CONFIRM}" =~ ^[Yy]$ ]]; then
            echo "취소되었습니다."
            exit 0
        fi
    else
        read -p "❓ ArgoCD 릴리즈를 삭제하고 새로 설치하시겠습니까? (y/N): " REINSTALL_CONFIRM
        if [[ ! "${REINSTALL_CONFIRM}" =~ ^[Yy]$ ]]; then
            echo "취소되었습니다."
            exit 0
        fi
    fi

    # 1. Helm Uninstall
    echo "   - Helm Release 삭제 중..."
    helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait 2>/dev/null || true

    # 2. NodePort 서비스 삭제
    echo "   - NodePort 서비스 삭제 중..."
    kubectl delete svc argocd-server-nodeport -n "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true

    # 3. HTTPRoute 삭제
    echo "   - HTTPRoute 삭제 중..."
    kubectl delete httproute argocd-route -n "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true

    # 4. 설정 및 네임스페이스 제거 (Reset 시에만)
    if [ "${RESET_MODE}" == "reset" ]; then
        echo "   - Namespace '${NAMESPACE}' 삭제 중..."
        kubectl delete ns "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
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

EXIST_RELEASE=$(helm list -n "$NAMESPACE" -q 2>/dev/null | grep "^${RELEASE_NAME}$" || echo "")
DO_UPGRADE=false
_FORCE_REINPUT=false

if [ -n "$EXIST_RELEASE" ] || [ -f "$CONF_FILE" ]; then
    echo ""
    echo -e "⚠️  ${YELLOW}기존 설치 또는 설정이 감지되었습니다.${NC}"
    [ -f "$CONF_FILE" ] && echo "  📋 저장된 설정 정보:"
    [ -n "$IMAGE_SOURCE" ] && echo "     - 이미지 소스 : $IMAGE_SOURCE"
    [ -n "$STORAGE_TYPE" ] && echo "     - 스토리지 유형: $STORAGE_TYPE"
    [ -n "$DOMAIN" ] && echo "     - 도메인      : $DOMAIN"

    echo ""
    echo "동작을 선택하세요:"
    echo "  1) 업그레이드 (저장된 설정 유지, 멱등 릴리즈 재구동)"
    echo "  2) 재설치     (기존 릴리즈 삭제 후 새로 설치)"
    echo "  3) 초기화     (설정 파일 및 네임스페이스 완전 삭제)"
    echo "  4) 취소"
    read -p "선택 [1/2/3/4]: " ACTION

    case "$ACTION" in
        1)
            DO_UPGRADE=true
            _IS_INVALID="false"
            if [ -z "$IMAGE_SOURCE" ] || [ -z "$STORAGE_TYPE" ] || [ -z "$DOMAIN" ]; then
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
    echo -e "${CYAN}   ArgoCD 설치 설정 입력                    ${NC}"
    echo -e "   [Chart Version] 7.4.1 / [Image] v2.12.1"
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

    # 2-2. 스토리지 설정
    echo ""
    echo "스토리지 유형을 선택하세요:"
    echo "  1) hostpath (로컬 노드 경로 사용)"
    echo "  2) nas (NFS 정적 할당 - manifests/nas-pv.yaml 수정 필요)"
    echo "  3) nfs-dynamic (StorageClass를 통한 동적 할당)"
    echo "  4) none (영구 저장소 없음)"
    read -p "선택 [1/2/3/4, 기본값: 1]: " _STORAGE_CHOICE
    _STORAGE_CHOICE="${_STORAGE_CHOICE:-1}"

    case "${_STORAGE_CHOICE}" in
        1)
            STORAGE_TYPE="hostpath"
            read -p "  Redis용 hostPath 경로 [기본: /data/argocd/redis]: " HOSTPATH_REDIS
            HOSTPATH_REDIS="${HOSTPATH_REDIS:-/data/argocd/redis}"
            read -p "  Repo-server용 hostPath 경로 [기본: /data/argocd/repo-cache]: " HOSTPATH_REPO
            HOSTPATH_REPO="${HOSTPATH_REPO:-/data/argocd/repo-cache}"
            NAS_SERVER=""
            NAS_REDIS_PATH=""
            NAS_REPO_PATH=""
            STORAGE_CLASS=""
            REDIS_SIZE=""
            REPO_SIZE=""
            ;;
        2)
            STORAGE_TYPE="nas"
            read -p "  NAS 서버 IP 주소: " NAS_SERVER
            if [ -z "${NAS_SERVER}" ]; then echo -e "${RED}[오류] NAS 서버 IP가 필요합니다.${NC}"; exit 1; fi
            read -p "  Redis용 NAS 경로 [기본: /nas/argocd/redis]: " NAS_REDIS_PATH
            NAS_REDIS_PATH="${NAS_REDIS_PATH:-/nas/argocd/redis}"
            read -p "  Repo-server용 NAS 경로 [기본: /nas/argocd/repo]: " NAS_REPO_PATH
            NAS_REPO_PATH="${NAS_REPO_PATH:-/nas/argocd/repo}"
            HOSTPATH_REDIS=""
            HOSTPATH_REPO=""
            STORAGE_CLASS=""
            ;;
        3)
            STORAGE_TYPE="nfs-dynamic"
            echo ""
            echo "현재 클러스터의 StorageClass 목록:"
            kubectl get sc 2>/dev/null || echo "  (StorageClass 조회 실패)"
            echo ""
            read -p "  사용할 StorageClass 이름 [기본: nfs-client]: " STORAGE_CLASS
            STORAGE_CLASS="${STORAGE_CLASS:-nfs-client}"
            HOSTPATH_REDIS=""
            HOSTPATH_REPO=""
            NAS_SERVER=""
            NAS_REDIS_PATH=""
            NAS_REPO_PATH=""
            ;;
        4)
            STORAGE_TYPE="none"
            HOSTPATH_REDIS=""
            HOSTPATH_REPO=""
            NAS_SERVER=""
            NAS_REDIS_PATH=""
            NAS_REPO_PATH=""
            STORAGE_CLASS=""
            REDIS_SIZE=""
            REPO_SIZE=""
            ;;
        *)
            echo -e "${RED}[오류] 올바른 스토리지 유형을 선택하세요.${NC}"; exit 1 ;;
    esac

    # 2-3. 볼륨 크기 입력
    if [ "$STORAGE_TYPE" = "nas" ] || [ "$STORAGE_TYPE" = "nfs-dynamic" ]; then
        read -p "  Redis 캐시 볼륨 크기 [기본: 10Gi]: " REDIS_SIZE
        REDIS_SIZE="${REDIS_SIZE:-10Gi}"
        read -p "  Repo 캐시 볼륨 크기  [기본: 20Gi]: " REPO_SIZE
        REPO_SIZE="${REPO_SIZE:-20Gi}"
    fi

    # 2-4. 네트워킹 설정
    echo ""
    read -p "NodePort 포트 번호 [기본: 30001]: " NODEPORT
    NODEPORT="${NODEPORT:-30001}"
    read -p "ArgoCD 도메인 호스트네임 [기본: argocd.devops.internal]: " DOMAIN
    DOMAIN="${DOMAIN:-argocd.devops.internal}"
    read -p "HTTPS/TLS 적용 여부? (y/N, 기본: n): " _TLS
    if [[ "$_TLS" =~ ^[yY]([eE][sS])?$ ]]; then
        TLS_ENABLED="true"
    else
        TLS_ENABLED="false"
    fi
    GATEWAY_NAME="cluster-gateway"
    GATEWAY_NAMESPACE="envoy-gateway-system"
fi

# 설정 저장
save_conf
save_values_infra

# ==========================================
# [3] 리소스 사전 생성
# ==========================================
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if [ "$STORAGE_TYPE" = "nas" ]; then
    echo ">>> Applying NAS PV/PVC (server: ${NAS_SERVER})"
    sed \
        -e "s|192.168.1.100|${NAS_SERVER}|g" \
        -e "s|/nas/argocd/redis|${NAS_REDIS_PATH}|g" \
        -e "s|/nas/argocd/repo|${NAS_REPO_PATH}|g" \
        -e "s|<REDIS_SIZE>|${REDIS_SIZE}|g" \
        -e "s|<REPO_SIZE>|${REPO_SIZE}|g" \
        "./manifests/nas-pv.yaml" | kubectl apply -f -
elif [ "$STORAGE_TYPE" = "nfs-dynamic" ]; then
    echo ">>> Creating Dynamic PVCs (StorageClass: ${STORAGE_CLASS})"
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

# ==========================================
# [4] Helm 배포 기동
# ==========================================
echo ""
echo "🚀 Helm Chart 배포 중..."

helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" \
    --namespace "$NAMESPACE" \
    -f values.yaml \
    -f values-infra.yaml \
    --wait

# ==========================================
# [5] 부가 서비스 및 라우팅 설정
# ==========================================
# NodePort 서비스 적용
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: argocd-server-nodeport
  namespace: ${NAMESPACE}
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: argocd-server
  ports:
    - name: http
      port: 80
      targetPort: 8080
      nodePort: ${NODEPORT}
EOF

# Envoy Gateway HTTPRoute 적용
if [ -n "$DOMAIN" ]; then
    echo ">>> Applying HTTPRoute (hostname: ${DOMAIN})"
    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-route
  namespace: ${NAMESPACE}
spec:
  parentRefs:
    - name: ${GATEWAY_NAME}
      namespace: ${GATEWAY_NAMESPACE}
  hostnames:
    - "${DOMAIN}"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: argocd-server
          port: 80
EOF

    # CoreDNS 등록
    echo ""
    read -p "❓ ${DOMAIN} 이 DNS 서버에 이미 등록되어 있나요? (y/n): " DNS_REGISTERED
    if [[ ! "$DNS_REGISTERED" =~ ^[Yy]$ ]]; then
        echo ">>> CoreDNS에 ${DOMAIN} 등록 중..."
        NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
        if [ -n "$NODE_IP" ]; then
            add_coredns_host "$NODE_IP" "$DOMAIN"
        fi
    fi
fi

# 최종 결과 리포트
echo ""
echo "======================================================"
echo -e " ${GREEN}✅ ArgoCD 설치 완료${NC}"
echo "======================================================"
kubectl get pods -n "$NAMESPACE"
echo ""
