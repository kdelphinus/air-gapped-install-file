#!/bin/bash
set -e
OPENSTACK_VERSION="1.53.0"
BASE_DIR="/usr/local/share/tofu-providers"
PROVIDER_DIR="$BASE_DIR/registry.opentofu.org/terraform-provider-openstack/openstack/${OPENSTACK_VERSION}/linux_amd64"

mkdir -p "$PROVIDER_DIR"
echo "🔹 Downloading OpenStack Provider v${OPENSTACK_VERSION}..."
curl -fsSL "https://github.com/terraform-provider-openstack/terraform-provider-openstack/releases/download/v${OPENSTACK_VERSION}/terraform-provider-openstack_${OPENSTACK_VERSION}_linux_amd64.zip" -o openstack.zip

unzip -oq openstack.zip

mv terraform-provider-openstack_v* "$PROVIDER_DIR/"
rm -f openstack.zip
echo "✅ OpenStack Provider Installed."
