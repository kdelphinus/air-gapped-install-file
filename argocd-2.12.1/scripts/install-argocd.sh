#!/bin/bash

# ==================== Config ====================
# Harbor Registry
HARBOR_REGISTRY="harbor.example.com:8443"
HARBOR_PROJECT="example-project"

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
echo " Harbor : ${HARBOR_REGISTRY}/${HARBOR_PROJECT}"
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
ARGOCD_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/argocd"
REDIS_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/redis"
HAPROXY_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/haproxy"

PROTOCOL="http"
[ "$TLS_ENABLED" = "true" ] && PROTOCOL="https"

HELM_SET_ARGS=(
    --set "configs.cm.url=${PROTOCOL}://${DOMAIN}"
    --set "global.image.repository=${ARGOCD_IMAGE}"
    --set "server.image.repository=${ARGOCD_IMAGE}"
    --set "repoServer.image.repository=${ARGOCD_IMAGE}"
    --set "controller.image.repository=${ARGOCD_IMAGE}"
    --set "applicationSet.image.repository=${ARGOCD_IMAGE}"
    --set "notifications.image.repository=${ARGOCD_IMAGE}"
    --set "redis.image.repository=${REDIS_IMAGE}"
    --set "haproxy.image.repository=${HAPROXY_IMAGE}"
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
