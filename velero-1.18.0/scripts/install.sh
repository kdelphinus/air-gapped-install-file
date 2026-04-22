#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="velero"
RELEASE_NAME="velero"
CHART_PATH="./charts/velero"
VALUES_FILE="./values.yaml"
CONF_FILE="./install.conf"

MINIO_TAG="RELEASE.2024-12-18T13-15-44Z"
MC_TAG="RELEASE.2024-11-21T17-21-54Z"

# ── install.conf 로드 / 저장 ──────────────────────────────
load_conf() {
    [ -f "$CONF_FILE" ] && source "$CONF_FILE"
}

save_conf() {
    cat > "$CONF_FILE" <<EOF
# Velero 1.18.0 설치 설정 — install.sh 에 의해 자동 관리됩니다.
IMAGE_SOURCE="${IMAGE_SOURCE}"
HARBOR_REGISTRY="${HARBOR_REGISTRY}"
HARBOR_PROJECT="${HARBOR_PROJECT}"
STORAGE_TYPE="${STORAGE_TYPE}"
HOSTPATH_DIR="${HOSTPATH_DIR}"
NFS_SERVER="${NFS_SERVER}"
NFS_PATH="${NFS_PATH}"
STORAGE_SIZE="${STORAGE_SIZE}"
INSTALLED_VERSION="v1.18.0"
EOF
    echo "  ✅ 설정이 ${CONF_FILE} 에 저장되었습니다."
}

load_conf

# ── 기존 설치 확인 ────────────────────────────────────────
EXIST_HELM=$(helm status $RELEASE_NAME -n $NAMESPACE > /dev/null 2>&1 && echo "yes" || echo "no")
EXIST_K8S=$(kubectl get deployment $RELEASE_NAME -n $NAMESPACE > /dev/null 2>&1 && echo "yes" || echo "no")
EXIST_NS=$(kubectl get namespace $NAMESPACE > /dev/null 2>&1 && echo "yes" || echo "no")

DO_UPGRADE=""

