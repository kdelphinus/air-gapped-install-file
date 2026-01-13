#!/bin/bash
set -e # 오류 발생 시 즉시 스크립트 중단

# =================================================================
# --- 설정 변수 (사용자 환경에 맞게 이 부분을 수정하세요) ---
# =================================================================

# 1. 기본 정보
NAMESPACE="ingress-nginx"
RELEASE_NAME="ingress-nginx"

# 2. 폐쇄망 환경 설정
HELM_CHART_PATH="./ingress-nginx-4.10.1.tgz"

# 3. 고급 설정
HELM_CHART_VERSION="4.10.1"


# =================================================================
# --- 메인 스크립트 로직 ---
# =================================================================

# --- 사전 요구사항 검사 함수 ---
check_command() {
    if ! command -v $1 &> /dev/null; then echo "오류: '$1' 명령어를 찾을 수 없습니다."; exit 1; fi
}

echo "🚀 NGINX Ingress Controller (노드명 고정) 폐쇄망 설치 스크립트를 시작합니다."

# 1. 도구 및 파일 확인
check_command kubectl
check_command helm
if [ ! -f "$HELM_CHART_PATH" ]; then
    echo "오류: Helm 차트 파일 '$HELM_CHART_PATH'을 찾을 수 없습니다."
    exit 1
fi

# 2. 기존 릴리스 확인 및 삭제
if helm status "$RELEASE_NAME" -n "$NAMESPACE" &>/dev/null; then
    echo "⚠️  $RELEASE_NAME 가 이미 설치되어 있습니다."
    read -p "기존 릴리스를 삭제하고 다시 설치하시겠습니까? (y/N): " DELETE_EXISTING
    if [[ "$DELETE_EXISTING" =~ ^[yY]([eE][sS])?$ ]]; then
        echo "➡️ 기존 Helm 릴리스 삭제 중..."
        helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" || true
        echo "➡️ 리소스 정리 대기 중..."
        sleep 10
    else
        echo "❌ 설치를 중단합니다."
        exit 1
    fi
fi

# 3. 네임스페이스 생성
echo "📦 네임스페이스 '$NAMESPACE'를 생성합니다..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 4. 인그레스 컨트롤러를 실행할 노드 선택
echo "----------------------------------------------------------------"
kubectl get nodes
echo "----------------------------------------------------------------"
read -p "⬆️  위 목록에서 인그레스 컨트롤러를 실행할 노드의 이름을 입력하세요: " TARGET_NODE_NAME
if [ -z "$TARGET_NODE_NAME" ]; then
    echo "❌ 노드 이름이 입력되지 않았습니다. 설치를 중단합니다."
    exit 1
fi

# 5. Helm 설치 (hostPort 및 노드명 고정 방식)
echo "⚙️  Helm을 사용하여 '$TARGET_NODE_NAME' 노드에 인그레스 컨트롤러를 배포합니다..."

# 사용자 입력: HTTP_PORT (기본값 80)
read -p "사용할 HTTP hostPort를 입력하세요 [기본값: 80]: " HOST_PORT_HTTP
HOST_PORT_HTTP=${HOST_PORT_HTTP:-80}

# 사용자 입력: HTTPS_PORT (기본값 443)
read -p "사용할 HTTPS hostPort를 입력하세요 [기본값: 443]: " HOST_PORT_HTTPS
HOST_PORT_HTTPS=${HOST_PORT_HTTPS:-443}

helm upgrade --install "$RELEASE_NAME" "$HELM_CHART_PATH" \
--version "$HELM_CHART_VERSION" \
--namespace "$NAMESPACE" \
--atomic \
--wait \
--set controller.image.pullPolicy=IfNotPresent \
--set controller.admissionWebhooks.patch.image.pullPolicy=IfNotPresent \
--set defaultBackend.image.pullPolicy=IfNotPresent \
--set controller.allowSnippetAnnotations=true \
--set controller.config.use-forwarded-headers="true" \
--set controller.config.proxy-body-size="50m" \
--set controller.service.enabled=false \
--set controller.hostPort.enabled=true \
--set controller.hostPort.ports.http=$HOST_PORT_HTTP \
--set controller.hostPort.ports.https=$HOST_PORT_HTTPS \
`# ----------------- 노드명 직접 고정 설정 ----------------- #` \
--set controller.nodeSelector."kubernetes\.io/hostname"="$TARGET_NODE_NAME" \
--set controller.config.ssl-redirect="false" 

# 6. 설치 완료 및 확인
echo ""
echo "================================================================"
echo "✅ NGINX Ingress Controller (노드명 고정) 설치가 완료되었습니다!"
echo "================================================================"

echo "잠시 후 파드 상태를 확인합니다..."
sleep 5

kubectl get pods -n "$NAMESPACE" -o wide

echo ""
echo "➡️ '$TARGET_NODE_NAME' 노드에 파드가 정상적으로 Running 상태인지 확인하세요."
echo "   이제 '$TARGET_NODE_NAME' 노드의 공인 IP와 설정한 포트(${HOST_PORT_HTTP}, ${HOST_PORT_HTTPS})로 접근할 수 있습니다."
echo "================================================================"
echo ""