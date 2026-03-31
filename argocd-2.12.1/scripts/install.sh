#!/bin/bash

# Root 권한 체크
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

# 스크립트 위치 기준으로 컴포넌트 루트로 이동 (scripts/ 하위에서 실행해도 경로 안전)
cd "$(dirname "$0")/.." || exit 1

# ==================== Config ====================
# ── 이미지 소스 선택 ──────────────────────────────────────────
echo ""
echo "이미지 소스를 선택하세요:"
echo "  1) Harbor 레지스트리 사용 (사전에 upload_images_to_harbor_v3-lite.sh 실행 필요)"
echo "  2) 로컬 tar 직접 import (Harbor 없음)"
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
        ctr -n k8s.io images import "${tar_file}"
        IMPORT_COUNT=$((IMPORT_COUNT + 1))
    done
    [ "${IMPORT_COUNT}" -eq 0 ] && echo "[경고] ./images/ 에 tar 파일이 없습니다."
    echo "  ${IMPORT_COUNT}개 이미지 import 완료"
    HARBOR_REGISTRY=""
    HARBOR_PROJECT=""
else
    echo "[오류] 1 또는 2를 선택하세요."; exit 1
fi

# Storage: "none" | "nas" | "hostpath"
STORAGE_TYPE="hostpath"

# NAS (NFS) Settings - STORAGE_TYPE="nas" 일 때 사용
NAS_SERVER="192.168.1.50"
NAS_REDIS_PATH="/nas/argocd/redis"
NAS_REPO_PATH="/nas/argocd/repo"

# hostPath Settings - STORAGE_TYPE="hostpath" 일 때 사용
HOSTPATH_REDIS="/data/argocd/redis"
HOSTPATH_REPO="/data/argocd/repo-cache"

# Networking
NODEPORT="30001"
DOMAIN="argocd.devops.internal"   # HTTPRoute hostname, "" 이면 HTTPRoute 미생성
TLS_ENABLED="false"               # "true" | "false" — https/http 결정
GATEWAY_NAME="cmp-gateway"
GATEWAY_NAMESPACE="envoy-gateway-system"
# ================================================

# CoreDNS 호스트 등록 함수 (DOMAIN 설정 시 Pod 내부 DNS 해석을 위해 등록)
add_coredns_host() {
    local ip="$1"
    local domain="$2"
    if kubectl get configmap coredns -n kube-system \
            -o jsonpath='{.data.NodeHosts}' | grep -qw "$domain"; then
        echo "  - CoreDNS: ${domain} 이미 등록됨, 건너뜁니다."
        return 0
    fi
    local new_hosts
    new_hosts="$(kubectl get configmap coredns -n kube-system \
        -o jsonpath='{.data.NodeHosts}')
${ip} ${domain}"
    kubectl get configmap coredns -n kube-system -o json \
        | jq --arg h "$new_hosts" '.data.NodeHosts = $h' \
        | kubectl apply -f -
    echo "  - CoreDNS: ${ip} ${domain} 등록 완료 (15초 내 자동 반영)"
}

NAMESPACE="argocd"
CHART_PATH="./charts/argo-cd"
VALUES_FILE="./values.yaml"
NAS_PV_FILE="./manifests/nas-pv.yaml"

echo "==========================================="
echo " Installing ArgoCD 2.12.1 (Offline)"
echo "==========================================="
echo " Image Source: ${IMAGE_SOURCE} (Harbor: ${HARBOR_REGISTRY}/${HARBOR_PROJECT})"
echo " Storage: ${STORAGE_TYPE}"
echo "==========================================="

# Create namespace if it doesn't exist
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# ---- Storage setup ----
if [ "$STORAGE_TYPE" = "nas" ]; then
    echo ""
    echo ">>> Applying NAS PV/PVC (server: ${NAS_SERVER})"
    sed \
        -e "s|192.168.1.100|${NAS_SERVER}|g" \
        -e "s|/nas/argocd/redis|${NAS_REDIS_PATH}|g" \
        -e "s|/nas/argocd/repo|${NAS_REPO_PATH}|g" \
        "$NAS_PV_FILE" | kubectl apply -f -
fi

# ---- Build helm --set args for Harbor image paths ----
PROTOCOL="http"
[ "$TLS_ENABLED" = "true" ] && PROTOCOL="https"

# Harbor 사용 시에만 이미지 레지스트리/프로젝트 오버라이드
HELM_IMAGE_ARGS=()
if [ "${IMAGE_SOURCE}" = "1" ]; then
    ARGOCD_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/argocd"
    REDIS_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/redis"
    HAPROXY_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/haproxy"
    HELM_IMAGE_ARGS=(
        --set "global.image.repository=${ARGOCD_IMAGE}"
        --set "server.image.repository=${ARGOCD_IMAGE}"
        --set "repoServer.image.repository=${ARGOCD_IMAGE}"
        --set "controller.image.repository=${ARGOCD_IMAGE}"
        --set "applicationSet.image.repository=${ARGOCD_IMAGE}"
        --set "notifications.image.repository=${ARGOCD_IMAGE}"
        --set "redis.image.repository=${REDIS_IMAGE}"
        --set "haproxy.image.repository=${HAPROXY_IMAGE}"
    )
