#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

CONF_FILE="${CONF_FILE:-install.conf}"

if [ -f "$CONF_FILE" ]; then
    while IFS='=' read -r key value; do
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value:-}"
        value="${value%%#*}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "$value" == \"*\" && "$value" == *\" ]]; then
            value="${value:1:${#value}-2}"
        fi
        [ "$key" = "BUNDLE_OUTPUT_DIR" ] && BUNDLE_OUTPUT_DIR="$value"
    done < "$CONF_FILE"
else
    BUNDLE_OUTPUT_DIR="bundles"
fi

echo "[안내] 이 스크립트는 빌더가 생성한 staging 산출물을 정리하기 위한 자리입니다."
echo "       번들 산출물은 삭제 전 내용을 확인한 뒤 수동으로 정리하세요."
echo "       대상 산출물 루트: ${BUNDLE_OUTPUT_DIR}"
