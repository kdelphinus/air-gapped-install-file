#!/bin/bash

# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="metallb-system"
RELEASE="metallb"
CONF_FILE="./install.conf"

echo "🧹 [Uninstall] MetalLB 리소스 및 네임스페이스 완전 삭제 시작..."

# 1. Helm 릴리스 제거
if helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "🗑️  Helm release '$RELEASE' 제거 중..."
    helm uninstall "$RELEASE" -n "$NAMESPACE" --wait=false
else
    echo "ℹ️  Helm release '$RELEASE'가 이미 존재하지 않거나 제거된 상태입니다."
fi

echo "⏳ 리소스 삭제 대기 중 (5초)..."
sleep 5

# 2. Finalizer 일괄 제거 (CRD 자원 삭제 시 hanging 방지)
echo "🔫 MetalLB Custom Resource Finalizer 일괄 제거 중..."
for KIND in ipaddresspool l2advertisement bgpadvertisement bgppeer community bfdprofile; do
    kubectl get $KIND -n $NAMESPACE -o name 2>/dev/null | \
    xargs -r -I {} kubectl patch {} -n $NAMESPACE -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
done

# 3. 네임스페이스 삭제
if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
    echo "🗑️  네임스페이스 '$NAMESPACE' 삭제 중..."
    kubectl delete ns "$NAMESPACE" --timeout=30s --wait=false 2>/dev/null
fi

# 4. 설정 파일 제거
if [ -f "$CONF_FILE" ]; then
    rm -f "$CONF_FILE"
    echo "🗑️  설정 파일($CONF_FILE) 삭제 완료."
fi

echo "✅ MetalLB 삭제 완료."
