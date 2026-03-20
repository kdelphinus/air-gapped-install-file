#!/bin/bash
cd "$(dirname "$0")/.." || exit 1
NAMESPACE="velero"
RELEASE_NAME="velero"
CHART_PATH="./charts/velero"
VALUES_FILE="./values.yaml"

echo "🚀 Installing Velero..."
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install $RELEASE_NAME "$CHART_PATH" \
  --namespace $NAMESPACE \
  -f "$VALUES_FILE" \
  --wait
