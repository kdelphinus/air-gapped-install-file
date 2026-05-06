#!/bin/bash
set -e
AWS_VERSION="5.30.0"
BASE_DIR="/usr/local/share/tofu-providers"
PROVIDER_DIR="$BASE_DIR/registry.opentofu.org/hashicorp/aws/${AWS_VERSION}/linux_amd64"

mkdir -p "$PROVIDER_DIR"
echo "🔹 Downloading AWS Provider v${AWS_VERSION}..."
curl -fsSL "https://releases.hashicorp.com/terraform-provider-aws/${AWS_VERSION}/terraform-provider-aws_${AWS_VERSION}_linux_amd64.zip" -o aws.zip

unzip -oq aws.zip

mv terraform-provider-aws_v* "$PROVIDER_DIR/"
rm -f aws.zip
echo "✅ AWS Provider Installed."
