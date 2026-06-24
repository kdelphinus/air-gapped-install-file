#!/bin/bash

# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

# ==========================================
# [설정] 기본 변수
# ==========================================
DEFAULT_NAMESPACE="opentelemetry"
CONF_FILE="./install.conf"
CHART_PATH=""

# 차트 경로 자동 검색 (압축파일 또는 폴더 형태 대응)
if [ -d "./charts/opentelemetry-operator" ]; then
    CHART_PATH="./charts/opentelemetry-operator"
elif [ -f "./charts/opentelemetry-operator-0.114.1.tgz" ]; then
    CHART_PATH="./charts/opentelemetry-operator-0.114.1.tgz"
else
    TGZ_FILE=$(ls ./charts/opentelemetry-operator-*.tgz 2>/dev/null | head -n 1)
    if [ -n "$TGZ_FILE" ]; then
        CHART_PATH="$TGZ_FILE"
    else
        CHART_PATH="./charts/opentelemetry-operator"
    fi
fi

# ── [0] 사전 요구사항(Prerequisites) 검증 ────────────────────────
echo "🔍 사전 요구사항(cert-manager) 검증 중..."
if ! kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
    echo -e "\033[0;31m"
    echo "❌ [오류] OpenTelemetry Operator 설치 실패"
    echo "========================================================="
    echo "  OpenTelemetry Operator를 사용하기 위해서는 인증서 및 웹훅 관리를 위한"
    echo "  cert-manager가 클러스터에 반드시 설치되어 있어야 합니다."
    echo "  현재 클러스터 내에 'certificates.cert-manager.io' CRD가 존재하지 않습니다."
    echo "========================================================="
    echo "  해결 방법:"
    echo "    1. cert-manager 오프라인 패키지를 활용하여 cert-manager를 배포하십시오."
    echo "    2. cert-manager가 정상 작동 상태(Running)인지 확인 후 다시 시도하십시오."
    echo -e "\033[0m"
    exit 1
fi
echo "  ✅ cert-manager 감지 완료 (certificates.cert-manager.io)"

# ── install.conf 로드 / 저장 ──────────────────────────────
load_conf() {
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
    fi
}

save_conf() {
    cat > "$CONF_FILE" <<EOF
# OpenTelemetry Operator 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
TARGET_NAMESPACE="${TARGET_NAMESPACE}"
INSTALLED_VERSION="v0.114.1"
EOF
    echo "  ✅ 설정이 ${CONF_FILE} 에 저장되었습니다."
}

# ==========================================
# [함수] 클린업 로직
# ==========================================
function cleanup_resources() {
  local RESET_MODE=$1 # "reset" 이면 install.conf 도 삭제
  echo ""
  echo "🧹 [Clean Up] 기존 리소스 제거 시작..."

  local NS=${TARGET_NAMESPACE:-$DEFAULT_NAMESPACE}

  helm uninstall otel-operator -n $NS --wait=false 2>/dev/null &
  echo "⏳ 리소스 삭제 대기 중..."
  sleep 5

  echo "🔫 Finalizer 일괄 제거 중..."
  for KIND in deployment service serviceaccount configmap mutatingwebhookconfiguration validatingwebhookconfiguration; do
    kubectl get $KIND -n $NS -o name 2>/dev/null | grep otel-operator | \
    xargs -r -I {} kubectl patch {} -n $NS -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
  done

  # 전역 웹훅 설정 제거 (네임스페이스 외부에 위치)
  kubectl delete mutatingwebhookconfiguration otel-operator-mutating-webhook-configuration --ignore-not-found=true 2>/dev/null || true
  kubectl delete validatingwebhookconfiguration otel-operator-validating-webhook-configuration --ignore-not-found=true 2>/dev/null || true

  if [ "$RESET_MODE" == "reset" ]; then
      rm -f "$CONF_FILE"
      echo "🗑️  설정 파일($CONF_FILE) 삭제 완료."
  fi

  echo "✅ 초기화 완료."
  echo ""
}

# ==========================================
# [1] 기존 설치 감지 및 메뉴
# ==========================================
load_conf
TARGET_NAMESPACE="${TARGET_NAMESPACE:-$DEFAULT_NAMESPACE}"
EXIST_HELM=$(helm status otel-operator -n $TARGET_NAMESPACE > /dev/null 2>&1 && echo "yes" || echo "no")
DO_UPGRADE=false

