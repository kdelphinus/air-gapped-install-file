#!/bin/bash
# 인터넷이 되는 환경에서 실행 — 이미지를 pull 후 .tar 로 저장
# 저장된 .tar 파일을 폐쇄망으로 옮긴 후 upload_images_to_harbor_v3-lite.sh 로 업로드
#
# 이미지 출처: ghcr.io/tektoncd (GitHub Container Registry, 무료·공개)
# 이미지명에 포함된 해시 접미사는 Tekton의 distroless 이미지 빌드 규칙입니다.
cd "$(dirname "$0")" || exit 1

# ==================== 이미지 목록 ====================
# @sha256 pinning — 재현 가능한 빌드를 위해 digest 포함하여 pull

IMAGES_PIPELINES=(
  "ghcr.io/tektoncd/pipeline/controller-10a3e32792f33651396d02b6855a6e36:v1.9.0@sha256:44d0de227e3ca2e400164800a263e6db446d1bd05f53d6d2d9b06d45b3026b09"
  "ghcr.io/tektoncd/pipeline/webhook-d4749e605405422fd87700164e31b2d1:v1.9.0@sha256:0d6132876c6e90b47e88635baecff3ebac75b57a6627d66bdc473e70d8370277"
  "ghcr.io/tektoncd/pipeline/resolvers-ff86b24f130c42b88983d3c13993056d:v1.9.0@sha256:1f3e346ba5b9b2a702cff5224713d0bbd7b31372614f3a5441a3df3df7a17e1e"
  "ghcr.io/tektoncd/pipeline/events-a9042f7efb0cbade2a868a1ee5ddd52c:v1.9.0@sha256:2691c8db13df4350e4c8e5602d7fec3562a53f10a01b03b4ef998911118192dc"
)

IMAGES_TRIGGERS=(
  "ghcr.io/tektoncd/triggers/controller-f656ca31de179ab913fa76abc255c315:v0.34.0@sha256:472ed3311309a9ac066afd8be2ae435cb6cc5bc73240a5f82a9b04ee5c6f77eb"
  "ghcr.io/tektoncd/triggers/webhook-dd1edc925ee1772a9f76e2c1bc291ef6:v0.34.0@sha256:71ef9c830240870c76496f1858abc350d08be93365fc8bea17853aa94f64adcd"
)

IMAGES_DASHBOARD=(
  "ghcr.io/tektoncd/dashboard/dashboard-9623576a202fe86c8b7d1bc489905f86:v0.65.0@sha256:d79099ebc32fcfce3f408935e3fd3f8e17df987a101db93a768e3e18c7bf7826"
)
# ====================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "========================================================================"
echo " Tekton v1.9.0 — 이미지 Pull & Save"
echo ""
echo " 컴포넌트를 선택하세요:"
echo "   1) Pipelines만 (필수)"
echo "   2) Pipelines + Triggers"
echo "   3) Pipelines + Triggers + Dashboard (전체)"
read -p " 선택 [1/2/3, 기본값 3]: " MODE
MODE="${MODE:-3}"
echo ""
echo " 저장 위치: $(pwd)"
echo "========================================================================"

IMAGES=("${IMAGES_PIPELINES[@]}")
[ "$MODE" -ge 2 ] && IMAGES+=("${IMAGES_TRIGGERS[@]}")
[ "$MODE" -ge 3 ] && IMAGES+=("${IMAGES_DASHBOARD[@]}")

FAIL=0

for full_ref in "${IMAGES[@]}"; do
  # 저장 시 사용할 tag-only 참조 (sha256 제거)
  tag_ref="${full_ref%%@sha256:*}"
  # tar 파일명: 마지막 path 세그먼트 + 태그
  last_seg="${tag_ref##*/}"
  tar_name="${last_seg//:/_}.tar"

  echo ""
  echo -e "${YELLOW}▶ ${tag_ref}${NC}"

  echo -n "   Pull (digest pin)...  "
  if ctr images pull "$full_ref" > /dev/null 2>&1; then
    echo -e "${GREEN}[완료]${NC}"
  else
    echo -e "${RED}[실패]${NC}"
    FAIL=$((FAIL + 1))
    continue
  fi

  echo -n "   Save → ${tar_name}...  "
  if ctr images export "$tar_name" "$tag_ref"; then
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
