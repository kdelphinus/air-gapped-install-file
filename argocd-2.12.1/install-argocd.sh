#!/bin/bash

# ==================== Config ====================
# Harbor Registry
HARBOR_REGISTRY="harbor-product.strato.co.kr:8443"
HARBOR_PROJECT="strato-solution-baseimage"

# Storage: "none" | "nas" | "hostpath"
STORAGE_TYPE="hostpath"

# NAS (NFS) Settings - STORAGE_TYPE="nas" 일 때 사용
NAS_SERVER="192.168.1.50"
NAS_REDIS_PATH="/nas/argocd/redis"
NAS_REPO_PATH="/nas/argocd/repo"

# hostPath Settings - STORAGE_TYPE="hostpath" 일 때 사용
HOSTPATH_REDIS="/data/argocd/redis"
HOSTPATH_REPO="/data/argocd/repo-cache"
# ================================================

NAMESPACE="argocd"
CHART_PATH="./argo-cd"
VALUES_FILE="./values.yaml"
NAS_PV_FILE="./nas-pv.yaml"

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

HELM_SET_ARGS=(
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
        --set "repoServer.volumeMounts[0].mountPath=/home/argocd/cmp-server/plugins"
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
        --set "repoServer.volumeMounts[0].mountPath=/home/argocd/cmp-server/plugins"
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

echo ""
echo "ArgoCD installation command completed."
echo "Check pods status using: kubectl get pods -n $NAMESPACE"
