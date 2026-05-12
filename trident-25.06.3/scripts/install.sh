#!/bin/bash

# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

# ==========================================
# [설정] 기본 변수
# ==========================================
NAMESPACE="trident"
CHART_PATH="./charts/trident-operator"
CONF_FILE="./install.conf"
VERSION="100.2506.3"

# ── install.conf 로드 / 저장 ──────────────────────────────
load_conf() {
    [ -f "$CONF_FILE" ] && source "$CONF_FILE"
}

save_conf() {
    cat > "$CONF_FILE" <<EOF
# NetApp Trident ${VERSION} 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
KUBELET_DIR="${KUBELET_DIR}"
INSTALLED_VERSION="${VERSION}"
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

  # 테스트 리소스 먼저 제거
  kubectl delete -f manifests/003_test.yaml --ignore-not-found=true
  kubectl delete -f manifests/002_storage_class.yaml --ignore-not-found=true
  kubectl delete -f manifests/001_backend_setup.yaml --ignore-not-found=true

  # Helm 제거
  helm uninstall trident -n $NAMESPACE --wait=false 2>/dev/null

  echo "⏳ 리소스 삭제 대기 중..."
  sleep 5

  # 네임스페이스 삭제
  if kubectl get ns $NAMESPACE > /dev/null 2>&1; then
      echo "🗑️  네임스페이스($NAMESPACE) 삭제..."
      kubectl delete ns $NAMESPACE --timeout=30s --wait=false 2>/dev/null
  fi

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
EXIST_HELM=$(helm status trident -n $NAMESPACE > /dev/null 2>&1 && echo "yes" || echo "no")
DO_UPGRADE=false

if [ "$EXIST_HELM" == "yes" ] || [ -f "$CONF_FILE" ]; then
    echo ""
    echo "⚠️  기존 설치 또는 설정이 감지되었습니다."
    [ -f "$CONF_FILE" ] && echo "  📋 저장된 설정 정보:"
    [ -n "$IMAGE_SOURCE" ] && echo "     - 이미지 소스  : $IMAGE_SOURCE"
    [ -n "$KUBELET_DIR" ] && echo "     - Kubelet 경로 : $KUBELET_DIR"

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
    read -p "선택 [1/2, 기본값 1]: " _IMG_SRC
    if [ "${_IMG_SRC:-1}" == "1" ]; then
        IMAGE_SOURCE="harbor"
        read -p "Harbor 주소 (예: 192.168.1.10:30002): " HARBOR_REGISTRY
        read -p "Harbor 프로젝트 (예: library): " HARBOR_PROJECT
    else
        IMAGE_SOURCE="local"
        echo "로컬 이미지를 containerd(k8s.io)에 로드 중..."
        for tar_file in ./images/*.tar*; do
            [ -e "$tar_file" ] || continue
            echo "  → $(basename "$tar_file") 임포트 중"
            sudo ctr -n k8s.io images import "$tar_file" 2>/dev/null
        done
    fi

    # 2-2. Kubelet Directory
    echo ""
    read -p "Kubelet Directory 경로 (기본값 /var/lib/kubelet): " KUBELET_DIR
    KUBELET_DIR="${KUBELET_DIR:-/var/lib/kubelet}"
fi

save_conf

# ==========================================
# [3] 설치/업그레이드 실행
# ==========================================

echo "🔧 설정 파일(values.yaml) 업데이트 중..."
sed -i "s|kubeletDir: .*|kubeletDir: \"$KUBELET_DIR\"|g" ./values.yaml

# Harbor 사용 시 이미지 레지스트리 설정 (Trident Operator의 경우 values.yaml 구조에 따라 다름)
# 여기서는 기본적으로 kubeletDir만 동기화하며, 이미지 관련은 수동 설정 또는 README 가이드 권장.

echo ""
echo "🚀 NetApp Trident Operator ${DO_UPGRADE:+업그레이드}${DO_UPGRADE:-설치} 중..."

# Namespace 생성
kubectl create ns $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Helm 설치 (로컬 차트 우선 참조, 없으면 에러 처리)
if [ -d "$CHART_PATH" ] || [ -f "${CHART_PATH}-*.tgz" ]; then
    helm upgrade --install trident $CHART_PATH \
      -n $NAMESPACE \
      -f ./values.yaml \
      --version $VERSION
else
    echo "❌ 오류: $CHART_PATH 경로에 차트가 존재하지 않습니다."
    echo "   offline 환경 설치를 위해 charts/ 디렉토리에 차트를 준비해주세요."
    exit 1
fi

echo "⏳ Trident Operator 배포 대기 중..."
kubectl wait --timeout=5m -n $NAMESPACE deployment/trident-operator --for=condition=Available

echo "🚀 정적 매니페스트(Backend, StorageClass) 적용 중..."
kubectl apply -f manifests/001_backend_setup.yaml
kubectl apply -f manifests/002_storage_class.yaml

echo ""
echo "========================================================"
echo "🎉 Trident 설치 완료! (v${VERSION})"
echo "설정 파일 : $CONF_FILE"
echo "Kubelet 경로: $KUBELET_DIR"
echo "========================================================"
echo "💡 'kubectl apply -f manifests/003_test.yaml' 명령으로 테스트를 진행할 수 있습니다."
