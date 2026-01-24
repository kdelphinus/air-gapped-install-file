> 검증 필요


# 📘 Jenkins Migration: All-in-One Guide

## 📋 워크플로우 개요

1. **Export (완료됨):** 구망에서 XML 추출 (`jenkins_export_날짜.tar.gz`)
2. **Transform (필수):** 로컬 PC에서 XML 내부의 IP/도메인/ID 변경
3. **Transfer:** USB/보안전송을 통해 폐쇄망 서버로 파일 이동
4. **Import:** 폐쇄망 Jenkins(K8s)에 자동 주입

---

## Phase 1. Export (추출) - [완료됨/참고용]

*이미 완료하신 단계입니다. 나중을 위해 최종 성공한 코드를 기록해둡니다.*

<details>
<summary>🔻 (클릭) 최종 Export 스크립트 보기</summary>

```bash
#!/bin/bash
# export_jenkins.sh
set -e
JENKINS_URL="http://210.217.178.150:8090"
JENKINS_USER="admin"
JENKINS_PASS='password'

EXPORT_DIR="jenkins_export_$(date +%Y%m%d)"
CLI_JAR="jenkins-cli.jar"
mkdir -p "$EXPORT_DIR" && cd "$EXPORT_DIR"

if [ ! -f "$CLI_JAR" ]; then
    wget --no-check-certificate -q "$JENKINS_URL/jnlpJars/jenkins-cli.jar" -O $CLI_JAR
fi

java -jar $CLI_JAR -s "$JENKINS_URL" -auth "$JENKINS_USER:$JENKINS_PASS" -noCertificateCheck list-jobs > job_list.txt

while read -r JOB_NAME; do
    CLEAN_NAME=$(echo "$JOB_NAME" | tr -d '\r')
    DIR_NAME=$(dirname "$CLEAN_NAME")
    [ "$DIR_NAME" != "." ] && mkdir -p "$DIR_NAME"
    
    # stdin 가로채기 방지 (< /dev/null) 적용됨
    java -jar $CLI_JAR -s "$JENKINS_URL" -auth "$JENKINS_USER:$JENKINS_PASS" -noCertificateCheck get-job "$CLEAN_NAME" < /dev/null > "${CLEAN_NAME}.xml"
done < job_list.txt

cd ..
tar -czf "${EXPORT_DIR}.tar.gz" "$EXPORT_DIR"

```

</details>

---

## Phase 2. Transform (데이터 세탁) - ⚠️ 가장 중요

폐쇄망에 들어가기 전에, **로컬 PC(작업자 PC)**에서 XML 내용을 수정해야 합니다. 402개의 파일을 일일이 열 수 없으므로 `sed`로 일괄 치환합니다.

### 🛠️ 일괄 수정 스크립트 (`transform.sh`)

```bash
#!/bin/bash
# 1. 압축 해제
tar -xzf jenkins_export_20260124.tar.gz
cd jenkins_export_20260124 # 폴더명 확인 필요

echo ">>> 데이터 변경 작업을 시작합니다..."

# =========================================================
# [설정 구역] 변경할 대상을 정확히 입력하세요.
# =========================================================

# A. Git 주소 변경 (Old IP -> New Domain)
# 예: 210.217.178.150 -> gitlab.internal.net
find . -name "*.xml" -print0 | xargs -0 sed -i 's|210.217.178.150|gitlab.internal.net|g'

# B. (선택사항) Credential ID 변경
# 만약 구망 ID와 폐쇄망 ID 규칙이 다르다면 사용
# find . -name "*.xml" -print0 | xargs -0 sed -i 's|<credentialsId>old-id</credentialsId>|<credentialsId>new-id</credentialsId>|g'

# C. (선택사항) Docker Registry 주소 변경
# find . -name "*.xml" -print0 | xargs -0 sed -i 's|docker.io|harbor.internal.net|g'

# =========================================================

echo ">>> 변경 완료. 다시 압축합니다."
cd ..
# "import_ready" 라는 이름으로 최종 압축
tar -czf jenkins_import_ready.tar.gz jenkins_export_20260124

```

---

## Phase 3. Transfer (반입)

1. 생성된 `jenkins_import_ready.tar.gz` 파일을 USB 등에 담습니다.
2. 폐쇄망 내부의 **작업용 서버(Bastion Host)** 또는 **Jenkins에 접근 가능한 터미널**로 파일을 옮깁니다.

---

## Phase 4. Import (적용) - 폐쇄망 내부 실행

이제 새로운 환경(Helm으로 배포된 Jenkins)에 밀어넣습니다.

### ✅ 사전 준비 (필수)

