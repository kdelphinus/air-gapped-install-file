#!/bin/bash

# 스크립트 위치 기준으로 컴포넌트 루트로 이동 (scripts/ 하위에서 실행해도 경로 안전)
cd "$(dirname "$0")/.." || exit 1

# ==========================================
# [설정] 변수 정의
# ==========================================
NAMESPACE="gitlab"
RELEASE_NAME="gitlab"
CHART_PATH="./charts/gitlab"
VALUES_FILE="./values.yaml"

# ── 이미지 소스 선택 ──────────────────────────────────────────
echo ""
echo "이미지 소스를 선택하세요:"
echo "  1) Harbor 레지스트리 사용 (사전에 images/upload_images_to_harbor_v3-lite.sh 실행 필요)"
echo "  2) 로컬 tar 직접 import (이미 이미지가 로드된 경우 건너뜀)"
read -p "선택 [1/2, 기본값: 1]: " IMAGE_SOURCE
IMAGE_SOURCE="${IMAGE_SOURCE:-1}"

if [ "${IMAGE_SOURCE}" = "1" ]; then
    read -p "Harbor 레지스트리 주소 (예: 192.168.1.10:30002 또는 harbor.example.com): " HARBOR_REGISTRY
    if [ -z "${HARBOR_REGISTRY}" ]; then
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

echo "========================================================"
echo "🔄 GitLab Helm Upgrade 스크립트를 시작합니다."
echo "========================================================"

# ==========================================
# 0. 현재 배포 상태 확인
# ==========================================
echo ""
echo "🔍 [사전 확인] 현재 배포 상태 점검..."

if ! helm status "$RELEASE_NAME" -n "$NAMESPACE" > /dev/null 2>&1; then
    echo "❌ 오류: Helm Release '$RELEASE_NAME'이 '$NAMESPACE' 네임스페이스에 없습니다."
    echo "   신규 설치는 scripts/install.sh 를 사용하세요."
    exit 1
fi

CURRENT_VERSION=$(helm list -n "$NAMESPACE" -o json \
    | python3 -c "import sys,json; r=[x for x in json.load(sys.stdin) if x['name']=='$RELEASE_NAME']; print(r[0]['chart'] if r else '')" 2>/dev/null || true)
echo "  - 현재 배포된 Chart: ${CURRENT_VERSION:-알 수 없음}"
echo "  - 업그레이드 대상 Chart: ${CHART_PATH}"

# ==========================================
# 1. 노드 고정 설정 (선택)
# ==========================================
echo ""
echo "--------------------------------------------------------"
echo "🖥️  [선택] 노드 고정(Node Pinning) 설정"
echo "--------------------------------------------------------"
echo "현재 클러스터의 노드 목록:"
kubectl get nodes
echo ""

NODE_LABEL_KEY="gitlab-node"
NODE_LABEL_VALUE="true"
NODE_SELECTOR_ARGS=""

read -p "❓ 특정 노드에 고정하시겠습니까? (y/n, 기본값: n): " USE_NODE_PIN
USE_NODE_PIN="${USE_NODE_PIN:-n}"

if [[ "$USE_NODE_PIN" == "y" || "$USE_NODE_PIN" == "Y" ]]; then
    read -p "GitLab을 배포할 노드 이름(NAME)을 입력해주세요: " TARGET_NODE

    if [ -z "$TARGET_NODE" ]; then
        echo "⚠️  노드 이름이 입력되지 않았습니다. 노드 고정을 건너뜁니다."
    elif ! kubectl get node "$TARGET_NODE" > /dev/null 2>&1; then
        echo "❌ 오류: '$TARGET_NODE'라는 노드를 찾을 수 없습니다."
        exit 1
    else
        echo "🔹 '$TARGET_NODE' 노드에 '$NODE_LABEL_KEY=$NODE_LABEL_VALUE' 라벨을 적용합니다..."
        kubectl label nodes "$TARGET_NODE" "$NODE_LABEL_KEY=$NODE_LABEL_VALUE" --overwrite
        echo "✅ 노드 고정 설정 완료."
        NODE_SELECTOR_ARGS="--set-string global.nodeSelector.${NODE_LABEL_KEY}=${NODE_LABEL_VALUE} \
                            --set-string redis.master.nodeSelector.${NODE_LABEL_KEY}=${NODE_LABEL_VALUE} \
                            --set-string postgresql.primary.nodeSelector.${NODE_LABEL_KEY}=${NODE_LABEL_VALUE}"
    fi
else
    echo "  → 노드 고정 없이 자동 스케줄링으로 업그레이드합니다."
fi

# ==========================================
# 2. 이미지 오버라이드 파일 생성
# ==========================================
IMAGE_VALUES_FILE="gitlab-images-override.yaml"

if [ "${IMAGE_SOURCE}" = "1" ]; then
    echo ""
    echo "⚙️  [자동화] Harbor 이미지 설정을 위한 '$IMAGE_VALUES_FILE' 생성 중..."

    cat <<EOF > $IMAGE_VALUES_FILE
