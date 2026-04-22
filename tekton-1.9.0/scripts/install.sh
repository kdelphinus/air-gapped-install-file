#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

# ==================== Config ====================
# ── 이미지 소스 선택 ──────────────────────────────────────────
echo ""
echo "이미지 소스를 선택하세요:"
echo "  1) Harbor 레지스트리 사용 (사전에 images/upload_images_to_harbor_v3-lite.sh 실행 필요)"
echo "  2) 로컬 tar 직접 import (이미 이미지가 로드된 경우 건너뜀)"
read -p "선택 [1/2, 기본값: 1]: " IMAGE_SOURCE
IMAGE_SOURCE="${IMAGE_SOURCE:-1}"

if [ "${IMAGE_SOURCE}" = "1" ]; then
    read -p "Harbor 레지스트리 주소 (예: 192.168.1.10:30002): " HARBOR_REGISTRY
    if [ -z "${HARBOR_REGISTRY}" ]; then
        echo "[오류] Harbor 레지스트리 주소가 필요합니다."; exit 1
    fi
    read -p "Harbor 프로젝트 (예: library): " HARBOR_PROJECT
    if [ -z "${HARBOR_PROJECT}" ]; then
        echo "[오류] Harbor 프로젝트가 필요합니다."; exit 1
    fi