1. **플러그인 확인:** XML에 정의된 플러그인들이 새 Jenkins에 설치되어 있어야 합니다. (특히 `Folders`, `Git`, `Pipeline` 관련)
2. **Credential 생성:** 파이프라인에서 사용하는 `Credential ID`가 새 Jenkins에 미리 생성되어 있어야 합니다. (ID값 일치 필수)
3. **K8s 포트포워딩:** 로컬 터미널에서 Jenkins로 통신하기 위해 포트를 엽니다.
```bash
# 터미널 창 1개 열어서 유지
kubectl port-forward svc/jenkins 8080:8080 -n jenkins

```



### 🚀 최종 Import 스크립트 (`import_final.sh`)

이 스크립트를 폐쇄망 서버에서 작성하고 실행하십시오.

```bash
#!/bin/bash
set -e

# ==========================================
# [NEW Config] 폐쇄망 Jenkins 접속 정보
# ==========================================
NEW_URL="http://localhost:8080" # 포트포워딩 주소
NEW_USER="admin"
NEW_PASS='new_password'         # 새 서버 비밀번호
SOURCE_DIR="jenkins_export_20260124" # 압축 푼 폴더명과 일치해야 함
# ==========================================

CLI_JAR="jenkins-cli.jar"

# 1. 압축 해제 (이미 했으면 주석 처리)
if [ -f "jenkins_import_ready.tar.gz" ]; then
    echo ">>> 압축 해제 중..."
    tar -xzf jenkins_import_ready.tar.gz
fi

# 2. CLI 다운로드 (새 서버 버전 맞춤)
echo ">>> Jenkins CLI 다운로드..."
wget --no-check-certificate -q "$NEW_URL/jnlpJars/jenkins-cli.jar" -O $CLI_JAR

# 3. 정렬 (폴더 -> 파일 순서 보장)
echo ">>> Import 순서 계산 중..."
# 경로 길이가 짧은 것(상위 폴더)부터 정렬
find "$SOURCE_DIR" -name "*.xml" | awk '{ print length, $0 }' | sort -n | cut -d" " -f2- > sorted_list.txt

TOTAL=$(wc -l < sorted_list.txt)
echo ">>> 총 ${TOTAL}개의 작업을 처리합니다."

count=0
while read -r XML_FILE; do
    count=$((count+1))
    
    # 잡 이름 추출 (파일 경로에서 소스폴더와 확장자 제거)
    # 예: jenkins_export/Group/Project.xml -> Group/Project
    JOB_NAME="${XML_FILE#$SOURCE_DIR/}"
    JOB_NAME="${JOB_NAME%.xml}"
    
    echo "[$count/$TOTAL] Importing: $JOB_NAME"
    
    # 1. 생성 시도 (Create)
    # 에러 메시지 숨김 (2>/dev/null) - 이미 있으면 실패하므로
    java -jar $CLI_JAR -s "$NEW_URL" -auth "$NEW_USER:$NEW_PASS" -noCertificateCheck create-job "$JOB_NAME" < "$XML_FILE" 2>/dev/null
    
    # 2. 실패 시(이미 존재) 업데이트 시도 (Update)
    if [ $? -ne 0 ]; then
        echo "    -> 이미 존재함. 설정 업데이트(Update) 진행..."
        java -jar $CLI_JAR -s "$NEW_URL" -auth "$NEW_USER:$NEW_PASS" -noCertificateCheck update-job "$JOB_NAME" < "$XML_FILE"
    fi
    
done < sorted_list.txt

echo "=========================================="
echo "🎉 마이그레이션 완료!"
echo "=========================================="

```

---

## 🛑 Architect's Final Checklist (마무리 점검)

스크립트 실행 후 다음을 확인하십시오.

1. **폴더 구조:** Jenkins 메인 화면에서 폴더(Folder) 구조가 깨지지 않고 트리 형태로 잘 보이는가?
2. **Multibranch Pipeline:** 멀티브랜치 파이프라인의 경우, Import 직후 자동으로 `Scan Repository`가 돕니다.
* 이때 **Credential**이 없거나 **Git 주소**가 틀리면 "Scan Failed"가 뜹니다.
* 이 경우 Jenkins 화면에서 해당 Job의 `Configure`에 들어가 Git 주소가 올바르게 바뀌었는지 눈으로 확인하세요.


3. **Agent Label:** 만약 구망에서 `agent { label 'linux' }`를 썼는데, 새 K8s 환경에는 해당 라벨의 노드가 없다면 빌드가 `Pending` 상태로 멈춥니다.
* *해결:* `Manage Jenkins > Nodes` 에서 라벨을 맞춰주거나, 파이프라인 스크립트를 수정해야 합니다.
