#!/bin/bash
# transform-jenkins-pipelines.sh
# Jenkins 파이프라인 XML을 폐쇄망 클러스터 환경에 맞게 변환
# (경로를 상대 경로로 수정하여 이식성 강화)

set -e

# ==============================================================================
# Config — 스크립트 위치 기준으로 상대 경로 설정
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
SOURCE_DIR="$(dirname "$BASE_DIR")/origin/jenkins_export_20260223"
OUTPUT_DIR="$BASE_DIR/manifests/transformed_pipelines/goe_filtered"

# 필터 (빈 값이면 전체 변환, 값이 있으면 파일명에 포함된 것만 변환)
FILTER="goe"

# Git 서버
OLD_GITLAB="gitlab\.strato\.co\.kr"
NEW_GITLAB="gitlab.internal.net"

# Harbor 레지스트리
OLD_HARBOR="harbor-product\.strato\.co\.kr:8443"
NEW_HARBOR="1.1.1.213:30002"

# Agent
OLD_AGENT="agent any"
NEW_AGENT="agent { label 'jenkins-agent' }"

# IP (Deployment Target)
OLD_IP="210\.217\.178\.150"
NEW_IP="1.1.1.50"

# ==============================================================================

echo "============================================="
echo " Jenkins Pipeline Transformer"
echo "============================================="
echo " Source : $SOURCE_DIR"
echo " Output : $OUTPUT_DIR"
echo " Filter : ${FILTER:-(전체)}"
echo " GitLab : $OLD_GITLAB -> $NEW_GITLAB"
echo " Harbor : $OLD_HARBOR -> $NEW_HARBOR"
echo " IP     : $OLD_IP -> $NEW_IP"
echo "============================================="
echo ""

# 1. 소스 확인
if [ ! -d "$SOURCE_DIR" ]; then
    echo "[ERROR] Source directory not found: $SOURCE_DIR"
    exit 1
fi

# 2. 출력 디렉토리 초기화
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# 3. 파일 복사 (필터 적용)
if [ -n "$FILTER" ]; then
    find "$SOURCE_DIR" -maxdepth 1 -name "*${FILTER}*.xml" -exec cp {} "$OUTPUT_DIR/" \;
else
    cp "$SOURCE_DIR"/*.xml "$OUTPUT_DIR/"
fi

TOTAL=$(find "$OUTPUT_DIR" -name "*.xml" | wc -l)
echo "[1/4] XML 파일 복사 완료: ${TOTAL}개"

# 4. 치환
echo "[2/4] 치환 중..."

find "$OUTPUT_DIR" -name "*.xml" -print0 | xargs -0 sed -i \
    -e "s|${OLD_GITLAB}|${NEW_GITLAB}|g" \
    -e "s|${OLD_HARBOR}|${NEW_HARBOR}|g" \
    -e "s|${OLD_AGENT}|${NEW_AGENT}|g" \
    -e "s|${OLD_IP}|${NEW_IP}|g" \
    -e "s|credentialsId: '10-product-gitlab-Credential'|credentialsId: 'gitlab.internal.net'|g"

echo "      GitLab : ${OLD_GITLAB} -> ${NEW_GITLAB}"
echo "      Harbor : ${OLD_HARBOR} -> ${NEW_HARBOR}"
echo "      IP     : ${OLD_IP} -> ${NEW_IP}"

# 5. 분석 리포트 생성
echo "[3/4] 분석 리포트 생성 중..."

REPORT_FILE="$BASE_DIR/reports/transformation_summary_bash.txt"
mkdir -p "$(dirname "$REPORT_FILE")"

{
    echo "====================================================="
    echo " Jenkins Pipeline 변환 리포트 (Bash)"
    echo " 생성일: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "====================================================="
    echo ""

    echo "[ 처리 현황 ]"
    echo "  필터   : ${FILTER:-(전체)}"
    echo "  파일 수: ${TOTAL}개"
    echo "  GitLab : ${OLD_GITLAB} -> ${NEW_GITLAB}"
    echo "  Harbor : ${OLD_HARBOR} -> ${NEW_HARBOR}"
    echo "  IP     : ${OLD_IP} -> ${NEW_IP}"
    echo ""

    echo "[ 사용된 Credential ID 전체 목록 ]"
    echo ""
    grep -rh "credentialsId" "$OUTPUT_DIR"/*.xml 2>/dev/null \
        | sed "s/&apos;/'/g" \
        | grep -oP "credentialsId: '[^']+'" \
        | grep -oP "'[^']+'" \
        | tr -d "'" \
        | sort | uniq -c | sort -rn \
        | awk '{printf "  %-5s %s\n", "["$1"]", $2}' \
        || echo "  (없음)"

    echo ""
    echo "[ 잔여 외부 주소 확인 ]"
    grep -rh "strato\.co\.kr\|10\.10\.\|docker\.io" "$OUTPUT_DIR"/*.xml 2>/dev/null \
        | grep -oP "https?://[^'\"&<> ]+" \
        | sort | uniq \
        | awk '{print "  " $0}' \
        || echo "  (없음)"

    echo ""
    echo "[ Docker 빌드 사용 파이프라인 수 ]"
    DOCKER_COUNT=$(grep -rl "docker\.build\|withDockerRegistry" "$OUTPUT_DIR"/*.xml 2>/dev/null | wc -l)
    echo "  ${DOCKER_COUNT}개 — DinD 파드 템플릿 설정 필요 (가이드 참조)"

    echo ""
    echo "====================================================="
} > "$REPORT_FILE"

echo "[4/4] 완료"
echo ""
cat "$REPORT_FILE"
echo ""
echo "============================================="
echo " 출력 디렉토리: $OUTPUT_DIR"
echo " 리포트: $REPORT_FILE"
echo "============================================="
