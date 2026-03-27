#!/bin/bash
# 인터넷 연결 환경에서 실행하는 스크립트입니다.
# 이미지를 Pull하여 .tar 파일로 저장합니다.
cd "$(dirname "$0")/.." || exit 1

IMAGE_DIR="./images"
mkdir -p "$IMAGE_DIR"

# ==================== 대상 이미지 ====================
IMAGES=(
    "docker.io/library/redis:7.2"
)
# =====================================================

echo "========================================================================"
echo " Redis Stream 7.2 (공식 이미지) — 이미지 Pull & Save"
echo " 출력 디렉토리: $IMAGE_DIR"
echo "========================================================================"

for img in "${IMAGES[@]}"; do
    # 파일명: docker.io/library/redis:7.2 → docker.io_library_redis_7.2.tar
    filename=$(echo "$img" | sed 's|/|_|g; s|:|_|').tar

    echo ""
    echo "처리 중: $img"

    # 1. Pull
    echo "   └─ 1. Pull..."
    if ! docker pull "$img"; then
        echo "   [실패] Pull 오류: $img"
        continue
    fi

    # 2. Save
    echo "   └─ 2. Save → $IMAGE_DIR/$filename"
    if docker save "$img" -o "$IMAGE_DIR/$filename"; then
        echo "   [완료] $filename"
    else
        echo "   [실패] Save 오류: $img"
    fi
done

echo ""
echo "========================================================================"
echo " 저장 완료. images/ 디렉토리를 에어갭 환경으로 이관 후"
echo " upload_images_to_harbor_v3-lite.sh 를 실행하세요."
echo "========================================================================"
du -sh "$IMAGE_DIR"
