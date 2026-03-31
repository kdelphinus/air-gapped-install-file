#!/bin/bash

# 스크립트 위치 기준으로 컴포넌트 루트로 이동 (scripts/ 하위에서 실행해도 경로 안전)
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
NODE_LABEL_KEY="gitlab-node"
NODE_LABEL_VALUE="true"

# ── 이미지 소스 선택 ──────────────────────────────────────────
echo ""
echo "이미지 소스를 선택하세요:"
echo "  1) Harbor 레지스트리 사용 (사전에 images/upload_images_to_harbor_v3-lite.sh 실행 필요)"
echo "  2) 로컬 tar 직접 import (이미 이미지가 로드된 경우 건너뜀)"
read -p "선택 [1/2, 기본값: 1]: " IMAGE_SOURCE
IMAGE_SOURCE="${IMAGE_SOURCE:-1}"

if [ "${IMAGE_SOURCE}" = "1" ]; then
    read -p "Harbor 레지스트리 주소 (예: 192.168.1.10:30002 또는 harbor.example.com): " HARBOR_REGISTRY
    if [ -z "${HARBOR_REGISTRY}" ]; then
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
    HARBOR_REGISTRY=""
    HARBOR_PROJECT=""
else
    echo "[오류] 1 또는 2를 선택하세요."; exit 1
fi

DOMAIN="gitlab.devops.internal" # CoreDNS 등록 도메인, "" 이면 건너뜀

echo "========================================================"
echo "🚀 GitLab 완전 초기화 및 재설치 스크립트를 시작합니다."
echo "========================================================"

# ==========================================
# 1. 기존 리소스 정리 (Clean Up)
# ==========================================
echo ""
echo "🧹 [1/4] 기존 리소스 삭제 중..."

# 1-1. Helm 삭제
if helm status $RELEASE_NAME -n $NAMESPACE > /dev/null 2>&1; then
    echo "  - Helm Release '$RELEASE_NAME' 삭제 중..."
    helm uninstall $RELEASE_NAME -n $NAMESPACE
else
    echo "  - 삭제할 Helm Release가 없습니다."
fi

# 1-2. 네임스페이스 삭제
if kubectl get ns $NAMESPACE > /dev/null 2>&1; then
    echo "  - Namespace '$NAMESPACE' 삭제 명령 전달 (백그라운드 진행)..."
    kubectl delete ns $NAMESPACE --wait=false
else
    echo "  - Namespace '$NAMESPACE'가 이미 없습니다."
fi

# 1-3. PV 삭제 (파일이 있다면)
if [ -f "$PV_FILE" ]; then
    echo "  - 기존 PV 리소스 삭제 중..."
    kubectl delete -f $PV_FILE --ignore-not-found=true
fi

# 1-4. 잔여 PV 강제 정리
echo "  - 잔여 GitLab 관련 PV 강제 정리..."
kubectl delete pv gitlab-postgresql-pv gitlab-redis-pv gitlab-gitaly-pv gitlab-minio-pv --ignore-not-found=true

# 1-5. CRD 및 기타 리소스 삭제
kubectl delete validatingwebhookconfiguration gitlab-certmanager-webhook --ignore-not-found=true
kubectl delete mutatingwebhookconfiguration gitlab-certmanager-webhook --ignore-not-found=true
kubectl delete -f $HTTPROUTE_FILE --ignore-not-found=true

# 1-6. 기존 노드 라벨 정리
echo "  - 기존 노드에 부여된 GitLab 라벨 제거 중..."
kubectl label nodes --all ${NODE_LABEL_KEY}- > /dev/null 2>&1 || true

# ==========================================
# 2. HTTPRoute 생성 (Gateway API)
# ==========================================
echo ""
echo "📄 [2/4] $HTTPROUTE_FILE 파일 적용..."

kubectl create ns $NAMESPACE

echo ""
read -p "❓ NGINX Ingress Controller를 사용하시나요? (y/n): " USE_NGINX

if [[ "$USE_NGINX" == "n" || "$USE_NGINX" == "N" ]]; then
    if [ -f "$HTTPROUTE_FILE" ]; then
        echo "🚀 [Envoy Gateway 모드] $HTTPROUTE_FILE 설정을 적용합니다..."
        kubectl apply -f $HTTPROUTE_FILE
    else
        echo "⚠️  경고: $HTTPROUTE_FILE 파일이 없어 적용하지 못했습니다."
    fi
else
    echo "🚫 [NGINX 모드] HTTPRoute(Gateway API) 적용을 건너뜁니다."
fi

# ==========================================
# 3. PV 생성 & 노드 지정
# ==========================================
echo ""
echo "📄 [3/4] 스토리지 및 노드 설정..."

kubectl apply -f $PV_FILE

echo ""
echo "--------------------------------------------------------"
echo "🖥️  [설정] GitLab이 배포될 노드 지정 (Node Pinning)"
echo "--------------------------------------------------------"
echo "현재 클러스터의 노드 목록:"
kubectl get nodes
echo ""

read -p "❓ GitLab을 배포할 노드 이름(NAME)을 입력해주세요 (엔터 입력 시 자동 분산 배포): " TARGET_NODE

# [핵심] Helm에 전달할 인자 변수 초기화 (기본값: 빈 값)
NODE_SELECTOR_ARGS=""

if [ -z "$TARGET_NODE" ]; then
    # 1) 엔터 입력 시 (노드 지정 안 함)
    echo "⚠️  노드 이름이 입력되지 않았습니다. 노드 고정(Node Pinning)을 건너뜁니다."
    echo "   👉 Kubernetes 스케줄러가 자원이 충분한 노드에 자동으로 배포합니다."
    # NODE_SELECTOR_ARGS는 여전히 빈 값입니다.
