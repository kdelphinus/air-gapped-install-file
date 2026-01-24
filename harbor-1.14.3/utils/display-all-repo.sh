#!/bin/bash

PROJECT="strato-solution-install-goe"
HARBOR_ADDR="harbor-product.strato.co.kr:8443"
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

