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
    echo "  - Namespace '$NAMESPACE' 삭제 중 (시간이 걸릴 수 있습니다)..."
    kubectl delete ns $NAMESPACE --wait=true
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

read -p "❓ GitLab을 배포할 노드 이름(NAME)을 입력해주세요: " TARGET_NODE

if [ -z "$TARGET_NODE" ]; then
    echo "❌ 노드 이름이 입력되지 않았습니다. 스크립트를 종료합니다."
    exit 1
fi

if ! kubectl get node "$TARGET_NODE" > /dev/null 2>&1; then
    echo "❌ 오류: '$TARGET_NODE'라는 노드를 찾을 수 없습니다."
    exit 1
fi

echo "🔹 '$TARGET_NODE' 노드에 '$NODE_LABEL_KEY=$NODE_LABEL_VALUE' 라벨을 적용합니다..."
kubectl label nodes "$TARGET_NODE" $NODE_LABEL_KEY=$NODE_LABEL_VALUE --overwrite
echo "✅ 노드 고정 설정 완료."

# ==========================================
# 4. Helm 배포 (핵심 수정)
# ==========================================
echo ""
echo "🚀 [4/4] GitLab Helm 배포 시작..."

if [ ! -f "$VALUES_FILE" ]; then
    echo "❌ 오류: 현재 폴더에 '$VALUES_FILE' 파일이 없습니다!"
    exit 1
fi

# [수정 포인트] --set 대신 --set-string 사용!
# global.nodeSelector는 모든 GitLab 컴포넌트(Webservice, Sidekiq 등)에 적용됩니다.
echo "   Target Node Label: $NODE_LABEL_KEY=$NODE_LABEL_VALUE"

helm install $RELEASE_NAME gitlab \
  -f $VALUES_FILE \
  --namespace $NAMESPACE \
  --timeout 600s \
  --set-string global.nodeSelector.${NODE_LABEL_KEY}=${NODE_LABEL_VALUE}

echo ""
echo "========================================================"
echo "🎉 초기화 및 재배포 명령이 완료되었습니다."
echo "   지정된 노드: $TARGET_NODE"
echo "⏳ 파드가 Running 상태가 될 때까지 기다려주세요."
echo "👉 모니터링 명령: kubectl get pods -n $NAMESPACE -w"
echo "========================================================"