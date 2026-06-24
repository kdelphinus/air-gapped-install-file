#!/bin/bash

# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

# ==========================================
# [설정] 기본 변수
# ==========================================
DEFAULT_NAMESPACE="monitoring"
CONF_FILE="./install.conf"
CHART_PATH=""

# 차트 경로 자동 검색 (압축파일 또는 폴더 형태 대응)
if [ -d "./charts/opentelemetry-collector" ]; then
    CHART_PATH="./charts/opentelemetry-collector"
elif [ -f "./charts/opentelemetry-collector-0.158.0.tgz" ]; then
    CHART_PATH="./charts/opentelemetry-collector-0.158.0.tgz"
else
    # 일반적인 tgz 매칭
    TGZ_FILE=$(ls ./charts/opentelemetry-collector-*.tgz 2>/dev/null | head -n 1)
    if [ -n "$TGZ_FILE" ]; then
        CHART_PATH="$TGZ_FILE"
    else
        CHART_PATH="./charts/opentelemetry-collector"
    fi
fi

# ── install.conf 로드 / 저장 ──────────────────────────────
load_conf() {
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
    fi
}

save_conf() {
    cat > "$CONF_FILE" <<EOF
# OpenTelemetry Collector 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
DEPLOY_MODE="${DEPLOY_MODE}"
SVC_TYPE="${SVC_TYPE}"
TARGET_NAMESPACE="${TARGET_NAMESPACE}"
INSTALLED_VERSION="v0.158.0"
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

  # conf가 먼저 로드된 경우 저장된 네임스페이스 사용, 없을 시 기본값 사용
  local NS=${TARGET_NAMESPACE:-$DEFAULT_NAMESPACE}

  helm uninstall otel-collector -n $NS --wait=false 2>/dev/null &
  echo "⏳ 리소스 삭제 대기 중..."
  sleep 5

  echo "🔫 Finalizer 일괄 제거 중..."
  for KIND in daemonset deployment service serviceaccount configmap; do
    kubectl get $KIND -n $NS -o name 2>/dev/null | grep otel-collector | \
    xargs -r -I {} kubectl patch {} -n $NS -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
  done

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
EXIST_HELM=$(helm status otel-collector -n $TARGET_NAMESPACE > /dev/null 2>&1 && echo "yes" || echo "no")
DO_UPGRADE=false

if [ "$EXIST_HELM" == "yes" ] || [ -f "$CONF_FILE" ]; then
    echo ""
    echo "⚠️  기존 설치 또는 설정이 감지되었습니다."
    [ -f "$CONF_FILE" ] && echo "  📋 저장된 설정 정보:"
    [ -n "$IMAGE_SOURCE" ] && echo "     - 이미지 소스  : $IMAGE_SOURCE"
    [ -n "$TARGET_NAMESPACE" ] && echo "     - 네임스페이스  : $TARGET_NAMESPACE"
    [ -n "$DEPLOY_MODE" ] && echo "     - 실행 모드    : $DEPLOY_MODE"
    [ -n "$SVC_TYPE" ] && echo "     - 서비스 타입  : $SVC_TYPE"

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

    # 2-2. 배포 모드 선택 (DaemonSet vs Deployment)
    echo ""
    echo "OpenTelemetry Collector 배포 방식을 선택하세요:"
    echo "  1) DaemonSet  (각 노드 단위 에이전트, 호스트 메트릭/로그 수집에 유리)"
    echo "  2) Deployment (중앙 집중형 중계 서버, 리포팅 메트릭/트레이스 처리에 유리)"
    read -p "선택 [1/2, 기본값 1]: " _MODE_SRC
    if [ "${_MODE_SRC:-1}" == "2" ]; then
        DEPLOY_MODE="deployment"
    else
        DEPLOY_MODE="daemonset"
    fi

    # 2-3. 서비스 노출 타입 선택
    echo ""
    echo "서비스 노출 방식을 선택하세요:"
    echo "  1) ClusterIP    (클러스터 내부 통신 전용)"
    echo "  2) NodePort     (외부 장비/앱 직접 접근)"
    echo "  3) LoadBalancer (외부 로드밸런서 연동)"
    read -p "선택 [1/2/3, 기본값 1]: " _SVC_SRC
    if [ "${_SVC_SRC:-1}" == "2" ]; then
        SVC_TYPE="NodePort"
    elif [ "${_SVC_SRC:-1}" == "3" ]; then
        SVC_TYPE="LoadBalancer"
    else
        SVC_TYPE="ClusterIP"
    fi

    # 2-4. 네임스페이스 지정
    echo ""
    read -p "설치할 네임스페이스를 입력하세요 (기본값: $DEFAULT_NAMESPACE): " _NS
    TARGET_NAMESPACE="${_NS:-$DEFAULT_NAMESPACE}"
fi

save_conf

# ==========================================
# [3] 설정 파일 동기화 (values.yaml 업데이트)
# ==========================================
IMG_OTEL="otel/opentelemetry-collector-contrib"
IMG_TAG="0.153.0"

if [ "$IMAGE_SOURCE" == "harbor" ]; then
    # Harbor 레지스트리 포맷 주입
    IMG_OTEL="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/opentelemetry-collector-contrib"
fi

echo "🔧 설정 파일(values.yaml) 동기화 중..."
sed -i "s|repository: .*|repository: \"$IMG_OTEL\"|g" ./values.yaml
sed -i "s|tag: .*|tag: \"$IMG_TAG\"|g" ./values.yaml
sed -i "s|mode: .*|mode: $DEPLOY_MODE|g" ./values.yaml
sed -i "s|type: .*|type: $SVC_TYPE|g" ./values.yaml

# ==========================================
# [4] 헬름 차트 배포 실행
# ==========================================
echo ""
echo "🚀 OpenTelemetry Collector 배포 시작 (버전 v0.158.0 / v0.153.0)..."
echo "  - 네임스페이스  : $TARGET_NAMESPACE"
echo "  - 차트 경로     : $CHART_PATH"
echo "  - 배포 방식     : $DEPLOY_MODE"
echo "  - 서비스 타입   : $SVC_TYPE"

helm upgrade --install otel-collector "$CHART_PATH" \
  -n "$TARGET_NAMESPACE" --create-namespace \
  -f ./values.yaml

# 자원 정상 전개 대기
echo "⏳ 파드가 구동될 때까지 대기합니다..."
if [ "$DEPLOY_MODE" == "deployment" ]; then
    kubectl wait --timeout=5m -n "$TARGET_NAMESPACE" deployment/otel-collector-opentelemetry-collector --for=condition=Available 2>/dev/null || true
else
    sleep 15 # DaemonSet은 롤아웃 확인을 위해 짧은 대기 진행
fi

echo ""
echo "========================================================"
echo "🎉 OpenTelemetry Collector 배포 완료!"
echo "설정 파일 : $CONF_FILE"
echo "배포 모드 : $DEPLOY_MODE"
echo "서비스    : $SVC_TYPE"
echo "========================================================"
kubectl get pods -n "$TARGET_NAMESPACE" -l app.kubernetes.io/name=opentelemetry-collector
echo ""
kubectl get svc -n "$TARGET_NAMESPACE" -l app.kubernetes.io/name=opentelemetry-collector
