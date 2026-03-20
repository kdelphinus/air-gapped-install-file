#!/bin/bash
cd "$(dirname "$0")/.." || exit 1
NAMESPACE="monitoring"
RELEASE_NAME="prometheus"
CHART_PATH="./charts/kube-prometheus-stack"
VALUES_FILE="./values.yaml"

echo "🚀 Installing Monitoring (kube-prometheus-stack)..."
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install $RELEASE_NAME "$CHART_PATH" \
  --namespace $NAMESPACE \
  -f "$VALUES_FILE" \
  --wait
