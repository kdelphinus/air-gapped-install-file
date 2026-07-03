#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

# ==================== Config ====================
NAMESPACE="gitea"
CHART_PATH="./charts/gitea"
VALUES_FILE="./values.yaml"
PV_FILE="./manifests/pv-gitea.yaml"
HTTPROUTE_FILE="./manifests/httproute-gitea.yaml"
CONF_FILE="./install.conf"
NODE_LABEL_KEY="gitea-node"
NODE_LABEL_VALUE="true"

# CoreDNS 호스트 등록 함수
add_coredns_host() {
    local ip="$1"
    local domain="$2"
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
    echo "  - CoreDNS: ${ip} ${domain} 등록 완료 (15초 내 자동 반영)"
}

# ── install.conf 로드 / 저장 ──────────────────────────────
load_conf() {
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
    fi
}

save_conf() {
    cat > "$CONF_FILE" <<EOF
# Gitea v1.25.5 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
DB_TYPE="${DB_TYPE}"
DB_TYPE_NAME="${DB_TYPE_NAME}"
PG_ENABLED="${PG_ENABLED}"
PG_REGISTRY="${PG_REGISTRY}"
PG_REPOSITORY="${PG_REPOSITORY}"
TARGET_NODE="${TARGET_NODE}"
DOMAIN="${DOMAIN}"
ADMIN_USERNAME="${ADMIN_USERNAME}"
INSTALLED_VERSION="v1.25.5"
EOF
    echo "  ✅ 설정이 ${CONF_FILE} 에 저장되었습니다."
}

# ── 클린업 로직 ──────────────────────────────────────────
cleanup_resources() {
    local RESET_MODE=$1
    echo ""
    echo "🧹 [Clean Up] 기존 Gitea 리소스 제거 시작..."

    if helm status gitea -n "${NAMESPACE}" >/dev/null 2>&1; then
        echo "🗑️  Helm Release 'gitea' 삭제 중..."
        helm uninstall gitea -n "${NAMESPACE}" --wait=false 2>/dev/null || true
    fi

    echo "⏳ 리소스 삭제 대기 중..."
    sleep 5

    echo "🗑️  HTTPRoute 삭제 중..."
    kubectl delete httproute gitea-route -n "${NAMESPACE}" --ignore-not-found=true

    local DELETE_VOLUMES="no"
    if [ "$RESET_MODE" == "reset" ]; then
        DELETE_VOLUMES="yes"
    else
        echo ""
        read -p "⚠️  PV/PVC 도 함께 삭제하시겠습니까? (데이터 영구 삭제, y/n): " DELETE_DATA
        if [[ "${DELETE_DATA}" =~ ^[Yy]$ ]]; then
            DELETE_VOLUMES="yes"
        fi
    fi

    if [ "$DELETE_VOLUMES" == "yes" ]; then
        echo "🗑️  PVC 및 PV 삭제 중..."
        kubectl delete pvc gitea-data-pvc -n "${NAMESPACE}" --ignore-not-found=true
        kubectl delete pv gitea-data-pv --ignore-not-found=true
    else
        echo "➡️  PVC 및 PV 볼륨 데이터가 보존되었습니다."
    fi

    # 네임스페이스 삭제 (볼륨 보존 시 cascade delete 방지를 위해 우회)
    if [ "$DELETE_VOLUMES" == "yes" ]; then
        if kubectl get ns "${NAMESPACE}" >/dev/null 2>&1; then
            echo "🗑️  Namespace '${NAMESPACE}' 삭제 중..."
            kubectl delete ns "${NAMESPACE}" --ignore-not-found=true --timeout=30s
        fi
    else
        echo "➡️  볼륨 보존 선택에 따라 Namespace '${NAMESPACE}' 삭제 단계를 생략합니다."
    fi

    if [ "$RESET_MODE" == "reset" ]; then
        rm -f "$CONF_FILE"
        rm -f "./values-infra.yaml"
        echo "🗑️  설정 파일 및 생성된 인프라 파일 삭제 완료 (Reset)."
    fi

    echo "✅ 초기화 완료."
    echo ""
}

echo ""
echo "==========================================="
echo " Installing Gitea 1.25.5"
echo "==========================================="

# ==========================================
# [1] 기존 설치 감지 및 메뉴
# ==========================================
load_conf
EXIST_HELM=$(helm status gitea -n "$NAMESPACE" >/dev/null 2>&1 && echo "yes" || echo "no")
DO_UPGRADE=false

