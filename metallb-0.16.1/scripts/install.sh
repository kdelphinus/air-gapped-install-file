#!/bin/bash
# ---------------------------------------------------------
# MetalLB v0.16.1 Installation Script
# [Chart Version] 0.16.1 (L2 Mode Only)
# [Target] Rocky Linux / Ubuntu (Online/Offline)
# ---------------------------------------------------------
set -e

# 스크립트 위치 기준으로 컴포넌트 루트로 이동
COMPONENT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$COMPONENT_ROOT" || exit 1

# 기본 변수
NAMESPACE="metallb-system"
CHART_PATH="./charts/metallb"
RELEASE_NAME="metallb"
CONF_FILE="./install.conf"
L2_MANIFEST="./manifests/l2-config.yaml"
VALUES_FILE="./values.yaml"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# ── 1. 오프라인 자산 디렉토리 사전 검증 ──────────────────────────────
validate_assets() {
    # 헬름 차트 디렉토리 검증 (공통 필수)
    if [ ! -d "$CHART_PATH" ]; then
        echo -e "${RED}[오류] 오프라인 Helm 차트 디렉토리(${CHART_PATH})가 존재하지 않습니다.${NC}"
        echo "       인터넷이 연결된 환경에서 먼저 scripts/download_assets_offline.sh를 실행하여 차트를 내려받으십시오."
        exit 1
    fi

    # 로컬 직접 사용 모드 시 이미지 tar 파일 실재성 파일 레벨 검사
    if [ "${IMAGE_SOURCE}" = "local" ]; then
        local controller_tar="./images/quay.io-metallb-controller-v0.16.1.tar"
        local speaker_tar="./images/quay.io-metallb-speaker-v0.16.1.tar"
        if [ ! -f "$controller_tar" ] || [ ! -f "$speaker_tar" ]; then
            echo -e "${RED}[오류] 로컬 임포트용 이미지 tar 파일이 누락되었습니다.${NC}"
            [ ! -f "$controller_tar" ] && echo "       - 누락: ${controller_tar}"
            [ ! -f "$speaker_tar" ] && echo "       - 누락: ${speaker_tar}"
            echo "       인터넷이 연결된 환경에서 먼저 scripts/download_assets_offline.sh를 기동해 주십시오."
            exit 1
        fi
    fi
}

# ── 2. 설정 로드 / 저장 (화이트리스트 로더 탑재) ──────────────────────────────
load_conf() {
    if [ -f "$CONF_FILE" ]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            if [[ "$key" =~ ^[A-Z0-9_]+$ ]]; then
                case "$key" in
                    IMAGE_SOURCE|HARBOR_REGISTRY|HARBOR_PROJECT|ADDRESS_POOL|POOL_NAME|MODE|INSTALLED_VERSION)
                        value=$(echo "$value" | sed -e "s/^'//" -e "s/'$//" -e 's/^"//' -e 's/"$//')
                        printf -v "$key" '%s' "$value"
                        ;;
                    *)
                        # 화이트리스트 외 전역 환경변수(PATH, NAMESPACE 등) 주입을 안전하게 차단
                        ;;
                esac
            fi
        done < "$CONF_FILE"
    fi
}

save_conf() {
    cat > "$CONF_FILE" <<EOF
# MetalLB 0.16.1 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE='${IMAGE_SOURCE}'
HARBOR_REGISTRY='${HARBOR_REGISTRY}'
HARBOR_PROJECT='${HARBOR_PROJECT}'
ADDRESS_POOL='${ADDRESS_POOL}'
POOL_NAME='${POOL_NAME}'
MODE='L2'
INSTALLED_VERSION='v0.16.1'
EOF
    echo -e "  ✅ 설정이 ${GREEN}${CONF_FILE}${NC} 에 저장되었습니다."
}

save_values_infra() {
    local IMG_CONTROLLER="quay.io/metallb/controller"
    local IMG_SPEAKER="quay.io/metallb/speaker"

    if [ "${IMAGE_SOURCE}" = "harbor" ]; then
        IMG_CONTROLLER="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/metallb-controller"
        IMG_SPEAKER="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/metallb-speaker"
    fi

    cat > "values-infra.yaml" <<EOF
# MetalLB 인프라 설정 — install.sh 에 의해 자동 생성됩니다.
controller:
  image:
    repository: "${IMG_CONTROLLER}"
    tag: v0.16.1
speaker:
  image:
    repository: "${IMG_SPEAKER}"
    tag: v0.16.1
EOF
    echo -e "  ✅ 인프라 오버라이드가 ${GREEN}values-infra.yaml${NC} 에 생성되었습니다."
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}[오류] '$1' 명령어를 찾을 수 없습니다.${NC}"
        exit 1
    fi
}

