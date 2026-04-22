#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="gitlab-omnibus"
RELEASE_NAME="gitlab-omnibus"
CHART_PATH="./charts/gitlab-omnibus"
VALUES_FILE="./values.yaml"
PV_TEMPLATE="./manifests/gitlab-omnibus-pv.yaml"
PV_FILE="./manifests/gitlab-omnibus-pv-temp.yaml"
HTTPROUTE_FILE="./manifests/gitlab-omnibus-httproute.yaml"
CONF_FILE="./install.conf"
GITLAB_VERSION="18.7.0-ce.0"

# ── install.conf 로드 / 저장 ──────────────────────────────
load_conf() {
    [ -f "$CONF_FILE" ] && source "$CONF_FILE"
}

save_conf() {
    cat > "$CONF_FILE" <<EOF
# GitLab Omnibus 18.7 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
STORAGE_TYPE="${STORAGE_TYPE}"
HOSTPATH_DIR="${HOSTPATH_DIR}"
NFS_SERVER="${NFS_SERVER}"
NFS_PATH="${NFS_PATH}"
STORAGE_SIZE="${STORAGE_SIZE}"
USE_NGINX="${USE_NGINX}"
TARGET_NODE="${TARGET_NODE}"
INSTALLED_VERSION="${GITLAB_VERSION}"
EOF
    echo "  ✅ 설정이 ${CONF_FILE} 에 저장되었습니다."
}

load_conf

# ── 기존 설치 확인 ────────────────────────────────────────
EXIST_HELM=$(helm status $RELEASE_NAME -n $NAMESPACE > /dev/null 2>&1 && echo "yes" || echo "no")
EXIST_NS=$([ "$(kubectl get namespace $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null)" = "Active" ] && echo "yes" || echo "no")
EXIST_K8S=$(kubectl get deployment $RELEASE_NAME -n $NAMESPACE --output=name 2>/dev/null | grep -q . && echo "yes" || echo "no")

DO_UPGRADE=""

