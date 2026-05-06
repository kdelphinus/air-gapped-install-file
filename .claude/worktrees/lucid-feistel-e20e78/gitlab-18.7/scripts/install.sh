#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

# ==========================================
# [설정] 변수 정의
# ==========================================
NAMESPACE="gitlab"
RELEASE_NAME="gitlab"
CHART_PATH="./charts/gitlab"
PV_FILE="./manifests/gitlab-pv.yaml"
HTTPROUTE_FILE="./manifests/gitlab-httproutes.yaml"
VALUES_FILE="./values.yaml"
CONF_FILE="./install.conf"
NODE_LABEL_KEY="gitlab-node"
NODE_LABEL_VALUE="true"
COMPONENTS_STATE_FILE="./gitlab-components-state.sh"
COMPONENTS_VALUES_FILE="./gitlab-components.yaml"
IMAGE_VALUES_FILE="./gitlab-images-override.yaml"
GITLAB_VERSION="v18.7.0"

# ── install.conf 로드 / 저장 ──────────────────────────────
load_conf() {
    [ -f "$CONF_FILE" ] && source "$CONF_FILE"
}

save_conf() {
    cat > "$CONF_FILE" <<EOF
# GitLab 18.7 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
USE_NGINX="${USE_NGINX}"
TARGET_NODE="${TARGET_NODE}"
OPT_REGISTRY="${OPT_REGISTRY}"
OPT_KAS="${OPT_KAS}"
OPT_CERTMANAGER="${OPT_CERTMANAGER}"
OPT_RUNNER="${OPT_RUNNER}"
OPT_PROMETHEUS="${OPT_PROMETHEUS}"
INSTALLED_VERSION="${GITLAB_VERSION}"
EOF
    echo "  ✅ 설정이 ${CONF_FILE} 에 저장되었습니다."
}

load_conf

# ── 기존 설치 확인 ────────────────────────────────────────
EXIST_HELM=$(helm status $RELEASE_NAME -n $NAMESPACE > /dev/null 2>&1 && echo "yes" || echo "no")
# Terminating 중인 namespace는 "없음"으로 처리 (--wait=false 삭제 후 재실행 오탐 방지)
EXIST_NS=$([ "$(kubectl get namespace $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null)" = "Active" ] && echo "yes" || echo "no")
# --output=name + grep으로 실제 리소스 존재 여부 확인 (namespace 없어도 exit 0 반환하는 kubectl 버그 우회)
EXIST_K8S=$(kubectl get deployment -l app=webservice -n $NAMESPACE --output=name 2>/dev/null | grep -q . && echo "yes" || echo "no")

DO_UPGRADE=""

_bool() { [[ "$1" =~ ^[Yy]$ ]] && echo "true" || echo "false"; }