else
    # 2) 노드 이름 입력 시
    if ! kubectl get node "$TARGET_NODE" > /dev/null 2>&1; then
        echo "❌ 오류: '$TARGET_NODE'라는 노드를 찾을 수 없습니다."
        exit 1
    fi

    echo "🔹 '$TARGET_NODE' 노드에 '$NODE_LABEL_KEY=$NODE_LABEL_VALUE' 라벨을 적용합니다..."
    
    # 혹시 모를 기존 라벨 충돌 방지를 위해 덮어쓰기(--overwrite) 옵션 사용
    kubectl label nodes "$TARGET_NODE" $NODE_LABEL_KEY=$NODE_LABEL_VALUE --overwrite
    echo "✅ 노드 고정 설정 완료."
    
    # [핵심] Helm에 전달할 옵션을 변수에 저장
    NODE_SELECTOR_ARGS="--set-string global.nodeSelector.${NODE_LABEL_KEY}=${NODE_LABEL_VALUE} \
                        --set-string redis.master.nodeSelector.${NODE_LABEL_KEY}=${NODE_LABEL_VALUE} \
                        --set-string postgresql.primary.nodeSelector.${NODE_LABEL_KEY}=${NODE_LABEL_VALUE}"
fi

# ==========================================
# 3.5. [자동화] 폐쇄망 이미지 경로 오버라이드 파일 생성
# ==========================================
IMAGE_VALUES_FILE="gitlab-images-override.yaml"

if [ "${IMAGE_SOURCE}" = "1" ]; then
    echo ""
    echo "⚙️  [자동화] Harbor 이미지 설정을 위한 '$IMAGE_VALUES_FILE' 생성 중..."

    cat <<EOF > $IMAGE_VALUES_FILE
global:
  image:
    registry: ${HARBOR_REGISTRY}
    pullPolicy: IfNotPresent

  # 공통 Helper 이미지
  kubectl:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/kubectl
  certificates:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/certificates
  gitlabBase:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-base

# 1. GitLab 메인 컴포넌트
gitlab:
  webservice:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-webservice-ce
    # [수정] Workhorse 이미지 추가
    workhorse:
      image: "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-workhorse-ce"

  sidekiq:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-sidekiq-ce
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

# 2. MinIO 설정
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

# 3. Cert-Manager
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

# 4. PostgreSQL & Redis
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

    echo "✅ 이미지 설정 파일 생성 완료."
else
    echo ""
    echo "ℹ️  로컬 import 모드 — '$IMAGE_VALUES_FILE' 생성을 건너뜁니다."
    IMAGE_VALUES_FILE=""
fi

# ==========================================
# 4. Helm 배포
# ==========================================
echo ""
echo "🚀 [4/4] GitLab Helm 배포 시작..."

if [ ! -f "$VALUES_FILE" ]; then
    echo "❌ 오류: 현재 폴더에 '$VALUES_FILE' 파일이 없습니다!"
    exit 1
fi

# 이미지 values 파일 인자 조건부 구성
IMAGE_VALUES_ARG=""
if [ -n "$IMAGE_VALUES_FILE" ]; then
    echo "   Applying Images from: $IMAGE_VALUES_FILE"
    IMAGE_VALUES_ARG="-f $IMAGE_VALUES_FILE"
else
    echo "   Image Values: 로컬 import 모드 (이미지 오버라이드 없음)"
fi

# 노드 선택 여부에 따른 로그 출력
if [ -n "$NODE_SELECTOR_ARGS" ]; then
    echo "   Target Node Label: $NODE_LABEL_KEY=$NODE_LABEL_VALUE"
    helm upgrade --install $RELEASE_NAME "$CHART_PATH" \
    -f $VALUES_FILE \
    $IMAGE_VALUES_ARG \
    --namespace $NAMESPACE \
    --timeout 600s \
    $NODE_SELECTOR_ARGS
else
    echo "   Node Selector: None (Automatic Scheduling)"
    helm upgrade --install $RELEASE_NAME "$CHART_PATH" \
    -f $VALUES_FILE \
    $IMAGE_VALUES_ARG \
    --namespace $NAMESPACE \
    --timeout 600s
fi

# ==========================================
# CoreDNS 등록
# ==========================================
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
        echo ">>> CoreDNS에 GitLab 도메인 등록 중..."
        NODE_IP=$(kubectl get nodes \
            -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
        add_coredns_host "$NODE_IP" "$DOMAIN"
    fi
else
    echo ""
    echo ">>> DOMAIN 미설정 — CoreDNS 등록을 건너뜁니다. (IP로 직접 접속)"
fi

echo ""
echo "========================================================"
echo "🎉 GitLab 설치 명령이 성공적으로 전달되었습니다."
echo "========================================================"
echo "📊 [모니터링] 설치 상태 확인:"
echo "   - Pod 상태: kubectl get pods -n $NAMESPACE -w"
echo "   - PV 상태:  kubectl get pv | grep gitlab"
echo "   - 이벤트:   kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp'"
echo ""
echo "🧹 [삭제/초기화] 필요 시 아래 명령을 실행하세요:"
echo "   - helm uninstall $RELEASE_NAME -n $NAMESPACE"
echo "   - kubectl delete ns $NAMESPACE"
echo "   - kubectl delete -f $PV_FILE"
echo "========================================================"

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
