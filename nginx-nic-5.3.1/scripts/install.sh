#!/bin/bash
set -e

# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

# =================================================================
# --- 설정 변수 ---
# =================================================================
NAMESPACE="nginx-ingress"
RELEASE_NAME="nginx-ingress"
HELM_CHART_PATH="./charts/nginx-ingress-5.3.1"
VALUES_FILE="./values.yaml"
CONF_FILE="./install.conf"

# 색상 코드
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ── install.conf 로드 / 저장 ──────────────────────────────
load_conf() {
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
    fi
}

save_conf() {
    cat > "$CONF_FILE" <<EOF
# NGINX Ingress Controller v5.3.1 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
REPLICAS="${REPLICAS}"
INGRESS_CLASS="${INGRESS_CLASS}"
HTTP_NODEPORT="${HTTP_NODEPORT}"
HTTPS_NODEPORT="${HTTPS_NODEPORT}"
DEFAULT_TLS_SECRET="${DEFAULT_TLS_SECRET}"
INSTALLED_VERSION="v5.3.1"
EOF
    echo -e "  ✅ 설정이 ${GREEN}${CONF_FILE}${NC} 에 저장되었습니다."
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}[오류] '$1' 명령어를 찾을 수 없습니다.${NC}"
        exit 1
    fi
}

echo "========================================================================"
echo " F5 NGINX Ingress Controller v5.3.1 폐쇄망 설치"
echo "========================================================================"

# 1. 도구 및 차트 파일 확인
check_command kubectl
check_command helm

if [ ! -d "$HELM_CHART_PATH" ]; then
    echo -e "${RED}[오류] Helm 차트 디렉토리 '$HELM_CHART_PATH'을 찾을 수 없습니다.${NC}"
    exit 1
fi

# 2. 기존 설치 감지 및 설정 로드
load_conf
EXIST_HELM=$(helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1 && echo "yes" || echo "no")
DO_UPGRADE=false

if [ "$EXIST_HELM" == "yes" ] || [ -f "$CONF_FILE" ]; then
    echo ""
    echo -e "⚠️  ${YELLOW}기존 설치 또는 설정이 감지되었습니다.${NC}"
    [ -f "$CONF_FILE" ] && echo "  📋 저장된 설정 정보:"
    [ -n "$IMAGE_SOURCE" ] && echo "     - 이미지 소스 : $IMAGE_SOURCE"
    [ -n "$HARBOR_REGISTRY" ] && echo "     - Harbor 주소 : $HARBOR_REGISTRY"
    [ -n "$HARBOR_PROJECT" ] && echo "     - 프로젝트명  : $HARBOR_PROJECT"
    [ -n "$REPLICAS" ] && echo "     - 복제본 수   : $REPLICAS"
    [ -n "$INGRESS_CLASS" ] && echo "     - 인그레스클래스: $INGRESS_CLASS"
    [ -n "$HTTP_NODEPORT" ] && echo "     - HTTP 포트   : $HTTP_NODEPORT"
    [ -n "$HTTPS_NODEPORT" ] && echo "     - HTTPS 포트  : $HTTPS_NODEPORT"

    echo ""
    echo "동작을 선택하세요:"
    echo "  1) 업그레이드 (저장된 설정 유지, Helm upgrade --install 무중단 배포)"
    echo "  2) 초기화     (모든 설정 및 리소스 완전 삭제)"
    echo "  3) 취소"
    read -p "선택 [1/2/3]: " ACTION

    case "$ACTION" in
        1) DO_UPGRADE=true ;;
        2)
            # 초기화 경로 (uninstall.sh --reset 연동 후 종료)
            if [ -f "./scripts/uninstall.sh" ]; then
                bash ./scripts/uninstall.sh --reset
            else
                echo -e "${RED}[오류] 삭제 스크립트가 존재하지 않습니다.${NC}"
            fi
            exit 0
            ;;
        *) echo "취소되었습니다."; exit 0 ;;
    esac
fi

