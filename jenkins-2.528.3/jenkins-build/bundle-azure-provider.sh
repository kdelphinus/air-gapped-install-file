#!/bin/bash
set -e
AZURE_VERSION="3.85.0"
BASE_DIR="/usr/local/share/tofu-providers"
PROVIDER_DIR="$BASE_DIR/registry.opentofu.org/hashicorp/azurerm/${AZURE_VERSION}/linux_amd64"

mkdir -p "$PROVIDER_DIR"
echo "🔹 Downloading AzureRM Provider v${AZURE_VERSION}..."
curl -fsSL "https://releases.hashicorp.com/terraform-provider-azurerm/${AZURE_VERSION}/terraform-provider-azurerm_${AZURE_VERSION}_linux_amd64.zip" -o azure.zip

unzip -oq azure.zip

mv terraform-provider-azurerm_v* "$PROVIDER_DIR/"
rm -f azure.zip
echo "✅ Azure Provider Installed."
