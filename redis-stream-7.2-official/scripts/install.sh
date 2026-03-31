#!/bin/bash

# Root 권한 체크
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

cd "$(dirname "$0")/.." || exit 1
set -e

NAMESPACE="redis-stream-official"
RELEASE_NAME="redis-stream-official"
MANIFEST_DIR="./manifests"

echo "======================================================"
echo " Redis Stream (HA) 설치 - 공식 이미지 (Helm) 방식"
echo " Namespace: ${NAMESPACE}"
echo "======================================================"

# 1. Namespace 생성 (Helm으로도 생성 가능하나 명시적 유지)
echo "1. Namespace 생성 및 확인 중..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# 2. 이미지 소스 선택
# ── 이미지 소스 선택 ──────────────────────────────────────────
echo ""
echo "이미지 소스를 선택하세요:"
echo "  1) Harbor 레지스트리 사용 (사전에 upload_images_to_harbor_v3-lite.sh 실행 필요)"
echo "  2) 로컬 tar 직접 import (Harbor 없음)"
read -p "선택 [1/2, 기본값: 1]: " IMAGE_SOURCE
IMAGE_SOURCE="${IMAGE_SOURCE:-1}"

if [ "${IMAGE_SOURCE}" = "1" ]; then
    read -p "Harbor 레지스트리 주소 (예: 192.168.1.10:30002 또는 harbor.example.com): " IMAGE_REGISTRY
    if [ -z "${IMAGE_REGISTRY}" ]; then
        echo "[오류] Harbor 레지스트리 주소가 필요합니다."; exit 1
    fi
    read -p "Harbor 프로젝트 (예: library, oss): " HARBOR_PROJECT
    if [ -z "${HARBOR_PROJECT}" ]; then
        echo "[오류] Harbor 프로젝트가 필요합니다."; exit 1
    fi
