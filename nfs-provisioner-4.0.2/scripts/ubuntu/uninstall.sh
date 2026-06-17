#!/bin/bash
# [폐쇄망] Ubuntu 서버에서 실행하세요.
cd "$(dirname "$0")/../.." || exit 1

echo "==========================================="
echo " Uninstalling NFS Provisioner (Ubuntu)"
echo "==========================================="
read -p "❓ 정말 삭제하시겠습니까? (y/n): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "취소되었습니다."; exit 0; }

# K8s NFS Provisioner 리소스 제거
if [ -f "./manifests/nfs-provisioner.yaml" ]; then
    echo "🗑️  K8s NFS Provisioner 리소스 삭제 중..."
    kubectl delete -f ./manifests/nfs-provisioner.yaml --ignore-not-found=true
fi

# StorageClass 제거
echo "🗑️  StorageClass 삭제 중..."
kubectl delete storageclass nfs-client --ignore-not-found=true

# NFS 서버 서비스 중지 및 비활성화
echo "🛑  NFS 서버 중지 중..."
sudo systemctl stop nfs-kernel-server 2>/dev/null || true
sudo systemctl disable nfs-kernel-server 2>/dev/null || true

echo ""
echo "✅ NFS Provisioner 삭제 완료."
echo "   /etc/exports 항목은 수동으로 정리하세요."
