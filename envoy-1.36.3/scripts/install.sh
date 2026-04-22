#!/bin/bash

# 스크립트 위치 기준으로 컴포넌트 루트로 이동 (scripts/ 하위에서 실행해도 경로 안전)
cd "$(dirname "$0")/.." || exit 1

# ==========================================
# [설정] 기본 변수
# ==========================================
NAMESPACE="envoy-gateway-system"
CONTROLLER_CHART="./charts/gateway-1.6.1"
INFRA_CHART="./charts/gateway-infra"
GW_NAME="cluster-gateway"
GW_CLASS_NAME="eg-cluster-entry"
GLOBAL_POLICY_FILE="./manifests/policy-global-config.yaml"

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
    IMG_GATEWAY="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/gateway:v1.6.1"
    IMG_PROXY="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/envoy:distroless-v1.36.3"
elif [ "${IMAGE_SOURCE}" = "2" ]; then
    echo "로컬 tar 파일을 모든 워커 노드에 import 해야 합니다."
    HARBOR_REGISTRY=""
    HARBOR_PROJECT=""
    IMG_GATEWAY="docker.io/envoyproxy/gateway:v1.6.1"
    IMG_PROXY="docker.io/envoyproxy/envoy:distroless-v1.36.3"
else
    echo "[오류] 1 또는 2를 선택하세요."; exit 1
fi

# ==========================================
# [함수] 클린업 로직
# ==========================================
function cleanup_resources() {
  echo ""
  echo "🧹 [Clean Up] 기존 리소스 강제 정리 시작..."

  # 1. 헬름 차트 제거 (기다리지 않고 백그라운드로 던짐)
  helm uninstall gateway-infra -n $NAMESPACE --wait=false 2>/dev/null &
  helm uninstall eg-gateway -n $NAMESPACE --wait=false 2>/dev/null &

  echo "⏳ 리소스 삭제 대기 중..."
  sleep 5

  # 2. [핵심] 이름($GW_NAME)을 지정하지 않고, 종류별로 싹 다 찾아서 Finalizer 제거
  # (Gateway 이름이 달라도, 여러 개여도 모두 처리됨)
  echo "🔫 좀비 리소스(Finalizer) 일괄 제거 중..."
  for KIND in gateway gatewayclass envoyproxy httproute service; do
    kubectl get $KIND -n $NAMESPACE -o name 2>/dev/null | \
    xargs -r -I {} kubectl patch {} -n $NAMESPACE -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
  done

  # 전역 정책 삭제
  kubectl delete -f $GLOBAL_POLICY_FILE 2>/dev/null

  # 3. 네임스페이스 강제 삭제 (최후의 수단)
  if kubectl get ns $NAMESPACE > /dev/null 2>&1; then
      echo "🗑️  네임스페이스($NAMESPACE) 강제 삭제 시도..."

      # 일단 일반 삭제 시도
      kubectl delete ns $NAMESPACE --timeout=5s --wait=false 2>/dev/null

      # 그래도 안 지워지면 API 강제 호출 (마법의 명령어)
      kubectl get namespace "$NAMESPACE" -o json 2>/dev/null | \
        tr -d "\n" | \
        sed "s/\"kubernetes\"//g" | \
        kubectl replace --raw "/api/v1/namespaces/$NAMESPACE/finalize" -f - > /dev/null 2>&1
  fi

  echo "✅ 초기화 완료."
  echo ""
}

# 스크립트로 Namespace 삭제가 안 될 시, 아래 명령어 수동 실행
# kubectl get namespace envoy-gateway-system -o json | \
#   tr -d "\n" | \
#   sed "s/\"kubernetes\"//g" | \
#   kubectl replace --raw "/api/v1/namespaces/envoy-gateway-system/finalize" -f -


# ==========================================
# [1] 기존 설치 감지 — 재설치 / 업그레이드 / 취소
# ==========================================
DO_UPGRADE=false
if kubectl get ns $NAMESPACE > /dev/null 2>&1; then
  echo ""
  echo "⚠️  기존 설치가 감지되었습니다."
  echo "  1) 삭제 후 재설치"
  echo "  2) 업그레이드 (helm upgrade, 기존 설정 유지)"
  echo "  3) 취소"
  read -p "선택 [1/2/3]: " EXIST_ACTION
  case "$EXIST_ACTION" in
    1)
      cleanup_resources
      ;;
    2)
      DO_UPGRADE=true
      echo ""
      echo "ℹ️  업그레이드 모드로 진행합니다."
      echo "⚠️  CRD 변경이 있는 경우 helm upgrade로는 자동 적용되지 않습니다."
      echo "    필요 시 아래 명령어로 CRD를 수동 적용하세요:"
      echo "    kubectl apply -f ./charts/gateway-1.6.1/crds/"
      echo ""
      ;;
    *)
      echo "취소되었습니다."; exit 0
      ;;
  esac
fi

# ==========================================
# [2] values-infra.yaml에서 서비스 타입 감지
# ==========================================
if [ ! -f "./values-infra.yaml" ]; then
  echo "❌ 에러: values-infra.yaml 파일이 없습니다. 배포 설정을 확인하세요."
  exit 1
