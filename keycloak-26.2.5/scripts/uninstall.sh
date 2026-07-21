#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
helm uninstall keycloak -n keycloak --wait=false 2>/dev/null || true
kubectl delete -f ./manifests/httproute.yaml --ignore-not-found=true 2>/dev/null || true
echo "Keycloak Helm 리소스만 삭제했습니다. PostgreSQL PVC와 Secret은 보존됩니다."
