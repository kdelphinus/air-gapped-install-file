
# 워커 노드에서 이미지 import
for i in ./*.tar; do
    sudo ctr -n=k8s.io images import "$i"
done

# Harbor push — 공통 업로드 스크립트 사용
# ../../harbor-1.14.3/utils/upload_images_to_harbor_v3-lite.sh 내 변수를 수정 후 실행합니다.
#   IMAGE_DIR      : 이 디렉터리 경로 (upload_images.sh 위치 기준)
#   HARBOR_REGISTRY: <NODE_IP>:30002
#   HARBOR_PROJECT : <HARBOR_PROJECT>
#   HARBOR_USER    : admin
#   HARBOR_PASSWORD: <HARBOR_PASSWORD>
# bash ../../harbor-1.14.3/utils/upload_images_to_harbor_v3-lite.sh