# 3. 신규 설치 또는 기존 설정 파일 부재 시 사용자 입력 획득
if [ "$DO_UPGRADE" != "true" ] || [ ! -f "$CONF_FILE" ]; then
    if [ "$DO_UPGRADE" == "true" ] && [ ! -f "$CONF_FILE" ]; then
        echo -e "${YELLOW}  ℹ️  설정 파일(install.conf)이 존재하지 않아 인프라 사양 입력을 진행합니다.${NC}"
    fi
    echo ""
    echo "이미지 소스를 선택하세요:"
    echo "  1) Harbor 레지스트리 사용 (폐쇄망 권장)"
    echo "  2) 로컬에 사전 로드된 이미지 사용 (기본 docker.io 경로 승계)"
    read -p "선택 [1/2, 기본값 1]: " _IMG_SRC
    case "${_IMG_SRC:-1}" in
        1)
            IMAGE_SOURCE="harbor"
            read -p "Harbor 주소 (예: 192.168.1.10:30002): " HARBOR_REGISTRY
            read -p "Harbor 프로젝트 (예: library): " HARBOR_PROJECT
            ;;
        2)
            IMAGE_SOURCE="online"
            HARBOR_REGISTRY=""
            HARBOR_PROJECT=""
            ;;
        *)
            echo -e "${RED}[오류] 올바르지 않은 입력입니다.${NC}"
            exit 1
            ;;
    esac

    echo ""
    read -p "복제본(Replica) 수 입력 (기본값 1): " REPLICAS
    REPLICAS="${REPLICAS:-1}"

    read -p "Ingress Class 이름 입력 (기본값 nginx): " INGRESS_CLASS
    INGRESS_CLASS="${INGRESS_CLASS:-nginx}"

    read -p "HTTP NodePort 포트 입력 (기본값 30080): " HTTP_NODEPORT
    HTTP_NODEPORT="${HTTP_NODEPORT:-30080}"

    read -p "HTTPS NodePort 포트 입력 (기본값 30443): " HTTPS_NODEPORT
    HTTPS_NODEPORT="${HTTPS_NODEPORT:-30443}"

    read -p "기본 TLS Secret 지정 (필요 시 namespace/secret 형식 입력, 기본값 없음): " DEFAULT_TLS_SECRET
fi

save_conf

# =================================================================
# 4. values-infra.yaml 인프라 파일 단일 템플릿 생성
# =================================================================
echo ""
echo "🔧 인프라 설정 파일(values-infra.yaml) 생성 중..."

if [ "$IMAGE_SOURCE" == "harbor" ]; then
    IMAGE_REPO="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/nginx-ingress"
else
    IMAGE_REPO="nginx/nginx-ingress"
fi

cat > ./values-infra.yaml <<EOF
# F5 NGINX Ingress Controller v5.3.1 인프라 설정 — install.sh 에 의해 자동 관리됩니다.
controller:
  image:
    repository: "${IMAGE_REPO}"
    tag: "5.3.1"
    pullPolicy: "IfNotPresent"
  replicaCount: ${REPLICAS}
  ingressClass:
    name: "${INGRESS_CLASS}"
  service:
    type: NodePort
    httpPort:
      port: 80
      nodePort: ${HTTP_NODEPORT}
    httpsPort:
      port: 443
      nodePort: ${HTTPS_NODEPORT}
  defaultTLS:
    secret: "${DEFAULT_TLS_SECRET}"
EOF

# 5. CRD 적용
echo "🚀 [1/2] CRD 리소스 적용 중 (manifests/)..."
kubectl apply -k ./manifests/

# 6. 네임스페이스 생성
echo "네임스페이스 '$NAMESPACE' 생성 중..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 7. Helm 멱등 배포
echo ""
echo -e "🚀 [2/2] NGINX Ingress Controller 배포 중... (${DO_UPGRADE:+업그레이드}${DO_UPGRADE:-설치})"
helm upgrade --install "$RELEASE_NAME" "$HELM_CHART_PATH" \
    --namespace "$NAMESPACE" \
    -f "$VALUES_FILE" \
    -f ./values-infra.yaml \
    --wait

echo ""
echo "========================================================"
echo -e "${GREEN}🎉 F5 NGINX Ingress Controller 설치 완료!${NC}"
echo "설정 파일 : $CONF_FILE"
echo "HTTP  진입점: http://<NODE_IP>:$HTTP_NODEPORT (NodePort)"
echo "HTTPS 진입점: https://<NODE_IP>:$HTTPS_NODEPORT (NodePort)"
echo "========================================================"
echo ""
kubectl get pods -n "$NAMESPACE"
echo ""
kubectl get svc -n "$NAMESPACE"
