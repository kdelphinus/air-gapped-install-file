#!/bin/bash

# ==========================================
# [설정] 변수 정의
# ==========================================
NAMESPACE="gitlab"
RELEASE_NAME="gitlab"
PV_FILE="gitlab-pv.yaml"
HTTPROUTE_FILE="gitlab-httproutes.yaml"
VALUES_FILE="install-gitlab-values.yaml"
NODE_LABEL_KEY="gitlab-node"
NODE_LABEL_VALUE="true"
HARBOR_REGISTRY="harbor.test.com:30002"  # Harbor 주소
HARBOR_PROJECT="cmp"           # Harbor 프로젝트 명

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

# ==========================================
# 4. Helm 배포
# ==========================================
echo ""
echo "🚀 [4/4] GitLab Helm 배포 시작..."

if [ ! -f "$VALUES_FILE" ]; then
    echo "❌ 오류: 현재 폴더에 '$VALUES_FILE' 파일이 없습니다!"
    exit 1
fi

echo "   Applying Images from: $IMAGE_VALUES_FILE"

# 노드 선택 여부에 따른 로그 출력
if [ -n "$NODE_SELECTOR_ARGS" ]; then
    echo "   Target Node Label: $NODE_LABEL_KEY=$NODE_LABEL_VALUE"
    helm upgrade --install $RELEASE_NAME gitlab \
    -f $VALUES_FILE \
    -f $IMAGE_VALUES_FILE \
    --namespace $NAMESPACE \
    --timeout 600s \
    $NODE_SELECTOR_ARGS
else
    echo "   Node Selector: None (Automatic Scheduling)"
    helm upgrade --install $RELEASE_NAME gitlab \
    -f $VALUES_FILE \
    -f $IMAGE_VALUES_FILE \
    --namespace $NAMESPACE \
    --timeout 600s
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
