#!/bin/bash
cd "$(dirname "$0")/.." || exit 1
NAMESPACE="nexus"
RELEASE_NAME="nexus"
CHART_PATH="./charts/nexus-repository-manager"
VALUES_FILE="./values.yaml"

echo "🚀 Installing Nexus Repository Manager..."
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install $RELEASE_NAME "$CHART_PATH" \
  --namespace $NAMESPACE \
  -f "$VALUES_FILE" \
  --wait