cleanup_resources() {
    local RESET_MODE=$1
    echo ""
    echo -e "🧹 ${YELLOW}[Clean Up] 리소스 제거 시작...${NC}"

    # ⚠️ 서비스 단절 및 초기화 영향 경고
    if [ "${RESET_MODE}" == "reset" ]; then
        echo -e "${RED}⚠️  [주의] 데이터 완전 초기화 모드입니다."
        echo -e "          네임스페이스와 함께 IPAddressPool, L2Advertisement 가 즉시 완전 제거됩니다."
        echo -e "          로컬 설정 백업 파일(install.conf, values-infra.yaml)도 함께 소거됩니다.${NC}"
        read -p "❓ 모든 설정 데이터를 삭제하고 네임스페이스를 완전히 소거하시겠습니까? (y/N): " RESET_CONFIRM_2
        if [[ ! "${RESET_CONFIRM_2}" =~ ^[Yy]$ ]]; then
            echo "취소되었습니다."
            exit 0
        fi
    else
        echo -e "${RED}⚠️  [주의] 재설치 시 controller/speaker DaemonSet이 일시 제거되므로"
        echo -e "          기존에 구동 중이던 모든 LoadBalancer 통신이 전면 차단됩니다.${NC}"
        read -p "❓ 모든 트래픽이 끊김을 감수하고 릴리즈를 재설치하시겠습니까? (y/N): " REINSTALL_CONFIRM
        if [[ ! "${REINSTALL_CONFIRM}" =~ ^[Yy]$ ]]; then
            echo "취소되었습니다."
            exit 0
        fi
    fi

    # 1. Helm Uninstall
    echo "   - Helm Release 삭제 중..."
    if [ "${RESET_MODE}" == "reinstall" ]; then
        # Reinstall의 경우 기존 리소스가 완전히 삭제(Terminating 완료)될 때까지 동기적으로 기다려
        # 신규 설치와 기존 자원 간의 충돌 및 오동작을 방지합니다.
        # 실패 상태를 명확히 노출하기 위해 에러를 임의로 은폐(|| true)하지 않습니다.
        helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait --timeout 5m
    else
        # 일반 초기화(Reset)의 경우 Namespace가 소거되므로 비동기식 삭제 정책을 유지합니다.
        helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait=false 2>/dev/null || true
    fi

    # 2. Reset 시에만 Namespace, IP 풀 및 CRD 자원 완전 파괴
    if [ "${RESET_MODE}" == "reset" ]; then
        echo "   - MetalLB CR Finalizer 일괄 제거 중..."
        for KIND in ipaddresspool l2advertisement bgpadvertisement bgppeer community bfdprofile; do
            kubectl get "$KIND" -n "$NAMESPACE" -o name 2>/dev/null | \
            xargs -r -I {} kubectl patch {} -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        done

        echo "   - Namespace '${NAMESPACE}' 삭제 중..."
        kubectl delete ns "$NAMESPACE" --timeout=30s --wait=false 2>/dev/null || true
        rm -f "$CONF_FILE" "values-infra.yaml"
        echo -e "   🗑️  설정 파일(install.conf, values-infra.yaml) 및 Namespace 삭제 완료."
    fi

    echo -e "${GREEN}✅ Clean Up 완료.${NC}"
    echo ""
}

# ==========================================
# [1] 기존 설치 감지 및 메뉴
# ==========================================
load_conf
check_command kubectl
check_command helm

EXIST_RELEASE=$(helm list -n "$NAMESPACE" -q 2>/dev/null | grep "^${RELEASE_NAME}$" || echo "")
DO_UPGRADE=false
_FORCE_REINPUT=false