global:
  image:
    registry: ${HARBOR_REGISTRY}
    pullPolicy: IfNotPresent

  # 공통 Helper 이미지
  kubectl:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/kubectl
  certificates:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/certificates
  gitlabBase:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-base

# 1. GitLab 메인 컴포넌트
gitlab:
  webservice:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-webservice-ce
    workhorse:
      image: "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-workhorse-ce"

  sidekiq:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-sidekiq-ce
  toolbox:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-toolbox-ce
  gitlab-shell:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-shell
  gitaly:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitaly
  gitlab-exporter:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-exporter
  kas:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-kas
  migrations:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-toolbox-ce

# 2. MinIO 설정
minio:
  image: "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/minio"
  imageTag: "RELEASE.2017-12-28T01-21-00Z"
  minioMc:
    image: "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/mc"
    tag: "RELEASE.2018-07-13T00-53-22Z"
  mcImage:
    repository: "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/mc"
    tag: "RELEASE.2018-07-13T00-53-22Z"
  makeBucketJob:
    image:
      repository: "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/mc"
      tag: "RELEASE.2018-07-13T00-53-22Z"

# 3. Cert-Manager
certmanager:
  image:
    repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/cert-manager-controller
    tag: v1.17.4
  webhook:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/cert-manager-webhook
      tag: v1.17.4
  cainjector:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/cert-manager-cainjector
      tag: v1.17.4
  startupapicheck:
    image:
      repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/cert-manager-startupapicheck
      tag: v1.17.4

# 4. PostgreSQL & Redis
postgresql:
  image:
    registry: ${HARBOR_REGISTRY}
    repository: ${HARBOR_PROJECT}/postgresql
    tag: "16.2.0"
  metrics:
    image:
      registry: ${HARBOR_REGISTRY}
      repository: ${HARBOR_PROJECT}/postgres-exporter
      tag: "0.15.0-debian-11-r7"

redis:
  image:
    registry: ${HARBOR_REGISTRY}
    repository: ${HARBOR_PROJECT}/redis
    tag: "7.2.4"
  metrics:
    image:
      registry: ${HARBOR_REGISTRY}
      repository: ${HARBOR_PROJECT}/redis-exporter
      tag: "1.58.0-debian-12-r4"

registry:
  image:
    repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-container-registry

upgradeCheck:
  image:
    repository: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gitlab-base
EOF

    echo "✅ 이미지 설정 파일 생성 완료."
else
    echo ""
    echo "ℹ️  로컬 import 모드 — '$IMAGE_VALUES_FILE' 생성을 건너뜁니다."
    IMAGE_VALUES_FILE=""
fi

# ==========================================
# 3. Helm Upgrade 실행
# ==========================================
echo ""
echo "🚀 [Helm Upgrade] GitLab 업그레이드 시작..."

if [ ! -f "$VALUES_FILE" ]; then
    echo "❌ 오류: 현재 폴더에 '$VALUES_FILE' 파일이 없습니다!"
    exit 1
fi

IMAGE_VALUES_ARG=""
if [ -n "$IMAGE_VALUES_FILE" ]; then
    echo "   Applying Images from: $IMAGE_VALUES_FILE"
    IMAGE_VALUES_ARG="-f $IMAGE_VALUES_FILE"
else
    echo "   Image Values: 로컬 import 모드 (이미지 오버라이드 없음)"
fi

if [ -n "$NODE_SELECTOR_ARGS" ]; then
    echo "   Target Node Label: $NODE_LABEL_KEY=$NODE_LABEL_VALUE"
    HELM_CMD="helm upgrade ${RELEASE_NAME} ${CHART_PATH} -f ${VALUES_FILE} ${IMAGE_VALUES_ARG} --namespace ${NAMESPACE} --timeout 600s ${NODE_SELECTOR_ARGS}"
else
    echo "   Node Selector: None (Automatic Scheduling)"
    HELM_CMD="helm upgrade ${RELEASE_NAME} ${CHART_PATH} -f ${VALUES_FILE} ${IMAGE_VALUES_ARG} --namespace ${NAMESPACE} --timeout 600s"
fi

echo ""
echo "--------------------------------------------------------"
echo "📋 [실행 명령어] 아래 명령어로 직접 실행할 수 있습니다:"
echo ""
echo "  ${HELM_CMD}"
echo "--------------------------------------------------------"
echo ""
eval "$HELM_CMD"

echo ""
echo "========================================================"
echo "🎉 GitLab 업그레이드 명령이 성공적으로 전달되었습니다."
echo "========================================================"
echo "📊 [모니터링] 업그레이드 상태 확인:"
echo "   - Pod 상태:    kubectl get pods -n $NAMESPACE -w"
echo "   - Revision:    helm history $RELEASE_NAME -n $NAMESPACE"
echo "   - 이벤트:      kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp'"
echo ""
echo "⏪ [롤백] 문제 발생 시 이전 버전으로 되돌리기:"
echo "   - helm rollback $RELEASE_NAME -n $NAMESPACE"
echo "========================================================"
