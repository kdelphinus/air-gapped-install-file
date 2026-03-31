#!/bin/bash
# 스크립트 위치 기준으로 컴포넌트 루트로 이동 (scripts/ 하위에서 실행해도 경로 안전)
cd "$(dirname "$0")/.." || exit 1

# Root 권한 체크
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

set -e # 오류 발생 시 즉시 스크립트 중단

# 임시 파일 정리 (정상/비정상 종료 모두 대응)
cleanup() { rm -f "$VALUES_FILE" "$PV_PVC_FILE" 2>/dev/null; }
trap cleanup EXIT

# =================================================================
# --- 설정 변수 (사용자 환경에 맞게 이 부분을 수정하세요) ---
# =================================================================

# 1. 기본 정보
HARBOR_NAMESPACE="harbor"
HARBOR_RELEASE_NAME="harbor"
PV_NAME="harbor-pv"
PVC_NAME="harbor-pvc"

# 2. 폐쇄망 환경 설정
HELM_CHART_PATH="./charts/harbor"

# 3. 외부 접속 설정 (TLS 사용 시 인증서의 domain과 일치 해야함)
EXTERNAL_HOSTNAME="" # 환경에 맞게 설정 (예: 172.31.63.195 또는 harbor.example.com)

# 4. 영구 저장소 설정
STORAGE_SIZE="50Gi"
# 스토리지 모드: "hostpath" 또는 "nfs" (빈 값이면 실행 시 선택)
STORAGE_MODE=""
# HostPath 설정
SAVE_PATH="/data/harbor"
NODE_NAME="" # 빈 값이면 자동 감지
# NFS 설정
NFS_SERVER="" # 예: 192.168.1.100
NFS_PATH=""   # 예: /nfs/harbor

# 5. 고급 설정 (Ingress 선택 시 사용)
INGRESS_CLASS="nginx"

# =================================================================
# --- 메인 스크립트 로직 ---
# =================================================================

# --- 사전 요구사항 검사 함수 ---
check_command() {
    if ! command -v "$1" &> /dev/null; then echo "오류: '$1' 명령어를 찾을 수 없습니다."; exit 1; fi
}

echo "Harbor 폐쇄망 설치 스크립트를 시작합니다."

# 0. 이미지 로드 단계 추가
echo ""
echo "0. 이미지 로드 방식 선택:"
echo "  1) 로컬 tar 직접 import (권장: 하버가 아직 없는 경우)"
echo "  2) Harbor 레지스트리 사용 (이미 하버가 있고 재설치하는 경우)"
read -p "선택 [1/2, 기본값 1]: " IMAGE_LOAD_CHOICE
IMAGE_LOAD_CHOICE="${IMAGE_LOAD_CHOICE:-1}"