_cleanup_resources() {
    local delete_data="$1"

    if [ "$EXIST_HELM" = "yes" ]; then
        echo "  - Helm Release 삭제 중..."
        helm uninstall $RELEASE_NAME -n $NAMESPACE --wait=false 2>/dev/null || true
    fi

    if [ -f "$HTTPROUTE_FILE" ]; then
        kubectl delete -f "$HTTPROUTE_FILE" --ignore-not-found=true 2>/dev/null || true
    fi

    kubectl delete pv gitlab-omnibus-data-pv gitlab-omnibus-config-pv --ignore-not-found=true 2>/dev/null || true

    echo "  - Namespace '$NAMESPACE' 삭제 중 (완전 삭제까지 대기)..."
    kubectl delete ns $NAMESPACE --ignore-not-found=true --wait=false 2>/dev/null || true
    kubectl wait --for=delete namespace/$NAMESPACE --timeout=120s 2>/dev/null || true

    rm -f "$PV_FILE" 2>/dev/null || true

    if [[ "$delete_data" =~ ^[Yy]$ ]] && [ -n "${HOSTPATH_DIR}" ]; then
        echo "  - 데이터 디렉토리 초기화 중..."
        if [ -d "${HOSTPATH_DIR}" ]; then
            sudo rm -rf "${HOSTPATH_DIR:?}"/*
            echo "    ✅ ${HOSTPATH_DIR} 초기화 완료"
        fi
    fi
}

if [ "$EXIST_HELM" = "yes" ] || [ "$EXIST_K8S" = "yes" ] || [ "$EXIST_NS" = "yes" ]; then
    echo -e "\033[1;33m[알림] GitLab Omnibus가 이미 설치되어 있는 것으로 보입니다.\033[0m"
    [ "$EXIST_HELM" = "yes" ] && echo "  - Helm 릴리스 발견: $RELEASE_NAME"
    [ "$EXIST_K8S" = "yes" ] && echo "  - Deployment 발견: $NAMESPACE/$RELEASE_NAME"
    [ "$EXIST_NS" = "yes" ] && echo "  - Namespace 발견: $NAMESPACE"

    if [ -f "$CONF_FILE" ]; then
        echo ""
        echo "  📋 저장된 설정 (${CONF_FILE}):"
        echo "     이미지 소스  : ${IMAGE_SOURCE:-미설정}"
        [ "${IMAGE_SOURCE}" = "harbor" ] && echo "     Harbor       : ${HARBOR_REGISTRY}/${HARBOR_PROJECT}"
        echo "     스토리지     : ${STORAGE_TYPE:-미설정}"
        [ "${STORAGE_TYPE}" = "hostpath" ] && echo "     HostPath     : ${HOSTPATH_DIR}"
        [ "${STORAGE_TYPE}" = "nfs"      ] && echo "     NFS          : ${NFS_SERVER}:${NFS_PATH}"
        echo "     설치 버전    : ${INSTALLED_VERSION:-미설정}"
    fi

    echo ""
    echo "동작을 선택하세요:"
    echo "  1) 업그레이드   — 저장된 설정 유지, Helm upgrade --install"
    echo "  2) 재설치       — 설정 재입력, 데이터 삭제 여부 선택"
    echo "  3) 초기화(리셋) — 모든 리소스 + 자동생성 파일 삭제 후 재설치"
    echo "  4) 취소"
    read -p "선택 [1/2/3/4, 기본값 4]: " INSTALL_ACTION
    INSTALL_ACTION="${INSTALL_ACTION:-4}"

    case "$INSTALL_ACTION" in
        1)
            echo "🚀 업그레이드 모드로 진행합니다."
            DO_UPGRADE="true"
            ;;
        2)
            read -p "⚠️  기존 데이터를 모두 삭제하고 완전 초기화할까요? (y/N): " DELETE_DATA
            DELETE_DATA="${DELETE_DATA:-N}"
            echo "🔥 기존 GitLab Omnibus 자원 삭제 중..."
            _cleanup_resources "$DELETE_DATA"
            echo "✅ 삭제 완료. 설정을 다시 입력합니다."
            IMAGE_SOURCE="" HARBOR_REGISTRY="" HARBOR_PROJECT=""
            STORAGE_TYPE="" HOSTPATH_DIR="" NFS_SERVER="" NFS_PATH="" STORAGE_SIZE=""
            USE_NGINX="" TARGET_NODE=""
            ;;
        3)
            echo "🗑️  초기화: 모든 리소스를 삭제하고 재설치합니다..."
            _cleanup_resources "y"
            [ -f "$CONF_FILE" ] && rm -f "$CONF_FILE" && echo "  - install.conf 삭제됨"
            echo "✅ 초기화 완료. 설정을 처음부터 입력합니다."
            IMAGE_SOURCE="" HARBOR_REGISTRY="" HARBOR_PROJECT=""
            STORAGE_TYPE="" HOSTPATH_DIR="" NFS_SERVER="" NFS_PATH="" STORAGE_SIZE=""
            USE_NGINX="" TARGET_NODE=""
            ;;
        *)
            echo "❌ 설치가 취소되었습니다."
            exit 0
            ;;
    esac
fi

# ── 이미지 소스 선택 ──────────────────────────────────────
if [ -z "${IMAGE_SOURCE}" ]; then
    echo ""
    echo "이미지 소스를 선택하세요:"
    echo "  1) Harbor 레지스트리 사용 (사전에 images/upload_images_to_harbor_v3-lite.sh 실행 필요)"
    echo "  2) 로컬 tar 직접 import (이미 이미지가 로드된 경우 건너뜀)"
    read -p "선택 [1/2, 기본값: 1]: " _IMG_SRC
    _IMG_SRC="${_IMG_SRC:-1}"
    if [ "$_IMG_SRC" = "1" ]; then
        IMAGE_SOURCE="harbor"
    elif [ "$_IMG_SRC" = "2" ]; then
        IMAGE_SOURCE="local"
    else
        echo "[오류] 1 또는 2를 선택하세요."; exit 1
    fi
fi

if [ "${IMAGE_SOURCE}" = "harbor" ]; then
    if [ -z "${HARBOR_REGISTRY}" ]; then
        read -p "Harbor 레지스트리 주소 (예: 192.168.1.10:30002): " HARBOR_REGISTRY
        [ -z "${HARBOR_REGISTRY}" ] && echo "[오류] Harbor 레지스트리 주소가 필요합니다." && exit 1
    fi
    if [ -z "${HARBOR_PROJECT}" ]; then
        read -p "Harbor 프로젝트 (예: library, oss): " HARBOR_PROJECT
        [ -z "${HARBOR_PROJECT}" ] && echo "[오류] Harbor 프로젝트가 필요합니다." && exit 1
    fi
elif [ "${IMAGE_SOURCE}" = "local" ] && [ "${DO_UPGRADE}" != "true" ]; then
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
fi

# ── 스토리지 타입 선택 ────────────────────────────────────
if [ -z "${STORAGE_TYPE}" ]; then
    echo ""
    echo "스토리지 타입을 선택하세요:"
    echo "  1) HostPath  — 로컬 노드 디렉토리 (단일 노드 환경 권장)"
    echo "  2) NAS/NFS   — 네트워크 공유 스토리지"
    read -p "선택 [1/2, 기본값: 1]: " _STOR
    _STOR="${_STOR:-1}"
    if [ "$_STOR" = "1" ]; then
        STORAGE_TYPE="hostpath"
    elif [ "$_STOR" = "2" ]; then
        STORAGE_TYPE="nfs"
    else
        echo "[오류] 1 또는 2를 선택하세요."; exit 1
    fi
fi

if [ "${STORAGE_TYPE}" = "hostpath" ]; then
    if [ -z "${HOSTPATH_DIR}" ]; then
        read -p "HostPath 디렉토리 (기본값: /data/gitlab_omnibus): " HOSTPATH_DIR
        HOSTPATH_DIR="${HOSTPATH_DIR:-/data/gitlab_omnibus}"
    fi
    if [ -z "${STORAGE_SIZE}" ]; then
        read -p "스토리지 용량 (기본값: 50Gi): " STORAGE_SIZE
        STORAGE_SIZE="${STORAGE_SIZE:-50Gi}"
    fi
elif [ "${STORAGE_TYPE}" = "nfs" ]; then
    if [ -z "${NFS_SERVER}" ]; then
        read -p "NFS 서버 주소 (예: 192.168.1.100): " NFS_SERVER
        [ -z "${NFS_SERVER}" ] && echo "[오류] NFS 서버 주소가 필요합니다." && exit 1
    fi
    if [ -z "${NFS_PATH}" ]; then
        read -p "NFS 공유 경로 (예: /exports/gitlab-omnibus): " NFS_PATH
        [ -z "${NFS_PATH}" ] && echo "[오류] NFS 경로가 필요합니다." && exit 1
    fi
    if [ -z "${STORAGE_SIZE}" ]; then
        read -p "스토리지 용량 (기본값: 50Gi): " STORAGE_SIZE
        STORAGE_SIZE="${STORAGE_SIZE:-50Gi}"
    fi
fi

save_conf

# ── Ingress 방식 선택 ─────────────────────────────────────
if [ -z "${USE_NGINX}" ] && [ "${DO_UPGRADE}" != "true" ]; then
    echo ""
    read -p "❓ NGINX Ingress Controller를 사용하시나요? (y/n, 기본값: n): " USE_NGINX
    USE_NGINX="${USE_NGINX:-n}"
fi

# ── 노드 고정 설정 ────────────────────────────────────────
NODE_SELECTOR_ARG=""
if [ "${DO_UPGRADE}" = "true" ] && [ -n "${TARGET_NODE}" ]; then
    echo "  저장된 노드 고정: ${TARGET_NODE}"
    read -p "  그대로 사용하시겠습니까? (Y/n): " KEEP_NODE
    [ "${KEEP_NODE:-Y}" =~ ^[Nn]$ ] && TARGET_NODE=""
fi

if [ -z "${TARGET_NODE}" ]; then
    echo ""
    echo "현재 클러스터의 노드 목록:"
    kubectl get nodes
    echo ""
    read -p "❓ GitLab을 배포할 노드 이름(NAME)을 입력하세요 (엔터 = 자동): " TARGET_NODE
fi

if [ -n "${TARGET_NODE}" ]; then
    if ! kubectl get node "${TARGET_NODE}" > /dev/null 2>&1; then
        echo "❌ 오류: '${TARGET_NODE}' 노드를 찾을 수 없습니다."; exit 1
    fi
    NODE_SELECTOR_ARG="--set nodeSelector.kubernetes\\.io/hostname=${TARGET_NODE}"
    echo "  ✅ 노드 고정: ${TARGET_NODE}"
fi

# ── 이미지 주소 구성 ──────────────────────────────────────
if [ "${IMAGE_SOURCE}" = "harbor" ]; then
    IMAGE_REGISTRY="${HARBOR_REGISTRY}"
    IMAGE_REPOSITORY="${HARBOR_PROJECT}/gitlab-ce"
else
    IMAGE_REGISTRY=""
    IMAGE_REPOSITORY="gitlab/gitlab-ce"
fi

# ── PV 매니페스트 생성 ────────────────────────────────────
echo ""
echo "🔧 PV 매니페스트 생성 중..."

if [ "${STORAGE_TYPE}" = "nfs" ]; then
    cat > "$PV_FILE" <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: gitlab-omnibus-data-pv
spec:
  capacity:
    storage: ${STORAGE_SIZE}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  claimRef:
    namespace: ${NAMESPACE}
    name: ${RELEASE_NAME}-data
  nfs:
    server: ${NFS_SERVER}
    path: ${NFS_PATH}/data
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: gitlab-omnibus-config-pv
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  claimRef:
    namespace: ${NAMESPACE}
    name: ${RELEASE_NAME}-config
  nfs:
    server: ${NFS_SERVER}
    path: ${NFS_PATH}/config
EOF
else
    sed \
        -e "s|<HOSTPATH_DIR>|${HOSTPATH_DIR}|g" \
        -e "s|50Gi|${STORAGE_SIZE}|g" \
        "$PV_TEMPLATE" > "$PV_FILE"
    # claimRef namespace를 실제 네임스페이스로 치환
    sed -i "s|namespace: gitlab-omnibus|namespace: ${NAMESPACE}|g" "$PV_FILE"
fi

echo "  ✅ PV 매니페스트 생성 완료"

# ── 설치/업그레이드 실행 ──────────────────────────────────
echo ""
echo "========================================================"
echo "🚀 GitLab Omnibus ${DO_UPGRADE:+업그레이드}${DO_UPGRADE:-설치} 시작"
echo "========================================================"

if [ "${DO_UPGRADE}" != "true" ]; then
    echo "🚀 Namespace 생성 중..."
    kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

    echo "📄 PV 생성 중..."
    kubectl apply -f "$PV_FILE"

    if [[ "${USE_NGINX}" == "n" || "${USE_NGINX}" == "N" ]]; then
        echo "📄 HTTPRoute 적용 중..."
        kubectl apply -f "$HTTPROUTE_FILE"
    fi
fi

echo "🚀 Helm upgrade --install 실행 중..."
helm upgrade --install $RELEASE_NAME "$CHART_PATH" \
    --namespace $NAMESPACE \
    -f "$VALUES_FILE" \
    --set image.registry="${IMAGE_REGISTRY}" \
    --set image.repository="${IMAGE_REPOSITORY}" \
    --set storage.data.size="${STORAGE_SIZE}" \
    --wait \
    --timeout 600s \
    $NODE_SELECTOR_ARG

save_conf

echo ""
echo "==========================================="
echo " ✅ GitLab Omnibus ${GITLAB_VERSION} 설치/업그레이드 완료"
echo "==========================================="
echo " GitLab URL  : http://gitlab.devops.internal"
echo " SSH         : ssh://git@<NODE_IP>:${sshPort:-30022}"
echo " 설정 파일   : ${CONF_FILE}"
echo "==========================================="
echo ""
echo "🔑 [초기 root 비밀번호]"
echo "   설치 완료 후 약 2분 뒤 아래 명령으로 확인:"
echo "   kubectl exec -n $NAMESPACE deploy/$RELEASE_NAME -- gitlab-rake 'gitlab:password:reset[root]'"
echo "   또는 /etc/gitlab/initial_root_password 파일 확인:"
echo "   kubectl exec -n $NAMESPACE deploy/$RELEASE_NAME -- cat /etc/gitlab/initial_root_password"
echo "==========================================="
kubectl get pods -n $NAMESPACE
