#!/bin/bash
set -e # 에러 발생 시 즉시 중단

# ==========================================
# [사용자 설정] 정보 수정
# ==========================================
JENKINS_URL="http://localhost:8090"
JENKINS_USER="admin"
JENKINS_PASS='password' # 본인의 비밀번호로 변경하세요
# ==========================================

# 저장할 디렉토리 설정
EXPORT_DIR="jenkins_export_$(date +%Y%m%d)"
CLI_JAR="jenkins-cli.jar"

echo "---------------------------------------------------"
echo "🚀 Jenkins Pipeline Export (Fixed Stdin Issue)"
echo "Target: $JENKINS_URL"
echo "---------------------------------------------------"

mkdir -p "$EXPORT_DIR"
cd "$EXPORT_DIR"

# 1. CLI 다운로드 (없으면)
if [ ! -f "$CLI_JAR" ]; then
    echo "[1/4] Jenkins CLI 다운로드..."
    wget --no-check-certificate -q "$JENKINS_URL/jnlpJars/jenkins-cli.jar" -O $CLI_JAR
fi

# 2. 리스트 스캔
echo "[2/4] Job 리스트 스캔..."
java -jar $CLI_JAR -s "$JENKINS_URL" -auth "$JENKINS_USER:$JENKINS_PASS" -noCertificateCheck list-jobs > job_list.txt

JOB_COUNT=$(wc -l < job_list.txt)
echo "🔍 총 ${JOB_COUNT}개의 작업을 발견했습니다."

# 3. 루프 실행 (수정된 부분)
echo "[3/4] XML 추출 시작..."

while read -r JOB_NAME; do
    CLEAN_NAME=$(echo "$JOB_NAME" | tr -d '\r')
    
    DIR_NAME=$(dirname "$CLEAN_NAME")
    if [ "$DIR_NAME" != "." ]; then
        mkdir -p "$DIR_NAME"
    fi

    echo "  Exporting: $CLEAN_NAME"
    
    # [핵심 수정] 끝에 < /dev/null 추가하여 stdin 가로채기 방지
    java -jar $CLI_JAR -s "$JENKINS_URL" \
         -auth "$JENKINS_USER:$JENKINS_PASS" \
         -noCertificateCheck \
         get-job "$CLEAN_NAME" < /dev/null > "${CLEAN_NAME}.xml"

done < job_list.txt

# 4. 압축
cd ..
echo "[4/4] 압축 중..."
tar -czf "${EXPORT_DIR}.tar.gz" "$EXPORT_DIR"

echo "✅ 완료! 파일 개수를 다시 확인해보세요."
