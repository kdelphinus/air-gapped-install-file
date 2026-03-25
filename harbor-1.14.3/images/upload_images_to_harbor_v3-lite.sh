#!/bin/bash
# 실제 스크립트는 scripts/ 에 위치합니다. 이 파일은 호환성을 위한 wrapper입니다.
exec "$(dirname "$0")/../scripts/upload_images_to_harbor_v3-lite.sh" "$@"
