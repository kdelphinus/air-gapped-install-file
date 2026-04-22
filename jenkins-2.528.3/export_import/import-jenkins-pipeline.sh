#!/bin/bash
set -e

# ==========================================
# [Configuration]
# ==========================================
JENKINS_URL="http://jenkins.test.com"
USER="admin"
PASS="Nga55UkalnSiGbaBIsurX6"
SOURCE_DIR="jenkins_export_20260223"
COOKIE_FILE="jenkins_cookie_jar.txt"
# ==========================================

echo "🚀 Starting Jenkins No-Java Import..."
echo "Target: $JENKINS_URL"

# 1. Authenticate & Fetch Crumb (보안 강화 대응 버전)
echo "[1/3] Authenticating..."

# XML 전체를 받아온 후 sed로 crumb와 field를 추출합니다.
CRUMB_XML=$(curl -s -u "$USER:$PASS" --cookie-jar "$COOKIE_FILE" "$JENKINS_URL/crumbIssuer/api/xml")

CRUMB_VALUE=$(echo $CRUMB_XML | sed 's/.*<crumb>\([^<]*\)<\/crumb>.*/\1/')
CRUMB_FIELD=$(echo $CRUMB_XML | sed 's/.*<crumbRequestField>\([^<]*\)<\/crumbRequestField>.*/\1/')

if [ -n "$CRUMB_VALUE" ] && [ "$CRUMB_VALUE" != "$CRUMB_XML" ]; then
    CRUMB_HEADER="-H $CRUMB_FIELD:$CRUMB_VALUE"
    echo "✅ Authenticated (Crumb found)"
else
    CRUMB_HEADER=""
    echo "⚠️  Authenticated (No Crumb found or CSRF disabled)"
fi

# 2. Sort files by path length (Create folders first)
echo "[2/3] Sorting job execution order..."
find "$SOURCE_DIR" -name "*.xml" | awk '{ print length, $0 }' | sort -n | cut -d" " -f2- > sorted_list.txt
TOTAL_COUNT=$(wc -l < sorted_list.txt)

# 3. Import Loop
echo "[3/3] Importing $TOTAL_COUNT jobs..."
CURRENT=0

while read -r XML_FILE; do
    CURRENT=$((CURRENT+1))

    # Extract Paths
    RELATIVE_PATH="${XML_FILE#$SOURCE_DIR/}"
    FULL_PATH="${RELATIVE_PATH%.xml}"
    JOB_NAME=$(basename "$FULL_PATH")
    DIR_NAME=$(dirname "$FULL_PATH")

    # Construct URL based on folder structure
    if [ "$DIR_NAME" == "." ]; then
        URL_PATH="job/$JOB_NAME"
        CREATE_URL="$JENKINS_URL/createItem?name=$JOB_NAME"
    else
        PATH_CONV=$(echo "$DIR_NAME" | sed 's/\//\/job\//g')
        URL_PATH="job/$PATH_CONV/job/$JOB_NAME"
        CREATE_URL="$JENKINS_URL/job/$PATH_CONV/createItem?name=$JOB_NAME"
    fi

    # http_code 추출
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "$USER:$PASS" --cookie "$COOKIE_FILE" "$JENKINS_URL/$URL_PATH/config.xml")

    if [ "$HTTP_CODE" -eq 200 ]; then
        # UPDATE
        curl -s -X POST "$JENKINS_URL/$URL_PATH/config.xml" \
             -u "$USER:$PASS" --cookie "$COOKIE_FILE" $CRUMB_HEADER \
             -H "Content-Type: application/xml" --data-binary "@$XML_FILE" -o /dev/null
        echo "[$CURRENT/$TOTAL_COUNT] ✅ Updated: $FULL_PATH"
    else
        # CREATE
        curl -s -X POST "$CREATE_URL" \
             -u "$USER:$PASS" --cookie "$COOKIE_FILE" $CRUMB_HEADER \
             -H "Content-Type: application/xml" --data-binary "@$XML_FILE" -o /dev/null
        echo "[$CURRENT/$TOTAL_COUNT] ✨ Created: $FULL_PATH"
    fi

done < sorted_list.txt

rm -f sorted_list.txt "$COOKIE_FILE"
echo "---------------------------------------------------"
echo "🎉 All pipelines have been migrated successfully!"
