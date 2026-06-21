#!/bin/bash

cd "$(dirname "$0")/.." || exit 1

set -euo pipefail

find_binary() {
    local name=$1
    local path
    path=$(command -v "$name" 2>/dev/null || true)
    echo "${path:-$name}"
}

KUBECTL=$(find_binary kubectl)
HELM=$(find_binary helm)

NAMESPACE="${NAMESPACE:-gatekeeper-system}"
RELEASE="${RELEASE:-gatekeeper}"
CONF_FILE="./install.conf"

if [ -f "$CONF_FILE" ]; then
    source "$CONF_FILE"
fi

echo "Removing Gatekeeper Helm release..."
$HELM uninstall "$RELEASE" -n "$NAMESPACE" --wait=false 2>/dev/null || true

echo "Removing Gatekeeper webhook configurations..."
$KUBECTL delete validatingwebhookconfiguration gatekeeper-validating-webhook-configuration \
    --ignore-not-found=true 2>/dev/null || true
$KUBECTL delete mutatingwebhookconfiguration gatekeeper-mutating-webhook-configuration \
    --ignore-not-found=true 2>/dev/null || true

read -r -p "Delete namespace ${NAMESPACE}? (y/N): " DELETE_NS
if [[ "$DELETE_NS" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    $KUBECTL delete ns "$NAMESPACE" --ignore-not-found=true --timeout=30s || true
fi

read -r -p "Delete install.conf? (y/N): " DELETE_CONF
if [[ "$DELETE_CONF" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    rm -f "$CONF_FILE"
fi

echo "Gatekeeper uninstall completed."