elif [ "${IMAGE_SOURCE}" = "2" ]; then
    echo "로컬 tar 파일을 containerd(k8s.io)에 import 중..."
    IMPORT_COUNT=0
    for tar_file in ./images/*.tar; do
        [ -e "${tar_file}" ] || continue
        echo "  → $(basename "${tar_file}")"
        ctr -n k8s.io images import "${tar_file}"
        IMPORT_COUNT=$((IMPORT_COUNT + 1))
    done
    [ "${IMPORT_COUNT}" -eq 0 ] && echo "[경고] ./images/ 에 tar 파일이 없습니다."
    echo "  ${IMPORT_COUNT}개 이미지 import 완료"
    IMAGE_REGISTRY=""
    HARBOR_PROJECT=""
else
    echo "[오류] 1 또는 2를 선택하세요."; exit 1
fi

# 3. Redis 비밀번호 입력
echo ""
read -s -p "Redis 비밀번호 입력: " REDIS_PASSWORD
echo ""
if [ -z "${REDIS_PASSWORD}" ]; then
    echo "[오류] 비밀번호가 비어 있습니다."
    exit 1
fi

# 4. 스토리지 설정 (PV는 Helm 밖에서 정적으로 유지)
echo ""
read -p "Storage Type 선택 (hostpath/nfs) [기본값: hostpath]: " STORAGE_TYPE
STORAGE_TYPE="${STORAGE_TYPE:-hostpath}"

if [ "${STORAGE_TYPE}" = "hostpath" ]; then
    echo "2. HostPath PV 설정 중..."
    NODES=($(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'))
    if [ ${#NODES[@]} -gt 0 ]; then
        echo "   사용 가능한 노드 목록:"
        for i in "${!NODES[@]}"; do echo "     $((i+1))) ${NODES[$i]}"; done
        read -p "   노드 번호 선택 [1-${#NODES[@]}, 기본값: 1]: " NODE_INDEX
        NODE_INDEX="${NODE_INDEX:-1}"
        NODE_NAME="${NODES[$((NODE_INDEX-1))]}"
    else
        NODE_NAME=$(hostname)
    fi
    read -p "   HostPath 기본 경로 [기본값: /data/redis-official]: " HOST_BASE_PATH
    HOST_BASE_PATH="${HOST_BASE_PATH:-/data/redis-official}"
    read -p "   PV 크기 [기본값: 10Gi]: " STORAGE_SIZE
    STORAGE_SIZE="${STORAGE_SIZE:-10Gi}"

    echo "   노드: ${NODE_NAME}, 경로: ${HOST_BASE_PATH}"
    echo ""

    # 기존 PV 존재 여부 및 경로 체크 (Immutable 필드 대응)
    for i in 0 1 2; do
        PV_NAME="redis-official-node-${i}-pv"
        EXISTING_PATH=$(kubectl get pv "${PV_NAME}" -o jsonpath='{.spec.hostPath.path}' 2>/dev/null || echo "")
        if [ -n "${EXISTING_PATH}" ]; then
            if [ "${EXISTING_PATH}" = "${HOST_BASE_PATH}/node-${i}" ]; then
                echo "   [확인] 기존 PV(${PV_NAME})가 동일한 경로(${EXISTING_PATH})로 존재합니다."
                read -p "   기존 PV를 재사용하시겠습니까? 재생성하려면 N [Y/n]: " REUSE_PV_CONFIRM
                if [ "${REUSE_PV_CONFIRM}" = "n" ] || [ "${REUSE_PV_CONFIRM}" = "N" ]; then
                    echo "   기존 PV(${PV_NAME}) 삭제 중..."
                    kubectl delete pv "${PV_NAME}" --wait=false
                else
                    echo "   기존 PV(${PV_NAME}) 재사용합니다."
                fi
            else
                echo "   [경고] 기존 PV(${PV_NAME})의 경로(${EXISTING_PATH})가 입력한 경로(${HOST_BASE_PATH}/node-${i})와 다릅니다."
                echo "          PV 경로는 생성 후 수정할 수 없습니다 (Immutable)."
                read -p "   기존 PV를 삭제하고 새로 생성하시겠습니까? (기존 데이터는 호스트에 보존됨) [y/N]: " DELETE_PV_CONFIRM
                if [ "${DELETE_PV_CONFIRM}" = "y" ] || [ "${DELETE_PV_CONFIRM}" = "Y" ]; then
                    echo "   기존 PV(${PV_NAME}) 삭제 중..."
                    kubectl delete pv "${PV_NAME}" --wait=false
                else
                    echo "[오류] 경로를 변경하려면 기존 PV를 수동으로 삭제하거나 동일한 경로를 사용해야 합니다."
                    exit 1
                fi
            fi
        fi
    done

    echo "   [주의] 노드(${NODE_NAME})에서 다음 명령을 미리 실행하세요:"
    echo "     mkdir -p ${HOST_BASE_PATH}/{node-0,node-1,node-2}"
    echo "     chmod 777 ${HOST_BASE_PATH}/{node-0,node-1,node-2}"
    echo ""
    read -p "   디렉토리 생성을 완료했으면 Enter를 눌러 계속..."

    sed -e "s|__NODE_NAME__|${NODE_NAME}|g" \
        -e "s|__BASE_PATH__|${HOST_BASE_PATH}|g" \
        -e "s|__STORAGE_SIZE__|${STORAGE_SIZE}|g" \
        "${MANIFEST_DIR}/10-pv-hostpath.yaml" | kubectl apply -f -

elif [ "${STORAGE_TYPE}" = "nfs" ]; then
    echo "2. NFS PV 설정 중..."
    read -p "   NFS 서버 IP: " NFS_SERVER
    if [ -z "${NFS_SERVER}" ]; then
        echo "[오류] NFS 서버 IP가 필요합니다."
        exit 1
    fi
    read -p "   NFS 기본 경로 [기본값: /nfs/redis-official]: " NFS_BASE_PATH
    NFS_BASE_PATH="${NFS_BASE_PATH:-/nfs/redis-official}"
    read -p "   PV 크기 [기본값: 10Gi]: " STORAGE_SIZE
    STORAGE_SIZE="${STORAGE_SIZE:-10Gi}"

    echo ""
    echo "   [주의] NFS 서버(${NFS_SERVER})에서 다음 명령을 미리 실행하세요:"
    echo "     mkdir -p ${NFS_BASE_PATH}/{node-0,node-1,node-2}"
    echo "     chmod 777 ${NFS_BASE_PATH}/{node-0,node-1,node-2}"
    echo ""
    read -p "   디렉토리 생성을 완료했으면 Enter를 눌러 계속..."

    sed -e "s|__NFS_SERVER__|${NFS_SERVER}|g" \
        -e "s|__NFS_BASE_PATH__|${NFS_BASE_PATH}|g" \
        -e "s|__STORAGE_SIZE__|${STORAGE_SIZE}|g" \
        "${MANIFEST_DIR}/10-pv-nfs.yaml" | kubectl apply -f -
else
    echo "[오류] 알 수 없는 Storage Type: ${STORAGE_TYPE}"
    exit 1
fi

# 3. Helm 배포
echo ""
echo "3. Helm Chart 배포 중..."

# Harbor 사용 시에만 이미지 레지스트리/프로젝트 오버라이드
HELM_IMAGE_ARGS=()
if [ "${IMAGE_SOURCE}" = "1" ]; then
    HELM_IMAGE_ARGS=(
        "--set" "global.imageRegistry=${IMAGE_REGISTRY}"
        "--set" "image.repository=${HARBOR_PROJECT}/redis"
    )
fi

helm upgrade --install ${RELEASE_NAME} charts/redis-sentinel \
    --namespace ${NAMESPACE} \
    -f values.yaml \
    "${HELM_IMAGE_ARGS[@]}" \
    --set redis.password="${REDIS_PASSWORD}" \
    --set storage.type="${STORAGE_TYPE}" \
    --set storage.size="${STORAGE_SIZE}" \
    --wait --timeout 300s

# 4. 최종 상태 확인
echo ""
echo "======================================================"
echo " 배포 완료 - 현재 Pod 상태"
echo "======================================================"
kubectl get pods -n "${NAMESPACE}"

echo ""
echo "접속 정보:"
echo "  Redis:    redis.${NAMESPACE}.svc.cluster.local:6379"
echo "  Sentinel: redis-sentinel.${NAMESPACE}.svc.cluster.local:26379"
echo ""
echo "연결 테스트:"
echo "  kubectl exec -it redis-node-0 -n ${NAMESPACE} -- \\"
echo "    redis-cli -a <password> --no-auth-warning INFO replication"
