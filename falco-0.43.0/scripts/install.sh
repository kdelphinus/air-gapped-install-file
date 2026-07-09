#!/bin/bash
set -e

# 스크립트 위치 기준으로 컴포넌트 루트로 이동
COMPONENT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$COMPONENT_ROOT" || exit 1

# =================================================================
# --- 설정 변수 ---
# =================================================================
CHART_PATH="./charts/falco"
VALUES_FILE="./values.yaml"
CONF_FILE="./install.conf"
NAMESPACE="falco"
RELEASE_NAME="falco"

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
# Falco v0.43.0 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
CONTAINERD_SOCKET="${CONTAINERD_SOCKET}"
APPLY_SUPPRESS="${APPLY_SUPPRESS}"
INSTALLED_VERSION="v0.43.0"
EOF
    echo -e "  ✅ 설정이 ${GREEN}${CONF_FILE}${NC} 에 저장되었습니다."
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}[오류] '$1' 명령어를 찾을 수 없습니다.${NC}"
        exit 1
    fi
}

# ==========================================
# [함수] 리소스 제거 로직 (재설치/초기화 시)
# ==========================================
cleanup_resources() {
    local RESET_MODE=$1
    echo ""
    echo -e "🧹 ${YELLOW}[Clean Up] 기존 Falco 리소스 제거 시작...${NC}"

    # 제거 전 재확인 프롬프트 최상단 기동 (P1 준수)
    echo ""
    read -p "⚠️  Falco의 모든 리소스와 Namespace를 제거하시겠습니까? (y/n): " DELETE_CONFIRM
    if [[ ! "${DELETE_CONFIRM}" =~ ^[Yy]$ ]]; then
        echo "취소되었습니다."
        exit 0
    fi

    # 1. Helm Uninstall
    if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "⏳ Helm 차트 삭제 중..."
        helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait=false 2>/dev/null
        sleep 3
    fi

    # 2. 네임스페이스 삭제
    if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
        echo "   - 네임스페이스 삭제 중..."
        kubectl delete namespace "$NAMESPACE" --ignore-not-found --timeout=30s 2>/dev/null || true
    fi

    if [ "$RESET_MODE" == "reset" ]; then
        rm -f "$CONF_FILE"
        rm -f "./values-infra.yaml"
        echo -e "🗑️  설정 파일 및 생성된 인프라 파일 삭제 완료 (Reset)."
    fi

    echo -e "${GREEN}✅ 초기화 완료.${NC}"
    echo ""
}

# ==========================================
# [1] 기존 설치 감지 및 메뉴
# ==========================================
load_conf
check_command kubectl
check_command helm

EXIST_HELM=$(helm status "$RELEASE_NAME" -n "$NAMESPACE" > /dev/null 2>&1 && echo "yes" || echo "no")
DO_UPGRADE=false
_FORCE_REINPUT=false