if [ "$EXIST_HELM" = "yes" ] || [ "$EXIST_K8S" = "yes" ] || [ "$EXIST_NS" = "yes" ]; then
    echo -e "\033[1;33m[알림] Velero가 이미 설치되어 있는 것으로 보입니다.\033[0m"
    [ "$EXIST_HELM" = "yes" ] && echo "  - Helm 릴리스 발견: $RELEASE_NAME"
    [ "$EXIST_K8S" = "yes" ] && echo "  - Kubernetes Deployment 발견: $NAMESPACE/$RELEASE_NAME"
    [ "$EXIST_NS" = "yes" ] && echo "  - Namespace 발견: $NAMESPACE"

    if [ -f "$CONF_FILE" ]; then
        echo ""
        echo "  📋 저장된 설정 (${CONF_FILE}):"
        echo "     이미지 소스  : ${IMAGE_SOURCE:-미설정}"
        [ "${IMAGE_SOURCE}" = "harbor" ] && echo "     Harbor       : ${HARBOR_REGISTRY}/${HARBOR_PROJECT}"
        echo "     스토리지     : ${STORAGE_TYPE:-미설정}"
        [ "${STORAGE_TYPE}" = "hostpath" ] && echo "     HostPath     : ${HOSTPATH_DIR}"
        [ "${STORAGE_TYPE}" = "nfs" ] && echo "     NFS          : ${NFS_SERVER}:${NFS_PATH}"
        echo "     용량         : ${STORAGE_SIZE:-미설정}"
        echo "     설치 버전    : ${INSTALLED_VERSION:-미설정}"
    fi

    echo ""
    echo "동작을 선택하세요:"
    echo "  1) 업그레이드   — 저장된 설정 유지, Helm upgrade --install"
    echo "  2) 재설치       — 설정 재입력, MinIO 데이터 삭제 여부 선택"
    echo "  3) 초기화(리셋) — 모든 리소스 + 데이터 + install.conf 완전 삭제 후 종료"
    echo "  4) 취소"
    read -p "선택 [1/2/3/4, 기본값 4]: " INSTALL_ACTION
    INSTALL_ACTION="${INSTALL_ACTION:-4}"

    case "$INSTALL_ACTION" in
        1)
            echo "🚀 업그레이드 모드로 진행합니다."
            DO_UPGRADE="true"
            ;;
        2)
            read -p "⚠️  MinIO 백업 데이터(PVC/PV)도 삭제하시겠습니까? (y=삭제, n=데이터 유지): " DELETE_DATA
            echo "🔥 기존 Velero 자원 삭제 중..."
            if [ "$EXIST_HELM" = "yes" ]; then
                helm uninstall $RELEASE_NAME -n $NAMESPACE --wait=false 2>/dev/null || true
            fi
            echo "  - MinIO Pod 종료 대기 중..."
            kubectl delete deployment minio -n $NAMESPACE --ignore-not-found=true
            kubectl delete job minio-setup -n $NAMESPACE --ignore-not-found=true
            kubectl wait --for=delete pod -l app=minio -n $NAMESPACE --timeout=60s 2>/dev/null || true
            if [[ "$DELETE_DATA" =~ ^[Yy]$ ]]; then
                PV_NAME=$(kubectl get pvc minio-pvc -n $NAMESPACE \
                    -o jsonpath='{.spec.volumeName}' 2>/dev/null)
                kubectl delete pvc minio-pvc -n $NAMESPACE --ignore-not-found=true
                [ -n "$PV_NAME" ] && kubectl delete pv "$PV_NAME" --ignore-not-found=true
                echo "  - PVC/PV 삭제 완료"
            fi
            kubectl delete namespace $NAMESPACE --ignore-not-found=true --timeout=60s
            echo "✅ 삭제 완료. 설정을 다시 입력합니다."
            # 재입력을 위해 설정 초기화
            IMAGE_SOURCE="" HARBOR_REGISTRY="" HARBOR_PROJECT=""
            STORAGE_TYPE="" HOSTPATH_DIR="" NFS_SERVER="" NFS_PATH="" STORAGE_SIZE=""
            ;;
        3)
            echo "🗑️  초기화: 모든 리소스와 데이터를 삭제합니다..."
            if [ "$EXIST_HELM" = "yes" ]; then
                helm uninstall $RELEASE_NAME -n $NAMESPACE --wait=false 2>/dev/null || true
            fi
            echo "  - MinIO Pod 종료 대기 중..."
            kubectl delete deployment minio -n $NAMESPACE --ignore-not-found=true
            kubectl delete job minio-setup -n $NAMESPACE --ignore-not-found=true
            kubectl wait --for=delete pod -l app=minio -n $NAMESPACE --timeout=60s 2>/dev/null || true
            PV_NAME=$(kubectl get pvc minio-pvc -n $NAMESPACE \
                -o jsonpath='{.spec.volumeName}' 2>/dev/null)
            kubectl delete pvc minio-pvc -n $NAMESPACE --ignore-not-found=true
            [ -n "$PV_NAME" ] && kubectl delete pv "$PV_NAME" --ignore-not-found=true
            kubectl delete namespace $NAMESPACE --ignore-not-found=true --timeout=60s
            if [ -f "$CONF_FILE" ]; then
                rm -f "$CONF_FILE"
                echo "  - install.conf 삭제됨"
            fi
            echo ""
            echo "✅ 초기화 완료."
            if [ "${STORAGE_TYPE}" = "hostpath" ] && [ -n "${HOSTPATH_DIR}" ]; then
                echo "  ⚠️  호스트 볼륨 실제 데이터는 수동으로 삭제하세요: ${HOSTPATH_DIR}"
            elif [ "${STORAGE_TYPE}" = "nfs" ] && [ -n "${NFS_SERVER}" ]; then
                echo "  ⚠️  NFS 서버(${NFS_SERVER}:${NFS_PATH})의 데이터는 수동으로 삭제하세요."
            fi
            echo "재설치를 진행합니다."
            # 재입력을 위해 설정 초기화
            IMAGE_SOURCE="" HARBOR_REGISTRY="" HARBOR_PROJECT=""
            STORAGE_TYPE="" HOSTPATH_DIR="" NFS_SERVER="" NFS_PATH="" STORAGE_SIZE=""
            ;;
        *)
            echo "❌ 설치가 취소되었습니다."
            exit 0
            ;;
    esac
fi

# ── 이미지 소스 설정 ──────────────────────────────────────
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

# ── 스토리지 타입 설정 ────────────────────────────────────
if [ -z "${STORAGE_TYPE}" ]; then
    echo ""
    echo "MinIO 스토리지 타입을 선택하세요:"
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
        read -p "HostPath 디렉토리 (기본값: /data/minio): " HOSTPATH_DIR
        HOSTPATH_DIR="${HOSTPATH_DIR:-/data/minio}"
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
        read -p "NFS 공유 경로 (예: /exports/velero): " NFS_PATH
        [ -z "${NFS_PATH}" ] && echo "[오류] NFS 경로가 필요합니다." && exit 1
    fi
    if [ -z "${STORAGE_SIZE}" ]; then
        read -p "스토리지 용량 (기본값: 50Gi): " STORAGE_SIZE
        STORAGE_SIZE="${STORAGE_SIZE:-50Gi}"
    fi
else
    echo "[오류] 알 수 없는 스토리지 타입: ${STORAGE_TYPE}"; exit 1
fi

save_conf

# ── 이미지 참조 구성 ──────────────────────────────────────
if [ "${IMAGE_SOURCE}" = "harbor" ]; then
    MINIO_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/minio:${MINIO_TAG}"
    MC_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/mc:${MC_TAG}"
