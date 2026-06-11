#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

DRY_RUN=0

if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
fi

source scripts/lib/common.sh
load_and_validate_config

echo "============================================================"
echo " Kubernetes Offline Builder - build bundle"
echo "============================================================"
print_builder_summary
echo "  Bundle directory : ${STAGING_DIR}"
echo "  Archive          : ${ARCHIVE_PATH}"
echo "============================================================"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] 번들 경로 계산만 수행했습니다."
    exit 0
fi

mkdir -p "$STAGING_DIR"

echo "[1/4] 번들 디렉터리 구조 생성..."
mkdir -p \
    "$STAGING_DIR/scripts" \
    "$STAGING_DIR/k8s/debs" \
    "$STAGING_DIR/k8s/binaries" \
    "$STAGING_DIR/k8s/images" \
    "$STAGING_DIR/k8s/utils" \
    "$STAGING_DIR/k8s/charts"

echo "[2/4] 번들 스크립트 템플릿 복사..."
cp -f templates/scripts/install.sh "$STAGING_DIR/scripts/install.sh"
cp -f templates/scripts/uninstall.sh "$STAGING_DIR/scripts/uninstall.sh"
cp -f templates/scripts/wsl2_prep.sh "$STAGING_DIR/scripts/wsl2_prep.sh"
chmod +x "$STAGING_DIR/scripts/"*.sh

echo "[3/4] 번들 설정 파일 생성..."
sed \
    -e "s|{{K8S_VERSION}}|${K8S_VERSION}|g" \
    -e "s|{{TARGET_OS}}|${TARGET_OS}|g" \
    -e "s|{{ARCH}}|${ARCH}|g" \
    -e "s|{{CONTAINER_RUNTIME}}|${CONTAINER_RUNTIME}|g" \
    -e "s|{{CONTAINERD_VERSION}}|${CONTAINERD_VERSION}|g" \
    -e "s|{{CNI_CHOICE}}|${CNI_CHOICE}|g" \
    -e "s|{{CALICO_VERSION}}|${CALICO_VERSION}|g" \
    -e "s|{{CALICO_INSTALL_METHOD}}|${CALICO_INSTALL_METHOD}|g" \
    -e "s|{{CILIUM_VERSION}}|${CILIUM_VERSION}|g" \
    -e "s|{{ENABLE_HUBBLE}}|${ENABLE_HUBBLE}|g" \
    -e "s|{{MTU_VALUE}}|${MTU_VALUE}|g" \
    templates/bundle-install.conf > "$STAGING_DIR/install.conf"

cat > "$STAGING_DIR/README.md" <<EOF
# Kubernetes ${K8S_VERSION} Offline Bundle (${TARGET_OS})

이 디렉터리는 k8s-offline-builder 에 의해 생성된 폐쇄망 설치 번들입니다.

## 구성

- Kubernetes: ${K8S_VERSION}
- Target OS: ${TARGET_OS}
- Runtime: ${CONTAINER_RUNTIME} (${CONTAINERD_VERSION})
- CNI: ${CNI_CHOICE}

## 설치

\`\`\`bash
sudo ./scripts/install.sh
\`\`\`

현재 번들 설치 스크립트는 Ubuntu 24.04 + containerd + Calico/Cilium 조합의 kubeadm init/join 설치를 지원합니다.
Rocky/RHEL 계열은 후속 구현 대상입니다.
EOF

echo "[4/4] tar.gz 패키징..."
mkdir -p "$BUNDLE_OUTPUT_DIR"
tar -czf "$ARCHIVE_PATH" -C "$BUNDLE_OUTPUT_DIR" "$BUNDLE_NAME"

echo "  → 번들 생성 완료: ${ARCHIVE_PATH}"
