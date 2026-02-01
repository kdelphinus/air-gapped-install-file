#!/bin/bash
set -e
HELM_VERSION="v3.13.2"
echo "🔹 Installing Helm ${HELM_VERSION}..."
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o helm.tar.gz
tar -zxvf helm.tar.gz
mv linux-amd64/helm /usr/local/bin/helm
rm -rf linux-amd64 helm.tar.gz
echo "✅ Helm Installed."