if [ "$EXIST_HELM" == "yes" ] || [ -f "$CONF_FILE" ]; then
    echo ""
    echo "⚠️  기존 설치 또는 설정이 감지되었습니다."
    [ -f "$CONF_FILE" ] && echo "  📋 저장된 설정 정보:"
    [ -n "$IMAGE_SOURCE" ] && echo "     - 이미지 소스  : $IMAGE_SOURCE"
    [ "$IMAGE_SOURCE" == "harbor" ] && echo "     - Harbor 주소  : $HARBOR_REGISTRY/$HARBOR_PROJECT"
    [ -n "$DB_TYPE" ] && echo "     - DB 타입      : $DB_TYPE (1=SQLite, 2=PostgreSQL)"
    [ -n "$DOMAIN" ] && echo "     - 도메인       : $DOMAIN"
    [ -n "$ADMIN_USERNAME" ] && echo "     - 관리자 계정  : $ADMIN_USERNAME"
    [ -n "$TARGET_NODE" ] && echo "     - 고정 노드    : $TARGET_NODE"

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
    # 2-1. 이미지 소스
    echo ""
    echo "이미지 소스를 선택하세요:"
    echo "  1) Harbor 레지스트리 사용 (사전에 images/upload_images_to_harbor_v3-lite.sh 실행 필요)"
    echo "  2) 로컬 이미지 직접 사용 (ctr import)"
    echo "  3) 온라인 Pull 사용 (인터넷 가능 환경)"
    read -p "선택 [1/2/3, 기본값 1]: " _IMG_SRC
    _IMG_SRC="${_IMG_SRC:-1}"
    if [ "$_IMG_SRC" = "1" ]; then
        IMAGE_SOURCE="harbor"
        read -p "Harbor 주소 (예: 192.168.1.10:30002): " HARBOR_REGISTRY
        if [ -z "${HARBOR_REGISTRY}" ]; then
            echo "[오류] Harbor 레지스트리 주소가 필요합니다."; exit 1
        fi
        read -p "Harbor 프로젝트 (예: library): " HARBOR_PROJECT
        if [ -z "${HARBOR_PROJECT}" ]; then
            echo "[오류] Harbor 프로젝트가 필요합니다."; exit 1
        fi
    elif [ "$_IMG_SRC" = "2" ]; then
        IMAGE_SOURCE="local"
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
        HARBOR_REGISTRY=""
        HARBOR_PROJECT=""
    elif [ "$_IMG_SRC" = "3" ]; then
        IMAGE_SOURCE="online"
        HARBOR_REGISTRY=""
        HARBOR_PROJECT=""
    else
        echo "[오류] 1, 2, 또는 3을 선택하세요."; exit 1
    fi

    # 2-2. DB 선택
    echo ""
    echo "데이터베이스를 선택하세요:"
    echo "  1) SQLite (기본, 추가 이미지 없음, 개발/소규모 환경)"
    echo "  2) PostgreSQL (권장, images/postgresql.tar 필요)"
    read -p "선택 [1/2, 기본값: 1]: " DB_TYPE
    DB_TYPE="${DB_TYPE:-1}"

    # 2-3. 도메인 설정
    echo ""
    read -p "HTTPRoute에 사용할 도메인 이름 (기본값: gitea.devops.internal, 공백 시 미생성): " DOMAIN
    DOMAIN="${DOMAIN:-gitea.devops.internal}"

    # 2-4. 노드 고정
    echo ""
    echo ">>> 사용 가능한 노드 목록:"
    kubectl get nodes -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[-1].type,ROLES:.metadata.labels.node-role\.kubernetes\.io/worker"
    echo ""
    read -p "Gitea 를 배치할 노드 이름 (엔터 = 자동 배치): " TARGET_NODE

    # 2-5. 관리자 계정 설정
    echo ""
    read -p "초기 관리자 계정 (기본값: gitea-admin): " ADMIN_USERNAME
    ADMIN_USERNAME="${ADMIN_USERNAME:-gitea-admin}"

    read -sp "초기 관리자 비밀번호 (엔터 시 임의 자동 생성): " ADMIN_PASSWORD; echo
fi

ADMIN_USERNAME="${ADMIN_USERNAME:-gitea-admin}"

if [ "$DO_UPGRADE" == "true" ]; then
    echo "⏳ 기존 관리자 비밀번호 복구를 시도합니다..."
    ENV_PWD=$(kubectl get deployment gitea -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="GITEA_ADMIN_PASSWORD")].value}' 2>/dev/null)
    if [ -z "$ENV_PWD" ]; then
        SECRET_NAME=$(kubectl get deployment gitea -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="GITEA_ADMIN_PASSWORD")].valueFrom.secretKeyRef.name}' 2>/dev/null)
        SECRET_KEY=$(kubectl get deployment gitea -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="GITEA_ADMIN_PASSWORD")].valueFrom.secretKeyRef.key}' 2>/dev/null)
        if [ -n "$SECRET_NAME" ] && [ -n "$SECRET_KEY" ]; then
            ENV_PWD=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath="{.data.${SECRET_KEY}}" | base64 -d 2>/dev/null)
        fi
    fi

    if [ -n "$ENV_PWD" ]; then
        ADMIN_PASSWORD="$ENV_PWD"
        echo "  🔑 기존 설치 상태로부터 비밀번호를 성공적으로 복구했습니다."
    else
        echo "  ⚠️  기존 비밀번호 복구에 실패했습니다."
        read -sp "관리자 비밀번호를 수동으로 입력하세요: " ADMIN_PASSWORD; echo
        if [ -z "$ADMIN_PASSWORD" ]; then
            echo "[오류] 비밀번호 입력이 누락되었습니다."
            exit 1
        fi
    fi
