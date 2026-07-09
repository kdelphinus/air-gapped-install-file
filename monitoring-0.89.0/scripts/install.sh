#!/bin/bash
set -e

# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

# =================================================================
# --- 설정 변수 ---
# =================================================================
NAMESPACE="monitoring"
RELEASE_NAME="prometheus"
CHART_PATH="./charts/kube-prometheus-stack"
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
# Monitoring v0.89.0 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
PROM_STORAGE_CLASS="${PROM_STORAGE_CLASS}"
PROM_STORAGE_SIZE="${PROM_STORAGE_SIZE}"
GRAFANA_STORAGE_CLASS="${GRAFANA_STORAGE_CLASS}"
GRAFANA_STORAGE_SIZE="${GRAFANA_STORAGE_SIZE}"
INSTALLED_VERSION="v0.89.0"
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
# [함수] 클린업 로직 (설치 중 재설치/초기화 시)
# ==========================================
cleanup_resources() {
    local RESET_MODE=$1
    echo ""
    echo -e "🧹 ${YELLOW}[Clean Up] 기존 Monitoring 리소스 제거 시작...${NC}"

    # 1. PV/PVC 삭제 여부 프롬프트 최우선 배치 (P0/Reset 준수)
    local DELETE_VOLUMES="no"
    echo ""
    read -p "⚠️  PV/PVC도 함께 삭제하시겠습니까? (데이터 영구 삭제, y/n): " DELETE_DATA
    if [[ "${DELETE_DATA}" =~ ^[Yy]$ ]]; then
        DELETE_VOLUMES="yes"
    fi

    # 2. 볼륨 보존 시 helm uninstall에 의한 PVC 자동 제거 방지 (keep 어노테이션 주입)
    if [ "$DELETE_VOLUMES" != "yes" ]; then
        if kubectl get pvc -n "$NAMESPACE" >/dev/null 2>&1; then
            echo "🛡️  볼륨 보존을 위해 Namespace '$NAMESPACE' 하위의 모든 PVC에 keep resource-policy를 설정합니다..."
            local pvc_list
            pvc_list=$(kubectl get pvc -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
            for pvc_name in $pvc_list; do
                [ -n "$pvc_name" ] || continue
                echo "   → PVC: $pvc_name"
                kubectl annotate pvc "$pvc_name" -n "$NAMESPACE" "helm.sh/resource-policy=keep" --overwrite 2>/dev/null || true
            done
        fi
    fi

    # 3. Helm Uninstall
    if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "⏳ Helm 차트 삭제 중..."
        helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait=false 2>/dev/null
        sleep 3
    fi

    # 4. Manifests 리소스 삭제 (pv-volume.yaml 은 제외)
    echo "🗑️  Manifests 삭제 중..."
    for f in ./manifests/*.yaml; do
        [ -f "$f" ] || continue
        [[ "$f" == *"pv-volume.yaml" ]] && continue
        kubectl delete -f "$f" --ignore-not-found=true 2>/dev/null || true
    done

    # pv-volume.yaml 은 볼륨 삭제 동의 시에만 삭제 진행
    if [ "$DELETE_VOLUMES" == "yes" ]; then
        if [ -f "./manifests/pv-volume.yaml" ]; then
            echo "   - PV/PVC manifests (pv-volume.yaml) 삭제 중..."
            kubectl delete -f ./manifests/pv-volume.yaml --ignore-not-found=true 2>/dev/null || true
        fi
    fi

    # 5. PVC 삭제 처리 (볼륨 삭제 선택 시)
    if [ "$DELETE_VOLUMES" == "yes" ]; then
        echo "   - PVC 삭제 중..."
        if kubectl get pvc -n "$NAMESPACE" >/dev/null 2>&1; then
            local pvc_list
            pvc_list=$(kubectl get pvc -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
            for pvc_name in $pvc_list; do
                [ -n "$pvc_name" ] || continue
                kubectl delete pvc "$pvc_name" -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
            done
        fi
    else
        echo "➡️  PVC 및 PV 볼륨 데이터가 안전하게 보존되었습니다."
    fi

    # 6. 네임스페이스 삭제 (볼륨 보존 시 cascade delete 방지를 위해 우회)
    if [ "$DELETE_VOLUMES" == "yes" ]; then
        if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
            echo "   - 네임스페이스 삭제 중..."
            kubectl delete namespace "$NAMESPACE" --ignore-not-found --timeout=30s 2>/dev/null || true
        fi
    else
        echo "➡️  볼륨 보존 선택에 따라 Namespace '${NAMESPACE}' 삭제 단계를 생략합니다."
    fi

    # 7. PV 삭제 (네임스페이스 삭제 후)
    if [ "$DELETE_VOLUMES" == "yes" ]; then
        echo "   - PV 삭제 중..."
        kubectl delete pv -l app.kubernetes.io/instance=$RELEASE_NAME --ignore-not-found=true 2>/dev/null || true
        kubectl get pv 2>/dev/null | grep "$NAMESPACE" | awk '{print $1}' | xargs -r kubectl delete pv 2>/dev/null || true
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

if [ "$EXIST_HELM" == "yes" ] || [ -f "$CONF_FILE" ]; then
    echo ""
    echo -e "⚠️  ${YELLOW}기존 설치 또는 설정이 감지되었습니다.${NC}"
    [ -f "$CONF_FILE" ] && echo "  📋 저장된 설정 정보:"
    [ -n "$IMAGE_SOURCE" ] && echo "     - 이미지 소스   : $IMAGE_SOURCE"
    [ -n "$HARBOR_REGISTRY" ] && echo "     - Harbor 주소   : $HARBOR_REGISTRY"
    [ -n "$PROM_STORAGE_CLASS" ] && echo "     - Prom 스토리지 클래스 : $PROM_STORAGE_CLASS"
    [ -n "$PROM_STORAGE_SIZE" ] && echo "     - Prom 볼륨 크기: $PROM_STORAGE_SIZE"

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
            # 설정 값 무결성 검증 (P2 완벽 해결)
            _IS_INVALID="false"
            if [ -z "$IMAGE_SOURCE" ] || [ -z "$PROM_STORAGE_CLASS" ] || [ -z "$PROM_STORAGE_SIZE" ] || [ -z "$GRAFANA_STORAGE_CLASS" ] || [ -z "$GRAFANA_STORAGE_SIZE" ]; then
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

    # 2-2. Prometheus 스토리지 입력
    echo ""
    read -p "Prometheus StorageClass 지정 (기본값 manual): " PROM_STORAGE_CLASS
    PROM_STORAGE_CLASS="${PROM_STORAGE_CLASS:-manual}"
    read -p "Prometheus 볼륨 크기 지정 (기본값 50Gi): " PROM_STORAGE_SIZE
    PROM_STORAGE_SIZE="${PROM_STORAGE_SIZE:-50Gi}"

    # 2-3. Grafana 스토리지 입력
    read -p "Grafana StorageClass 지정 (기본값 manual): " GRAFANA_STORAGE_CLASS
    GRAFANA_STORAGE_CLASS="${GRAFANA_STORAGE_CLASS:-manual}"
    read -p "Grafana 볼륨 크기 지정 (기본값 10Gi): " GRAFANA_STORAGE_SIZE
    GRAFANA_STORAGE_SIZE="${GRAFANA_STORAGE_SIZE:-10Gi}"
fi

save_conf

# ==========================================
# [3] values-infra.yaml 생성 (Single Source of Truth)
# ==========================================
echo ""
echo "🔧 인프라 설정 파일(values-infra.yaml) 생성 중..."

# 이미지 변수 조립
GLOBAL_REGISTRY_BLOCK=""
if [ "$IMAGE_SOURCE" == "harbor" ]; then
    GLOBAL_REGISTRY_BLOCK="global:
  imageRegistry: \"${HARBOR_REGISTRY}\"
  imageNamePrefix: \"${HARBOR_PROJECT}/\""
else
    GLOBAL_REGISTRY_BLOCK="global:
  imageRegistry: \"\"
  imageNamePrefix: \"\""
fi

cat > ./values-infra.yaml <<EOF
# Monitoring v0.89.0 인프라 설정 — install.sh 에 의해 자동 관리됩니다.
${GLOBAL_REGISTRY_BLOCK}

prometheus:
  prometheusSpec:
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: "${PROM_STORAGE_CLASS}"
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: "${PROM_STORAGE_SIZE}"

grafana:
  persistence:
    enabled: true
    storageClassName: "${GRAFANA_STORAGE_CLASS}"
    size: "${GRAFANA_STORAGE_SIZE}"
EOF

# ==========================================
# [4] Kubernetes 리소스 준비 및 설치
# ==========================================
echo ""
echo -e "🚀 ${GREEN}[1/2] Kubernetes 네임스페이스 및 Helm 배포 중...${NC}"

# 네임스페이스 생성
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Helm upgrade --install 멱등 설치 기동 (values-infra.yaml 병합)
helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  -f "$VALUES_FILE" \
  -f ./values-infra.yaml \
  --wait

# ServiceMonitor / PodMonitor 적용 (Prometheus 스크레이프 대상 등록)
echo ""
echo -e "🚀 ${GREEN}[2/2] 커스텀 메트릭/대시보드 리소스 적용 중...${NC}"
for f in ./manifests/servicemonitors-*.yaml ./manifests/podmonitors-*.yaml; do
    [ -f "$f" ] && echo "📊 $f 적용 중..." && kubectl apply -f "$f"
done

# 커스텀 알림 룰 적용
for f in ./manifests/alertrules-*.yaml; do
    [ -f "$f" ] && echo "🔔 $f 적용 중..." && kubectl apply -f "$f"
done

# Grafana 커스텀 대시보드 적용
for f in ./manifests/grafana-dashboard-*.yaml; do
    [ -f "$f" ] && echo "📈 $f 적용 중..." && kubectl apply -f "$f"
done

# HTTPRoute 적용 (Envoy Gateway 사용 시)
if [ -f "./manifests/httproute.yaml" ]; then
    echo "📡 HTTPRoute 적용 중..."
    kubectl apply -f ./manifests/httproute.yaml
fi

echo ""
echo "========================================================"
echo -e "${GREEN}🎉 Monitoring (kube-prometheus-stack) 설치 완료!${NC}"
echo "설정 파일 : $CONF_FILE"
echo "========================================================"
echo ""
kubectl get pods -n $NAMESPACE
