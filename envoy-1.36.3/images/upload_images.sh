
# 워커 노드에서 이미지 import
for i in ./*.tar; do
    sudo ctr -n=k8s.io images import "$i"
done

# 확인
#sudo ctr -n k8s.io images import <이미지_파일.tar>