#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

# ==================== Config ====================
# ── 이미지 소스 선택 ──────────────────────────────────────────
echo ""
echo "이미지 소스를 선택하세요:"
echo "  1) Harbor 레지스트리 사용 (사전에 images/upload_images_to_harbor_v3-lite.sh 실행 필요)"
echo "  2) 로컬 tar 직접 import (이미 이미지가 로드된 경우 건너뜀)"
read -p "선택 [1/2, 기본값: 1]: " IMAGE_SOURCE
IMAGE_SOURCE="${IMAGE_SOURCE:-1}"

if [ "${IMAGE_SOURCE}" = "1" ]; then
    read -p "Harbor 레지스트리 주소 (예: 192.168.1.10:30002): " HARBOR_REGISTRY
    if [ -z "${HARBOR_REGISTRY}" ]; then
        echo "[오류] Harbor 레지스트리 주소가 필요합니다."; exit 1
    fi
    read -p "Harbor 프로젝트 (예: library): " HARBOR_PROJECT
    if [ -z "${HARBOR_PROJECT}" ]; then
        echo "[오류] Harbor 프로젝트가 필요합니다."; exit 1
    fi
elif [ "${IMAGE_SOURCE}" = "2" ]; then
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
else
    echo "[오류] 1 또는 2를 선택하세요."; exit 1
fi

# ── DB 선택 ───────────────────────────────────────────────────
echo ""
echo "데이터베이스를 선택하세요:"
echo "  1) SQLite (기본, 추가 이미지 없음, 개발/소규모 환경)"
echo "  2) PostgreSQL (권장, images/postgresql.tar 필요)"
read -p "선택 [1/2, 기본값: 1]: " DB_TYPE
DB_TYPE="${DB_TYPE:-1}"

# Networking
NODEPORT_HTTP="30003"
NODEPORT_SSH="30022"
DOMAIN="gitea.devops.internal"     # HTTPRoute hostname, "" 이면 HTTPRoute 미생성
GATEWAY_NAME="cluster-gateway"
GATEWAY_NAMESPACE="envoy-gateway-system"
# ================================================

NAMESPACE="gitea"
CHART_PATH="./charts/gitea"
VALUES_FILE="./values.yaml"
PV_FILE="./manifests/pv-gitea.yaml"
HTTPROUTE_FILE="./manifests/httproute-gitea.yaml"

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

echo ""
echo "==========================================="
echo " Installing Gitea 1.25.5 (Offline)"
echo "==========================================="
echo " Image Source : ${IMAGE_SOURCE}"
echo " DB Type      : ${DB_TYPE} (1=SQLite, 2=PostgreSQL)"
[ -n "${HARBOR_REGISTRY}" ] && echo " Harbor       : ${HARBOR_REGISTRY}/${HARBOR_PROJECT}"
echo "==========================================="

# ── 기존 설치 감지 ────────────────────────────────────────────
if kubectl get ns "${NAMESPACE}" > /dev/null 2>&1; then
    echo ""
    echo "⚠️  기존 설치 감지: namespace '${NAMESPACE}' 가 존재합니다."
    echo "  1) 삭제 후 재설치"
    echo "  2) Helm upgrade (설정 변경 시)"
    echo "  3) 취소"
    read -p "선택 [1/2/3]: " REINSTALL_CHOICE

    if [ "${REINSTALL_CHOICE}" = "1" ]; then
        echo "기존 설치를 삭제합니다..."
        helm uninstall gitea -n "${NAMESPACE}" --wait=false 2>/dev/null || true
        sleep 5
        kubectl delete httproute gitea-route -n "${NAMESPACE}" --ignore-not-found=true
        kubectl delete ns "${NAMESPACE}" --ignore-not-found=true --timeout=30s
        kubectl delete pvc gitea-data-pvc -n "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
    elif [ "${REINSTALL_CHOICE}" = "2" ]; then
        DO_UPGRADE=true
    else
        echo "취소되었습니다."; exit 0
    fi
fi

