#!/bin/bash
# GitLab CE Omnibus 이미지 다운로드 스크립트
# 인터넷이 연결된 환경에서 실행하세요.
cd "$(dirname "$0")" || exit 1

IMAGE="gitlab/gitlab-ce:18.7.0-ce.0"
IMAGE_CTR="docker.io/${IMAGE}"   # ctr는 레지스트리 호스트를 명시해야 함
OUTPUT="gitlab-ce_18.7.0-ce.0.tar"

echo "==========================================="
echo " GitLab CE Omnibus 이미지 다운로드"
echo " 대상: ${IMAGE}"
echo " 출력: $(pwd)/${OUTPUT}"
echo "==========================================="
echo ""

if [ -f "${OUTPUT}" ]; then
    echo "⚠️  ${OUTPUT} 이미 존재합니다."
    read -p "덮어쓰시겠습니까? (y/N): " OVERWRITE
    [[ "${OVERWRITE}" =~ ^[Yy]$ ]] || { echo "취소됨."; exit 0; }
fi

if command -v docker &>/dev/null; then
    echo "▶ docker pull ${IMAGE}"
    docker pull "${IMAGE}"
    echo ""
    echo "▶ docker save → ${OUTPUT}"
    docker save "${IMAGE}" -o "${OUTPUT}"
elif command -v ctr &>/dev/null; then
    echo "▶ ctr images pull ${IMAGE_CTR}"
    sudo ctr images pull "${IMAGE_CTR}"
    echo ""
    echo "▶ ctr images export → ${OUTPUT}"
    sudo ctr images export "${OUTPUT}" "${IMAGE_CTR}"
else
    echo "[오류] docker 또는 ctr 명령이 필요합니다." && exit 1
fi

echo ""
SIZE=$(du -sh "${OUTPUT}" 2>/dev/null | cut -f1)
echo "✅ 다운로드 완료: ${OUTPUT} (${SIZE})"
echo ""
echo "다음 단계:"
echo "  1) 폐쇄망 서버로 ${OUTPUT} 파일을 전송하세요."
echo "  2) Harbor 업로드: bash upload_images_to_harbor_v3-lite.sh <REGISTRY> <PROJECT>"
echo "  3) 또는 로컬 import: sudo ctr -n k8s.io images import ${OUTPUT}"
