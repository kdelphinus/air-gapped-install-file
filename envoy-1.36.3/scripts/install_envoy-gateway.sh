#!/bin/bash

# ==========================================
# [설정] 기본 변수
# ==========================================
NAMESPACE="envoy-gateway-system"
CONTROLLER_CHART="./charts/gateway-1.6.1"
INFRA_CHART="./charts/strato-gateway-infra"
GW_NAME="cmp-gateway"
IMG_GATEWAY="docker.io/envoyproxy/gateway:v1.6.1"
IMG_PROXY="docker.io/envoyproxy/envoy:distroless-v1.36.3"
GW_CLASS_NAME="eg-cluster-entry"
GLOBAL_POLICY_FILE="./manifests/policy-global-config.yaml"

# ==========================================
# [함수] 클린업 로직
# ==========================================
function cleanup_resources() {
  echo ""
  echo "🧹 [Clean Up] 기존 리소스 강제 정리 시작..."

  # 1. 헬름 차트 제거 (기다리지 않고 백그라운드로 던짐)
  helm uninstall strato-gateway-infra -n $NAMESPACE --wait=false 2>/dev/null &
  helm uninstall eg -n $NAMESPACE --wait=false 2>/dev/null &
  
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
# [1] 재설치 여부 확인
# ==========================================
if kubectl get ns $NAMESPACE > /dev/null 2>&1; then
  echo "⚠️  기존 설치가 감지되었습니다."
  read -p "❓ 삭제 후 재설치하시겠습니까? (y/n): " DO_CLEANUP
  if [[ "$DO_CLEANUP" =~ ^[Yy]$ ]]; then
    cleanup_resources
  else
    echo "ℹ️  기존 리소스를 유지하고 업데이트(Upgrade)합니다."
  fi
fi

# ==========================================
# [2] 설치 모드 선택 (LB vs NodePort)
# ==========================================
echo ""
echo "----------------------------------------------------------------"
echo " 🛠️  설치 모드 선택:"
echo " 1) LoadBalancer Mode (기본) - HostNetwork/MetalLB 사용"
echo " 2) NodePort Mode (권장) - 외부 LB 연동 (NodePort 30443)"
echo "----------------------------------------------------------------"
read -p "선택 [1 or 2]: " INSTALL_MODE

# ==========================================
# [3] 노드 고정 설정 (선택 사항)
# ==========================================
echo ""
echo "🌐 현재 클러스터 노드 목록:"
echo "----------------------------------------------------------------"
# 노드 이름, 상태, 역할을 표 형태로 출력합니다.
kubectl get nodes -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[?(@.type=='Ready')].status,ROLE:.metadata.labels['kubernetes\.io/role']" | sed 's/True/Ready/g'
echo "----------------------------------------------------------------"
echo "위 목록에서 Envoy를 고정할 노드 이름을 입력하세요."
read -p "입력 없이 엔터를 누르면 쿠버네티스가 자동으로 배치합니다: " TARGET_NODE

if [ -z "$TARGET_NODE" ]; then
    NODE_FLAG=""
    echo "ℹ️  노드 고정 없이 자동 배치합니다."
else
    # 입력한 노드 이름이 실제 존재하는지 한 번 더 체크 (방어 로직)
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
helm upgrade --install eg $CONTROLLER_CHART \
  -n $NAMESPACE --create-namespace \
  --set global.images.envoyGateway.image=$IMG_GATEWAY \
  --set global.images.envoyGateway.pullPolicy="IfNotPresent"

echo "⏳ 컨트롤러 준비 대기..."
kubectl wait --timeout=5m -n $NAMESPACE deployment/envoy-gateway --for=condition=Available

# ==========================================
# [5] Infrastructure 설치 (핵심)
# ==========================================
echo "🚀 [2/2] Infrastructure 배포 중..."

# 공통 옵션
BASE_OPTS="-n $NAMESPACE --set envoy.image=$IMG_PROXY --set gateway.name=$GW_NAME $NODE_FLAG"

if [ "$INSTALL_MODE" == "2" ]; then
    # NodePort 모드: values.yaml + nodeport-values.yaml 함께 적용
    # [참고] 앞단에 외부 하드웨어 LB(VIP)가 있는 경우:
    #   - Service EXTERNAL-IP와 Gateway 주소에 VIP 대신 Worker Node IP가 표시되는 것은 정상입니다.
    #   - VIP는 외부 LB가 소유하며 Kubernetes는 알 수 없습니다. Gateway spec.addresses 패치 불필요.
    #   - 트래픽 흐름: 클라이언트 → VIP(외부 LB) → Worker Node IP:30080/30443 → Envoy → 백엔드
    if [ ! -f "$INFRA_CHART/nodeport-values.yaml" ]; then
        echo "❌ 에러: $INFRA_CHART/nodeport-values.yaml 파일이 없습니다!"
        exit 1
    fi
    echo "🔧 [NodePort Mode] 적용 중..."
    helm upgrade --install strato-gateway-infra $INFRA_CHART $BASE_OPTS \
        -f $INFRA_CHART/nodeport-values.yaml
    
    echo "⏳ Envoy 서비스 생성 대기 중..."
    sleep 10 # 리소스 생성 대기

    # 서비스 이름 찾기 (Gateway 이름이 포함된 서비스)
    SVC_NAME=$(kubectl get svc -n $NAMESPACE -l gateway.envoyproxy.io/owning-gateway-name=$GW_NAME -o jsonpath='{.items[0].metadata.name}')

    if [ ! -z "$SVC_NAME" ]; then
        echo "🔧 서비스($SVC_NAME) 포트를 30443으로 변경합니다..."
        # 443 -> 30443, 80 -> 30080 강제 패치
        kubectl patch svc $SVC_NAME -n $NAMESPACE --type='merge' -p '{"spec":{"ports":[{"name":"https","port":443,"targetPort":10443,"nodePort":30443},{"name":"http","port":80,"targetPort":10080,"nodePort":30080}]}}'
        echo "✅ 포트 변경 완료."
    else
        echo "⚠️  서비스를 찾지 못해 포트 변경에 실패했습니다. (수동 확인 필요)"
    fi
else
    # LoadBalancer 모드: values.yaml만 적용
    echo "ℹ️  [LoadBalancer Mode] 적용 중..."
    helm upgrade --install strato-gateway-infra $INFRA_CHART $BASE_OPTS
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
if [ "$INSTALL_MODE" == "2" ]; then
    echo "Mode      : NodePort (30443)"
    echo "Check     : netstat -tlpn | grep 30443"
else
    echo "Mode      : LoadBalancer"
fi
echo "========================================================"
kubectl get svc -n $NAMESPACE