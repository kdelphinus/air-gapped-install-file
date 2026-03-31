#!/bin/bash

# 스크립트 위치 기준으로 컴포넌트 루트로 이동 (scripts/ 하위에서 실행해도 경로 안전)
cd "$(dirname "$0")/.." || exit 1

# ==============================================================================
# 🛠️ [설정 변수] 환경에 맞게 이 부분만 수정하세요.
# ==============================================================================

# 1. 이미지 소스 선택
# ── 이미지 소스 선택 ──────────────────────────────────────────
echo ""
echo "이미지 소스를 선택하세요:"
echo "  1) Harbor 레지스트리 사용 (사전에 upload_images_to_harbor_v3-lite.sh 실행 필요)"
echo "  2) 로컬 tar 직접 import (Harbor 없음)"
read -p "선택 [1/2, 기본값: 1]: " IMAGE_SOURCE
IMAGE_SOURCE="${IMAGE_SOURCE:-1}"

if [ "${IMAGE_SOURCE}" = "1" ]; then
    read -p "Harbor 레지스트리 주소 (예: 192.168.1.10:30002 또는 harbor.example.com): " REGISTRY_URL
    if [ -z "${REGISTRY_URL}" ]; then
        echo "[오류] Harbor 레지스트리 주소가 필요합니다."; exit 1
    fi
    read -p "Harbor 프로젝트 (예: library, oss): " HARBOR_PROJECT
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
    REGISTRY_URL=""
    HARBOR_PROJECT=""
else
    echo "[오류] 1 또는 2를 선택하세요."; exit 1
fi

# Jenkins Controller (Master) 설정
CONTROLLER_REPO="${HARBOR_PROJECT}/cmp-jenkins-full"
CONTROLLER_TAG="2.528.3"        # 방금 빌드한 버전
NODE_LABEL_KEY="jenkins-node"   # 노드 고정을 위한 라벨 키
NODE_LABEL_VALUE="true"         # 노드 고정을 위한 라벨 값

# Jenkins Agent (Slave) 설정
AGENT_REPO="${HARBOR_PROJECT}/inbound-agent"
AGENT_TAG="latest"

# Sidecar (Config Auto Reload) 설정
SIDECAR_REPO="${HARBOR_PROJECT}/k8s-sidecar"
SIDECAR_TAG="1.30.7"

# 2. 쿠버네티스 설정
DOMAIN=""                       # HTTPRoute 도메인, "" 이면 NodePort로만 접속 (CoreDNS 등록 건너뜀)
NAMESPACE="jenkins"
IMAGE_PULL_SECRET="regcred"     # Private Registry 접근을 위한 시크릿 이름
STORAGE_CLASS="manual"          # PV 스토리지 클래스 이름 (HostPath 사용 시 manual)
STORAGE_SIZE="20Gi"
NODE_PORT="30000"

# 3. 헬름 차트 경로 (현재 경로 기준)
CHART_PATH="./charts/jenkins"

# ==============================================================================
# 🚀 스크립트 실행 시작
# ==============================================================================
set -e # 에러 발생 시 스크립트 중단

echo "🔄 [1/6] 네임스페이스 확인 및 생성..."
if kubectl get namespace "$NAMESPACE" > /dev/null 2>&1; then
    echo "   ✅ 네임스페이스 '$NAMESPACE'가 이미 존재합니다."
else
    kubectl create namespace "$NAMESPACE"
    echo "   ✅ 네임스페이스 '$NAMESPACE'를 생성했습니다."
fi

# ==============================================================================
# 📂 [2/6] PV / PVC 생성 (Jenkins 홈 + Gradle 캐시)
# ==============================================================================
echo ""
echo "📂 [2/6] PV / PVC 생성 중..."

echo "   - Jenkins 홈 PV 적용 중..."
kubectl apply -f ./manifests/pv-volume.yaml

echo "   - Gradle 캐시 PV/PVC 적용 중..."
kubectl apply -f ./manifests/gradle-cache-pv-pvc.yaml

echo "   ✅ PV / PVC 적용 완료."

# ==============================================================================
# 🖥️ [3/6] 노드 지정 (Node Pinning) 로직 추가
# ==============================================================================
echo ""
echo "--------------------------------------------------------"
echo "🖥️  [설정] Jenkins Controller가 배포될 노드 지정 [3/6]"
echo "--------------------------------------------------------"

# 기존 라벨 정리 (중복 방지)
echo "🧹 기존 노드에 부여된 Jenkins 라벨 정리 중..."
kubectl label nodes --all ${NODE_LABEL_KEY}- > /dev/null 2>&1 || true

echo "현재 클러스터의 노드 목록:"
kubectl get nodes
echo ""

read -p "❓ Jenkins를 배포할 노드 이름(NAME)을 입력해주세요: " TARGET_NODE

if [ -z "$TARGET_NODE" ]; then
    echo "❌ 노드 이름이 입력되지 않았습니다. 스크립트를 종료합니다."
    exit 1
fi

# 노드 존재 여부 확인
if ! kubectl get node "$TARGET_NODE" > /dev/null 2>&1; then
    echo "❌ 오류: '$TARGET_NODE'라는 노드를 찾을 수 없습니다."
    exit 1
fi

