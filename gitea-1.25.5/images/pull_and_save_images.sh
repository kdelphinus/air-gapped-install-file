#!/bin/bash
# 인터넷이 되는 환경에서 실행 — 이미지를 pull 후 .tar 로 저장
# 저장된 .tar 파일을 폐쇄망으로 옮긴 후 upload_images_to_harbor_v3-lite.sh 로 업로드
#
# 이미지 출처:
#   - Gitea     : docker.gitea.com (공식)
#   - 나머지    : docker.io/bitnamilegacy (Bitnami 무료 레거시 네임스페이스, 인증 불필요)
#                 차트 values.yaml 이 bitnami/ → bitnamilegacy/ 로 이미 오버라이드되어 있음
cd "$(dirname "$0")" || exit 1

# ==================== 이미지 목록 ====================
# [공통] SQLite + valkey-cluster (기본 구성)
IMAGES_COMMON=(
  "docker.gitea.com/gitea:1.25.5-rootless"
  "docker.io/bitnamilegacy/valkey-cluster:8.1.3-debian-12-r3"
  "docker.io/bitnamilegacy/os-shell:12-debian-12-r51"
  "docker.io/bitnamilegacy/redis-exporter:1.76.0-debian-12-r0"
)

# [PostgreSQL 선택 시 추가] install.sh DB 타입 2 선택 시만 필요
IMAGES_PG=(
  "docker.io/bitnamilegacy/postgresql:17.6.0-debian-12-r4"
  "docker.io/bitnamilegacy/postgres-exporter:0.17.1-debian-12-r16"
)
# ====================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "========================================================================"
echo " Gitea 1.25.5 — 이미지 Pull & Save"
echo ""
echo " 구성을 선택하세요:"
echo "   1) SQLite (기본) — 공통 이미지만"
echo "   2) PostgreSQL    — 공통 + PostgreSQL 이미지"
read -p " 선택 [1/2, 기본값 1]: " MODE
MODE="${MODE:-1}"
echo ""
echo " 저장 위치: $(pwd)"
echo "========================================================================"

IMAGES=("${IMAGES_COMMON[@]}")
if [ "$MODE" = "2" ]; then
  IMAGES+=("${IMAGES_PG[@]}")
fi

FAIL=0

for image in "${IMAGES[@]}"; do
  # tar 파일명: 슬래시·콜론을 _ 로 변환
  tar_name="$(echo "$image" | sed 's|[/:]|_|g').tar"

  echo ""
  echo -e "${YELLOW}▶ ${image}${NC}"

  echo -n "   Pull...  "
  if ctr images pull "$image" > /dev/null 2>&1; then
    echo -e "${GREEN}[완료]${NC}"
  else
    echo -e "${RED}[실패]${NC}"
    FAIL=$((FAIL + 1))
    continue
  fi

  echo -n "   Save → ${tar_name}...  "
  if ctr images export "$tar_name" "$image"; then
    echo -e "${GREEN}[완료]${NC}"
  else
    echo -e "${RED}[실패]${NC}"
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "========================================================================"
if [ "$FAIL" -eq 0 ]; then
  echo -e " ${GREEN}✅ 모든 이미지 저장 완료${NC}"
else
  echo -e " ${RED}⚠️  실패 ${FAIL}건 — 위 로그를 확인하세요${NC}"
fi
echo ""
echo " 다음 단계: 이 디렉토리의 .tar 파일을 폐쇄망 서버로 복사 후"
echo "   sudo ./upload_images_to_harbor_v3-lite.sh"
echo "========================================================================"