fi
SVC_TYPE=$(grep -A2 '^service:' ./values-infra.yaml | grep 'type:' | awk '{print $2}')
echo "ℹ️  서비스 타입: ${SVC_TYPE:-LoadBalancer} (values-infra.yaml 기준)"

# ==========================================
# [3] 노드 고정 설정 (선택 사항)
# ==========================================
echo ""
echo "🌐 현재 클러스터 노드 목록:"
echo "----------------------------------------------------------------"
kubectl get nodes -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[?(@.type=='Ready')].status,ROLE:.metadata.labels['kubernetes\.io/role']" | sed 's/True/Ready/g'
echo "----------------------------------------------------------------"
echo "위 목록에서 Envoy를 고정할 노드 이름을 입력하세요."
read -p "입력 없이 엔터를 누르면 쿠버네티스가 자동으로 배치합니다: " TARGET_NODE

if [ -z "$TARGET_NODE" ]; then
    NODE_FLAG=""
    echo "ℹ️  노드 고정 없이 자동 배치합니다."
else
    if ! kubectl get node "$TARGET_NODE" > /dev/null 2>&1; then
        echo "⚠️  경고: '$TARGET_NODE' 노드를 찾을 수 없습니다. 자동 배치로 진행합니다."
        NODE_FLAG=""
    else
        NODE_FLAG="--set envoy.nodeName=$TARGET_NODE"
        echo "✅ Envoy를 '$TARGET_NODE' 노드에 고정합니다."
    fi
fi

# ==========================================
# [4] Controller 설치
# ==========================================
echo ""
echo "🚀 [1/2] Envoy Gateway Controller 설치 중..."

helm upgrade --install eg-gateway $CONTROLLER_CHART \
  -n $NAMESPACE --create-namespace \
  --set global.images.envoyGateway.image=$IMG_GATEWAY \
  --set global.images.envoyGateway.pullPolicy="IfNotPresent"

echo "⏳ 컨트롤러 준비 대기..."
kubectl wait --timeout=5m -n $NAMESPACE deployment/envoy-gateway --for=condition=Available

# ==========================================
# [5] Infrastructure 설치
# ==========================================
echo "🚀 [2/2] Infrastructure 배포 중..."

helm upgrade --install gateway-infra $INFRA_CHART \
  -n $NAMESPACE \
  -f ./values-infra.yaml \
  --set envoy.image=$IMG_PROXY \
  --set gateway.name=$GW_NAME \
  $NODE_FLAG

# NodePort 모드: 포트를 30080/30443으로 고정
if [ "$SVC_TYPE" == "NodePort" ]; then
    echo "⏳ Envoy 서비스 생성 대기 중..."
    sleep 10

    SVC_NAME=$(kubectl get svc -n $NAMESPACE -l gateway.envoyproxy.io/owning-gateway-name=$GW_NAME -o jsonpath='{.items[0].metadata.name}')

    if [ -n "$SVC_NAME" ]; then
        echo "🔧 서비스($SVC_NAME) 포트를 30080/30443으로 변경합니다..."
        kubectl patch svc $SVC_NAME -n $NAMESPACE --type='merge' \
          -p '{"spec":{"ports":[{"name":"https","port":443,"targetPort":10443,"nodePort":30443},{"name":"http","port":80,"targetPort":10080,"nodePort":30080}]}}'
        echo "✅ 포트 변경 완료."
    else
        echo "⚠️  서비스를 찾지 못해 포트 변경에 실패했습니다. (수동 확인 필요)"
    fi
fi

# ==========================================
# [6] Global Policy
# ==========================================
if [ -f "$GLOBAL_POLICY_FILE" ]; then
  echo ""
  echo "----------------------------------------------------------------"
  echo " 📜 전역 정책 설정 확인 ($GLOBAL_POLICY_FILE)"
  read -p "❓ 전역 정책(EnvoyPatchPolicy 등)을 지금 적용하시겠습니까? (y/n): " APPLY_POLICY

  if [[ "$APPLY_POLICY" =~ ^[Yy]$ ]]; then
    echo "🚀 전역 정책 적용 중..."
    kubectl apply -f $GLOBAL_POLICY_FILE
    echo "✅ 적용 완료."
  else
    echo "ℹ️  전역 정책 적용을 건너뜁니다."
  fi
else
  echo ""
  echo "ℹ️  전역 정책 파일($GLOBAL_POLICY_FILE)이 없어 건너뜁니다."
fi

# 파드 재시작으로 설정 강제 적용
echo "♻️  설정 적용을 위해 Proxy 파드 재시작..."
kubectl delete pods -n $NAMESPACE -l gateway.envoyproxy.io/owning-gateway-name=$GW_NAME --ignore-not-found

echo ""
echo "========================================================"
echo "🎉 설치 완료!"
echo "Gateway   : $GW_NAME"
if [ "$SVC_TYPE" == "NodePort" ]; then
    echo "Mode      : NodePort (30080/30443)"
    echo "Check     : netstat -tlpn | grep 30443"
else
    echo "Mode      : LoadBalancer"
fi
echo "========================================================"
kubectl get svc -n $NAMESPACE