_cleanup_resources() {
    local delete_data="$1"

    if [ "$EXIST_HELM" = "yes" ]; then
        echo "  - Helm Release '$RELEASE_NAME' 삭제 중..."
        helm uninstall $RELEASE_NAME -n $NAMESPACE --wait=false 2>/dev/null || true
    fi

    kubectl delete validatingwebhookconfiguration gitlab-certmanager-webhook --ignore-not-found=true 2>/dev/null || true
    kubectl delete mutatingwebhookconfiguration gitlab-certmanager-webhook --ignore-not-found=true 2>/dev/null || true

    if [ -f "$HTTPROUTE_FILE" ]; then
        kubectl delete -f "$HTTPROUTE_FILE" --ignore-not-found=true 2>/dev/null || true
    fi

    kubectl label nodes --all ${NODE_LABEL_KEY}- > /dev/null 2>&1 || true

    kubectl delete -n $NAMESPACE pvc data-gitlab-postgresql-0
    kubectl delete -n $NAMESPACE pvc redis-data-gitlab-redis-master-0
    kubectl delete -n $NAMESPACE pvc repo-data-gitlab-gitaly-0

    if [ -f "$PV_FILE" ]; then
        kubectl delete -f "$PV_FILE" --ignore-not-found=true 2>/dev/null || true
    fi
    kubectl delete pv gitlab-postgresql-pv gitlab-redis-pv gitlab-gitaly-pv gitlab-minio-pv --ignore-not-found=true 2>/dev/null || true

    echo "  - Namespace '$NAMESPACE' 삭제 중 (완전 삭제까지 대기)..."
    kubectl delete ns $NAMESPACE --ignore-not-found=true --wait=false 2>/dev/null || true
    kubectl wait --for=delete namespace/$NAMESPACE --timeout=120s 2>/dev/null || true

    rm -f "$IMAGE_VALUES_FILE" "$COMPONENTS_VALUES_FILE" "$COMPONENTS_STATE_FILE" 2>/dev/null || true

    if [[ "$delete_data" =~ ^[Yy]$ ]]; then
        echo "  - 데이터 디렉토리 초기화 중..."
        for dir in /data/gitlab_pg /data/gitlab_redis /data/gitlab_data; do
            if [ -d "$dir" ]; then
                sudo rm -rf "${dir:?}"/*
                echo "    ✅ $dir 초기화 완료"
            fi
        done
    fi
}

if [ "$EXIST_HELM" = "yes" ] || [ "$EXIST_K8S" = "yes" ] || [ "$EXIST_NS" = "yes" ]; then
    echo -e "\033[1;33m[알림] GitLab이 이미 설치되어 있는 것으로 보입니다.\033[0m"
    [ "$EXIST_HELM" = "yes" ] && echo "  - Helm 릴리스 발견: $RELEASE_NAME"
    [ "$EXIST_K8S" = "yes" ] && echo "  - Kubernetes Deployment 발견: $NAMESPACE/webservice"
    [ "$EXIST_NS" = "yes" ] && echo "  - Namespace 발견: $NAMESPACE"

    if [ -f "$CONF_FILE" ]; then
        echo ""
        echo "  📋 저장된 설정 (${CONF_FILE}):"
        echo "     이미지 소스  : ${IMAGE_SOURCE:-미설정}"
        [ "${IMAGE_SOURCE}" = "harbor" ] && echo "     Harbor       : ${HARBOR_REGISTRY}/${HARBOR_PROJECT}"
        echo "     Ingress      : $( [ "${USE_NGINX}" = "y" ] && echo "NGINX" || echo "Envoy Gateway" )"
        [ -n "${TARGET_NODE}" ] && echo "     노드 고정    : ${TARGET_NODE}"
        echo "     설치 버전    : ${INSTALLED_VERSION:-미설정}"
    fi

    echo ""
    echo "동작을 선택하세요:"
    echo "  1) 업그레이드   — 저장된 설정 유지, Helm upgrade --install"
    echo "  2) 재설치       — 설정 재입력, 데이터 삭제 여부 선택"
    echo "  3) 초기화(리셋) — 모든 리소스 + 자동생성 파일 삭제 후 재설치"
    echo "  4) 취소"
    read -p "선택 [1/2/3/4, 기본값 4]: " INSTALL_ACTION
    INSTALL_ACTION="${INSTALL_ACTION:-4}"

    case "$INSTALL_ACTION" in
        1)
            echo "🚀 업그레이드 모드로 진행합니다."
            DO_UPGRADE="true"
            ;;
        2)
            read -p "⚠️  기존 데이터를 모두 삭제하고 완전 초기화할까요? (y/N): " DELETE_DATA
            DELETE_DATA="${DELETE_DATA:-N}"
            echo "🔥 기존 GitLab 자원 삭제 중..."
            _cleanup_resources "$DELETE_DATA"
            echo "✅ 삭제 완료. 설정을 다시 입력합니다."
            IMAGE_SOURCE="" HARBOR_REGISTRY="" HARBOR_PROJECT=""
            USE_NGINX="" TARGET_NODE=""
            OPT_REGISTRY="" OPT_KAS="" OPT_CERTMANAGER="" OPT_RUNNER="" OPT_PROMETHEUS=""
            sleep 5
            ;;
        3)
            echo "🗑️  초기화: 모든 리소스와 자동생성 파일을 삭제하고 재설치합니다..."
            _cleanup_resources "y"
            [ -f "$CONF_FILE" ] && rm -f "$CONF_FILE" && echo "  - install.conf 삭제됨"
            echo "✅ 초기화 완료. 설정을 처음부터 입력합니다."
            IMAGE_SOURCE="" HARBOR_REGISTRY="" HARBOR_PROJECT=""
            USE_NGINX="" TARGET_NODE=""
            OPT_REGISTRY="" OPT_KAS="" OPT_CERTMANAGER="" OPT_RUNNER="" OPT_PROMETHEUS=""
            ;;
        *)
            echo "❌ 설치가 취소되었습니다."
            exit 0
            ;;
    esac
fi

# ==========================================
# [이미지 소스] Harbor 또는 로컬 tar
# ==========================================
if [ -z "${IMAGE_SOURCE}" ]; then
    echo ""
    echo "이미지 소스를 선택하세요:"
    echo "  1) Harbor 레지스트리 사용 (사전에 images/upload_images_to_harbor_v3-lite.sh 실행 필요)"
    echo "  2) 로컬 tar 직접 import (이미 이미지가 로드된 경우 건너뜀)"
    read -p "선택 [1/2, 기본값: 1]: " _IMG_SRC
    _IMG_SRC="${_IMG_SRC:-1}"
    if [ "$_IMG_SRC" = "1" ]; then
        IMAGE_SOURCE="harbor"
    elif [ "$_IMG_SRC" = "2" ]; then
        IMAGE_SOURCE="local"
    else
        echo "[오류] 1 또는 2를 선택하세요."; exit 1
    fi
fi

if [ "${IMAGE_SOURCE}" = "harbor" ]; then
    if [ -z "${HARBOR_REGISTRY}" ]; then
        read -p "Harbor 레지스트리 주소 (예: 192.168.1.10:30002): " HARBOR_REGISTRY
        [ -z "${HARBOR_REGISTRY}" ] && echo "[오류] Harbor 레지스트리 주소가 필요합니다." && exit 1
    fi
    if [ -z "${HARBOR_PROJECT}" ]; then
        read -p "Harbor 프로젝트 (예: library, oss): " HARBOR_PROJECT
        [ -z "${HARBOR_PROJECT}" ] && echo "[오류] Harbor 프로젝트가 필요합니다." && exit 1
    fi
elif [ "${IMAGE_SOURCE}" = "local" ] && [ "${DO_UPGRADE}" != "true" ]; then
    echo "로컬 tar 파일을 containerd(k8s.io)에 import 중..."
    IMPORT_COUNT=0
    for tar_file in ./images/*.tar; do
        [ -e "${tar_file}" ] || continue
        echo "  → $(basename "${tar_file}")"
        sudo ctr -n k8s.io images import "${tar_file}"
        IMPORT_COUNT=$((IMPORT_COUNT + 1))
    done
    [ "${IMPORT_COUNT}" -eq 0 ] && echo "[경고] ./images/ 에 tar 파일이 없습니다."
    echo "  ${IMPORT_COUNT}개 이미지 import 완료"
fi

# ==========================================
# [선택 컴포넌트] 업그레이드 시 이전 설정 유지
# ==========================================
if [ "${DO_UPGRADE}" = "true" ]; then
    # 이전 conf에서 이미 로드됨 — 변경 여부만 확인
    echo ""
    echo "========================================================"
    echo "  [선택 컴포넌트] 현재 설정"
    echo "========================================================"
    echo "    컨테이너 레지스트리 : $( [[ "${OPT_REGISTRY}" =~ ^[Yy]$ ]] && echo "활성화" || echo "비활성화" )"
    echo "    KAS                 : $( [[ "${OPT_KAS}" =~ ^[Yy]$ ]] && echo "활성화" || echo "비활성화" )"
    echo "    Cert Manager        : $( [[ "${OPT_CERTMANAGER}" =~ ^[Yy]$ ]] && echo "활성화" || echo "비활성화" )"
    echo "    GitLab Runner       : $( [[ "${OPT_RUNNER}" =~ ^[Yy]$ ]] && echo "활성화" || echo "비활성화" )"
    echo "    Prometheus          : $( [[ "${OPT_PROMETHEUS}" =~ ^[Yy]$ ]] && echo "활성화" || echo "비활성화" )"
    echo ""
    read -p "  현재 설정을 그대로 유지하시겠습니까? (Y/n): " KEEP_COMPONENTS
    KEEP_COMPONENTS="${KEEP_COMPONENTS:-Y}"

    if [[ "${KEEP_COMPONENTS}" =~ ^[Nn]$ ]]; then
        read -p "  컨테이너 레지스트리 활성화? (y/N, 현재: ${OPT_REGISTRY}): " NEW_REGISTRY
        read -p "  KAS 활성화? (y/N, 현재: ${OPT_KAS}): " NEW_KAS
        read -p "  Cert Manager 활성화? (y/N, 현재: ${OPT_CERTMANAGER}): " NEW_CERTMANAGER
        read -p "  GitLab Runner 활성화? (y/N, 현재: ${OPT_RUNNER}): " NEW_RUNNER
        read -p "  Prometheus 활성화? (y/N, 현재: ${OPT_PROMETHEUS}): " NEW_PROMETHEUS
        OPT_REGISTRY="${NEW_REGISTRY:-${OPT_REGISTRY}}"
        OPT_KAS="${NEW_KAS:-${OPT_KAS}}"
        OPT_CERTMANAGER="${NEW_CERTMANAGER:-${OPT_CERTMANAGER}}"
        OPT_RUNNER="${NEW_RUNNER:-${OPT_RUNNER}}"
        OPT_PROMETHEUS="${NEW_PROMETHEUS:-${OPT_PROMETHEUS}}"
    fi
else
    echo ""
    echo "========================================================"
    echo "  [선택 컴포넌트] 활성화할 컴포넌트를 선택하세요."
    echo "  기본값 N = 최소 구성"
    echo "========================================================"
    read -p "  컨테이너 레지스트리 (이미지 push/pull) 활성화? (y/N): " OPT_REGISTRY
    OPT_REGISTRY="${OPT_REGISTRY:-N}"
    read -p "  KAS (GitLab-K8s 클러스터 연동) 활성화? (y/N): " OPT_KAS
    OPT_KAS="${OPT_KAS:-N}"
    read -p "  Cert Manager (TLS 인증서 자동 관리) 활성화? (y/N): " OPT_CERTMANAGER
    OPT_CERTMANAGER="${OPT_CERTMANAGER:-N}"
    read -p "  GitLab Runner (CI/CD 파이프라인 실행) 활성화? (y/N): " OPT_RUNNER
    OPT_RUNNER="${OPT_RUNNER:-N}"
    read -p "  Prometheus + GitLab Exporter (모니터링) 활성화? (y/N): " OPT_PROMETHEUS
    OPT_PROMETHEUS="${OPT_PROMETHEUS:-N}"
fi

echo ""
echo "선택 결과:"
echo "  - 컨테이너 레지스트리 : ${OPT_REGISTRY}"
echo "  - KAS                 : ${OPT_KAS}"
echo "  - Cert Manager        : ${OPT_CERTMANAGER}"
echo "  - GitLab Runner       : ${OPT_RUNNER}"
echo "  - Prometheus          : ${OPT_PROMETHEUS}"

cat > "${COMPONENTS_STATE_FILE}" <<EOF
# 선택 설치 컴포넌트 상태 (install.sh 자동 생성)
OPT_REGISTRY=${OPT_REGISTRY}
OPT_KAS=${OPT_KAS}
OPT_CERTMANAGER=${OPT_CERTMANAGER}
OPT_RUNNER=${OPT_RUNNER}
OPT_PROMETHEUS=${OPT_PROMETHEUS}
EOF

cat > "${COMPONENTS_VALUES_FILE}" <<EOF
# 선택 설치 컴포넌트 (install.sh 자동 생성)
installCertmanager: $(_bool "${OPT_CERTMANAGER}")
global:
  registry:
    enabled: $(_bool "${OPT_REGISTRY}")
  kas:
    enabled: $(_bool "${OPT_KAS}")
registry:
  enabled: $(_bool "${OPT_REGISTRY}")
gitlab-runner:
  install: $(_bool "${OPT_RUNNER}")
prometheus:
  install: $(_bool "${OPT_PROMETHEUS}")
gitlab:
  gitlab-exporter:
    enabled: $(_bool "${OPT_PROMETHEUS}")
EOF

echo "  ✅ 컴포넌트 설정 저장: ${COMPONENTS_VALUES_FILE}"

# ==========================================
# [설치/업그레이드] 이후 공통 플로우
# ==========================================
echo ""
echo "========================================================"
echo "🚀 GitLab ${DO_UPGRADE:+업그레이드}${DO_UPGRADE:-설치} 시작"
echo "========================================================"

# ── Namespace 생성 (신규 설치 시) ──────────────────────────
if [ "${DO_UPGRADE}" != "true" ]; then
    echo ""
    echo "🚀 Namespace 생성 중..."
    kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

    # ── HTTPRoute 적용 ────────────────────────────────────────
    if [ -z "${USE_NGINX}" ]; then
        echo ""
        read -p "❓ NGINX Ingress Controller를 사용하시나요? (y/n): " USE_NGINX
    fi

    if [[ "${USE_NGINX}" == "n" || "${USE_NGINX}" == "N" ]]; then
        if [ -f "$HTTPROUTE_FILE" ]; then
            echo "📄 [Envoy Gateway 모드] $HTTPROUTE_FILE 설정 적용..."
            kubectl apply -f "$HTTPROUTE_FILE"
        else
            echo "⚠️  경고: $HTTPROUTE_FILE 파일이 없어 적용하지 못했습니다."
        fi
    else
        echo "🚫 [NGINX 모드] HTTPRoute 적용을 건너뜁니다."
    fi

    # ── PV 생성 ───────────────────────────────────────────────
    echo ""
    echo "📄 PV 생성 중..."
    kubectl apply -f "$PV_FILE"

    # ── 데이터 디렉토리 생성/권한 ──────────────────────────────
    echo ""
    echo "📁 데이터 디렉토리 생성 및 권한 설정 중..."
    sudo mkdir -p /data/gitlab_pg /data/gitlab_redis /data/gitlab_data /data/gitlab_data/minio
    sudo chown -R 1001:1001 /data/gitlab_pg
    sudo chown -R 1001:1001 /data/gitlab_redis
    sudo chown -R 1000:1000 /data/gitlab_data
    echo "  ✅ 권한 설정 완료"

    sleep 5
fi

# ── 노드 고정 설정 ────────────────────────────────────────
echo ""
echo "--------------------------------------------------------"
echo "🖥️  [선택] GitLab이 배포될 노드 지정 (Node Pinning)"
echo "--------------------------------------------------------"

NODE_SELECTOR_ARGS=""

if [ "${DO_UPGRADE}" = "true" ] && [ -n "${TARGET_NODE}" ]; then
    echo "  저장된 노드 고정 설정: ${TARGET_NODE}"
    read -p "  그대로 사용하시겠습니까? (Y/n): " KEEP_NODE
    KEEP_NODE="${KEEP_NODE:-Y}"
    if [[ "${KEEP_NODE}" =~ ^[Nn]$ ]]; then
        TARGET_NODE=""
    fi
fi

if [ -z "${TARGET_NODE}" ]; then
    echo "현재 클러스터의 노드 목록:"
    kubectl get nodes
    echo ""
    read -p "❓ GitLab을 배포할 노드 이름(NAME)을 입력하세요 (엔터 = 자동 분산 배포): " TARGET_NODE
fi

if [ -n "${TARGET_NODE}" ]; then
    if ! kubectl get node "${TARGET_NODE}" > /dev/null 2>&1; then
        echo "❌ 오류: '${TARGET_NODE}'라는 노드를 찾을 수 없습니다."
        exit 1
    fi
    kubectl label nodes "${TARGET_NODE}" ${NODE_LABEL_KEY}=${NODE_LABEL_VALUE} --overwrite
    echo "  ✅ 노드 고정 설정 완료: ${TARGET_NODE}"
    NODE_SELECTOR_ARGS="--set-string global.nodeSelector.${NODE_LABEL_KEY}=${NODE_LABEL_VALUE} \
                        --set-string redis.master.nodeSelector.${NODE_LABEL_KEY}=${NODE_LABEL_VALUE} \
                        --set-string postgresql.primary.nodeSelector.${NODE_LABEL_KEY}=${NODE_LABEL_VALUE}"
else
    echo "  → 노드 고정 없이 자동 스케줄링으로 진행합니다."
fi

# ── 이미지 오버라이드 파일 생성 ──────────────────────────
IMAGE_VALUES_ARG=""

if [ "${IMAGE_SOURCE}" = "harbor" ]; then
    echo ""
    echo "⚙️  Harbor 이미지 설정 파일 생성 중 (${IMAGE_VALUES_FILE})..."

    cat > "$IMAGE_VALUES_FILE" <<EOF
global:
  image:
    registry: ${HARBOR_REGISTRY}
    pullPolicy: IfNotPresent

  kubectl:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/kubectl
  certificates:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/certificates
  gitlabBase:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-base

gitlab:
  webservice:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-webservice-ce
    workhorse:
      image: "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-workhorse-ce"
  sidekiq:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-sidekiq-ce
    extraInitContainers: |
      - name: fix-tmp
        image: "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-base:${GITLAB_VERSION}"
        command: ['sh', '-c', 'chmod 1777 /tmp']
        securityContext:
          runAsUser: 0
        volumeMounts:
        - name: sidekiq-tmp
          mountPath: /tmp
  toolbox:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-toolbox-ce
  gitlab-shell:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-shell
  gitaly:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitaly
  gitlab-exporter:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-exporter
  kas:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-kas
  migrations:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-toolbox-ce

minio:
  image: "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/minio"
  imageTag: "RELEASE.2017-12-28T01-21-00Z"
  minioMc:
    image: "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/mc"
    tag: "RELEASE.2018-07-13T00-53-22Z"
  mcImage:
    repository: "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/mc"
    tag: "RELEASE.2018-07-13T00-53-22Z"
  makeBucketJob:
    image:
      repository: "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/mc"
      tag: "RELEASE.2018-07-13T00-53-22Z"

certmanager:
  image:
    repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/cert-manager-controller
    tag: v1.17.4
  webhook:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/cert-manager-webhook
      tag: v1.17.4
  cainjector:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/cert-manager-cainjector
      tag: v1.17.4
  startupapicheck:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/cert-manager-startupapicheck
      tag: v1.17.4

postgresql:
  image:
    registry: ${HARBOR_REGISTRY}
    repository: ${HARBOR_PROJECT}/postgresql
    tag: "16.2.0"
  metrics:
    image:
      registry: ${HARBOR_REGISTRY}
      repository: ${HARBOR_PROJECT}/postgres-exporter
      tag: "0.15.0-debian-11-r7"

redis:
  image:
    registry: ${HARBOR_REGISTRY}
    repository: ${HARBOR_PROJECT}/redis
    tag: "7.2.4"
  metrics:
    image:
      registry: ${HARBOR_REGISTRY}
      repository: ${HARBOR_PROJECT}/redis-exporter
      tag: "1.58.0-debian-12-r4"

registry:
  image:
    repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-container-registry

upgradeCheck:
  image:
    repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-base
EOF

    echo "  ✅ 이미지 설정 파일 생성 완료."
    IMAGE_VALUES_ARG="-f ${IMAGE_VALUES_FILE}"
else
    echo ""
    echo "ℹ️  로컬 import 모드 — 이미지 오버라이드 파일 생성을 건너뜁니다."
    echo "  ⚠️  sidekiq /tmp fix: 로컬 모드에서는 emptyDir만 적용됩니다."
    echo "      sticky bit가 필요하다면 gitlab-base 이미지 로드 후 values.yaml에서"
    echo "      gitlab.sidekiq.extraInitContainers 를 직접 설정하세요."
fi

# ── Helm 배포 ──────────────────────────────────────────────
echo ""
echo "🚀 Helm upgrade --install 실행 중..."

if [ ! -f "$VALUES_FILE" ]; then
    echo "❌ 오류: '$VALUES_FILE' 파일이 없습니다!"; exit 1
fi

HELM_CMD="helm upgrade --install ${RELEASE_NAME} ${CHART_PATH} \
    -f ${VALUES_FILE} \
    -f ${COMPONENTS_VALUES_FILE} \
    ${IMAGE_VALUES_ARG} \
    --namespace ${NAMESPACE} \
    --timeout 600s \
    ${NODE_SELECTOR_ARGS}"

if [ -n "$NODE_SELECTOR_ARGS" ]; then
    echo "   노드 고정: ${NODE_LABEL_KEY}=${NODE_LABEL_VALUE} (${TARGET_NODE})"
fi

eval "$HELM_CMD"

# ── 설정 저장 ─────────────────────────────────────────────
save_conf

# ── CoreDNS 등록 ──────────────────────────────────────────
add_coredns_host() {
    local ip="$1" domain="$2"
    if kubectl get configmap coredns -n kube-system \
            -o jsonpath='{.data.NodeHosts}' | grep -qw "$domain"; then
        echo "  - CoreDNS: ${domain} 이미 등록됨, 건너뜁니다."
        return 0
    fi
    local new_hosts
    new_hosts="$(kubectl get configmap coredns -n kube-system \
        -o jsonpath='{.data.NodeHosts}')
${ip} ${domain}"
    kubectl get configmap coredns -n kube-system -o json \
        | jq --arg h "$new_hosts" '.data.NodeHosts = $h' \
        | kubectl apply -f -
    echo "  - CoreDNS: ${ip} ${domain} 등록 완료"
}

DOMAIN="gitlab.devops.internal"
if [ -n "$DOMAIN" ]; then
    echo ""
    read -p "❓ ${DOMAIN} 이 DNS 서버에 이미 등록되어 있나요? (y/n): " DNS_REGISTERED
    if [[ "$DNS_REGISTERED" == "y" || "$DNS_REGISTERED" == "Y" ]]; then
        echo "  - DNS 서버에 등록됨 — CoreDNS 등록을 건너뜁니다."
    else
        echo ">>> CoreDNS에 GitLab 도메인 등록 중..."
        NODE_IP=$(kubectl get nodes \
            -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
        add_coredns_host "$NODE_IP" "$DOMAIN"
    fi
fi

echo ""
echo "==========================================="
echo " ✅ GitLab ${GITLAB_VERSION} ${DO_UPGRADE:+업그레이드}${DO_UPGRADE:-설치} 완료"
echo "==========================================="
echo " GitLab URL  : http://${DOMAIN}"
echo " 설정 파일   : ${CONF_FILE}"
echo "==========================================="
echo "📊 [모니터링]"
echo "   kubectl get pods -n $NAMESPACE -w"
echo "   kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp'"
echo ""
echo "🔑 [초기 root 비밀번호]"
ROOT_PW=$(kubectl get secret gitlab-gitlab-initial-root-password -n $NAMESPACE \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)
if [ -n "$ROOT_PW" ]; then
    echo "   $ROOT_PW"
else
    echo "   (아직 생성 중 — 잠시 후 아래 명령으로 확인하세요)"
    echo "   kubectl get secret gitlab-gitlab-initial-root-password -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d && echo"
fi
echo "==========================================="
echo ""
echo "==========================================="
echo " [주의] 클라이언트 hosts 등록 필요"
echo "==========================================="
echo "   <GATEWAY_IP>  ${DOMAIN}"
echo "==========================================="
kubectl get pods -n $NAMESPACE 2>/dev/null || true
