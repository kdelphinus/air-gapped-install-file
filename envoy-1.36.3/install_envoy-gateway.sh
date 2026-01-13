#!/bin/bash

# ==========================================
# [설정] 기본 변수
# ==========================================
NAMESPACE="envoy-gateway-system"
CONTROLLER_CHART="./gateway-helm"
INFRA_CHART="./strato-gateway-infra"

# Gateway 이름
GW_NAME="cmp-gateway"

# 이미지 정보 (infra 차트의 values.yaml과 일치해야 함)
IMG_GATEWAY="docker.io/envoyproxy/gateway:v1.6.1"
IMG_PROXY="docker.io/envoyproxy/envoy:distroless-v1.36.3"

# 클러스터 레벨 리소스 이름 (GatewayClass 등 삭제용)
GW_CLASS_NAME="eg-direct-node"

# ==========================================
# [함수] 클린업 로직 (싹 지우기)
# ==========================================
function force_delete_ns() {
    NS=$1
    if kubectl get ns "$NS" &> /dev/null; then
        echo "🗑️  '$NS' 네임스페이스 삭제 시작..."
        # 1. 일단 정석대로 삭제 시도 (백그라운드 실행)
        kubectl delete ns "$NS" --timeout=10s --ignore-not-found=true & 
        
        # 2. 잠시 대기 (5초)
        sleep 5
        
        # 3. 여전히 살아있다면? -> 강제 삭제(Finalizer 제거) 발동
        if kubectl get ns "$NS" &> /dev/null; then
            echo "⚠️  '$NS'가 Terminating 상태에서 멈췄습니다. 강제 삭제(Finalizer 제거)를 실행합니다."
            
            # 마법의 명령어: Finalizer 강제 제거
            kubectl get namespace "$NS" -o json | \
              tr -d "\n" | \
              sed "s/\"kubernetes\"//g" | \
              kubectl replace --raw "/api/v1/namespaces/$NS/finalize" -f - > /dev/null 2>&1
              
            echo "✅  '$NS' 강제 정리 완료."
        else
            echo "✅  '$NS' 정상 삭제 완료."
        fi
    else
        echo "ℹ️  '$NS' 네임스페이스는 이미 없습니다."
    fi
}

function cleanup_resources() {
  echo ""
  echo "🧹 [Clean Up] 기존 리소스 강제 정리 시작..."

  # 1. Helm 차트 삭제
  echo "   - Helm Uninstall 중..."
  helm uninstall cmp-gateway-infra -n $NAMESPACE 2>/dev/null
  helm uninstall eg -n $NAMESPACE 2>/dev/null

  # 2. [중요] 네임스페이스 내부 좀비 리소스 강제 정리
  # (이게 없으면 네임스페이스가 Terminating에서 안 끝남)
  echo "   - 내부 리소스(Gateway, Proxy) Finalizer 제거 중..."
  kubectl patch gateway $GW_NAME -n $NAMESPACE -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
  kubectl delete gateway $GW_NAME -n $NAMESPACE
  kubectl patch envoyproxy direct-node-proxy -n $NAMESPACE -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
  
  # 3. GatewayClass 강제 삭제
  echo "   - GatewayClass 강제 삭제 중..."
  kubectl patch gatewayclass $GW_CLASS_NAME -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
  kubectl delete gatewayclass $GW_CLASS_NAME --ignore-not-found --wait=false 2>/dev/null

  # 4. 네임스페이스 삭제 및 대기
  if kubectl get ns $NAMESPACE > /dev/null 2>&1; then
    force_delete_ns "$NAMESPACE"
  else
    echo "   ✨ Namespace가 이미 없습니다."
  fi
  echo "✅ 초기화 완료! 설치를 시작합니다."
  echo ""
}

# ==========================================
# [1] 대상 노드 설정
# ==========================================
if [ -z "$1" ]; then
  echo "------------------------------------------------"
  echo " 🌍 현재 클러스터 노드 목록:"
  kubectl get nodes --no-headers -o custom-columns=":metadata.name"
  echo "------------------------------------------------"
  read -p "배포할 노드 이름을 입력하세요: " TARGET_NODE