else
    MINIO_IMAGE="minio/minio:${MINIO_TAG}"
    MC_IMAGE="minio/mc:${MC_TAG}"
fi

echo ""
echo "🔧 매니페스트 및 values 파일 준비 중..."
echo "   이미지 소스 : ${IMAGE_SOURCE}"
[ "${IMAGE_SOURCE}" = "harbor" ] && echo "   Harbor      : ${HARBOR_REGISTRY}/${HARBOR_PROJECT}"
echo "   스토리지    : ${STORAGE_TYPE}"
[ "${STORAGE_TYPE}" = "hostpath" ] && echo "   HostPath    : ${HOSTPATH_DIR} (${STORAGE_SIZE})"
[ "${STORAGE_TYPE}" = "nfs" ] && echo "   NFS         : ${NFS_SERVER}:${NFS_PATH} (${STORAGE_SIZE})"

# ── 매니페스트 치환 ───────────────────────────────────────
if [ "${DO_UPGRADE}" = "true" ]; then
    # 업그레이드: 워크로드(Deployment/Service/Job)만 갱신, PV/PVC 변경 없음
    sed \
        -e "s|<MINIO_IMAGE>|${MINIO_IMAGE}|g" \
        -e "s|<MC_IMAGE>|${MC_IMAGE}|g" \
        manifests/minio-workload.yaml > manifests/minio-temp.yaml
elif [ "${STORAGE_TYPE}" = "nfs" ]; then
    sed \
        -e "s|<MINIO_IMAGE>|${MINIO_IMAGE}|g" \
        -e "s|<MC_IMAGE>|${MC_IMAGE}|g" \
        -e "s|<NFS_SERVER>|${NFS_SERVER}|g" \
        -e "s|<NFS_PATH>|${NFS_PATH}|g" \
        -e "s|<STORAGE_SIZE>|${STORAGE_SIZE}|g" \
        manifests/minio-nfs.yaml > manifests/minio-temp.yaml
else
    sed \
        -e "s|<MINIO_IMAGE>|${MINIO_IMAGE}|g" \
        -e "s|<MC_IMAGE>|${MC_IMAGE}|g" \
        -e "s|<HOSTPATH_DIR>|${HOSTPATH_DIR}|g" \
        -e "s|<STORAGE_SIZE>|${STORAGE_SIZE}|g" \
        manifests/minio-hostpath.yaml > manifests/minio-temp.yaml
fi

if [ "${IMAGE_SOURCE}" = "harbor" ]; then
    sed \
        -e "s|<NODE_IP>|${HARBOR_REGISTRY}|g" \
        -e "s|<PROJECT>|${HARBOR_PROJECT}|g" \
        "$VALUES_FILE" > ./values-temp.yaml
else
    cp "$VALUES_FILE" ./values-temp.yaml
fi

# ── CRD 업데이트 ─────────────────────────────────────────
# Helm hook(upgradeCRDs)을 우회하여 직접 적용 — 버전 불일치 방지
echo "📋 Velero CRD 업데이트 중..."
kubectl apply -f "$CHART_PATH/crds/" 2>&1 | grep -v "^Warning:" || true

# ── Namespace 생성 ────────────────────────────────────────
echo "🚀 Namespace 생성 중..."
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# ── MinIO 배포 ────────────────────────────────────────────
echo "🚀 MinIO 배포 중..."
# 기존 minio-setup Job 삭제 (spec 변경 방지 및 재실행 허용)
kubectl delete job minio-setup -n $NAMESPACE --ignore-not-found=true 2>/dev/null || true
kubectl apply -f manifests/minio-temp.yaml
kubectl apply -f manifests/minio-httproute.yaml

echo "⏳ MinIO 준비 대기 중 (최대 2분)..."
kubectl rollout status deployment/minio -n $NAMESPACE --timeout=120s

# ── Velero Helm 설치/업그레이드 ───────────────────────────
# credentials는 values.yaml의 secretContents로 Helm이 직접 생성
echo "🚀 Velero Helm ${DO_UPGRADE:+upgrade}${DO_UPGRADE:-install} 중..."
helm upgrade --install $RELEASE_NAME "$CHART_PATH" \
    --namespace $NAMESPACE \
    -f ./values-temp.yaml \
    --wait

# ── 임시 파일 정리 ────────────────────────────────────────
rm -f manifests/minio-temp.yaml ./values-temp.yaml

echo ""
echo "==========================================="
echo " ✅ Velero 1.18.0 설치/업그레이드 완료"
echo "==========================================="
echo " MinIO Console : http://minio-velero.devops.internal"
echo " 설정 파일     : ${CONF_FILE}"
echo "==========================================="
kubectl get pods -n $NAMESPACE
