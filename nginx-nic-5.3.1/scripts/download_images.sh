#!/bin/bash
# 인터넷 연결 환경에서 실행하는 이미지 다운로드 스크립트
# 기본 엔진: ctr (containerd)
# 지원 인자: --engine [ctr|docker|skopeo], --help
cd "$(dirname "$0")/.." || exit 1

IMAGE_DIR="./images"
mkdir -p "$IMAGE_DIR"

# ==================== 대상 이미지 ====================
# F5 NIC v5.3.1 차트는 admissionWebhooks를 지원하지 않으므로
# kube-webhook-certgen 이미지는 불필요합니다.
IMAGES=(
    "docker.io/nginx/nginx-ingress:5.3.1"
)
# =====================================================

show_help() {
    echo "사용법: $0 [옵션]"
    echo ""
    echo "옵션:"
    echo "  -e, --engine [ENGINE]  사용할 컨테이너 엔진 지정 (ctr, docker, skopeo)"
    echo "                         (미지정 시 ctr -> skopeo -> docker 순으로 자동 탐색)"
    echo "  -h, --help             도움말 출력"
    exit 0
}

# 인자 처리
SELECTED_ENGINE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--engine) SELECTED_ENGINE="$2"; shift 2 ;;
        -h|--help) show_help ;;
        *) echo "알 수 없는 옵션: $1"; show_help ;;
    esac
done

# 엔진 자동 결정
if [ -z "$SELECTED_ENGINE" ]; then
    if command -v ctr &> /dev/null; then SELECTED_ENGINE="ctr"
    elif command -v skopeo &> /dev/null; then SELECTED_ENGINE="skopeo"
    elif command -v docker &> /dev/null; then SELECTED_ENGINE="docker"
    else echo "오류: ctr, skopeo, docker 중 하나는 설치되어 있어야 합니다."; exit 1; fi
fi

echo "========================================================================"
echo " F5 NGINX Ingress Controller v5.3.1 — 이미지 다운로드"
echo " 사용 엔진: $SELECTED_ENGINE"
echo "========================================================================"

for img in "${IMAGES[@]}"; do
    # 파일명 생성 개선: 레지스트리 주소를 제외하고 이름과 태그만 추출하여 하이픈으로 연결
    # 예: registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.4.4 -> kube-webhook-certgen-v1.4.4.tar
    filename=$(echo "$img" | awk -F/ '{print $NF}' | sed 's/:/-/').tar
    
    echo -e "\n처리 중: $img"
    echo "저장 파일: $IMAGE_DIR/$filename"

    case $SELECTED_ENGINE in
        "ctr")
            echo "   └─ [ctr] pull & export..."
            # ctr은 기본적으로 root 권한이 필요할 수 있으므로 실패 시 sudo 권장 메시지 출력
            if ! sudo ctr -n k8s.io images pull "$img"; then
                echo "   [실패] ctr pull 오류. (네트워크 상태 또는 권한 확인 필요)"
                continue
            fi
            if sudo ctr -n k8s.io images export "$IMAGE_DIR/$filename" "$img"; then
                echo "   [완료] $filename"
            else
                echo "   [실패] ctr export 오류"
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
    esac
done

echo ""
echo "========================================================================"
echo " 저장 완료. ($IMAGE_DIR)"
echo "========================================================================"
du -sh "$IMAGE_DIR" 2>/dev/null || true