else
  TARGET_NODE=$1
fi

if [ -z "$TARGET_NODE" ]; then
  echo "❌ 노드 이름이 입력되지 않아 종료합니다."
  exit 1
fi

# ==========================================
# [2] 재설치 여부 확인
# ==========================================
# 네임스페이스가 이미 존재하면 묻는다.
if kubectl get ns $NAMESPACE > /dev/null 2>&1; then
  echo ""
  echo "⚠️  경고: 기존 설치('$NAMESPACE')가 감지되었습니다."
  echo "    설정이 꼬였거나 초기화가 필요하다면 'y'를 눌러 삭제 후 재설치하세요."
  read -p "❓ 기존 리소스를 모두 삭제하고 재설치하시겠습니까? (y/n): " DO_CLEANUP
  
  if [ "$DO_CLEANUP" == "y" ] || [ "$DO_CLEANUP" == "Y" ]; then
    cleanup_resources
  else
    echo "ℹ️  기존 리소스를 유지하고 덮어쓰기(Upgrade)를 진행합니다."
  fi
fi

# ==========================================
# [3] 컨테이너 런타임 자동 감지 & 이미지 체크
# ==========================================
CRI_TYPE="unknown"
CHECK_CMD=""

if [ -S "/run/k3s/containerd/containerd.sock" ]; then
  CRI_TYPE="k3s"
  CHECK_CMD="ctr -a /run/k3s/containerd/containerd.sock -n k8s.io image list"
elif [ -S "/run/containerd/containerd.sock" ]; then
  CRI_TYPE="containerd"
  if command -v nerdctl &> /dev/null; then CHECK_CMD="nerdctl -n k8s.io images"; else CHECK_CMD="ctr -n k8s.io image list"; fi
elif command -v docker &> /dev/null; then
  CRI_TYPE="docker"
  CHECK_CMD="docker images"
fi

echo "🔍 감지된 런타임: $CRI_TYPE ($TARGET_NODE)"

if [ "$CRI_TYPE" != "unknown" ]; then
  # 이미지 존재 여부만 체크 (경고만 표시)
  HAS_GW=$($CHECK_CMD | grep "envoyproxy/gateway")
  HAS_PROXY=$($CHECK_CMD | grep "envoyproxy/envoy")

  if [ -z "$HAS_GW" ] || [ -z "$HAS_PROXY" ]; then
    echo "⚠️  [경고] 현재 노드에서 Envoy 이미지가 확인되지 않습니다."
    echo "    (멀티 노드 환경이라면 대상 노드에만 있어도 되므로 무시 가능)"
  else
    echo "✅ 로컬 이미지 확인됨."
  fi
fi

# ==========================================
# [4] 설치 시작
# ==========================================
echo ""
echo "🚀 [1/2] Envoy Gateway Controller 설치 중..."

helm upgrade --install eg $CONTROLLER_CHART \
  -n $NAMESPACE \
  --create-namespace \
  --set global.imageRegistry="" \
  --set global.images.envoyGateway.image=$IMG_GATEWAY \
  --set global.images.envoyGateway.pullPolicy="IfNotPresent"

echo "⏳ 컨트롤러 실행 대기 중..."
kubectl wait --timeout=5m -n $NAMESPACE deployment/envoy-gateway --for=condition=Available

echo "🚀 [2/2] Infrastructure ($TARGET_NODE) 배포 중..."
helm upgrade --install strato-gateway-infra $INFRA_CHART \
  -n $NAMESPACE \
  --set envoy.nodeName=$TARGET_NODE \
  --set envoy.image=$IMG_PROXY \
  --set gateway.name=$GW_NAME

echo "♻️  설정 적용을 위해 Proxy 파드 재시작..."
kubectl delete pods -n $NAMESPACE -l gateway.envoyproxy.io/owning-gateway-name=$GW_NAME --ignore-not-found

echo ""
echo "========================================================"
echo "🎉 설치가 완료되었습니다!"
echo "Target Node : $TARGET_NODE"
echo "Gateway Name: $GW_NAME"
echo "Namespace   : $NAMESPACE"
echo "========================================================"
kubectl get pods -n $NAMESPACE -o wide