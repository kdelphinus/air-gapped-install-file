#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

source scripts/lib/common.sh
load_and_validate_config

echo "============================================================"
echo " Kubernetes Offline Builder - download"
echo "============================================================"
print_builder_summary
echo "============================================================"
echo ""

case "$TARGET_OS" in
    ubuntu24.04)
        echo "[계획] Ubuntu 24.04 DEB 수집 로직을 다음 단계에서 구현합니다."
        echo "       - pkgs.k8s.io core:/stable:/${K8S_MINOR}/deb/"
        echo "       - Docker CE repo containerd.io"
        echo "       - apt-rdepends + apt-get download"
        ;;
    *)
        echo "[오류] 현재 골격 단계에서는 ubuntu24.04 만 대상으로 정의되어 있습니다: $TARGET_OS"
        exit 1
        ;;
esac

echo ""
echo "[계획] kubeadm config images list 기반 이미지 수집은 다음 단계에서 구현합니다."
echo "[계획] CNI 매니페스트/이미지 수집은 다음 단계에서 구현합니다."
