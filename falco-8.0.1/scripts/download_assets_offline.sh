#!/bin/bash
# Phase 1: Falco 8.0.1 에셋 다운로드 (인터넷 연결 필요)
# 작성: Gemini CLI

# 0. 설정
COMPONENT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHART_DIR="$COMPONENT_ROOT/charts"
IMAGE_DIR="$COMPONENT_ROOT/images"
CHART_VERSION="8.0.1"
ENGINE_VERSION="0.43.0"
SIDEKICK_VERSION="2.29.0"

echo "[Phase 1] Falco 8.0.1 에셋 수집 시작..."

# 1. 차트 다운로드
echo "1. Helm Chart 다운로드 (version: $CHART_VERSION)..."
helm repo add falcosecurity https://falcosecurity.github.io/charts --force-update
helm pull falcosecurity/falco --version "$CHART_VERSION" --untar -d "$CHART_DIR"
if [ $? -eq 0 ]; then echo "OK: Chart 수집 완료."; else echo "ERROR: Chart 수집 실패."; exit 1; fi

# 2. 이미지 Pull & Export (ctr 사용)
echo "2. 컨테이너 이미지 수집 (ctr)..."
images=(
  "docker.io/falcosecurity/falco:$ENGINE_VERSION"
  "docker.io/falcosecurity/falcosidekick:$SIDEKICK_VERSION"
)

for img in "${images[@]}"; do
    echo "  - Pulling $img..."
    sudo ctr images pull "$img"
    
    # tar 파일명 정제 (docker.io/falcosecurity/falco-no-driver:0.38.0 -> falco-no-driver-0.38.0.tar)
    img_name=$(echo "$img" | awk -F'/' '{print $NF}' | tr ':' '-')
    echo "  - Exporting $img to $IMAGE_DIR/$img_name.tar..."
    sudo ctr images export "$IMAGE_DIR/$img_name.tar" "$img"
done

echo "[Phase 1] 완료: 모든 에셋이 $COMPONENT_ROOT 에 저장되었습니다."
