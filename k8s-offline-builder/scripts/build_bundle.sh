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

echo "[계획] 다음 단계에서 번들 템플릿 복사와 tar.gz 패키징을 구현합니다."
echo "       현재는 산출물 디렉터리만 생성했습니다: ${STAGING_DIR}"
