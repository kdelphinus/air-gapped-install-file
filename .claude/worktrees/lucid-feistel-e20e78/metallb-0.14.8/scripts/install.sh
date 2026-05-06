#!/bin/bash

# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

# ==========================================
# [설정] 기본 변수
# ==========================================
NAMESPACE="metallb-system"
CHART="./charts/metallb"
RELEASE="metallb"
CONF_FILE="./install.conf"
L2_MANIFEST="./manifests/l2-config.yaml"
VALUES_FILE="./values.yaml"

# ── install.conf 로드 / 저장 ──────────────────────────────
load_conf() {
    [ -f "$CONF_FILE" ] && source "$CONF_FILE"
}

save_conf() {
    cat > "$CONF_FILE" <<EOF
# MetalLB 0.14.8 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
ADDRESS_POOL="${ADDRESS_POOL}"
MODE="${MODE}"
INSTALLED_VERSION="v0.14.8"
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

  helm uninstall "$RELEASE" -n $NAMESPACE --wait=false 2>/dev/null

  echo "⏳ 리소스 삭제 대기 중..."
  sleep 5

  echo "🔫 MetalLB CR Finalizer 일괄 제거 중..."
  for KIND in ipaddresspool l2advertisement bgpadvertisement bgppeer community bfdprofile; do
    kubectl get $KIND -n $NAMESPACE -o name 2>/dev/null | \
    xargs -r -I {} kubectl patch {} -n $NAMESPACE -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
  done

  # 네임스페이스 삭제
  if kubectl get ns $NAMESPACE > /dev/null 2>&1; then
      echo "🗑️  네임스페이스($NAMESPACE) 삭제..."
      kubectl delete ns $NAMESPACE --timeout=15s --wait=false 2>/dev/null
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
EXIST_HELM=$(helm status "$RELEASE" -n $NAMESPACE > /dev/null 2>&1 && echo "yes" || echo "no")
DO_UPGRADE=false

if [ "$EXIST_HELM" == "yes" ] || [ -f "$CONF_FILE" ]; then
    echo ""
    echo "⚠️  기존 설치 또는 설정이 감지되었습니다."
    [ -f "$CONF_FILE" ] && echo "  📋 저장된 설정 정보:"
    [ -n "$IMAGE_SOURCE" ] && echo "     - 이미지 소스  : $IMAGE_SOURCE"
    [ -n "$HARBOR_REGISTRY" ] && echo "     - Harbor       : $HARBOR_REGISTRY/$HARBOR_PROJECT"
    [ -n "$ADDRESS_POOL" ] && echo "     - IP 풀        : $ADDRESS_POOL"
    [ -n "$MODE" ] && echo "     - 모드         : $MODE"

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

    # 2-2. 모드 (v1은 L2만 지원)
    MODE="L2"

    # 2-3. IP 주소 풀
    echo ""
    echo "⚠️  IP 주소 풀은 반드시 노드와 동일한 L2 네트워크 대역이어야 합니다."
    echo "   노드/게이트웨이/Pod/Service CIDR 과 겹치지 않는 유휴 IP 범위를 지정하세요."
    echo "   (예: 노드가 172.30.235.0/24 라면 → 172.30.235.200-172.30.235.220)"
    while true; do
        read -p "LoadBalancer IP 풀 (형식: start-end): " ADDRESS_POOL
        if [[ "$ADDRESS_POOL" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}-([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            break
        fi
        echo "  ❌ 형식이 올바르지 않습니다. 예: 172.30.235.200-172.30.235.220"
    done
fi

save_conf

# ==========================================
# [3] YAML 동기화
# ==========================================
echo ""
echo "🔧 설정 파일(values.yaml, l2-config.yaml) 업데이트 중..."

# 3-1. values.yaml — Harbor 이미지 경로
if [ "$IMAGE_SOURCE" == "harbor" ]; then
    IMG_CONTROLLER="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/metallb-controller"
    IMG_SPEAKER="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/metallb-speaker"
    sed -i "s|repository:.*metallb-controller.*|repository: ${IMG_CONTROLLER}|g" "$VALUES_FILE"
    sed -i "s|repository:.*metallb-speaker.*|repository: ${IMG_SPEAKER}|g" "$VALUES_FILE"
fi

# 3-2. manifests/l2-config.yaml — IP 풀 치환
# addresses 목록의 첫 줄(들여쓰기 + "- <range>")을 사용자 입력으로 교체
sed -i -E "s|^([[:space:]]*)-[[:space:]]+([0-9]{1,3}\.){3}[0-9]{1,3}-([0-9]{1,3}\.){3}[0-9]{1,3}[[:space:]]*$|\1- ${ADDRESS_POOL}|" "$L2_MANIFEST"

# ==========================================
# [4] 설치/업그레이드 실행
# ==========================================
echo ""
echo "🚀 [1/2] MetalLB Helm ${DO_UPGRADE:+업그레이드}${DO_UPGRADE:-설치} 중..."
helm upgrade --install "$RELEASE" "$CHART" \
  -n $NAMESPACE --create-namespace \
  -f "$VALUES_FILE"

echo "⏳ controller / speaker 기동 대기..."
kubectl wait --timeout=5m -n $NAMESPACE deployment/metallb-controller --for=condition=Available
kubectl rollout status daemonset/metallb-speaker -n $NAMESPACE --timeout=5m

echo "🚀 [2/2] IPAddressPool / L2Advertisement 적용 중..."
kubectl apply -f "$L2_MANIFEST"

echo ""
echo "========================================================"
echo "🎉 MetalLB v0.14.8 구성 완료!"
echo "설정 파일 : $CONF_FILE"
echo "IP 풀     : $ADDRESS_POOL"
echo "모드      : $MODE"
echo "========================================================"
kubectl get pods -n $NAMESPACE
echo ""
kubectl get ipaddresspool,l2advertisement -n $NAMESPACE
