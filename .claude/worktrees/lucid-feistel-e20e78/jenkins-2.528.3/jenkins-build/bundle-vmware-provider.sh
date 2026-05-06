#!/bin/bash
set -e
VSPHERE_VERSION="2.6.1"
BASE_DIR="/usr/local/share/tofu-providers"
PROVIDER_DIR="$BASE_DIR/registry.opentofu.org/hashicorp/vsphere/${VSPHERE_VERSION}/linux_amd64"

mkdir -p "$PROVIDER_DIR"
echo "🔹 Downloading vSphere Provider v${VSPHERE_VERSION}..."
curl -fsSL "https://releases.hashicorp.com/terraform-provider-vsphere/${VSPHERE_VERSION}/terraform-provider-vsphere_${VSPHERE_VERSION}_linux_amd64.zip" -o vsphere.zip

echo "🔹 Unzipping..."
unzip -oq vsphere.zip

mv terraform-provider-vsphere_v* "$PROVIDER_DIR/"
rm -f vsphere.zip
echo "✅ VMware Provider Installed."
