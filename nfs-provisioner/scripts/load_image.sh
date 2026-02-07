#!/bin/bash
# [폐쇄망] 컨테이너 이미지 로드 스크립트
# Docker 또는 Containerd(ctr) 환경을 감지하여 이미지를 로드합니다.

IMAGE_FILE="nfs-provisioner.tar"
IMAGE_TAG="registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2"
TARGET_REGISTRY="my-registry.local" # 사용자가 수정해야 할 부분

if [ ! -f "$IMAGE_FILE" ]; then
    echo "오류: $IMAGE_FILE 파일이 없습니다."
    exit 1
fi

echo "=== 컨테이너 이미지 로드 시작 ==="

# 1. Containerd (ctr) 확인
if command -v ctr &> /dev/null; then
    echo ">> Containerd(ctr) 환경이 감지되었습니다."
    echo "   Namespace: k8s.io (Kubernetes 기본값)"
    
    # 이미지 임포트
    # --all-platforms: 모든 플랫폼 아키텍처 포함 (있는 경우)
    # --digests: 다이제스트 검증 (옵션)
    sudo ctr -n k8s.io images import "$IMAGE_FILE"
    
    echo ">> 이미지 로드 완료."
    echo "   확인: sudo ctr -n k8s.io images list | grep nfs"
    
    echo ""
    echo "   [참고] 내부 레지스트리를 사용한다면 태그 변경 및 푸시가 필요합니다."
    echo "   Containerd에서는 'ctr images tag'와 'ctr images push'를 사용하세요."
    echo "   예: sudo ctr -n k8s.io images tag $IMAGE_TAG $TARGET_REGISTRY/nfs-subdir-external-provisioner:v4.0.2"
    echo "       sudo ctr -n k8s.io images push $TARGET_REGISTRY/nfs-subdir-external-provisioner:v4.0.2 --plain-http"

# 2. Docker 확인
elif command -v docker &> /dev/null; then
    echo ">> Docker 환경이 감지되었습니다."
    
    sudo docker load -i "$IMAGE_FILE"
    
    echo ">> 이미지 로드 완료."
    echo "   확인: docker images | grep nfs"

# 3. Nerdctl 확인 (Containerd용 Docker 호환 CLI)
elif command -v nerdctl &> /dev/null; then
    echo ">> Nerdctl 환경이 감지되었습니다."
    
    sudo nerdctl -n k8s.io load -i "$IMAGE_FILE"
    
    echo ">> 이미지 로드 완료."
else
    echo "오류: 컨테이너 런타임(ctr, docker, nerdctl)을 찾을 수 없습니다."
    exit 1
fi