else
    if [ -z "${ADMIN_PASSWORD}" ]; then
        ADMIN_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)
        echo "  - 관리자 비밀번호가 자동으로 생성되었습니다."
    fi
fi

save_conf

# ==========================================


# ==========================================
# [3] 설정 파일(values-infra.yaml) 생성 및 리소스 배포
# ==========================================
echo "🔧 인프라 설정 파일(values-infra.yaml) 생성 중..."

# Gitea 이미지 설정
if [ "${IMAGE_SOURCE}" = "harbor" ]; then
    GITEA_REGISTRY="${HARBOR_REGISTRY}"
    GITEA_REPOSITORY="${HARBOR_PROJECT}/gitea"
else
    GITEA_REGISTRY="docker.gitea.com"
    GITEA_REPOSITORY="gitea"
fi

# DB 및 PostgreSQL 설정
if [ "${DB_TYPE}" = "2" ]; then
    DB_TYPE_NAME="postgres"
    PG_ENABLED="true"
    if [ "${IMAGE_SOURCE}" = "harbor" ]; then
        PG_REGISTRY="${HARBOR_REGISTRY}"
        PG_REPOSITORY="${HARBOR_PROJECT}/postgresql"
    else
        PG_REGISTRY="docker.io"
        PG_REPOSITORY="bitnamilegacy/postgresql"
    fi
else
    DB_TYPE_NAME="sqlite3"
    PG_ENABLED="false"
    PG_REGISTRY="docker.io"
    PG_REPOSITORY="bitnamilegacy/postgresql"
fi

# 노드 고정 (nodeSelector) 적용
NODE_SELECTOR_BLOCK="nodeSelector: {}"
if [ -n "${TARGET_NODE}" ]; then
    kubectl label nodes "${TARGET_NODE}" "${NODE_LABEL_KEY}=${NODE_LABEL_VALUE}" --overwrite
    NODE_SELECTOR_BLOCK="nodeSelector:
  ${NODE_LABEL_KEY}: \"${NODE_LABEL_VALUE}\""
fi

# 루트 권한 extra init container 설정
if [ "${IMAGE_SOURCE}" = "harbor" ]; then
    OS_SHELL_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/os-shell:12-debian-12-r51"
else
    OS_SHELL_IMAGE="docker.io/bitnamilegacy/os-shell:12-debian-12-r51"
fi

ROOT_URL_VAL="http://gitea.devops.internal"
if [ -n "${DOMAIN}" ]; then
    ROOT_URL_VAL="http://${DOMAIN}"
fi

cat > ./values-infra.yaml <<EOF
# Gitea v1.25.5 인프라 설정 — install.sh 에 의해 자동 관리됩니다.
image:
  registry: "${GITEA_REGISTRY}"
  repository: "${GITEA_REPOSITORY}"

gitea:
  admin:
    username: "${ADMIN_USERNAME}"
  config:
    server:
      ROOT_URL: "${ROOT_URL_VAL}"
    database:
      DB_TYPE: "${DB_TYPE_NAME}"

postgresql:
  enabled: ${PG_ENABLED}
  image:
    registry: "${PG_REGISTRY}"
    repository: "${PG_REPOSITORY}"

${NODE_SELECTOR_BLOCK}

preExtraInitContainers:
  - name: volume-permissions
    image: "${OS_SHELL_IMAGE}"
    imagePullPolicy: IfNotPresent
    command:
      - /bin/sh
      - -c
      - "chown -R 1000:1000 /data && chmod -R 775 /data"
    securityContext:
      runAsUser: 0
      runAsGroup: 0
      privileged: true
    volumeMounts:
      - name: data
        mountPath: /data
EOF

# ── 네임스페이스 및 PV 생성 ───────────────────────────────────
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo ">>> PV/PVC 적용 중..."
kubectl apply -f "${PV_FILE}"

# Helm이 직접 생성하지 않은 PVC를 관리할 수 있도록 adoption 레이블/어노테이션 추가
kubectl label pvc gitea-data-pvc -n "${NAMESPACE}" \
    "app.kubernetes.io/managed-by=Helm" --overwrite 2>/dev/null || true