if [ "$EXIST_HELM" == "yes" ] || [ -f "$CONF_FILE" ]; then
    echo ""
    echo -e "⚠️  ${YELLOW}기존 설치 또는 설정이 감지되었습니다.${NC}"
    [ -f "$CONF_FILE" ] && echo "  📋 저장된 설정 정보:"
    [ -n "$IMAGE_SOURCE" ] && echo "     - 이미지 소스   : $IMAGE_SOURCE"
    [ -n "$HARBOR_REGISTRY" ] && echo "     - Harbor 주소   : $HARBOR_REGISTRY"
    [ -n "$CONTAINERD_SOCKET" ] && echo "     - 소켓 경로     : $CONTAINERD_SOCKET"
    [ -n "$APPLY_SUPPRESS" ] && echo "     - 노이즈 억제 룰: $APPLY_SUPPRESS"

    echo ""
    echo "동작을 선택하세요:"
    echo "  1) 업그레이드 (저장된 설정 유지, Helm upgrade --install 무중단 배포)"
    echo "  2) 재설치     (기존 리소스 삭제 후 새로 설치)"
    echo "  3) 초기화     (모든 리소스 및 설정 파일 완전 삭제)"
    echo "  4) 취소"
    read -p "선택 [1/2/3/4]: " ACTION

    case "$ACTION" in
        1)
            DO_UPGRADE=true
            # 설정 값 무결성 검증 (P2 해결)
            _IS_INVALID="false"
            if [ -z "$IMAGE_SOURCE" ] || [ -z "$CONTAINERD_SOCKET" ] || [ -z "$APPLY_SUPPRESS" ]; then
                _IS_INVALID="true"
            elif [ "$IMAGE_SOURCE" == "harbor" ] && { [ -z "$HARBOR_REGISTRY" ] || [ -z "$HARBOR_PROJECT" ]; }; then
                _IS_INVALID="true"
            fi

            if [ "$_IS_INVALID" == "true" ]; then
                echo -e "${YELLOW}  ℹ️  저장된 설정 정보가 불완전하거나 유실되었습니다. 인프라 사양 입력을 재진행합니다.${NC}"
                _FORCE_REINPUT="true"
            fi
            ;;
        2) cleanup_resources "reinstall" ;;
        3) cleanup_resources "reset"; exit 0 ;;
        *) echo "취소되었습니다."; exit 0 ;;
    esac
fi

