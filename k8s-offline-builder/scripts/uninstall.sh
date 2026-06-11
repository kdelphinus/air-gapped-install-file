#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

CONF_FILE="${CONF_FILE:-install.conf}"

if [ -f "$CONF_FILE" ]; then
    source "$CONF_FILE"
else
    BUNDLE_OUTPUT_DIR="bundles"
fi

echo "[안내] 이 스크립트는 빌더가 생성한 staging 산출물을 정리하기 위한 자리입니다."
echo "       실제 삭제 로직은 다음 단계에서 --yes 옵션과 함께 구현합니다."
echo "       대상 산출물 루트: ${BUNDLE_OUTPUT_DIR}"