if [ -n "$EXIST_RELEASE" ] || [ -f "$CONF_FILE" ]; then
    echo ""
    echo -e "⚠️  ${YELLOW}기존 설치 또는 설정이 감지되었습니다.${NC}"
    [ -f "$CONF_FILE" ] && echo "  📋 저장된 설정 정보:"
    [ -n "$IMAGE_SOURCE" ] && echo "     - 이미지 소스 : $IMAGE_SOURCE"
    [ -n "$HARBOR_REGISTRY" ] && echo "     - 레지스트리  : $HARBOR_REGISTRY/$HARBOR_PROJECT"
    [ -n "$ADDRESS_POOL" ] && echo "     - IP 주소 풀  : $ADDRESS_POOL"
    [ -n "$POOL_NAME" ] && echo "     - Pool 이름   : $POOL_NAME"

    echo ""
    echo "동작을 선택하세요:"
    echo "  1) 업그레이드 (저장된 설정 유지, Helm upgrade 기동 - 무중단 권장)"
    echo "  2) 재설치     (Namespace 및 IP 풀은 보존하되 controller/speaker 일시 중단 후 재구성)"
    echo "  3) 초기화     (IP 풀, 네임스페이스 및 모든 설정 자산 전면 파괴)"
    echo "  4) 취소"
    read -p "선택 [1/2/3/4]: " ACTION

    case "$ACTION" in
        1)
            DO_UPGRADE=true
            _IS_INVALID="false"
            if [ -z "$IMAGE_SOURCE" ] || [ -z "$ADDRESS_POOL" ] || [ -z "$POOL_NAME" ]; then
                _IS_INVALID="true"
            fi
            if [ "${IMAGE_SOURCE}" = "harbor" ] && { [ -z "${HARBOR_REGISTRY}" ] || [ -z "${HARBOR_PROJECT}" ]; }; then
                _IS_INVALID="true"
            fi

            if [ "$_IS_INVALID" == "true" ]; then
                echo -e "${YELLOW}  ℹ️  저장된 설정 정보가 불완전합니다. 설치 설정을 다시 입력해 주십시오.${NC}"
                _FORCE_REINPUT="true"
            fi
            ;;
        2) cleanup_resources "reinstall" ;;
        3)
            echo -e "${RED}⚠️  [경고] 초기화 시 IP 풀 설정, L2 Advertisement 및 네임스페이스가 완전히 영구 삭제됩니다."
            echo -e "          기존 외부 LoadBalancer IP 통신이 전면 영구 중단됩니다.${NC}"
            read -p "❓ 정말 모든 데이터와 설정을 지우는 초기화 작업을 기동하시겠습니까? (y/N): " RESET_CONFIRM_1
            if [[ ! "${RESET_CONFIRM_1}" =~ ^[Yy]$ ]]; then
                echo "취소되었습니다."
                exit 0
            fi
            cleanup_resources "reset"
            exit 0
            ;;
        *) echo "취소되었습니다."; exit 0 ;;
    esac
fi

