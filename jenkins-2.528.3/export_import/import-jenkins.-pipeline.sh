#!/bin/bash
set -e

# ==========================================
# [NEW ENVIRONMENT] 폐쇄망 젠킨스 정보 입력
# ==========================================
NEW_JENKINS_URL="http://localhost:8080" # 포트포워딩 또는 내부 IP
NEW_USER="admin"
NEW_PASS='new_password'
# 가져온 백업 폴더 이름 (압축 푼 폴더명)
SOURCE_DIR="jenkins_export_20260124"
# ==========================================

CLI_JAR="jenkins-cli.jar"

echo "---------------------------------------------------"
echo "🚀 Jenkins Pipeline Bulk Import System"
echo "Target: $NEW_JENKINS_URL"
echo "Source: $SOURCE_DIR"
echo "---------------------------------------------------"

# 1. CLI 다운로드 (새 서버에서 받아야 버전이 맞음)
if [ ! -f "$CLI_JAR" ]; then
    echo "[1/3] Downloading Jenkins CLI from new server..."
    wget --no-check-certificate -q "$NEW_JENKINS_URL/jnlpJars/jenkins-cli.jar" -O $CLI_JAR
fi

# 2. 파일 리스트 정렬 (가장 중요한 부분)
# 폴더를 먼저 만들어야 하므로, '경로 길이가 짧은 순서'대로 정렬합니다.
# 예: 'Group.xml'이 'Group/Project.xml'보다 먼저 실행되게 함.
echo "[2/3] Sorting job execution order..."
find "$SOURCE_DIR" -name "*.xml" | awk '{ print length, $0 }' | sort -n | cut -d" " -f2- > sorted_import_list.txt

TOTAL_COUNT=$(wc -l < sorted_import_list.txt)
echo "📦 Total jobs to import: $TOTAL_COUNT"

# 3. Import 실행
echo "[3/3] Starting Batch Import..."
CURRENT=0

while read -r XML_FILE; do
    CURRENT=$((CURRENT+1))
    
    # 파일 경로에서 Job 이름 추출
    # 예: jenkins_export/FolderA/JobB.xml -> FolderA/JobB
    # 1) 앞의 소스 디렉토리 제거
    RELATIVE_PATH="${XML_FILE#$SOURCE_DIR/}"
    # 2) 뒤의 .xml 확장자 제거
    JOB_NAME="${RELATIVE_PATH%.xml}"
    
    echo "[$CURRENT/$TOTAL_COUNT] Creating: $JOB_NAME"
    
    # 이미 존재하는지 확인 (Update) 또는 생성 (Create)
    # create-job은 이미 있으면 에러나므로, update-job을 시도하거나 에러를 무시하는 전략 사용
    
    # 전략: create-job을 시도하고, 'already exists' 에러가 나면 update-job으로 덮어씀
    set +e # 일시적으로 에러 무시 허용
    
    java -jar $CLI_JAR -s "$NEW_JENKINS_URL" -auth "$NEW_USER:$NEW_PASS" -noCertificateCheck create-job "$JOB_NAME" < "$XML_FILE" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo "   ✅ Created successfully."
    else
        echo "   ⚠️  Already exists. Updating configuration..."
        java -jar $CLI_JAR -s "$NEW_JENKINS_URL" -auth "$NEW_USER:$NEW_PASS" -noCertificateCheck update-job "$JOB_NAME" < "$XML_FILE"
    fi
    
    set -e # 에러 감지 다시 켜기

done < sorted_import_list.txt

echo "---------------------------------------------------"
echo "🎉 All pipelines have been migrated successfully!"
echo "---------------------------------------------------"