#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="envoy-gateway-system"
GW_NAME="cluster-gateway"
GLOBAL_POLICY_FILE="./manifests/policy-global-config.yaml"

echo "==========================================="
echo " Uninstalling Envoy Gateway 1.7.2 / Proxy 1.37.2"
echo "==========================================="
read -p "❓ 정말 삭제하시겠습니까? (y/n): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "취소되었습니다."; exit 0; }

# 전역 정책 제거
if [ -f "$GLOBAL_POLICY_FILE" ]; then
    echo "🗑️  전역 정책 삭제 중..."
    kubectl delete -f $GLOBAL_POLICY_FILE --ignore-not-found=true
fi

# Helm 제거
for RELEASE in gateway-infra eg-gateway; do
    if helm status $RELEASE -n $NAMESPACE > /dev/null 2>&1; then
        echo "🗑️  Helm Release '$RELEASE' 삭제 중..."
        helm uninstall $RELEASE -n $NAMESPACE --wait=false
    else
        echo "  - 삭제할 Helm Release '$RELEASE'가 없습니다."
    fi
done

echo "⏳ 리소스 삭제 대기 중..."
sleep 5

# Finalizer 제거 (좀비 리소스 방지)
echo "🔧 Finalizer 일괄 제거 중..."
for KIND in gateway gatewayclass envoyproxy httproute service; do
    kubectl get $KIND -n $NAMESPACE -o name 2>/dev/null | \
        xargs -r -I {} kubectl patch {} -n $NAMESPACE \
        -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
done

# 네임스페이스 삭제
echo "🗑️  Namespace '$NAMESPACE' 삭제 중..."
kubectl delete ns $NAMESPACE --ignore-not-found=true --timeout=15s 2>/dev/null || true

# 네임스페이스가 Terminating에 걸릴 경우 강제 처리
if kubectl get ns $NAMESPACE > /dev/null 2>&1; then
    echo "⚠️  Namespace가 Terminating 상태입니다. 강제 삭제 중..."
    kubectl get namespace $NAMESPACE -o json 2>/dev/null | \
        tr -d "\n" | \
        sed "s/\"kubernetes\"//g" | \
        kubectl replace --raw "/api/v1/namespaces/$NAMESPACE/finalize" -f - > /dev/null 2>&1 || true
fi

echo ""
echo "✅ Envoy Gateway 삭제 완료."