kubectl annotate pvc gitea-data-pvc -n "${NAMESPACE}" \
    "meta.helm.sh/release-name=gitea" \
    "meta.helm.sh/release-namespace=${NAMESPACE}" \
    --overwrite 2>/dev/null || true

# ── Helm 설치 / 업그레이드 ────────────────────────────────────
if [ ! -d "${CHART_PATH}" ]; then
    echo "[오류] Helm 차트 디렉토리 '${CHART_PATH}' 가 없습니다."; exit 1
fi

echo ""
echo ">>> Helm ${DO_UPGRADE:+upgrade}${DO_UPGRADE:-install} 실행 중..."
helm upgrade --install gitea "${CHART_PATH}" \
    -n "${NAMESPACE}" \
    -f "${VALUES_FILE}" \
    -f ./values-infra.yaml \
    --set-string gitea.admin.password="${ADMIN_PASSWORD}"

echo ""
echo ">>> Gitea Pod 준비 대기 중 (최대 5분)..."
kubectl wait --timeout=5m -n "${NAMESPACE}" \
    deployment/gitea --for=condition=Available 2>/dev/null || \
kubectl rollout status deployment/gitea -n "${NAMESPACE}" --timeout=5m

# ── NodePort 패치 ─────────────────────────────────────────────
NODEPORT_HTTP="30003"
NODEPORT_SSH="30022"
GATEWAY_NAME="cluster-gateway"
GATEWAY_NAMESPACE="envoy-gateway-system"

echo ""
echo ">>> NodePort 패치 중 (HTTP: ${NODEPORT_HTTP}, SSH: ${NODEPORT_SSH})..."
sleep 5
HTTP_SVC=$(kubectl get svc -n "${NAMESPACE}" \
    -o jsonpath='{.items[?(@.spec.type=="NodePort")].metadata.name}' 2>/dev/null | \
    tr ' ' '\n' | grep -v ssh | head -1)

if [ -n "${HTTP_SVC}" ]; then
    kubectl patch svc "${HTTP_SVC}" -n "${NAMESPACE}" --type='merge' \
        -p "{\"spec\":{\"ports\":[{\"name\":\"http\",\"port\":3000,\"targetPort\":3000,\"nodePort\":${NODEPORT_HTTP}}]}}"
fi

SSH_SVC=$(kubectl get svc -n "${NAMESPACE}" \
    -o jsonpath='{.items[?(@.spec.type=="NodePort")].metadata.name}' 2>/dev/null | \
    tr ' ' '\n' | grep ssh | head -1)

if [ -n "${SSH_SVC}" ]; then
    kubectl patch svc "${SSH_SVC}" -n "${NAMESPACE}" --type='merge' \
        -p "{\"spec\":{\"ports\":[{\"name\":\"ssh\",\"port\":22,\"targetPort\":22,\"nodePort\":${NODEPORT_SSH}}]}}"
fi

# ── HTTPRoute ─────────────────────────────────────────────────
if [ -n "${DOMAIN}" ]; then
    echo ""
    echo ">>> HTTPRoute 적용 중 (hostname: ${DOMAIN})..."
    sed "s|gitea.devops.internal|${DOMAIN}|g; s|cluster-gateway|${GATEWAY_NAME}|g; s|envoy-gateway-system|${GATEWAY_NAMESPACE}|g" \
        "${HTTPROUTE_FILE}" | kubectl apply -f -
else
    echo ""
    echo ">>> DOMAIN 미설정 — HTTPRoute 생성을 건너뜁니다."
fi

# ── CoreDNS 등록 ──────────────────────────────────────────────
if [ -n "${DOMAIN}" ]; then
    echo ""
    read -p "❓ ${DOMAIN} 이 DNS 서버에 이미 등록되어 있나요? (y/n): " DNS_REGISTERED
    if [[ "${DNS_REGISTERED}" =~ ^[Yy]$ ]]; then
        echo "  - DNS 서버에 등록됨 — CoreDNS 등록을 건너뜁니다."
    else
        NODE_IP=$(kubectl get nodes \
            -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
        add_coredns_host "${NODE_IP}" "${DOMAIN}"
    fi
fi

# ── 완료 메시지 ───────────────────────────────────────────────
echo ""
echo "==========================================="
echo " ✅ Gitea 1.25.5 설치 완료"
echo "==========================================="
echo " NodePort HTTP : http://<NODE_IP>:${NODEPORT_HTTP}"
echo " NodePort SSH  : ssh://git@<NODE_IP>:${NODEPORT_SSH}"
[ -n "${DOMAIN}" ] && echo " 도메인       : http://${DOMAIN}"
echo ""
echo " 초기 관리자 로그인 정보:"
echo "   아이디(ID)   : ${ADMIN_USERNAME}"
echo "   비밀번호(PW) : ${ADMIN_PASSWORD}"
echo "==========================================="
kubectl get pods -n "${NAMESPACE}"
