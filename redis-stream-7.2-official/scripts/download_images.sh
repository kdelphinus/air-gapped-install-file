#!/bin/bash
# 인터넷 연결 환경에서 실행하는 이미지 다운로드 스크립트
# 기본 엔진: ctr (containerd)
# 지원 인자: --engine [ctr|docker|skopeo], --help
cd "$(dirname "$0")/.." || exit 1

IMAGE_DIR="./images"
mkdir -p "$IMAGE_DIR"

# ==================== 대상 이미지 ====================
IMAGES=(
    "docker.io/library/redis:7.2"
)
# =====================================================

show_help() {
    echo "사용법: $0 [옵션]"
    echo ""
    echo "옵션:"
    echo "  -e, --engine [ENGINE]  사용할 컨테이너 엔진 지정 (ctr, docker, skopeo)"
    echo "                         (미지정 시 ctr -> skopeo -> docker 순으로 자동 탐색)"
    echo "  -h, --help             도움말 출력"
    echo ""
    echo "예시:"
    echo "  $0 --engine docker"
    echo "  $0 -e skopeo"
    exit 0
}

# 인자 처리
SELECTED_ENGINE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--engine)
            SELECTED_ENGINE="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo "알 수 없는 옵션: $1"
            show_help
            ;;
    esac
done

# 엔진 자동 결정 로직 (인자가 없을 경우)
if [ -z "$SELECTED_ENGINE" ]; then
    if command -v ctr &> /dev/null; then
        SELECTED_ENGINE="ctr"
    elif command -v skopeo &> /dev/null; then
        SELECTED_ENGINE="skopeo"
    elif command -v docker &> /dev/null; then
        SELECTED_ENGINE="docker"
    else
        echo "오류: ctr, skopeo, docker 중 하나는 설치되어 있어야 합니다."
        exit 1
    fi
fi

echo "========================================================================"
echo " Redis Stream v7.2-official — 이미지 다운로드"
echo " 사용 엔진: $SELECTED_ENGINE"
echo "========================================================================"

for img in "${IMAGES[@]}"; do
    filename=$(echo "$img" | awk -F/ '{print $NF}' | sed 's/:/-/').tar
    echo -e "\n처리 중: $img"

    case $SELECTED_ENGINE in
        "ctr")
            echo "   └─ [ctr] pull & export..."
            if ctr -n k8s.io images pull "$img" && ctr -n k8s.io images export "$IMAGE_DIR/$filename" "$img"; then
                echo "   [완료] $filename"
            else
                echo "   [실패] ctr 오류 (sudo 권한이 필요할 수 있습니다)"
            fi
            ;;
        "skopeo")
            echo "   └─ [skopeo] copy..."
            if skopeo copy "docker://$img" "docker-archive:$IMAGE_DIR/$filename:$img"; then
                echo "   [완료] $filename"
            else
                echo "   [실패] skopeo 오류"
            fi
            ;;
        "docker")
            echo "   └─ [docker] pull & save..."
            if docker pull "$img" && docker save "$img" -o "$IMAGE_DIR/$filename"; then
                echo "   [완료] $filename"
            else
                echo "   [실패] docker 오류"
            fi
            ;;
        *)
            echo "오류: 지원하지 않는 엔진입니다 ($SELECTED_ENGINE)"
            exit 1
            ;;
    esac
done

echo ""
echo "========================================================================"
echo " 저장 완료. ($IMAGE_DIR)"
echo "========================================================================"
du -sh "$IMAGE_DIR"
