#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

DEFAULT_NAMESPACE="opentelemetry"
CONF_FILE="./install.conf"

# install.conf에서 네임스페이스 가져오기 시도
if [ -f "$CONF_FILE" ]; then
    source "$CONF_FILE"
fi

TARGET_NAMESPACE="${TARGET_NAMESPACE:-$DEFAULT_NAMESPACE}"

echo "==========================================="
echo " Uninstalling OpenTelemetry Operator v0.114.1"
echo "==========================================="
read -p "❓ 정말 삭제하시겠습니까? (y/n): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "취소되었습니다."; exit 0; }

# Helm 제거
if helm status otel-operator -n "$TARGET_NAMESPACE" > /dev/null 2>&1; then
    echo "🗑️  Helm Release 'otel-operator' 삭제 중..."
    helm uninstall otel-operator -n "$TARGET_NAMESPACE" --wait=false
else
    echo "  - 삭제할 Helm Release 'otel-operator'가 없습니다."
fi

echo "⏳ 리소스 삭제 대기 중..."
sleep 5

# Finalizer 제거 (좀비 리소스 방지)
echo "🔧 Finalizer 일괄 제거 중..."
for KIND in deployment service serviceaccount configmap; do
    kubectl get $KIND -n "$TARGET_NAMESPACE" -o name 2>/dev/null | grep otel-operator | \
        xargs -r -I {} kubectl patch {} -n "$TARGET_NAMESPACE" \
        -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
done

# 웹훅 리소스 강제 삭제 (네임스페이스 외부에 생성되므로 명시적 삭제 필수)
echo "🗑️  Mutating/Validating Webhook Configuration 삭제 중..."
kubectl delete mutatingwebhookconfiguration otel-operator-mutating-webhook-configuration --ignore-not-found=true 2>/dev/null || true
kubectl delete validatingwebhookconfiguration otel-operator-validating-webhook-configuration --ignore-not-found=true 2>/dev/null || true

# 사용자 지정 네임스페이스이면서 디폴트가 아닌 경우 네임스페이스 삭제 시도
if [ "$TARGET_NAMESPACE" != "monitoring" ] && [ "$TARGET_NAMESPACE" != "kube-system" ] && [ "$TARGET_NAMESPACE" != "default" ]; then
    echo "🗑️  Namespace '$TARGET_NAMESPACE' 삭제 중..."
    kubectl delete ns "$TARGET_NAMESPACE" --ignore-not-found=true --timeout=15s 2>/dev/null || true

    # 네임스페이스가 Terminating에 걸릴 경우 강제 처리
    if kubectl get ns "$TARGET_NAMESPACE" > /dev/null 2>&1; then
        echo "⚠️  Namespace가 Terminating 상태입니다. 강제 삭제 중..."
        kubectl get namespace "$TARGET_NAMESPACE" -o json 2>/dev/null | \
            tr -d "\n" | \
            sed "s/\"kubernetes\"//g" | \
            kubectl replace --raw "/api/v1/namespaces/$TARGET_NAMESPACE/finalize" -f - > /dev/null 2>&1 || true
    fi
fi

# 설정 파일 제거 여부 질문
read -p "❓ 로컬 설정 파일(${CONF_FILE})도 제거하시겠습니까? (y/N): " DEL_CONF
if [[ "$DEL_CONF" =~ ^[Yy]$ ]]; then
    rm -f "$CONF_FILE"
    echo "🗑️  설정 파일(${CONF_FILE})이 삭제되었습니다."
fi

echo ""
echo "✅ OpenTelemetry Operator 삭제 완료."
