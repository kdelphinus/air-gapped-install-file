#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

echo "==========================================="
echo " Uninstalling Tekton v1.9.0"
echo "==========================================="
read -p "❓ 정말 삭제하시겠습니까? (y/n): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "취소되었습니다."; exit 0; }

MANIFESTS_DIR="./manifests"

# Dashboard 제거 (있는 경우)
if kubectl get ns tekton-pipelines > /dev/null 2>&1 && \
   kubectl get deployment tekton-dashboard -n tekton-pipelines > /dev/null 2>&1; then
    echo "🗑️  Tekton Dashboard 삭제 중..."
    kubectl delete -f "${MANIFESTS_DIR}/dashboard-v0.65.0-release.yaml" \
        --ignore-not-found=true 2>/dev/null || true
fi

# Triggers 제거 (있는 경우)
if kubectl get ns tekton-pipelines > /dev/null 2>&1 && \
   kubectl get deployment tekton-triggers-controller -n tekton-pipelines > /dev/null 2>&1; then
    echo "🗑️  Tekton Triggers 삭제 중..."
    kubectl delete -f "${MANIFESTS_DIR}/triggers-v0.34.x-release.yaml" \
        --ignore-not-found=true 2>/dev/null || true
fi

# Pipelines 제거
echo "🗑️  Tekton Pipelines 삭제 중..."
kubectl delete -f "${MANIFESTS_DIR}/pipelines-v1.9.0-release.yaml" \
    --ignore-not-found=true 2>/dev/null || true

# 네임스페이스 강제 삭제 (Finalizer 잔류 대비)
for NS in tekton-pipelines tekton-pipelines-resolvers tekton-triggers tekton-dashboard; do
    if kubectl get ns "${NS}" > /dev/null 2>&1; then
        echo "🗑️  Namespace '${NS}' 삭제 중..."
        kubectl delete ns "${NS}" --ignore-not-found=true --timeout=30s
    fi
done

echo ""
echo "✅ Tekton 삭제 완료."