if [ "$IMAGE_LOAD_CHOICE" == "1" ]; then
    echo "➡️ 로컬 이미지 로드 중 (ctr import)..."
    if [ -f "./scripts/load_images.sh" ]; then
        bash ./scripts/load_images.sh
    else
        for tar_file in ./images/*.tar; do
            [ -e "$tar_file" ] || continue
            echo "  → $(basename "$tar_file") 로드 중..."
            sudo ctr -n k8s.io images import "$tar_file"
        done
    fi
    echo "✅ 이미지 로드 완료."
else
    echo "➡️ 이미 이미지가 로드되어 있거나 레지스트리를 사용한다고 가정합니다."
fi

# 1. 도구 및 파일 확인
check_command kubectl
check_command helm
if [ ! -e "$HELM_CHART_PATH" ]; then
    echo "오류: Helm 차트 '$HELM_CHART_PATH'을 찾을 수 없습니다."
    exit 1
fi

# EXTERNAL_HOSTNAME 미설정 시 자동 감지 또는 입력 프롬프트
if [ -z "$EXTERNAL_HOSTNAME" ]; then
    # 1번(로컬 로드) 선택 시 현재 노드 IP 자동 감지 및 자동 할당
    if [ "$IMAGE_LOAD_CHOICE" == "1" ]; then
        # 첫 번째 노드의 InternalIP 감지
        DETECTED_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null | awk '{print $1}')
        if [ -z "$DETECTED_IP" ]; then
            DETECTED_IP=$(hostname -I | awk '{print $1}')
        fi
        
        if [ -n "$DETECTED_IP" ]; then
            EXTERNAL_HOSTNAME="$DETECTED_IP"
            echo "➡️ 로컬 설치 모드: 접속 주소를 자동 감지된 IP(${EXTERNAL_HOSTNAME})로 설정합니다."
        fi
    fi

    # 여전히 비어있으면 (2번 선택 시 또는 감지 실패 시) 입력 프롬프트 표시
    if [ -z "$EXTERNAL_HOSTNAME" ]; then
        read -p "Harbor 외부 접속 IP 또는 도메인을 입력하세요: " EXTERNAL_HOSTNAME_INPUT
        EXTERNAL_HOSTNAME="$EXTERNAL_HOSTNAME_INPUT"
        if [ -z "$EXTERNAL_HOSTNAME" ]; then
            echo "오류: 호스트명을 입력해야 합니다."
            exit 1
        fi
    fi
fi


# ---------------------------
# 2. 기존 Harbor 설치 확인 및 삭제 처리
# ---------------------------
RELEASE_EXISTS=$(helm list -n "$HARBOR_NAMESPACE" -q | grep -w "$HARBOR_RELEASE_NAME" || true)
PVC_EXISTS=$(kubectl get pvc -n "$HARBOR_NAMESPACE" -o name | grep "$PVC_NAME" || true)
PV_EXISTS=$(kubectl get pv -o name | grep "$PV_NAME" || true)
SVC_EXISTS=$(kubectl get svc -n "$HARBOR_NAMESPACE" -l "release=$HARBOR_RELEASE_NAME" -o name || true)

if [[ -n "$RELEASE_EXISTS" || -n "$PVC_EXISTS" || -n "$PV_EXISTS" || -n "$SVC_EXISTS" ]]; then
    echo "⚠️ 기존 Harbor 리소스가 감지되었습니다."
    read -p "기존 Harbor를 완전히 삭제하고 새로 설치하시겠습니까? (y/N): " DELETE_EXISTING
    if [[ "$DELETE_EXISTING" =~ ^[yY]([eE][sS])?$ ]]; then

        # Helm 릴리스 삭제
        if [[ -n "$RELEASE_EXISTS" ]]; then
            echo "➡️ Helm 릴리스 삭제 중..."
            helm uninstall "$HARBOR_RELEASE_NAME" -n "$HARBOR_NAMESPACE" || true
        fi

        # PVC 삭제
        echo "➡️ PVC 삭제 확인..."
        PVC_LIST=$(kubectl get pvc -n "$HARBOR_NAMESPACE" --no-headers --ignore-not-found | awk '{print $1}')
        if [[ -n "$PVC_LIST" ]]; then
            echo "➡️ PVC 삭제 중..."
            echo "$PVC_LIST" | xargs -r kubectl delete pvc -n "$HARBOR_NAMESPACE"
            for pvc in $PVC_LIST; do
                kubectl wait --for=delete pvc/"$pvc" -n "$HARBOR_NAMESPACE" --timeout=60s || true
            done
        else
            echo "➡️ PVC가 존재하지 않아 삭제할 필요 없음"
        fi

        # PV 삭제
        echo "➡️ PV 삭제 확인..."
        PV_LIST=$(kubectl get pv --no-headers --ignore-not-found | grep "$HARBOR_RELEASE_NAME" | awk '{print $1}')
        if [[ -n "$PV_LIST" ]]; then
            echo "➡️ PV 삭제 중..."
            echo "$PV_LIST" | xargs -r kubectl delete pv
            for pv in $PV_LIST; do
                kubectl wait --for=delete pv/"$pv" --timeout=60s || true
            done
        else
            echo "➡️ PV가 존재하지 않아 삭제할 필요 없음"
        fi

        # Service 삭제
        if [[ -n "$SVC_EXISTS" ]]; then
            echo "➡️ Service 삭제 중..."
            kubectl delete svc -n "$HARBOR_NAMESPACE" -l "release=$HARBOR_RELEASE_NAME" --ignore-not-found
        fi

    else
        echo "❌ 설치를 중단합니다."
        exit 1
    fi
fi

# 3. 노출 방식 선택
echo ""
echo "Harbor 노출 방식을 선택하세요:"
echo "  1) NodePort + Envoy Gateway (기본, HTTPRoute로 도메인 라우팅)"
echo "  2) nginx Ingress"
read -p "선택 [1/2, 기본값 1]: " EXPOSE_CHOICE
EXPOSE_CHOICE="${EXPOSE_CHOICE:-1}"

PROTOCOL="http"
TLS_SECRET_NAME=""
TLS_ENABLED="false"
TLS_CERT_SOURCE="none"

if [[ "$EXPOSE_CHOICE" == "2" ]]; then
    EXPOSE_TYPE="ingress"
    echo "nginx Ingress 방식으로 설치합니다."
    read -p "TLS(HTTPS)를 활성화하시겠습니까? (y/N): " ENABLE_TLS
    if [[ "$ENABLE_TLS" =~ ^[yY]([eE][sS])?$ ]]; then
        PROTOCOL="https"
        TLS_ENABLED="true"
        TLS_CERT_SOURCE="secret"
        read -p "미리 생성해 둔 TLS 시크릿의 이름을 입력하세요: " TLS_SECRET_NAME
        if [ -z "$TLS_SECRET_NAME" ]; then echo "오류: TLS 시크릿 이름은 비워둘 수 없습니다."; exit 1; fi
    fi
else
    EXPOSE_TYPE="nodePort"
    echo "NodePort + Envoy Gateway 방식으로 설치합니다."
    echo "  → Envoy HTTPRoute(manifests/route-harbor.yaml)로 도메인 라우팅을 설정하세요."
    read -p "Envoy Gateway에서 HTTPS(보안 접속)를 사용하시겠습니까? (y/N): " ENVOY_TLS
    if [[ "$ENVOY_TLS" =~ ^[yY]([eE][sS])?$ ]]; then
        PROTOCOL="https"
    fi
fi

# 4. 관리자 비밀번호 직접 입력받기
while true; do
    read -sp "Harbor 관리자('admin') 비밀번호를 입력하세요: " ADMIN_PASSWORD
    echo
    read -sp "비밀번호를 다시 한번 입력하세요: " ADMIN_PASSWORD_CONFIRM
    echo
    if [ -z "$ADMIN_PASSWORD" ]; then
        echo "비밀번호가 비어있습니다. 다시 시도하세요."
    elif [ ${#ADMIN_PASSWORD} -lt 8 ]; then
        echo "비밀번호는 최소 8자 이상이어야 합니다. 다시 시도하세요."
    elif [ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]; then
        echo "비밀번호가 일치하지 않습니다. 다시 시도하세요."
    else
        break
    fi
done

# 5. 네임스페이스 생성
echo "Harbor 네임스페이스 '$HARBOR_NAMESPACE'를 생성합니다..."
kubectl create namespace "$HARBOR_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "[INFO] Done."

# 6. 스토리지 타입 선택 및 PV/PVC 생성
PV_PVC_FILE="harbor-hostpath-persistence.yaml"

echo ""
if [[ "$STORAGE_MODE" == "hostpath" ]]; then
    STORAGE_CHOICE="1"
    echo "스토리지 모드: HostPath (STORAGE_MODE 사전 설정)"
elif [[ "$STORAGE_MODE" == "nfs" ]]; then
    STORAGE_CHOICE="2"
    echo "스토리지 모드: NFS (STORAGE_MODE 사전 설정)"
else
    echo "스토리지 타입을 선택하세요:"
    echo "  1) HostPath (노드 고정, 단일 노드 환경 권장)"
    echo "  2) NFS"
    read -p "선택 [1/2, 기본값 1]: " STORAGE_CHOICE
    STORAGE_CHOICE="${STORAGE_CHOICE:-1}"
fi

read -p "전체 저장 공간의 크기를 입력하세요 [${STORAGE_SIZE}]: " USER_STORAGE_SIZE
STORAGE_SIZE="${USER_STORAGE_SIZE:-$STORAGE_SIZE}"

if [[ "$STORAGE_CHOICE" == "2" ]]; then
    # --- NFS ---
    if [ -z "$NFS_SERVER" ]; then
        read -p "NFS 서버 주소를 입력하세요 (예: 192.168.1.100): " NFS_SERVER
        [ -z "$NFS_SERVER" ] && { echo "오류: NFS 서버 주소를 입력해야 합니다."; exit 1; }
    fi
    if [ -z "$NFS_PATH" ]; then
        read -p "NFS 내보내기 경로를 입력하세요 (예: /nfs/harbor): " NFS_PATH
        [ -z "$NFS_PATH" ] && { echo "오류: NFS 경로를 입력해야 합니다."; exit 1; }
    fi
    echo "NFS PV/PVC를 생성합니다... (서버: ${NFS_SERVER}, 경로: ${NFS_PATH})"
    cat > "$PV_PVC_FILE" <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${PV_NAME}
spec:
  capacity:
    storage: ${STORAGE_SIZE}
  volumeMode: Filesystem
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: harbor-nfs-sc
  nfs:
    server: ${NFS_SERVER}
    path: ${NFS_PATH}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${HARBOR_NAMESPACE}
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: harbor-nfs-sc
  resources:
    requests:
      storage: ${STORAGE_SIZE}
EOF

else
    # --- HostPath ---
    if [ -z "$NODE_NAME" ]; then
        NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        [ -n "$NODE_NAME" ] && echo "자동 감지된 노드: $NODE_NAME"
    fi
    read -p "데이터를 저장할 호스트 노드의 절대 경로를 입력하세요 [${SAVE_PATH}]: " USER_SAVE_PATH
    SAVE_PATH="${USER_SAVE_PATH:-$SAVE_PATH}"
    read -p "PV를 고정할 노드 이름을 입력하세요 [${NODE_NAME}]: " USER_NODE_NAME
    NODE_NAME="${USER_NODE_NAME:-$NODE_NAME}"
    [ -z "$NODE_NAME" ] && { echo "오류: 노드 이름을 입력해야 합니다."; exit 1; }

    echo "HostPath PV/PVC를 생성합니다... (노드: ${NODE_NAME}, 경로: ${SAVE_PATH})"
    cat > "$PV_PVC_FILE" <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${PV_NAME}
spec:
  capacity:
    storage: ${STORAGE_SIZE}
  volumeMode: Filesystem
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: harbor-hostpath-sc
  hostPath:
    path: ${SAVE_PATH}
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - "${NODE_NAME}"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${HARBOR_NAMESPACE}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: harbor-hostpath-sc
  resources:
    requests:
      storage: ${STORAGE_SIZE}
EOF
fi

kubectl apply -f "$PV_PVC_FILE"

# externalURL 계산
# - Envoy(nodePort): 도메인만 사용 (Envoy가 포트 처리)
# - nodePort 직접: IP:포트 사용
# - Ingress: 도메인만 사용
if [[ "$EXPOSE_TYPE" == "nodePort" && "$EXPOSE_CHOICE" == "1" ]]; then
    EXTERNAL_URL="${PROTOCOL}://${EXTERNAL_HOSTNAME}"
elif [[ "$EXPOSE_TYPE" == "nodePort" ]]; then
    EXTERNAL_URL="${PROTOCOL}://${EXTERNAL_HOSTNAME}:30002"
else
    EXTERNAL_URL="${PROTOCOL}://${EXTERNAL_HOSTNAME}"
fi

# 7. Harbor 설치
echo "Helm을 사용하여 Harbor를 배포합니다. 이 작업은 몇 분 정도 소요될 수 있습니다..."
VALUES_FILE="harbor-generated-values.yaml"
# values.yaml 생성
cat > "$VALUES_FILE" <<EOF
externalURL: ${EXTERNAL_URL}

harborAdminPassword: "${ADMIN_PASSWORD}"

expose:
  type: ${EXPOSE_TYPE}
  nodePort:
    name: harbor
    ports:
      http:
        port: 80
        nodePort: 30002
      https:
        port: 443
        nodePort: 30003
  tls:
    enabled: ${TLS_ENABLED}
    certSource: ${TLS_CERT_SOURCE}
    secret:
      secretName: "${TLS_SECRET_NAME}"
  ingress:
    className: "${INGRESS_CLASS}"
    hosts:
      core: ${EXTERNAL_HOSTNAME}
    annotations:
      nginx.ingress.kubernetes.io/proxy-body-size: "0"
      $([[ "$TLS_ENABLED" == "true" ]] && echo 'nginx.ingress.kubernetes.io/ssl-redirect: "true"' || echo "")

persistence:
  enabled: true
  resourcePolicy: "keep"
  persistentVolumeClaim:
    registry:
      existingClaim: "harbor-pvc"
      subPath: registry
    database:
      existingClaim: "harbor-pvc"
      subPath: database
    jobservice:
      jobLog:
        existingClaim: "harbor-pvc"
        subPath: jobservice-logs
    redis:
      existingClaim: "harbor-pvc"
      subPath: redis
    trivy:
      existingClaim: "harbor-pvc"
      subPath: trivy
  imageChartStorage:
    type: filesystem
EOF

helm upgrade --install "$HARBOR_RELEASE_NAME" "$HELM_CHART_PATH" \
    --namespace "$HARBOR_NAMESPACE" \
    -f ./values.yaml \
    -f "$VALUES_FILE" \
    --atomic \
    --wait

echo ""
echo "================================================================"
echo " Harbor 설치가 완료되었습니다!"
echo "================================================================"

if [[ "$EXPOSE_TYPE" == "nodePort" && "$EXPOSE_CHOICE" == "1" ]]; then
    echo " Harbor UI 접속 주소 (Envoy): ${PROTOCOL}://${EXTERNAL_HOSTNAME}"
    if [ -n "$NODE_NAME" ]; then
        NODE_IP=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
        [ -n "$NODE_IP" ] && echo " Harbor NodePort 직접 접속:   http://${NODE_IP}:30002"
    fi
    echo ""
    echo " Envoy HTTPRoute 설정:"
    echo "   kubectl apply -f manifests/route-harbor.yaml"
    echo "   (route-harbor.yaml의 hostnames를 '${EXTERNAL_HOSTNAME}'으로 수정 후 적용)"
elif [ "$EXPOSE_TYPE" = "nodePort" ]; then
    if [ -n "$NODE_NAME" ]; then
        NODE_IP=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
        [ -n "$NODE_IP" ] && echo " Harbor UI 접속 주소 (HTTP):  http://${NODE_IP}:30002"
    else
        echo " Harbor UI 접속 주소 (HTTP):  http://${EXTERNAL_HOSTNAME}:30002"
    fi
else
    echo " Harbor UI 접속 주소: ${PROTOCOL}://${EXTERNAL_HOSTNAME}"
fi

echo " 사용자명: admin"
echo " 비밀번호: (설치 시 입력한 비밀번호)"
echo "================================================================"
echo ""