# ── 네임스페이스 및 PV 생성 ───────────────────────────────────
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# ── 노드 고정 (선택) ──────────────────────────────────────────
echo ""
echo ">>> 사용 가능한 노드 목록:"
kubectl get nodes -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[-1].type,ROLES:.metadata.labels.node-role\.kubernetes\.io/worker"
echo ""
read -p "Gitea 를 배치할 노드 이름 (엔터 = 자동 배치): " TARGET_NODE

NODE_LABEL_KEY="gitea-node"
NODE_LABEL_VALUE="true"
NODE_FLAG=""

if [ -n "${TARGET_NODE}" ]; then
    kubectl label nodes "${TARGET_NODE}" "${NODE_LABEL_KEY}=${NODE_LABEL_VALUE}" --overwrite
    NODE_FLAG="--set-string nodeSelector.${NODE_LABEL_KEY}=${NODE_LABEL_VALUE}"
    # PV nodeAffinity 가 gitea-node=true 를 사용하므로 레이블 일치 확인
fi

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

# ── Helm --set 인자 구성 ──────────────────────────────────────
HELM_IMAGE_ARGS=()
if [ "${IMAGE_SOURCE}" = "1" ]; then
    GITEA_IMAGE_REGISTRY="${HARBOR_REGISTRY}"
    GITEA_IMAGE_REPO="${HARBOR_PROJECT}/gitea"
    HELM_IMAGE_ARGS=(
        --set "image.registry=${GITEA_IMAGE_REGISTRY}"
        --set "image.repository=${GITEA_IMAGE_REPO}"
        --set "image.tag=1.25.5"
    )
fi

HELM_DB_ARGS=()
if [ "${DB_TYPE}" = "2" ]; then
    # PostgreSQL 단일 인스턴스 활성화
    PG_IMAGE_REPO="${HARBOR_PROJECT}/postgresql"
    HELM_DB_ARGS=(
        --set "postgresql.enabled=true"
        --set "postgresql-ha.enabled=false"
        --set "gitea.config.database.DB_TYPE=postgres"
        --set "gitea.config.database.HOST=gitea-postgresql:5432"
        --set "gitea.config.database.NAME=gitea"
        --set "gitea.config.database.USER=gitea"
        --set "gitea.config.database.PASSWD=gitea"
    )
    if [ "${IMAGE_SOURCE}" = "1" ]; then
        HELM_DB_ARGS+=(
            --set "postgresql.image.registry=${HARBOR_REGISTRY}"
            --set "postgresql.image.repository=${PG_IMAGE_REPO}"
        )
    fi
fi

# ── Helm 설치 / 업그레이드 ────────────────────────────────────
if [ ! -d "${CHART_PATH}" ]; then
    echo "[오류] Helm 차트 디렉토리 '${CHART_PATH}' 가 없습니다."; exit 1
fi

echo ""
echo ">>> Helm ${DO_UPGRADE:+upgrade}${DO_UPGRADE:-install} 실행 중..."
helm upgrade --install gitea "${CHART_PATH}" \
    -n "${NAMESPACE}" \
    -f "${VALUES_FILE}" \
    "${HELM_IMAGE_ARGS[@]}" \
    "${HELM_DB_ARGS[@]}" \
    ${NODE_FLAG}

echo ""
echo ">>> Gitea Pod 준비 대기 중 (최대 5분)..."
kubectl wait --timeout=5m -n "${NAMESPACE}" \
    deployment/gitea --for=condition=Available 2>/dev/null || \
kubectl rollout status deployment/gitea -n "${NAMESPACE}" --timeout=5m

# ── NodePort 패치 ─────────────────────────────────────────────
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
echo " 초기 관리자 비밀번호 확인:"
echo "   kubectl get secret gitea-admin-secret -n ${NAMESPACE} -o jsonpath='{.data.password}' | base64 -d"
echo "   (없으면 values.yaml 의 adminPassword 항목 참조)"
echo "==========================================="
kubectl get pods -n "${NAMESPACE}"
