#!/bin/bash
set -e

# 스크립트 위치 기준으로 컴포넌트 루트로 이동
COMPONENT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$COMPONENT_ROOT" || exit 1

# =================================================================
# --- 설정 변수 ---
# =================================================================
CONF_FILE="./install.conf"
NAMESPACE="tekton-pipelines"
RELEASE_NAME="tekton"

MANIFESTS_DIR="./manifests"
PIPELINES_MANIFEST="${MANIFESTS_DIR}/pipelines-v1.9.0-release.yaml"
TRIGGERS_MANIFEST="${MANIFESTS_DIR}/triggers-v0.34.0-release.yaml"
DASHBOARD_MANIFEST="${MANIFESTS_DIR}/dashboard-v0.65.0-release.yaml"
TMP_DIR="/tmp/tekton-install-$$"
NODEPORT_DASHBOARD="30004"

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
# Tekton v1.9.0 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
INSTALL_TRIGGERS="${INSTALL_TRIGGERS}"
INSTALL_DASHBOARD="${INSTALL_DASHBOARD}"
NODEPORT_DASHBOARD="${NODEPORT_DASHBOARD}"
INSTALLED_VERSION="v1.9.0"
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
    echo -e "🧹 ${YELLOW}[Clean Up] 기존 Tekton 리소스 제거 시작...${NC}"

    # 제거 전 재확인 프롬프트 최상단 기동 (P1 준수)
    echo ""
    read -p "⚠️  Tekton의 모든 리소스 및 네임스페이스를 제거하시겠습니까? (y/n): " DELETE_CONFIRM
    if [[ ! "${DELETE_CONFIRM}" =~ ^[Yy]$ ]]; then
        echo "취소되었습니다."
        exit 0
    fi

    # 1. 릴리즈 리소스 삭제
    echo "   - 매니페스트 리소스 삭제 중..."
    if [ -f "${DASHBOARD_MANIFEST}" ]; then
        kubectl delete -f "${DASHBOARD_MANIFEST}" --ignore-not-found=true --timeout=30s 2>/dev/null || true
    fi
    if [ -f "${TRIGGERS_MANIFEST}" ]; then
        kubectl delete -f "${TRIGGERS_MANIFEST}" --ignore-not-found=true --timeout=30s 2>/dev/null || true
    fi
    if [ -f "${PIPELINES_MANIFEST}" ]; then
        kubectl delete -f "${PIPELINES_MANIFEST}" --ignore-not-found=true --timeout=30s 2>/dev/null || true
    fi

    # 2. 관련 네임스페이스 강제 삭제
    for NS in tekton-pipelines tekton-pipelines-resolvers tekton-triggers tekton-dashboard; do
        if kubectl get ns "${NS}" >/dev/null 2>&1; then
            echo "   - Namespace '${NS}' 삭제 중..."
            kubectl delete ns "${NS}" --ignore-not-found=true --timeout=30s 2>/dev/null || true
        fi
    done

    # 3. 설정 파일 삭제 (Reset 모드 시에만)
    if [ "$RESET_MODE" == "reset" ]; then
        rm -f "$CONF_FILE"
        echo -e "🗑️  설정 파일(${CONF_FILE}) 삭제 완료."
    fi

    echo -e "${GREEN}✅ 초기화 완료.${NC}"
    echo ""
}

# ── 이미지 경로 rewrite 함수 ──────────────────────────────────
# release.yaml 내 이미지 경로를 Harbor 주소로 교체 후 임시 파일 생성
rewrite_manifest() {
    local src="$1"
    local dst="$2"

    if [ "${IMAGE_SOURCE}" = "1" ]; then
        # ghcr.io/tektoncd 및 gcr.io/tekton-releases 하위의 모든 이미지 경로를 유연하게 치환
        # @sha256: 다이제스트 제거 및 Harbor 저장 경로 단일 레벨 변환 보장
        sed -E \
            -e "s,(ghcr\.io/tektoncd|gcr\.io/tekton-releases)/[^/]+/([^:\"' ]*):([^@\"' ]*)@sha256:[a-zA-Z0-9:]*,${HARBOR_REGISTRY}/${HARBOR_PROJECT}/\2:\3,g" \
            -e "s,(ghcr\.io/tektoncd|gcr\.io/tekton-releases)/[^/]+/([^:\"' ]*):([^@\"' ]*),${HARBOR_REGISTRY}/${HARBOR_PROJECT}/\2:\3,g" \
            "$src" > "$dst"
    else
        # 로컬 import 사용 시 원본 그대로 복사
        cp "$src" "$dst"
    fi
}

# ==========================================
# [1] 기존 설치 감지 및 메뉴
# ==========================================
load_conf
check_command kubectl

EXIST_NS=$(kubectl get ns "$NAMESPACE" > /dev/null 2>&1 && echo "yes" || echo "no")
DO_UPGRADE=false
_FORCE_REINPUT=false