echo "🔹 '$TARGET_NODE' 노드에 '$NODE_LABEL_KEY=$NODE_LABEL_VALUE' 라벨을 적용합니다..."
kubectl label nodes "$TARGET_NODE" $NODE_LABEL_KEY=$NODE_LABEL_VALUE --overwrite
echo "✅ 노드 고정 설정 완료."

# ==============================================================================
# 📦 [4/6] Jenkins Helm 차트 배포
# ==============================================================================
echo ""
echo "📦 [4/6] Jenkins Helm 차트 배포 중..."

# 루트의 values.yaml 존재 확인
JENKINS_VALUES=""
if [ -f "./values.yaml" ]; then
    JENKINS_VALUES="-f ./values.yaml"
    echo "   ℹ️ 루트의 values.yaml 설정을 적용합니다."
fi

# 기존에 설치된 릴리스가 있다면 upgrade, 없다면 install
if helm status jenkins -n "$NAMESPACE" > /dev/null 2>&1; then
    ACTION="upgrade"
    echo "   ℹ️ 기존 배포가 감지되었습니다. 업그레이드를 진행합니다."
else
    ACTION="install"
    echo "   ℹ️ 신규 설치를 진행합니다."
fi

# Harbor 사용 시에만 이미지 레지스트리/프로젝트 오버라이드
HELM_IMAGE_ARGS=()
if [ "${IMAGE_SOURCE}" = "1" ]; then
    HELM_IMAGE_ARGS=(
        "--set" "controller.image.registry=${REGISTRY_URL}"
        "--set" "controller.image.repository=${CONTROLLER_REPO}"
        "--set" "agent.image.registry=${REGISTRY_URL}"
        "--set" "agent.image.repository=${AGENT_REPO}"
        "--set" "controller.sidecars.configAutoReload.image.registry=${REGISTRY_URL}"
        "--set" "controller.sidecars.configAutoReload.image.repository=${SIDECAR_REPO}"
    )
fi

# --set controller.nodeSelector 옵션 추가됨
helm $ACTION jenkins "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  $JENKINS_VALUES \
  \
  "${HELM_IMAGE_ARGS[@]}" \
  \
  --set controller.image.tag="$CONTROLLER_TAG" \
  --set controller.imagePullPolicy=Always \
  --set controller.imagePullSecrets[0].name="$IMAGE_PULL_SECRET" \
  \
  --set controller.serviceType=NodePort \
  --set controller.nodePort="$NODE_PORT" \
  \
  --set-string controller.nodeSelector.${NODE_LABEL_KEY}=${NODE_LABEL_VALUE} \
  \
  --set agent.image.tag="$AGENT_TAG" \
  --set agent.imagePullPolicy=IfNotPresent \
  --set agent.imagePullSecrets[0].name="$IMAGE_PULL_SECRET" \
  \
  --set persistence.storageClass="$STORAGE_CLASS" \
  --set persistence.size="$STORAGE_SIZE" \
  \
  --set controller.sidecars.configAutoReload.image.tag="$SIDECAR_TAG" \
  --set controller.sidecars.configAutoReload.imagePullPolicy=IfNotPresent \
  \
  --set controller.runAsUser=1000 \
  --set controller.fsGroup=1000 \
  \
  --set controller.installPlugins=false

echo "⏳ [5/6] Pod가 준비될 때까지 대기 중... (최대 5분)"
# Pod가 Running 및 Ready 상태가 될 때까지 대기
kubectl wait --namespace "$NAMESPACE" \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=jenkins-controller \
  --timeout=300s

echo "🔑 [6/6] 초기 관리자 비밀번호 확인"
echo "--------------------------------------------------------"
PASSWORD=$(kubectl get secret -n "$NAMESPACE" jenkins -o jsonpath="{.data.jenkins-admin-password}" | base64 --decode)
echo "   👤 ID: admin"
echo "   🔐 PW: $PASSWORD"
echo "   🖥️  Node: $TARGET_NODE"
echo "--------------------------------------------------------"
echo "🎉 Jenkins 배포가 완료되었습니다!"
echo "👉 접속 주소: http://<NodeIP>:$NODE_PORT"

# ---- CoreDNS 등록 ----
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

if [ -n "$DOMAIN" ]; then
    echo ""
    read -p "❓ ${DOMAIN} 이 DNS 서버에 이미 등록되어 있나요? (y/n): " DNS_REGISTERED
    if [[ "$DNS_REGISTERED" == "y" || "$DNS_REGISTERED" == "Y" ]]; then
        echo "  - DNS 서버에 등록됨 — CoreDNS 등록을 건너뜁니다."
    else
        echo ">>> CoreDNS에 ${DOMAIN} 등록 중..."
        NODE_IP=$(kubectl get nodes \
            -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
        add_coredns_host "$NODE_IP" "$DOMAIN"
    fi
else
    echo ""
    echo ">>> DOMAIN 미설정 — CoreDNS 등록을 건너뜁니다. (NodePort로만 접속)"
fi

if [ -n "$DOMAIN" ]; then
    echo ""
    echo "==========================================="
    echo " [주의] 클라이언트 hosts 등록 필요"
    echo "==========================================="
    echo " 도메인으로 접속하려면 접속할 PC의 hosts 파일에 아래 항목을 추가하세요."
    echo ""
    echo "   <GATEWAY_IP>  ${DOMAIN}"
    echo ""
    echo " - Windows: C:\\Windows\\System32\\drivers\\etc\\hosts"
    echo " - Linux/Mac: /etc/hosts"
    echo "==========================================="
fi