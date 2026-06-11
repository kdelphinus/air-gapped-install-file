#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

echo "[계획] 생성된 Kubernetes 오프라인 번들의 uninstall.sh 템플릿입니다."
echo "       다음 단계에서 kubeadm reset 및 잔재 정리 로직을 채웁니다."