if [ "$EXIST_NS" == "yes" ] || [ -f "$CONF_FILE" ]; then
    echo ""
    echo -e "⚠️  ${YELLOW}기존 설치 또는 설정이 감지되었습니다.${NC}"
    [ -f "$CONF_FILE" ] && echo "  📋 저장된 설정 정보:"
    [ -n "$IMAGE_SOURCE" ] && echo "     - 이미지 소스 : $IMAGE_SOURCE"
    [ -n "$HARBOR_REGISTRY" ] && echo "     - Harbor 주소 : $HARBOR_REGISTRY"
    [ -n "$INSTALL_TRIGGERS" ] && echo "     - Triggers    : $INSTALL_TRIGGERS"
    [ -n "$INSTALL_DASHBOARD" ] && echo "     - Dashboard   : $INSTALL_DASHBOARD"

    echo ""
    echo "동작을 선택하세요:"
    echo "  1) 업그레이드 (저장된 설정 유지, 매니페스트 멱등 재적용)"
    echo "  2) 재설치     (기존 리소스 삭제 후 새로 설치)"
    echo "  3) 초기화     (모든 리소스 및 설정 파일 완전 삭제)"
    echo "  4) 취소"
    read -p "선택 [1/2/3/4]: " ACTION

    case "$ACTION" in
        1)
            DO_UPGRADE=true
            # 설정 값 무결성 검증
            _IS_INVALID="false"
            if [ -z "$IMAGE_SOURCE" ] || [ -z "$INSTALL_TRIGGERS" ] || [ -z "$INSTALL_DASHBOARD" ]; then
                _IS_INVALID="true"
            elif [ "$IMAGE_SOURCE" == "1" ] && { [ -z "$HARBOR_REGISTRY" ] || [ -z "$HARBOR_PROJECT" ]; }; then
                _IS_INVALID="true"
            fi

            if [ "$_IS_INVALID" == "true" ]; then
                echo -e "${YELLOW}  ℹ️  저장된 설정 정보가 불완전합니다. 설치 설정을 다시 입력해 주십시오.${NC}"
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
    # 2-1. 이미지 소스 선택
    echo ""
    echo "이미지 소스를 선택하세요:"
    echo "  1) Harbor 레지스트리 사용 (사전에 images/upload_images_to_harbor_v3-lite.sh 실행 필요)"
    echo "  2) 로컬 tar 직접 import (이미 이미지가 로드된 경우 건너뜀)"
    read -p "선택 [1/2, 기본값: 1]: " IMAGE_SOURCE
    IMAGE_SOURCE="${IMAGE_SOURCE:-1}"

    if [ "${IMAGE_SOURCE}" = "1" ]; then
        read -p "Harbor 레지스트리 주소 (예: 192.168.1.10:30002): " HARBOR_REGISTRY
        if [ -z "${HARBOR_REGISTRY}" ]; then
            echo -e "${RED}[오류] Harbor 레지스트리 주소가 필요합니다.${NC}"; exit 1
        fi
        read -p "Harbor 프로젝트 (예: library): " HARBOR_PROJECT
        if [ -z "${HARBOR_PROJECT}" ]; then
            echo -e "${RED}[오류] Harbor 프로젝트가 필요합니다.${NC}"; exit 1
        fi
    elif [ "${IMAGE_SOURCE}" = "2" ]; then
        echo "로컬 tar 파일을 containerd(k8s.io)에 import 중..."
        IMPORT_COUNT=0
        for tar_file in ./images/*.tar; do
            [ -e "${tar_file}" ] || continue
            echo "  → $(basename "${tar_file}")"
            sudo ctr -n k8s.io images import "${tar_file}" 2>/dev/null || true
            IMPORT_COUNT=$((IMPORT_COUNT + 1))
        done
        [ "${IMPORT_COUNT}" -eq 0 ] && echo -e "${YELLOW}[경고] ./images/ 에 tar 파일이 없습니다.${NC}"
        echo "  ${IMPORT_COUNT}개 이미지 import 완료"
        HARBOR_REGISTRY=""
        HARBOR_PROJECT=""
    else
        echo -e "${RED}[오류] 1 또는 2를 선택하세요.${NC}"; exit 1
    fi

    # 2-2. 설치할 컴포넌트 선택
    echo ""
    echo "설치할 컴포넌트를 선택하세요."
    echo "  [필수] Tekton Pipelines v1.9.0 — 항상 설치됩니다."
    echo ""
    read -p "  [선택] Tekton Triggers v0.34.0 설치? (y/n): " INSTALL_TRIGGERS
    read -p "  [선택] Tekton Dashboard v0.65.0 설치? (y/n): " INSTALL_DASHBOARD
fi

save_conf

# ── 매니페스트 파일 존재 확인 ────────────────────────────────
if [ ! -f "${PIPELINES_MANIFEST}" ]; then
    echo -e "${RED}[오류] ${PIPELINES_MANIFEST} 가 없습니다.${NC}"
    exit 1
fi
if [[ "${INSTALL_TRIGGERS}" =~ ^[Yy]$ ]] && [ ! -f "${TRIGGERS_MANIFEST}" ]; then
    echo -e "${RED}[오류] ${TRIGGERS_MANIFEST} 가 없습니다.${NC}"
    exit 1
fi
if [[ "${INSTALL_DASHBOARD}" =~ ^[Yy]$ ]] && [ ! -f "${DASHBOARD_MANIFEST}" ]; then
    echo -e "${RED}[오류] ${DASHBOARD_MANIFEST} 가 없습니다.${NC}"
    exit 1
fi

echo ""
echo "==========================================="
echo " Installing Tekton v1.9.0 LTS (Offline)"
echo "==========================================="
echo " Image Source : ${IMAGE_SOURCE}"
[ -n "${HARBOR_REGISTRY}" ] && echo " Harbor       : ${HARBOR_REGISTRY}/${HARBOR_PROJECT}"
echo " Triggers     : ${INSTALL_TRIGGERS}"
echo " Dashboard    : ${INSTALL_DASHBOARD}"
echo "==========================================="

mkdir -p "${TMP_DIR}"

# ── Tekton Pipelines 설치 (필수) ─────────────────────────────
echo ""
echo ">>> [1/3] Tekton Pipelines v1.9.0 설치 중..."
rewrite_manifest "${PIPELINES_MANIFEST}" "${TMP_DIR}/pipelines.yaml"
kubectl apply -f "${TMP_DIR}/pipelines.yaml"

echo ""
echo ">>> Tekton Pipelines 준비 대기 중 (최대 5분)..."
kubectl wait --timeout=5m -n tekton-pipelines \
    deployment/tekton-pipelines-controller --for=condition=Available

# ── Tekton Triggers 설치 (선택) ──────────────────────────────
if [[ "${INSTALL_TRIGGERS}" =~ ^[Yy]$ ]]; then
    echo ""
    echo ">>> [2/3] Tekton Triggers 설치 중..."
    rewrite_manifest "${TRIGGERS_MANIFEST}" "${TMP_DIR}/triggers.yaml"
    kubectl apply -f "${TMP_DIR}/triggers.yaml"

    kubectl wait --timeout=5m -n tekton-pipelines \
        deployment/tekton-triggers-controller --for=condition=Available
else
    echo ""
    echo ">>> [2/3] Tekton Triggers 건너뜁니다."
fi

# ── Tekton Dashboard 설치 (선택) ─────────────────────────────
if [[ "${INSTALL_DASHBOARD}" =~ ^[Yy]$ ]]; then
    echo ""
    echo ">>> [3/3] Tekton Dashboard 설치 중..."
    rewrite_manifest "${DASHBOARD_MANIFEST}" "${TMP_DIR}/dashboard.yaml"
    kubectl apply -f "${TMP_DIR}/dashboard.yaml"

    kubectl wait --timeout=5m -n tekton-pipelines \
        deployment/tekton-dashboard --for=condition=Available

    # Dashboard NodePort 패치
    echo ""
    echo ">>> Dashboard NodePort 패치 중 (포트: ${NODEPORT_DASHBOARD})..."
    sleep 5
    DASHBOARD_SVC=$(kubectl get svc -n tekton-pipelines \
        -l app=tekton-dashboard -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -n "${DASHBOARD_SVC}" ]; then
        kubectl patch svc "${DASHBOARD_SVC}" -n tekton-pipelines --type='merge' \
            -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"name\":\"http\",\"port\":9097,\"targetPort\":9097,\"nodePort\":${NODEPORT_DASHBOARD}}]}}"
    fi
else
    echo ""
    echo ">>> [3/3] Tekton Dashboard 건너뜁니다."
fi

# ── 임시 파일 정리 ────────────────────────────────────────────
rm -rf "${TMP_DIR}"

# ── 완료 메시지 ───────────────────────────────────────────────
echo ""
echo "==========================================="
echo -e " ${GREEN}✅ Tekton v1.9.0 설치 완료${NC}"
echo "==========================================="
echo " Pipelines : 설치됨"
[[ "${INSTALL_TRIGGERS}" =~ ^[Yy]$ ]] && echo " Triggers  : 설치됨"
[[ "${INSTALL_DASHBOARD}" =~ ^[Yy]$ ]] && echo " Dashboard : http://<NODE_IP>:${NODEPORT_DASHBOARD}"
echo ""
echo " CLI 설치 확인:"
echo "   tkn version"
echo ""
echo " Pod 상태 확인:"
echo "   kubectl get pods -n tekton-pipelines"
echo "==========================================="
kubectl get pods -n tekton-pipelines
echo ""