# ==========================================
# [2] 설치 설정 입력 (새로 설치 또는 설정 복원 불완전 시)
# ==========================================
if [ "$DO_UPGRADE" != "true" ] || [ ! -f "$CONF_FILE" ] || [ "$_FORCE_REINPUT" == "true" ]; then
    echo -e "${CYAN}===========================================${NC}"
    echo -e "${CYAN}   MetalLB v0.16.1 설치 설정 입력 (L2 전용)    ${NC}"
    echo -e "${CYAN}===========================================${NC}"

    # 2-1. 이미지 소스 선택
    echo ""
    echo "이미지 소스를 선택하세요:"
    echo "  1) Harbor 레지스트리 사용"
    echo "  2) 로컬 이미지 직접 사용 (ctr import)"
    read -p "선택 [1/2, 기본값: 1]: " _IMG_SRC
    _IMG_SRC="${_IMG_SRC:-1}"

    if [ "$_IMG_SRC" = "1" ]; then
        IMAGE_SOURCE="harbor"
        read -p "Harbor 레지스트리 주소 (예: 192.168.1.10:30002): " HARBOR_REGISTRY
        if [ -z "${HARBOR_REGISTRY}" ]; then
            echo -e "${RED}[오류] Harbor 레지스트리 주소가 필요합니다.${NC}"; exit 1
        fi
        read -p "Harbor 프로젝트 (예: library): " HARBOR_PROJECT
        if [ -z "${HARBOR_PROJECT}" ]; then
            echo -e "${RED}[오류] Harbor 프로젝트가 필요합니다.${NC}"; exit 1
        fi
    elif [ "$_IMG_SRC" = "2" ]; then
        IMAGE_SOURCE="local"
        validate_assets # 로컬 모드 자산 실재성 조밀 체크 실행
        echo "로컬 tar 이미지를 containerd(k8s.io)에 로드 중..."
        for tar_file in ./images/*.tar*; do
            [ -e "${tar_file}" ] || continue
            echo "  → $(basename "${tar_file}")"
            sudo ctr -n k8s.io images import "${tar_file}" 2>/dev/null || true
        done
        HARBOR_REGISTRY=""
        HARBOR_PROJECT=""
    else
        echo -e "${RED}[오류] 1 또는 2를 선택하세요.${NC}"; exit 1
    fi

    # 2-2. IP 주소 풀 범위 입력
    echo ""
    echo -e "${YELLOW}⚠️  [경고] IP 주소 풀은 클러스터 호스트 노드 대역과 L2 수준에서 통신 가능해야 합니다."
    echo -e "          반드시 노드 IP, Gateway, Pod/Service CIDR 대역과 절대 중복되거나 충돌하지 않는 유휴 대역을 지정해야 합니다.${NC}"
    while true; do
        read -p "LoadBalancer IP 범위 (형식: start-end 또는 CIDR, 예: 192.168.10.50-192.168.10.60): " ADDRESS_POOL
        if [[ "$ADDRESS_POOL" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}-([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || \
           [[ "$ADDRESS_POOL" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            # 중복/충돌 미팅 경고 확인 프롬프트
            read -p "❓ 입력하신 대역 (${ADDRESS_POOL})이 네트워크 충돌이 없는 유휴 범위임을 확실히 확인하셨습니까? (y/N): " DEPLOY_CONFIRM
            if [[ "$DEPLOY_CONFIRM" =~ ^[Yy]$ ]]; then
                break
            fi
            echo "대역을 재입력해 주십시오."
        else
            echo -e "${RED}  ❌ 형식이 올바르지 않습니다. 예: 192.168.10.50-192.168.10.60 또는 10.10.10.80/29${NC}"
        fi
    done

    # 2-3. IPAddressPool 이름 입력
    echo ""
    while true; do
        read -p "IPAddressPool 이름 입력 [기본값: cluster-pool]: " USER_POOL_NAME
        POOL_NAME="${USER_POOL_NAME:-cluster-pool}"
        # DNS Label 정합성 체크 (RFC 1123)
        if [[ "$POOL_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
            break
        fi
        echo -e "${RED}  ❌ 올바른 DNS label 형식이 아닙니다 (소문자, 숫자, 하이픈만 허용, 문자로 시작 및 종료).${NC}"
    done
fi

validate_assets
save_conf
save_values_infra

# ==========================================
# [3] 네임스페이스 및 Helm 배포 기동
# ==========================================
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if [ "$DO_UPGRADE" == "true" ]; then
    ACTION_TXT="업그레이드"
else
    ACTION_TXT="설치"
fi

echo ""
echo -e "🚀 [1/2] MetalLB Helm ${ACTION_TXT} 중..."
helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" \
    --namespace "$NAMESPACE" \
    -f values.yaml \
    -f values-infra.yaml \
    --wait

echo "⏳ controller / speaker Pod 기동 완료 대기..."
kubectl wait --timeout=5m -n "$NAMESPACE" deployment/metallb-controller --for=condition=Available
kubectl rollout status daemonset/metallb-speaker -n "$NAMESPACE" --timeout=5m

# ==========================================
# [4] IPAddressPool / L2Advertisement 템플릿 적용 (원본 불변 파이프 배포)
# ==========================================
echo ""
echo -e "🚀 [2/2] IPAddressPool / L2Advertisement 파이프 배포 중..."

# 원본 manifests/l2-config.yaml 파일은 절대 수정하지 않고,
# 메모리상에서 cluster-pool과 addresses 대역을 동적으로 치환해 파이프 인입으로 배포함
sed \
    -e "s|cluster-pool|${POOL_NAME}|g" \
    -e "s|172.30.235.200-172.30.235.210|${ADDRESS_POOL}|g" \
    "$L2_MANIFEST" | kubectl apply -f -

# 최종 결과 리포트
echo ""
echo "========================================================"
echo -e " ${GREEN}✅ MetalLB v0.16.1 구성 완료 (L2 Mode Only)${NC}"
echo "========================================================"
echo " 설정 파일 : $CONF_FILE"
echo " IP 풀     : $ADDRESS_POOL"
echo " Pool 이름 : $POOL_NAME"
echo "========================================================"
kubectl get pods -n "$NAMESPACE"
echo ""
kubectl get ipaddresspool,l2advertisement -n "$NAMESPACE"
echo ""
