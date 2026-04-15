#!/bin/bash
cd "$(dirname "$0")/.." || exit 1
set -e

# jq 존재 여부 확인
if ! command -v jq &> /dev/null; then
    echo "[ERROR] 'jq' 명령어를 찾을 수 없습니다. jq를 설치하세요."
    exit 1
fi

PROJECT="strato-solution-install-goe"
HARBOR_ADDR="harbor.example.com:8443"
HARBOR_HTTP="https"
HARBOR_URL="$HARBOR_HTTP://$HARBOR_ADDR"
#USER=""
#PASS=""

PROJECTS=$(curl -s "$HARBOR_URL/api/v2.0/projects?page_size=100" | jq -r '.[].name')
#echo "projects: $PROJECTS"

echo "* Repository"
for PRJ in $PROJECTS; do
  REPOS=$(curl -s "$HARBOR_URL/api/v2.0/projects/$PRJ/repositories?page_size=100" | jq -r '.[].name')
  #echo "repositories: $REPOS"
  
  echo ">>> Project: $PRJ"
  for RP in $REPOS; do
    echo "   - $RP"
  done

done

