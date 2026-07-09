#!/bin/bash
# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="monitoring"
RELEASE_NAME="prometheus"
CONF_FILE="./install.conf"

# 색상 코드
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

RESET_MODE="uninstall"
if [ "$1" == "--reset" ] || [ "$1" == "reset" ]; then
    RESET_MODE="reset"
fi

echo "==========================================="
echo " Uninstalling Monitoring (kube-prometheus-stack)"
echo "==========================================="

read -p "❓ 정말 삭제하시겠습니까? (y/n): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "취소되었습니다."; exit 0; }

echo ""
read -p "⚠️  PV/PVC도 함께 삭제하시겠습니까? (데이터 영구 삭제, y/n): " DELETE_VOLUMES

# 1. 볼륨 보존 선택 시 헬름 언인스톨 전 동적 PVC keep 어노테이션 주입
if [[ ! "${DELETE_VOLUMES}" =~ ^[Yy]$ ]]; then
    if kubectl get pvc -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "🛡️  볼륨 보존을 위해 Namespace '$NAMESPACE' 하위의 모든 PVC에 keep resource-policy를 설정합니다..."
        pvc_list=$(kubectl get pvc -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
        for pvc_name in $pvc_list; do
            [ -n "$pvc_name" ] || continue
            echo "   → PVC: $pvc_name"
            kubectl annotate pvc "$pvc_name" -n "$NAMESPACE" "helm.sh/resource-policy=keep" --overwrite 2>/dev/null || true
        done
    fi
fi

# 2. Helm 릴리스 제거
if helm status $RELEASE_NAME -n $NAMESPACE > /dev/null 2>&1; then
    echo "🗑️  Helm Release '$RELEASE_NAME' 삭제 중..."
    helm uninstall $RELEASE_NAME -n $NAMESPACE
else
    echo "  - 삭제할 Helm Release가 없습니다."
fi

# 3. manifests 제거 (pv-volume.yaml 은 제외)
echo "🗑️  Manifests 삭제 중..."
for f in ./manifests/*.yaml; do
    [ -f "$f" ] || continue
    [[ "$f" == *"pv-volume.yaml" ]] && continue
    kubectl delete -f "$f" --ignore-not-found=true 2>/dev/null || true
done

# pv-volume.yaml 은 볼륨 삭제 동의 시에만 삭제 진행
if [[ "${DELETE_VOLUMES}" =~ ^[Yy]$ ]]; then
    if [ -f "./manifests/pv-volume.yaml" ]; then
        echo "   - PV/PVC manifests (pv-volume.yaml) 삭제 중..."
        kubectl delete -f ./manifests/pv-volume.yaml --ignore-not-found=true 2>/dev/null || true
    fi
fi

# 4. PVC 삭제 (볼륨 삭제 선택 시)
if [[ "${DELETE_VOLUMES}" =~ ^[Yy]$ ]]; then
    echo "🗑️  PVC 삭제 중..."
    if kubectl get pvc -n "$NAMESPACE" >/dev/null 2>&1; then
        pvc_list=$(kubectl get pvc -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
        for pvc_name in $pvc_list; do
            [ -n "$pvc_name" ] || continue
            kubectl delete pvc "$pvc_name" -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
        done
    fi
fi

# 5. 네임스페이스 삭제 (볼륨 보존 시 cascade delete 방지를 위해 우회)
if [[ "${DELETE_VOLUMES}" =~ ^[Yy]$ ]]; then
    echo "🗑️  Namespace '$NAMESPACE' 삭제 중..."
    kubectl delete ns $NAMESPACE --ignore-not-found=true --timeout=30s 2>/dev/null || true
else
    echo "➡️  볼륨 보존 선택에 따라 Namespace '${NAMESPACE}' 삭제 단계를 생략합니다."
fi

# 6. PV 삭제 (네임스페이스 삭제 후)
if [[ "${DELETE_VOLUMES}" =~ ^[Yy]$ ]]; then
    echo "⏳ PVC 삭제 완료 대기 중..."
    for i in $(seq 1 30); do
        PVC_COUNT=$(kubectl get pvc -n $NAMESPACE --no-headers 2>/dev/null | wc -l || echo 0)
        [ "${PVC_COUNT:-0}" -eq 0 ] && break
        sleep 1
    done

    echo "🗑️  PV 삭제 중..."
    kubectl delete pv -l app.kubernetes.io/instance=$RELEASE_NAME --ignore-not-found=true 2>/dev/null || true
    kubectl get pv 2>/dev/null | grep "$NAMESPACE" | awk '{print $1}' | xargs -r kubectl delete pv 2>/dev/null || true
fi

# 7. 설정 파일 삭제 (Reset 모드 시에만 초기화 진행)
if [ "$RESET_MODE" == "reset" ]; then
    if [ -f "$CONF_FILE" ]; then
        rm -f "$CONF_FILE"
        echo "🗑️  설정 파일(install.conf) 삭제 완료."
    fi
    if [ -f "./values-infra.yaml" ]; then
        rm -f "./values-infra.yaml"
        echo "🗑️  인프라 설정 파일(values-infra.yaml) 삭제 완료."
    fi
fi

echo ""
echo -e "${GREEN}✅ Monitoring 삭제 완료.${NC}"
echo ""
