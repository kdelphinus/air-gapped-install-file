#!/bin/bash
# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

NAMESPACE="harbor"
TRIVY_POD="harbor-trivy-0"
CACHE_DIR="/home/scanner/.cache/trivy"
JAVA_CACHE_DIR="/home/scanner/.cache/trivy/java-db"

# 색상 코드
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "========================================================================"
echo " 🛡️  Harbor Trivy 취약점 DB 수동 반입 (에어갭용)"
echo "========================================================================"

# 1. 준비물 확인 안내
if [ ! -f "trivy-db.tar.gz" ] || [ ! -f "trivy-java-db.tar.gz" ]; then
    echo -e "${YELLOW}[안내] 취약점 DB 파일이 필요합니다. 외부망에서 다음 파일을 다운로드하여 이 폴더에 넣어주세요.${NC}"
    echo ""
    echo "  1. 취약점 DB (Vulnerability DB):"
    echo "     - 다운로드: https://github.com/aquasecurity/trivy-db/releases/latest/download/trivy-offline-db.tgz"
    echo "     - 파일명을 'trivy-db.tar.gz'로 변경"
    echo ""
    echo "  2. Java 취약점 DB (Java DB):"
    echo "     - 다운로드: https://github.com/aquasecurity/trivy-java-db/releases/latest/download/javadb.tar.gz"
    echo "     - 파일명을 'trivy-java-db.tar.gz'로 변경"
    echo ""
    echo -e "${RED}[오류] 필요한 파일이 없습니다. 파일을 반입 후 다시 실행해 주세요.${NC}"
    exit 1
fi

# 2. Pod 상태 확인
if ! kubectl get pod "$TRIVY_POD" -n "$NAMESPACE" > /dev/null 2>&1; then
    echo -e "${RED}[오류] $TRIVY_POD 포드를 찾을 수 없습니다. Harbor가 먼저 설치되어 있어야 합니다.${NC}"
    exit 1
fi

echo "1. 임시 디렉토리에 압축 해제 중..."
mkdir -p tmp/trivy-db tmp/trivy-java-db
tar -xzf trivy-db.tar.gz -C tmp/trivy-db
tar -xzf trivy-java-db.tar.gz -C tmp/trivy-java-db

echo "2. Trivy Pod로 DB 파일 복사 중..."
# Vulnerability DB 복사 (db/ 폴더 구조 확인 필요)
kubectl exec -n "$NAMESPACE" "$TRIVY_POD" -- mkdir -p "$CACHE_DIR/db"
kubectl cp tmp/trivy-db/. "$NAMESPACE/$TRIVY_POD:$CACHE_DIR/db/"

# Java DB 복사
kubectl exec -n "$NAMESPACE" "$TRIVY_POD" -- mkdir -p "$JAVA_CACHE_DIR"
kubectl cp tmp/trivy-java-db/. "$NAMESPACE/$TRIVY_POD:$JAVA_CACHE_DIR/"

echo "3. 권한 설정 및 정리 중..."
kubectl exec -n "$NAMESPACE" "$TRIVY_POD" -- chown -R 10000:10000 "$CACHE_DIR"
rm -rf tmp/trivy-db tmp/trivy-java-db

echo ""
echo "========================================================================"
echo -e " ${GREEN}✅ 취약점 DB 반입 완료!${NC}"
echo "========================================================================"
echo " 이제 Harbor UI에서 이미지 스캔을 실행할 수 있습니다."
echo " (Project -> [이미지 선택] -> Scan 버튼 클릭)"
echo "========================================================================"