fi

HELM_SET_ARGS=(
    --set "configs.cm.url=${PROTOCOL}://${DOMAIN}"
    "${HELM_IMAGE_ARGS[@]}"
)

# ---- Build helm --set args for Storage ----
if [ "$STORAGE_TYPE" = "nas" ]; then
    HELM_SET_ARGS+=(
        --set "repoServer.volumes[0].name=argocd-repo-cache"
        --set "repoServer.volumes[0].persistentVolumeClaim.claimName=argocd-repo-pvc"
        --set "repoServer.volumeMounts[0].name=argocd-repo-cache"
        --set "repoServer.volumeMounts[0].mountPath=/home/argocd/cmp-server/cache"
        --set "redis.volumes[0].name=redis-data"
        --set "redis.volumes[0].persistentVolumeClaim.claimName=argocd-redis-pvc"
        --set "redis.volumeMounts[0].name=redis-data"
        --set "redis.volumeMounts[0].mountPath=/data"
    )
elif [ "$STORAGE_TYPE" = "hostpath" ]; then
    HELM_SET_ARGS+=(
        --set "repoServer.volumes[0].name=argocd-repo-cache"
        --set "repoServer.volumes[0].hostPath.path=${HOSTPATH_REPO}"
        --set "repoServer.volumes[0].hostPath.type=DirectoryOrCreate"
        --set "repoServer.volumeMounts[0].name=argocd-repo-cache"
        --set "repoServer.volumeMounts[0].mountPath=/home/argocd/cmp-server/cache"
        --set "redis.volumes[0].name=redis-data"
        --set "redis.volumes[0].hostPath.path=${HOSTPATH_REDIS}"
        --set "redis.volumes[0].hostPath.type=DirectoryOrCreate"
        --set "redis.volumeMounts[0].name=redis-data"
        --set "redis.volumeMounts[0].mountPath=/data"
    )
fi

# ---- Install ----
if [ -d "$CHART_PATH" ]; then
    helm upgrade --install argocd "$CHART_PATH" \
        -n "$NAMESPACE" \
        -f "$VALUES_FILE" \
        "${HELM_SET_ARGS[@]}"
else
    echo "Error: Helm chart directory '$CHART_PATH' not found."
    exit 1
fi

# ---- NodePort Service ----
echo ""
echo ">>> Applying NodePort service (port: ${NODEPORT})"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: argocd-server-nodeport
  namespace: ${NAMESPACE}
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: argocd-server
  ports:
    - name: http
      port: 80
      targetPort: 8080
      nodePort: ${NODEPORT}
EOF

# ---- HTTPRoute ----
if [ -n "$DOMAIN" ]; then
    echo ""
    echo ">>> Applying HTTPRoute (hostname: ${DOMAIN})"
    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-route
  namespace: ${NAMESPACE}
spec:
  parentRefs:
    - name: ${GATEWAY_NAME}
      namespace: ${GATEWAY_NAMESPACE}
  hostnames:
    - "${DOMAIN}"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: argocd-server
          port: 80
EOF
else
    echo ""
    echo ">>> DOMAIN not set, skipping HTTPRoute"
fi

# ---- CoreDNS 등록 ----
if [ -n "$DOMAIN" ]; then
    echo ""
    read -p "❓ ${DOMAIN} 이 DNS 서버에 이미 등록되어 있나요? (y/n): " DNS_REGISTERED
    if [[ "$DNS_REGISTERED" == "y" || "$DNS_REGISTERED" == "Y" ]]; then
        echo "  - DNS 서버에 등록됨 — CoreDNS 등록을 건너뜁니다."
    else
        echo ">>> CoreDNS에 ${DOMAIN} 등록 중..."
        NODE_IP=$(kubectl get nodes \
            -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
        add_coredns_host "$NODE_IP" "$DOMAIN"
    fi
else
    echo ""
    echo ">>> DOMAIN 미설정 — CoreDNS 등록을 건너뜁니다. (NodePort로만 접속)"
fi

echo ""
echo "ArgoCD installation command completed."
echo "Check pods status using: kubectl get pods -n $NAMESPACE"

if [ -n "$DOMAIN" ]; then
    echo ""
    echo "==========================================="
    echo " [주의] 클라이언트 hosts 등록 필요"
    echo "==========================================="
    echo " 도메인으로 접속하려면 접속할 PC의 hosts 파일에 아래 항목을 추가하세요."
    echo ""
    echo "   <GATEWAY_IP>  ${DOMAIN}"
    echo ""
    echo " - Windows: C:\\Windows\\System32\\drivers\\etc\\hosts"
    echo " - Linux/Mac: /etc/hosts"
    echo "==========================================="
fi
