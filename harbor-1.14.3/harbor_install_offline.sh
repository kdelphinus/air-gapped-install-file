#!/bin/bash
set -e # 오류 발생 시 즉시 스크립트 중단

# =================================================================
# --- 설정 변수 (사용자 환경에 맞게 이 부분을 수정하세요) ---
# =================================================================

# 1. 기본 정보
HARBOR_NAMESPACE="harbor"
HARBOR_RELEASE_NAME="harbor"

# 2. 폐쇄망 환경 설정
HELM_CHART_PATH="./harbor-1.14.3.tgz"
PRIVATE_REGISTRY="" # 노드에 직접 이미지를 로드했다면 빈 문자열("")로 설정

# 3. 외부 접속 설정 (TLS 사용 시 인증서의 domain과 일치 해야함)
EXTERNAL_HOSTNAME="172.31.63.195"

# 4. 영구 저장소 설정 (HostPath)
SAVE_PATH="/harbor/data"
NODE_NAME="ip-172-31-63-195.ap-northeast-2.compute.internal" # 실제 노드 이름으로 변경

STORAGE_SIZE="1Gi"

# 5. 고급 설정
INGRESS_CLASS="nginx"

# =================================================================
# --- 메인 스크립트 로직 ---
# =================================================================

# --- 사전 요구사항 검사 함수 ---
check_command() {
    if ! command -v $1 &> /dev/null; then echo "오류: '$1' 명령어를 찾을 수 없습니다."; exit 1; fi
}

echo "Harbor 폐쇄망 설치 스크립트를 시작합니다."

# 1. 도구 및 파일 확인
check_command kubectl 
check_command helm
if [ ! -f "$HELM_CHART_PATH" ]; then
    echo "오류: Helm 차트 파일 '$HELM_CHART_PATH'을 찾을 수 없습니다."
    exit 1
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

# 3. TLS 및 서비스 타입 선택
read -p "TLS(HTTPS)를 활성화하시겠습니까? (y/N): " ENABLE_TLS
PROTOCOL="http"
TLS_SECRET_NAME="" # TLS 시크릿 이름 변수 초기화
if [[ "$ENABLE_TLS" =~ ^[yY]([eE][sS])?$ ]]; then
    PROTOCOL="https"
    EXPOSE_TYPE="ingress"
    echo "TLS를 활성화합니다. 서비스 노출 방식은 'ingress'로 고정됩니다."
    read -p "미리 생성해 둔 TLS 시크릿의 이름을 입력하세요: " TLS_SECRET_NAME
    if [ -z "$TLS_SECRET_NAME" ]; then echo "오류: TLS 시크릿 이름은 비워둘 수 없습니다."; exit 1; fi
else
    EXPOSE_TYPE="nodePort"
    echo "TLS를 비활성화하고 ${EXPOSE_TYPE}으로 설치를 진행합니다."
fi

# 4. 관리자 비밀번호 직접 입력받기
while true; do
    read -sp "Harbor 관리자('admin') 비밀번호를 입력하세요: " ADMIN_PASSWORD
    echo
    read -sp "비밀번호를 다시 한번 입력하세요: " ADMIN_PASSWORD_CONFIRM
    echo
    if [ "$ADMIN_PASSWORD" = "$ADMIN_PASSWORD_CONFIRM" ] && [ -n "$ADMIN_PASSWORD" ]; then
        break
    else
        echo "비밀번호가 비어있거나 일치하지 않습니다. 다시 시도하세요."
    fi
done

# 5. 네임스페이스 생성
echo "Harbor 네임스페이스 '$HARBOR_NAMESPACE'를 생성합니다..."
kubectl create namespace "$HARBOR_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "[INFO] Done."

# 7. HostPath PV 및 PVC 생성
PV_NAME="harbor-pv"
PVC_NAME="harbor-pvc"
PV_PVC_FILE="harbor-hostpath-persistence.yaml"

echo "HostPath 영구 저장소 설정을 진행합니다."
read -p "데이터를 저장할 호스트 노드의 절대 경로를 입력하세요 [${SAVE_PATH}]: " USER_SAVE_PATH
SAVE_PATH=${USER_SAVE_PATH:-$SAVE_PATH}
read -p "위 경로가 있는 워커 노드의 이름을 입력하세요 [${NODE_NAME}]: " USER_NODE_NAME
NODE_NAME=${USER_NODE_NAME:-$NODE_NAME}
read -p "전체 저장 공간의 크기를 입력하세요 [${STORAGE_SIZE}]: " USER_STORAGE_SIZE
STORAGE_SIZE=${USER_STORAGE_SIZE:-$STORAGE_SIZE}

echo "HostPath를 사용하는 PV와 PVC를 생성하고 적용합니다..."
cat > "$PV_PVC_FILE" <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${PV_NAME}
spec:
  capacity: { storage: ${STORAGE_SIZE} }
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
        - {key: kubernetes.io/hostname, operator: In, values: ["${NODE_NAME}"]}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${HARBOR_NAMESPACE}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: harbor-hostpath-sc
  resources: { requests: { storage: ${STORAGE_SIZE} } }
EOF
kubectl apply -f "$PV_PVC_FILE"

# externalURL 계산
if [[ "$ENABLE_TLS" =~ ^[yY]([eE][sS])?$ ]]; then
    EXTERNAL_URL="${PROTOCOL}://${EXTERNAL_HOSTNAME}"
else
    EXTERNAL_URL="${PROTOCOL}://${EXTERNAL_HOSTNAME}:30002"
fi

# cert_source 계산
if [[ "$ENABLE_TLS" =~ ^[yY]([eE][sS])?$ ]]; then
    TLS_ENABLED="true"
    TLS_CERT_SOURCE="secret"
else
    TLS_ENABLED="false"
    TLS_CERT_SOURCE="none"
fi

# 7. Harbor 설치
echo "Helm을 사용하여 Harbor를 배포합니다. 이 작업은 몇 분 정도 소요될 수 있습니다..."
VALUES_FILE="harbor-generated-values.yaml"
# values.yaml 생성
cat > "$VALUES_FILE" <<EOF
image:
  repository: ${PRIVATE_REGISTRY}
  pullPolicy: IfNotPresent

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
      $([[ "$ENABLE_TLS" =~ ^[yY]([eE][sS])?$ ]] && echo 'nginx.ingress.kubernetes.io/ssl-redirect: "true"' || echo "")

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
# 내부 컴포넌트 TLS (전역 설정)
internalTLS:
  enabled: false

# trivy 인터넷 연결이 필요하므로 비활성화
trivy:
  enabled: false
  skipUpdate: true
  offlineScan: true
  internalTLS:
    enabled: false   # ✅ Trivy는 항상 TLS OFF
EOF

helm upgrade --install "$HARBOR_RELEASE_NAME" "$HELM_CHART_PATH" \
    --namespace "$HARBOR_NAMESPACE" \
    -f "$VALUES_FILE" \
    --atomic \
    --wait

echo ""
echo "================================================================"
echo " Harbor 설치가 완료되었습니다!"
echo "================================================================"

if [ "$EXPOSE_TYPE" = "nodePort" ]; then
    NODE_IP=$(kubectl get node ${NODE_NAME} -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
    echo " Harbor UI 접속 주소 (HTTP):  http://${NODE_IP}:30002"
else
    echo " Harbor UI 접속 주소: ${PROTOCOL}://${EXTERNAL_HOSTNAME}"
fi

echo " 사용자명: admin"
echo " 비밀번호: ${ADMIN_PASSWORD}"
echo "================================================================"
echo ""