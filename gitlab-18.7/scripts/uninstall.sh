#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="gitlab"
RELEASE_NAME="gitlab"
PV_FILE="./manifests/gitlab-pv.yaml"
HTTPROUTE_FILE="./manifests/gitlab-httproutes.yaml"
NODE_LABEL_KEY="gitlab-node"

echo "==========================================="
echo " Uninstalling GitLab 18.7"
echo "==========================================="
read -p "❓ 정말 삭제하시겠습니까? (y/n): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "취소되었습니다."; exit 0; }

# Helm 제거
if helm status $RELEASE_NAME -n $NAMESPACE > /dev/null 2>&1; then
    echo "🗑️  Helm Release '$RELEASE_NAME' 삭제 중..."
    helm uninstall $RELEASE_NAME -n $NAMESPACE
else
    echo "  - 삭제할 Helm Release가 없습니다."
fi

# Webhook 제거
echo "🗑️  Webhook 제거 중..."
kubectl delete validatingwebhookconfiguration gitlab-certmanager-webhook --ignore-not-found=true
kubectl delete mutatingwebhookconfiguration gitlab-certmanager-webhook --ignore-not-found=true

# HTTPRoute 제거
if [ -f "$HTTPROUTE_FILE" ]; then
    echo "🗑️  HTTPRoute 삭제 중..."
    kubectl delete -f $HTTPROUTE_FILE --ignore-not-found=true
fi

# 노드 라벨 제거
echo "🗑️  노드 라벨 '$NODE_LABEL_KEY' 제거 중..."
kubectl label nodes --all ${NODE_LABEL_KEY}- > /dev/null 2>&1 || true

# 임시 파일 제거
rm -f ./gitlab-images-override.yaml ./gitlab-generated-values.yaml 2>/dev/null || true

# 네임스페이스 삭제 (PVC 포함) — PV 삭제 전에 먼저 실행
echo "🗑️  Namespace '$NAMESPACE' 삭제 중..."
kubectl delete ns $NAMESPACE --ignore-not-found=true --wait=false

# PV 삭제 여부 (Retain policy — 삭제 시 데이터 유실)
echo ""
read -p "⚠️  PV도 삭제하시겠습니까? (데이터 유실 주의) (y/n): " DELETE_PV
if [[ "$DELETE_PV" =~ ^[Yy]$ ]]; then
    # PVC가 완전히 삭제될 때까지 대기 (최대 60초)
    echo "⏳ PVC 삭제 완료 대기 중..."
    for i in $(seq 1 60); do
        PVC_COUNT=$(kubectl get pvc -n $NAMESPACE --no-headers 2>/dev/null | wc -l)
        [ "$PVC_COUNT" -eq 0 ] && break
        sleep 1
    done
    echo "🗑️  PV 삭제 중..."
    if [ -f "$PV_FILE" ]; then
        kubectl delete -f $PV_FILE --ignore-not-found=true
    fi
    kubectl delete pv gitlab-postgresql-pv gitlab-redis-pv gitlab-gitaly-pv gitlab-minio-pv --ignore-not-found=true
fi

echo ""
echo "✅ GitLab 삭제 완료."
echo "   PV 데이터가 남아있는 경우 호스트 경로에서 직접 삭제하세요."
