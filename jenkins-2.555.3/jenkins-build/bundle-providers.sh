#!/bin/bash
set -e

# 인자 파싱
PROVIDERS="${1:-aws}"
BASE_DIR="/usr/local/share/tofu-providers"

echo "===================================================="
echo " 🛠️  OpenTofu Providers & Tools Bundle Script"
echo "===================================================="
echo "🔹 Target CSP Providers: $PROVIDERS"

# 1. 공통 툴 설치 (Kubectl & Helm)
KUBE_VERSION="v1.28.4"
HELM_VERSION="v3.13.2"

echo ""
echo "🔹 [1/2] Installing base DevOps tools (kubectl, helm)..."
# Kubectl 설치
echo "   → Installing kubectl ${KUBE_VERSION}..."
curl -fsSL "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl
chmod +x /usr/local/bin/kubectl
echo "   ✅ Kubectl Installed."

# Helm 설치
echo "   → Installing Helm ${HELM_VERSION}..."
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tar.gz
tar -zxf /tmp/helm.tar.gz -C /tmp/
mv /tmp/linux-amd64/helm /usr/local/bin/helm
rm -rf /tmp/linux-amd64 /tmp/helm.tar.gz
echo "   ✅ Helm Installed."

# 2. CSP 프로바이더 다운로드 및 매핑
echo ""
echo "🔹 [2/2] Downloading CSP Providers..."
IFS=', ' read -r -a CSP_ARRAY <<< "$PROVIDERS"

for csp in "${CSP_ARRAY[@]}"; do
    csp=$(echo "$csp" | tr '[:upper:]' '[:lower:]' | xargs)
    [ -z "$csp" ] && continue

    case "$csp" in
        aws)
            AWS_VERSION="5.30.0"
            PROVIDER_DIR="$BASE_DIR/registry.opentofu.org/hashicorp/aws/${AWS_VERSION}/linux_amd64"
            mkdir -p "$PROVIDER_DIR"
            echo "   → Downloading AWS Provider v${AWS_VERSION}..."
            curl -fsSL "https://releases.hashicorp.com/terraform-provider-aws/${AWS_VERSION}/terraform-provider-aws_${AWS_VERSION}_linux_amd64.zip" -o /tmp/aws.zip
            unzip -oq /tmp/aws.zip -d /tmp/aws-extracted
            mv /tmp/aws-extracted/terraform-provider-aws_v* "$PROVIDER_DIR/"
            rm -rf /tmp/aws.zip /tmp/aws-extracted
            echo "   ✅ AWS Provider Installed."
            ;;
        azure|azurerm)
            AZURE_VERSION="3.85.0"
            PROVIDER_DIR="$BASE_DIR/registry.opentofu.org/hashicorp/azurerm/${AZURE_VERSION}/linux_amd64"
            mkdir -p "$PROVIDER_DIR"
            echo "   → Downloading AzureRM Provider v${AZURE_VERSION}..."
            curl -fsSL "https://releases.hashicorp.com/terraform-provider-azurerm/${AZURE_VERSION}/terraform-provider-azurerm_${AZURE_VERSION}_linux_amd64.zip" -o /tmp/azure.zip
            unzip -oq /tmp/azure.zip -d /tmp/azure-extracted
            mv /tmp/azure-extracted/terraform-provider-azurerm_v* "$PROVIDER_DIR/"
            rm -rf /tmp/azure.zip /tmp/azure-extracted
            echo "   ✅ Azure Provider Installed."
            ;;
        vmware|vsphere)
            VMWARE_VERSION="2.6.0"
            PROVIDER_DIR="$BASE_DIR/registry.opentofu.org/hashicorp/vsphere/${VMWARE_VERSION}/linux_amd64"
            mkdir -p "$PROVIDER_DIR"
            echo "   → Downloading VMware vSphere Provider v${VMWARE_VERSION}..."
            curl -fsSL "https://releases.hashicorp.com/terraform-provider-vsphere/${VMWARE_VERSION}/terraform-provider-vsphere_${VMWARE_VERSION}_linux_amd64.zip" -o /tmp/vmware.zip
            unzip -oq /tmp/vmware.zip -d /tmp/vmware-extracted
            mv /tmp/vmware-extracted/terraform-provider-vsphere_v* "$PROVIDER_DIR/"
            rm -rf /tmp/vmware.zip /tmp/vmware-extracted
            echo "   ✅ VMware Provider Installed."
            ;;
        openstack)
            OPENSTACK_VERSION="1.53.0"
            PROVIDER_DIR="$BASE_DIR/registry.opentofu.org/terraform-provider-openstack/openstack/${OPENSTACK_VERSION}/linux_amd64"
            mkdir -p "$PROVIDER_DIR"
            echo "   → Downloading OpenStack Provider v${OPENSTACK_VERSION}..."
            curl -fsSL "https://github.com/terraform-provider-openstack/terraform-provider-openstack/releases/download/v${OPENSTACK_VERSION}/terraform-provider-openstack_${OPENSTACK_VERSION}_linux_amd64.zip" -o /tmp/openstack.zip
            unzip -oq /tmp/openstack.zip -d /tmp/openstack-extracted
            mv /tmp/openstack-extracted/terraform-provider-openstack_v* "$PROVIDER_DIR/"
            rm -rf /tmp/openstack.zip /tmp/openstack-extracted
            echo "   ✅ OpenStack Provider Installed."
            ;;
        *)
            echo "   ⚠️  알 수 없는 CSP 프로바이더명입니다. 건너뜁니다: $csp"
            ;;
    esac
done

echo ""
echo "🎉 [Completed] All tools and providers are set up."
