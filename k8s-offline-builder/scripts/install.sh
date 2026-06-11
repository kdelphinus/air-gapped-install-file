#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

echo "[안내] k8s-offline-builder 는 설치 대상 컴포넌트가 아니라 오프라인 번들 생성기입니다."
echo "       온라인 호스트에서는 다음 순서로 실행하세요:"
echo ""
echo "       sudo ./scripts/download.sh"
echo "       ./scripts/build_bundle.sh"
echo ""
echo "       폐쇄망 설치는 생성된 bundles/k8s-<version>-<os>/ 내부 scripts/install.sh 를 사용합니다."
