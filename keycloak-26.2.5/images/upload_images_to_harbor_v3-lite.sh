#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

read -r -p "Harbor 주소 (예: 192.168.1.10:30002): " HARBOR_REGISTRY
read -r -p "Harbor 프로젝트 (예: oss): " HARBOR_PROJECT
read -r -p "Harbor HTTPS 사용 여부 (y/N): " USE_HTTPS
read -r -p "Harbor 사용자 (기본값: admin): " HARBOR_USER
HARBOR_USER="${HARBOR_USER:-admin}"
read -r -s -p "Harbor 비밀번호: " HARBOR_PASSWORD
echo

PUSH_OPTIONS=(--platform linux/amd64)
if [[ ! "$USE_HTTPS" =~ ^[Yy]$ ]]; then
  PUSH_OPTIONS+=(--plain-http)
fi

declare -A IMAGES=(
  ["images/keycloak-26.2.5.tar"]="quay.io/keycloak/keycloak:26.2.5"
  ["images/postgres-16.9.tar"]="docker.io/library/postgres:16.9"
)

for archive in "${!IMAGES[@]}"; do
  source_image="${IMAGES[$archive]}"
  target_image="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${source_image##*/}"
  [[ -f "$archive" ]] || { echo "[오류] 이미지 파일이 없습니다: $archive"; exit 1; }
  sudo ctr -n k8s.io images import --all-platforms "$archive"
  sudo ctr -n k8s.io images tag "$source_image" "$target_image"
  sudo ctr -n k8s.io images push "${PUSH_OPTIONS[@]}" --user "${HARBOR_USER}:${HARBOR_PASSWORD}" "$target_image"
done

echo "[완료] Harbor 업로드가 완료되었습니다."