if [ "$EXIST_HELM" == "yes" ] || [ -f "$CONF_FILE" ]; then
    echo ""
    echo "⚠️  기존 설치 또는 설정이 감지되었습니다."
    [ -f "$CONF_FILE" ] && echo "  📋 저장된 설정 정보:"
    [ -n "$IMAGE_SOURCE" ] && echo "     - 이미지 소스  : $IMAGE_SOURCE"
    [ -n "$TARGET_NAMESPACE" ] && echo "     - 네임스페이스  : $TARGET_NAMESPACE"

    echo ""
    echo "동작을 선택하세요:"
    echo "  1) 업그레이드 (저장된 설정 유지, Helm upgrade)"
    echo "  2) 재설치     (기존 리소스 삭제 후 새로 설치)"
    echo "  3) 초기화     (모든 리소스 및 설정 파일 완전 삭제)"
    echo "  4) 취소"
    read -p "선택 [1/2/3/4]: " ACTION

    case "$ACTION" in
        1) DO_UPGRADE=true ;;
        2) cleanup_resources "reinstall" ;;
        3) cleanup_resources "reset"; exit 0 ;;
        *) echo "취소되었습니다."; exit 0 ;;
    esac
fi

# ==========================================
# [2] 설치 설정 입력 (새로 설치 시에만)
# ==========================================
if [ "$DO_UPGRADE" != "true" ]; then
    # 2-1. 이미지 소스
    echo ""
    echo "이미지 소스를 선택하세요:"
    echo "  1) Harbor 레지스트리 사용"
    echo "  2) 로컬 이미지 직접 사용 (ctr import)"
    echo "  3) 온라인 공식 레지스트리 직접 사용 (인터넷 환경)"
    read -p "선택 [1/2/3, 기본값 1]: " _IMG_SRC
    if [ "${_IMG_SRC:-1}" == "1" ]; then
        IMAGE_SOURCE="harbor"
        read -p "Harbor 주소 (예: 192.168.1.10:30002): " HARBOR_REGISTRY
        read -p "Harbor 프로젝트 (예: library): " HARBOR_PROJECT
    elif [ "${_IMG_SRC:-1}" == "2" ]; then
        IMAGE_SOURCE="local"
        echo "로컬 이미지를 containerd(k8s.io)에 로드 중..."
        for tar_file in ./images/*.tar*; do
            [ -e "$tar_file" ] || continue
            echo "  → $(basename "$tar_file") 임포트 중"
            sudo ctr -n k8s.io images import "$tar_file" 2>/dev/null || sudo docker load -i "$tar_file" 2>/dev/null
        done
    else
        IMAGE_SOURCE="online"
        echo "온라인 공식 이미지를 직접 사용합니다 (Helm 배포 시 자동 다운로드)."
    fi

    # 2-2. 네임스페이스 지정
    echo ""
    read -p "설치할 네임스페이스를 입력하세요 (기본값: $DEFAULT_NAMESPACE): " _NS
    TARGET_NAMESPACE="${_NS:-$DEFAULT_NAMESPACE}"
fi

save_conf

# ==========================================
# [3] 설정 파일 동기화 (values.yaml 업데이트)
# ==========================================
IMG_OPERATOR="ghcr.io/open-telemetry/opentelemetry-operator/opentelemetry-operator"
IMG_TAG="v0.152.0"

if [ "$IMAGE_SOURCE" == "harbor" ]; then
    # Harbor 레지스트리 포맷 주입
    IMG_OPERATOR="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/opentelemetry-operator"
fi

echo "🔧 설정 파일(values.yaml) 동기화 중..."
sed -i "s|repository: .*|repository: \"$IMG_OPERATOR\"|g" ./values.yaml
sed -i "s|tag: .*|tag: \"$IMG_TAG\"|g" ./values.yaml

# ==========================================
# [4] 헬름 차트 배포 실행
# ==========================================
echo ""
echo "🚀 OpenTelemetry Operator 배포 시작 (버전 v0.114.1 / v0.152.0)..."
echo "  - 네임스페이스  : $TARGET_NAMESPACE"
echo "  - 차트 경로     : $CHART_PATH"

helm upgrade --install otel-operator "$CHART_PATH" \
  -n "$TARGET_NAMESPACE" --create-namespace \
  -f ./values.yaml

echo "⏳ 파드가 구동될 때까지 대기합니다..."
kubectl wait --timeout=5m -n "$TARGET_NAMESPACE" deployment/otel-operator-opentelemetry-operator --for=condition=Available 2>/dev/null || true

echo ""
echo "========================================================"
echo "🎉 OpenTelemetry Operator 배포 완료!"
echo "설정 파일 : $CONF_FILE"
echo "네임스페이스 : $TARGET_NAMESPACE"
echo "========================================================"
kubectl get pods -n "$TARGET_NAMESPACE" -l app.kubernetes.io/name=opentelemetry-operator
