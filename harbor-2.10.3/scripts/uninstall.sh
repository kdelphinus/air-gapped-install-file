#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="harbor"
RELEASE_NAME="harbor"
CONF_FILE="./install.conf"

RESET_MODE="uninstall"
if [ "$1" == "--reset" ] || [ "$1" == "reset" ]; then
    RESET_MODE="reset"
fi

echo "==========================================="
echo " Uninstalling Harbor 2.10.3"
echo "==========================================="
read -p "❓ 정말 삭제하시겠습니까? (y/n): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "취소되었습니다."; exit 0; }

# Helm 제거
if helm status "$RELEASE_NAME" -n "$NAMESPACE" > /dev/null 2>&1; then
    echo "🗑️  Helm Release '$RELEASE_NAME' 삭제 중..."
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE"
else
    echo "  - 삭제할 Helm Release가 없습니다."
fi

# PVC 및 PV 삭제 여부 통합 프롬프트 (데이터 보호 목적)
echo ""
read -p "⚠️  PVC 및 PV를 삭제하시겠습니까? (Harbor 저장 이미지 데이터 전체 유실 주의) (y/n): " DELETE_VOLUMES
if [[ "$DELETE_VOLUMES" =~ ^[Yy]$ ]]; then
    echo "🗑️  PVC 삭제 중..."
    kubectl delete pvc -n "$NAMESPACE" --all --ignore-not-found=true

    echo "🗑️  PV 삭제 중..."
    kubectl delete pv harbor-pv --ignore-not-found=true
    kubectl get pv 2>/dev/null | grep "$NAMESPACE" | awk '{print $1}' | xargs -r kubectl delete pv
else
    echo "➡️  PVC 및 PV 볼륨 데이터가 보존되었습니다."
fi

# 네임스페이스 삭제 (볼륨 보존 시 namespace 삭제로 인한 namespaced PVC cascade delete 방지)
if [[ "$DELETE_VOLUMES" =~ ^[Yy]$ ]]; then
    echo "🗑️  Namespace '$NAMESPACE' 삭제 중..."
    kubectl delete ns "$NAMESPACE" --ignore-not-found=true
else
    echo "➡️  볼륨 보존 선택에 따라 Namespace '$NAMESPACE' 삭제 단계를 생략합니다."
fi

# 리셋 모드 시 설정 파일 제거
if [ "$RESET_MODE" == "reset" ]; then
    echo "🗑️  설정 파일 및 생성된 인프라 파일 삭제 완료 (Reset)..."
    rm -f "$CONF_FILE"
    rm -f "./values-infra.yaml"
    rm -f "./manifests/harbor-persistence-infra.yaml"
fi

echo ""
echo "✅ Harbor 삭제 완료."
[ "$RESET_MODE" != "reset" ] && echo "   (설정파일 및 인프라 매니페스트는 보존되었습니다. 완전 초기화는 ./scripts/uninstall.sh --reset 을 실행하세요.)"
echo "   PV 데이터가 남아있는 경우 호스트 경로에서 직접 삭제하세요."
