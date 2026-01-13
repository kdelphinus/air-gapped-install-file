#!/bin/bash
set -e
KUBE_VERSION="v1.28.4"
echo "🔹 Installing kubectl ${KUBE_VERSION}..."
curl -fsSL "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl
chmod +x /usr/local/bin/kubectl
echo "✅ Kubectl Installed."