elif [ "${IMAGE_SOURCE}" = "2" ]; then
    echo "로컬 tar 파일을 containerd(k8s.io)에 import 중..."
    IMPORT_COUNT=0
    for tar_file in ./images/*.tar; do
        [ -e "${tar_file}" ] || continue
        echo "  → $(basename "${tar_file}")"
        sudo ctr -n k8s.io images import "${tar_file}"
        IMPORT_COUNT=$((IMPORT_COUNT + 1))
    done
    [ "${IMPORT_COUNT}" -eq 0 ] && echo "[경고] ./images/ 에 tar 파일이 없습니다."
    echo "  ${IMPORT_COUNT}개 이미지 import 완료"
    HARBOR_REGISTRY=""
    HARBOR_PROJECT=""
else
    echo "[오류] 1 또는 2를 선택하세요."; exit 1
fi

# ── 설치할 컴포넌트 선택 ──────────────────────────────────────
echo ""
echo "설치할 컴포넌트를 선택하세요."
echo "  [필수] Tekton Pipelines v1.9.0 — 항상 설치됩니다."
echo ""
read -p "  [선택] Tekton Triggers v0.34.x 설치? (y/n): " INSTALL_TRIGGERS
read -p "  [선택] Tekton Dashboard v0.65.0 설치? (y/n): " INSTALL_DASHBOARD

NODEPORT_DASHBOARD="30004"
# ================================================

MANIFESTS_DIR="./manifests"
PIPELINES_MANIFEST="${MANIFESTS_DIR}/pipelines-v1.9.0-release.yaml"
TRIGGERS_MANIFEST="${MANIFESTS_DIR}/triggers-v0.34.0-release.yaml"
DASHBOARD_MANIFEST="${MANIFESTS_DIR}/dashboard-v0.65.0-release.yaml"
TMP_DIR="/tmp/tekton-install-$$"

echo ""
echo "==========================================="
echo " Installing Tekton v1.9.0 LTS (Offline)"
echo "==========================================="
echo " Image Source : ${IMAGE_SOURCE}"
[ -n "${HARBOR_REGISTRY}" ] && echo " Harbor       : ${HARBOR_REGISTRY}/${HARBOR_PROJECT}"
echo " Triggers     : ${INSTALL_TRIGGERS}"
echo " Dashboard    : ${INSTALL_DASHBOARD}"
echo "==========================================="

# ── 매니페스트 파일 존재 확인 ────────────────────────────────
if [ ! -f "${PIPELINES_MANIFEST}" ]; then
    echo "[오류] ${PIPELINES_MANIFEST} 가 없습니다."
    echo "  아래 명령으로 다운로드하세요 (인터넷 환경에서):"
    echo "  curl -LO https://storage.googleapis.com/tekton-releases/pipeline/previous/v1.9.0/release.yaml"
    echo "  mv release.yaml ${PIPELINES_MANIFEST}"
    exit 1
fi

if [[ "${INSTALL_TRIGGERS}" =~ ^[Yy]$ ]] && [ ! -f "${TRIGGERS_MANIFEST}" ]; then
    echo "[오류] ${TRIGGERS_MANIFEST} 가 없습니다."
    echo "  curl -LO https://storage.googleapis.com/tekton-releases/triggers/previous/v0.34.0/release.yaml"
    echo "  mv release.yaml ${TRIGGERS_MANIFEST}"
    exit 1
fi

if [[ "${INSTALL_DASHBOARD}" =~ ^[Yy]$ ]] && [ ! -f "${DASHBOARD_MANIFEST}" ]; then
    echo "[오류] ${DASHBOARD_MANIFEST} 가 없습니다."
    echo "  curl -LO https://storage.googleapis.com/tekton-releases/dashboard/previous/v0.65.0/release.yaml"
    echo "  mv release.yaml ${DASHBOARD_MANIFEST}"
    exit 1
fi

# ── 기존 설치 감지 ────────────────────────────────────────────
if kubectl get ns tekton-pipelines > /dev/null 2>&1; then
    echo ""
    echo "⚠️  기존 설치 감지: namespace 'tekton-pipelines' 가 존재합니다."
    echo "  1) 삭제 후 재설치"
    echo "  2) 매니페스트 재적용 (업그레이드)"
    echo "  3) 취소"
    read -p "선택 [1/2/3]: " REINSTALL_CHOICE

    if [ "${REINSTALL_CHOICE}" = "1" ]; then
        echo "기존 설치를 삭제합니다..."
        kubectl delete ns tekton-pipelines tekton-pipelines-resolvers \
            tekton-triggers tekton-dashboard --ignore-not-found=true --timeout=60s
        sleep 5
    elif [ "${REINSTALL_CHOICE}" = "2" ]; then
        echo "매니페스트를 재적용합니다..."
    else
        echo "취소되었습니다."; exit 0
    fi
fi

# ── 이미지 경로 rewrite 함수 ──────────────────────────────────
# release.yaml 내 이미지 경로를 Harbor 주소로 교체 후 임시 파일 생성
rewrite_manifest() {
    local src="$1"
    local dst="$2"

    if [ "${IMAGE_SOURCE}" = "1" ]; then
        # Tekton v1.9.0 이미지: ghcr.io/tektoncd/<component>/<name-hash>:<tag>@sha256:<digest>
        # upload_images_to_harbor_v3-lite.sh 는 마지막 세그먼트만 Harbor 경로로 사용하므로
        # Harbor 경로: <REGISTRY>/<PROJECT>/<name-hash>:<tag>
        # @sha256 digest 는 Harbor re-tag 후 유효하지 않으므로 제거
        sed \
            -e "s|ghcr\.io/tektoncd/pipeline/\([^:]*\):\([^@]*\)@sha256:[^\"' ]*|${HARBOR_REGISTRY}/${HARBOR_PROJECT}/\1:\2|g" \
            -e "s|ghcr\.io/tektoncd/triggers/\([^:]*\):\([^@]*\)@sha256:[^\"' ]*|${HARBOR_REGISTRY}/${HARBOR_PROJECT}/\1:\2|g" \
            -e "s|ghcr\.io/tektoncd/dashboard/\([^:]*\):\([^@]*\)@sha256:[^\"' ]*|${HARBOR_REGISTRY}/${HARBOR_PROJECT}/\1:\2|g" \
            "$src" > "$dst"
    else
        # 로컬 import 사용 시 원본 그대로 복사
        cp "$src" "$dst"
    fi
}

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
echo " ✅ Tekton v1.9.0 설치 완료"
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