# ==========================================
# [2] 설치 설정 입력 (새로 설치 시에만)
# ==========================================
if [ "$DO_UPGRADE" != "true" ] || [ ! -f "$CONF_FILE" ] || [ "$_FORCE_REINPUT" == "true" ]; then
    if [ "$DO_UPGRADE" == "true" ] && [ ! -f "$CONF_FILE" ] && [ "$_FORCE_REINPUT" != "true" ]; then
        echo -e "${YELLOW}  ℹ️  설정 파일(install.conf)이 존재하지 않아 인프라 사양 입력을 진행합니다.${NC}"
    fi

    # 2-1. 이미지 소스 선택
    echo ""
    echo "이미지 소스를 선택하세요:"
    echo "  1) Harbor 레지스트리 사용 (폐쇄망 권장)"
    echo "  2) 로컬에 사전 로드된 이미지 사용 (기본 경로 승계)"
    read -p "선택 [1/2, 기본값 1]: " _IMG_SRC
    case "${_IMG_SRC:-1}" in
        1)
            IMAGE_SOURCE="harbor"
            read -p "Harbor 주소 (예: 192.168.1.10:30002): " HARBOR_REGISTRY
            read -p "Harbor 프로젝트 (예: library): " HARBOR_PROJECT
            ;;
        2)
            IMAGE_SOURCE="local"
            HARBOR_REGISTRY=""
            HARBOR_PROJECT=""
            ;;
        *)
            echo -e "${RED}[오류] 이미지 소스는 1, 2 중 하나를 선택해야 합니다.${NC}"
            exit 1
            ;;
    esac

    # 로컬 이미지 로드 처리
    if [ "$IMAGE_SOURCE" == "local" ]; then
        echo "로컬 tar 파일을 containerd(k8s.io)에 import 중..."
        IMPORT_COUNT=0
        for tar_file in ./images/*.tar; do
            [ -e "${tar_file}" ] || continue
            echo "  → $(basename "${tar_file}")"
            sudo ctr -n k8s.io images import "${tar_file}" 2>/dev/null || true
            IMPORT_COUNT=$((IMPORT_COUNT + 1))
        done
        echo "  ${IMPORT_COUNT}개 이미지 import 완료"
    fi

    # 2-2. 소켓 감지 및 설정
    echo ""
    CONTAINERD_SOCKET="/run/containerd/containerd.sock"
    if [ -S "/run/k3s/containerd/containerd.sock" ]; then
        echo -e "${GREEN}[INFO] K3s 소켓이 감지되었습니다. 경로를 변경합니다.${NC}"
        CONTAINERD_SOCKET="/run/k3s/containerd/containerd.sock"
    fi
    read -p "Containerd 소켓 경로 지정 (기본값 $CONTAINERD_SOCKET): " _SOCK
    CONTAINERD_SOCKET="${_SOCK:-$CONTAINERD_SOCKET}"

    # 2-3. 노이즈 억제 룰 사용 여부 프롬프트 기동
    echo ""
    APPLY_SUPPRESS="false"
    SUPPRESS_FILE="./values-suppress-noise.yaml"
    if [ -f "$SUPPRESS_FILE" ]; then
        echo "=== 노이즈 억제 룰 ==="
        echo "GitLab Shell 등 알려진 정상 동작이 Falco 룰에 걸려 대시보드에 노이즈가 발생할 수 있습니다."
        echo "values-suppress-noise.yaml 에 정의된 억제 룰을 함께 적용하시겠습니까?"
        read -r -p "[y/N, 기본값 N]: " _apply_suppress
        if [[ "$_apply_suppress" =~ ^[Yy]$ ]]; then
            APPLY_SUPPRESS="true"
        fi
    fi
fi

save_conf

# ==========================================
# [3] values-infra.yaml 생성 (Single Source of Truth)
# ==========================================
echo ""
echo "🔧 인프라 설정 파일(values-infra.yaml) 생성 중..."

# 이미지 변수 조립
IMAGE_REGISTRY_BLOCK=""
if [ "$IMAGE_SOURCE" == "harbor" ]; then
    IMAGE_REGISTRY_BLOCK="image:
  registry: \"${HARBOR_REGISTRY}\"
  repository: \"${HARBOR_PROJECT}/falco\"

falcosidekick:
  image:
    registry: \"${HARBOR_REGISTRY}\"
    repository: \"${HARBOR_PROJECT}/falcosidekick\"
  testConnection:
    image:
      registry: \"${HARBOR_REGISTRY}\"
      repository: \"${HARBOR_PROJECT}/curl\"
      tag: \"latest\""
else
    IMAGE_REGISTRY_BLOCK="image:
  registry: \"\"
  repository: \"falcosecurity/falco\"

falcosidekick:
  image:
    registry: \"\"
    repository: \"falcosecurity/falcosidekick\"
  testConnection:
    image:
      registry: \"\"
      repository: \"appropriate/curl\"
      tag: \"latest\""
fi

cat > ./values-infra.yaml <<EOF
# Falco v0.43.0 인프라 설정 — install.sh 에 의해 자동 관리됩니다.
${IMAGE_REGISTRY_BLOCK}

collectors:
  containerEngine:
    enabled: true
    engines:
      docker:
        enabled: false
      podman:
        enabled: false
      containerd:
        enabled: false
      cri:
        enabled: true
        sockets:
          - "${CONTAINERD_SOCKET}"
EOF

# ==========================================
# [4] Kubernetes 리소스 준비 및 설치
# ==========================================
echo ""
echo -e "🚀 ${GREEN}Falco 설치를 진행합니다...${NC}"

# 네임스페이스 생성
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# 추가 values 매니페스트 조립
HELM_ARGS=("-f" "$VALUES_FILE" "-f" "./values-infra.yaml")
if [ "$APPLY_SUPPRESS" == "true" ] && [ -f "./values-suppress-noise.yaml" ]; then
    HELM_ARGS+=("-f" "./values-suppress-noise.yaml")
    echo -e "  📊 노이즈 억제 룰을 병합하여 배포합니다."
fi

# Helm upgrade --install 멱등 설치 기동
helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  "${HELM_ARGS[@]}" \
  --wait --timeout 5m

echo ""
echo "========================================================"
echo -e "${GREEN}🎉 Falco (Intrusion Detection System) 설치 완료!${NC}"
echo "설정 파일 : $CONF_FILE"
echo "확인 명령어 : kubectl get pods -n $NAMESPACE"
echo "========================================================"
echo ""
