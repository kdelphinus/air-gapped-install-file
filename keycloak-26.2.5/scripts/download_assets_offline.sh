#!/usr/bin/env bash
set -euo pipefail

# 인터넷 연결이 가능한 준비 서버에서만 실행합니다.
cd "$(dirname "$0")/.."
mkdir -p images

IMAGES=(
  "quay.io/keycloak/keycloak:26.2.5"
  "docker.io/library/postgres:16.9"
)

for image in "${IMAGES[@]}"; do
  archive="images/$(basename "${image%%:*}")-${image##*:}.tar"
  echo "다운로드: $image"
  sudo ctr images pull --platform linux/amd64 "$image"
  sudo ctr images export --platform linux/amd64 "$archive" "$image"
done

echo "[완료] images/ 디렉터리의 tar 파일을 폐쇄망으로 반입하십시오."
