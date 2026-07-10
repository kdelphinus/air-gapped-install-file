#!/bin/bash
set -e

# 스크립트 위치 기준으로 컴포넌트 루트로 이동
COMPONENT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$COMPONENT_ROOT" || exit 1

# =================================================================
# --- 설정 변수 ---
# =================================================================
CHART_PATH="./charts/tetragon"
VALUES_FILE="./values.yaml"
CONF_FILE="./install.conf"
NAMESPACE="kube-system"
RELEASE_NAME="tetragon"

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
# Tetragon v1.6.0 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
APPLY_POLICY="${APPLY_POLICY}"
INSTALLED_VERSION="v1.6.0"
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
    echo -e "🧹 ${YELLOW}[Clean Up] 기존 Tetragon 리소스 제거 시작...${NC}"

    # 제거 전 재확인 프롬프트 최상단 기동 (P1 준수)
    echo ""
    read -p "⚠️  Tetragon의 모든 리소스를 제거하시겠습니까? (y/n): " DELETE_CONFIRM
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

    # 2. TracingPolicy 삭제 (Reset 모드 시에만 확인 후 삭제)
    if [ "$RESET_MODE" == "reset" ]; then
        echo ""
        read -p "⚠️  Tetragon 샘플 정책(block-sensitive-read)도 함께 삭제하시겠습니까? (y/n): " DELETE_POLICY
        if [[ "${DELETE_POLICY}" =~ ^[Yy]$ ]]; then
            echo "   - 샘플 TracingPolicy 삭제 중..."
            kubectl delete tracingpolicy block-sensitive-read --ignore-not-found=true 2>/dev/null || true
        fi
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
    [ -n "$APPLY_POLICY" ] && echo "     - 샘플 정책 적용: $APPLY_POLICY"

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
            if [ -z "$IMAGE_SOURCE" ] || [ -z "$APPLY_POLICY" ]; then
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

    # 2-2. 정책 적용 여부 감지
    echo ""
    APPLY_POLICY="false"
    read -p "민감 파일 읽기 차단 정책(TracingPolicy)을 적용하시겠습니까? (y/n): " _apply_policy
    if [[ "$_apply_policy" =~ ^[Yy]$ ]]; then
        APPLY_POLICY="true"
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
    IMAGE_REGISTRY_BLOCK="tetragon:
  image:
    override: \"${HARBOR_REGISTRY}/${HARBOR_PROJECT}/tetragon:v1.6.0\"

tetragonOperator:
  image:
    override: \"${HARBOR_REGISTRY}/${HARBOR_PROJECT}/tetragon-operator:v1.6.0\"

export:
  stdout:
    image:
      override: \"${HARBOR_REGISTRY}/${HARBOR_PROJECT}/hubble-export-stdout:v1.1.0\""
else
    IMAGE_REGISTRY_BLOCK="tetragon:
  image:
    override: \"quay.io/cilium/tetragon:v1.6.0\"

tetragonOperator:
  image:
    override: \"quay.io/cilium/tetragon-operator:v1.6.0\"

export:
  stdout:
    image:
      override: \"quay.io/cilium/hubble-export-stdout:v1.1.0\""
fi

cat > ./values-infra.yaml <<EOF
# Tetragon v1.6.0 인프라 설정 — install.sh 에 의해 자동 관리됩니다.
${IMAGE_REGISTRY_BLOCK}
EOF

# ==========================================
# [4] Kubernetes 리소스 준비 및 설치
# ==========================================
echo ""
echo -e "🚀 ${GREEN}Tetragon 설치를 진행합니다...${NC}"

# Helm upgrade --install 멱등 설치 기동
helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  -f "$VALUES_FILE" \
  -f ./values-infra.yaml \
  --wait --timeout 5m

# 정책 적용 기동
if [ "$APPLY_POLICY" == "true" ] && [ -f "./manifests/block-sensitive-read.yaml" ]; then
    echo "📊 TracingPolicy (block-sensitive-read) 적용 중..."
    kubectl apply -f ./manifests/block-sensitive-read.yaml
fi

echo ""
echo "========================================================"
echo -e "${GREEN}🎉 Tetragon (eBPF Security Engine) 설치 완료!${NC}"
echo "설정 파일 : $CONF_FILE"
echo "확인 명령어 : kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=tetragon"
echo "========================================================"
echo ""
