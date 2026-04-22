#!/bin/bash

# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

# ==========================================
# [설정] 기본 변수
# ==========================================
NAMESPACE="envoy-gateway-system"
CONTROLLER_CHART="./charts/gateway-1.7.2"
INFRA_CHART="./charts/gateway-infra"
GW_NAME="cluster-gateway"
CONF_FILE="./install.conf"

# ── install.conf 로드 / 저장 ──────────────────────────────
load_conf() {
    [ -f "$CONF_FILE" ] && source "$CONF_FILE"
}

save_conf() {
    cat > "$CONF_FILE" <<EOF
# Envoy Gateway 1.7.2 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
SVC_TYPE="${SVC_TYPE}"
TLS_ENABLED="${TLS_ENABLED}"
NODE_HTTP_PORT="${NODE_HTTP_PORT}"
NODE_HTTPS_PORT="${NODE_HTTPS_PORT}"
TARGET_NODE="${TARGET_NODE}"
INSTALLED_VERSION="v1.7.2"
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

  helm uninstall gateway-infra -n $NAMESPACE --wait=false 2>/dev/null &
  helm uninstall eg-gateway -n $NAMESPACE --wait=false 2>/dev/null &

  echo "⏳ 리소스 삭제 대기 중..."
  sleep 5

  echo "🔫 Finalizer 일괄 제거 중..."
  for KIND in gateway gatewayclass envoyproxy httproute service; do
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
EXIST_HELM=$(helm status eg-gateway -n $NAMESPACE > /dev/null 2>&1 && echo "yes" || echo "no")
DO_UPGRADE=false

if [ "$EXIST_HELM" == "yes" ] || [ -f "$CONF_FILE" ]; then
    echo ""
    echo "⚠️  기존 설치 또는 설정이 감지되었습니다."
    [ -f "$CONF_FILE" ] && echo "  📋 저장된 설정 정보:"
    [ -n "$IMAGE_SOURCE" ] && echo "     - 이미지 소스  : $IMAGE_SOURCE"
    [ -n "$SVC_TYPE" ] && echo "     - 서비스 타입  : $SVC_TYPE"
    [ -n "$TLS_ENABLED" ] && echo "     - TLS 활성화   : $TLS_ENABLED"
    [ "$SVC_TYPE" == "NodePort" ] && echo "     - NodePort     : $NODE_HTTP_PORT / $NODE_HTTPS_PORT"
    [ -n "$TARGET_NODE" ] && echo "     - 고정 노드    : $TARGET_NODE"

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


    # 2-2. 서비스 타입 및 포트
    echo ""
    echo "서비스 노출 방식을 선택하세요:"
    echo "  1) LoadBalancer (자동 IP 할당 환경)"
    echo "  2) NodePort     (HAProxy 또는 직접 접근)"
    read -p "선택 [1/2, 기본값 2]: " _SVC_SRC
    if [ "${_SVC_SRC:-2}" == "1" ]; then
        SVC_TYPE="LoadBalancer"
    else
        SVC_TYPE="NodePort"
        read -p "HTTP NodePort (기본 30080): " NODE_HTTP_PORT
        NODE_HTTP_PORT="${NODE_HTTP_PORT:-30080}"
        read -p "HTTPS NodePort (기본 30443): " NODE_HTTPS_PORT
        NODE_HTTPS_PORT="${NODE_HTTPS_PORT:-30443}"
    fi

    # 2-3. TLS(HTTPS) 사용 여부
    echo ""
    read -p "HTTPS(TLS)를 활성화하시겠습니까? (y/n, 기본값 y): " _TLS_YN
    if [[ "${_TLS_YN:-y}" =~ ^[Yy]$ ]]; then
        TLS_ENABLED="true"
    else
        TLS_ENABLED="false"
    fi

    # 2-4. 노드 고정
    echo ""
    kubectl get nodes -o wide
    read -p "Envoy를 고정할 노드 이름 (입력 없이 엔터 시 자동 배치): " TARGET_NODE
fi

save_conf

# ==========================================
# [3] 설치/업그레이드 실행
# ==========================================
IMG_GATEWAY="docker.io/envoyproxy/gateway:v1.7.2"
IMG_PROXY="docker.io/envoyproxy/envoy:distroless-v1.37.2"

if [ "$IMAGE_SOURCE" == "harbor" ]; then
    IMG_GATEWAY="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gateway:v1.7.2"
    IMG_PROXY="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/envoy:distroless-v1.37.2"
fi

echo "🔧 설정 파일(values.yaml, values-infra.yaml) 업데이트 중..."
# 1. values.yaml (Envoy Gateway)
sed -i "s|image: .*|image: \"$IMG_GATEWAY\"|g" ./values.yaml

# 2. values-infra.yaml (Envoy Proxy)
TLS_ENABLED="${TLS_ENABLED:-true}"
sed -i "s|image: .*envoy:.*|image: \"$IMG_PROXY\"|g" ./values-infra.yaml
sed -i "s|type: .*|type: $SVC_TYPE|g" ./values-infra.yaml
sed -i "s|enabled: .*|enabled: $TLS_ENABLED|g" ./values-infra.yaml
sed -i "s|http: [0-9]*|http: $NODE_HTTP_PORT|g" ./values-infra.yaml
sed -i "s|https: [0-9]*|https: $NODE_HTTPS_PORT|g" ./values-infra.yaml

if [ "$SVC_TYPE" == "NodePort" ]; then
    sed -i "s|proxyProtocol: .*|proxyProtocol: true|g" ./values-infra.yaml
else
    sed -i "s|proxyProtocol: .*|proxyProtocol: false|g" ./values-infra.yaml
fi

if [ -n "$TARGET_NODE" ]; then
    sed -i "s|nodeName: .*|nodeName: \"$TARGET_NODE\"|g" ./values-infra.yaml
else
    sed -i "s|nodeName: .*|nodeName: \"\"|g" ./values-infra.yaml
fi

echo ""
echo "🚀 [1/2] Envoy Gateway Controller ${DO_UPGRADE:+업그레이드}${DO_UPGRADE:-설치} 중..."
helm upgrade --install eg-gateway $CONTROLLER_CHART \
  -n $NAMESPACE --create-namespace \
  -f ./values.yaml

kubectl wait --timeout=5m -n $NAMESPACE deployment/envoy-gateway --for=condition=Available

echo "🚀 [2/2] Infrastructure 배포 중..."
helm upgrade --install gateway-infra $INFRA_CHART \
  -n $NAMESPACE \
  -f ./values-infra.yaml

echo ""
echo "========================================================"
echo "🎉 구성 완료! (v1.7.2 / v1.37.2)"
echo "설정 파일 : $CONF_FILE"
echo "서비스    : $SVC_TYPE"
[ "$SVC_TYPE" == "NodePort" ] && echo "포트      : HTTP $NODE_HTTP_PORT / HTTPS $NODE_HTTPS_PORT"
echo "========================================================"
kubectl get svc -n $NAMESPACE
