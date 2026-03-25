#!/bin/bash
cd "$(dirname "$0")/.." || exit 1
set -e

# containerd config.toml 에 Harbor 레지스트리 설정 추가 스크립트
CONFIG_FILE="/etc/containerd/config.toml"

# containerd 실행 상태 확인
if ! systemctl is-active containerd > /dev/null 2>&1; then
  echo "[ERROR] containerd 서비스가 실행 중이 아닙니다."
  exit 1
fi

# Harbor 주소 입력받기 (예: 172.31.63.195:30002)
read -p "Harbor 레지스트리 주소 (예: 172.31.63.195:30002): " HARBOR_REGISTRY
if [ -z "$HARBOR_REGISTRY" ]; then
  echo "[ERROR] 레지스트리 주소를 입력하세요!"
  exit 1
fi

# 주소 형식 검증
if ! [[ "$HARBOR_REGISTRY" =~ ^[a-zA-Z0-9._-]+:[0-9]+$ ]]; then
  echo "[ERROR] 올바른 형식이 아닙니다 (예: 172.31.63.195:30002)"
  exit 1
fi

# 이미 설정이 있는지 확인
if grep -q "$HARBOR_REGISTRY" "$CONFIG_FILE"; then
  echo "[INFO] 이미 $HARBOR_REGISTRY 설정이 존재합니다. 변경하지 않음."
else
  # 변경이 필요한 경우에만 백업 생성
  BACKUP_FILE="/etc/containerd/config.toml.bak.$(date +%Y%m%d%H%M%S)"
  sudo cp "$CONFIG_FILE" "$BACKUP_FILE"
  echo "[INFO] 기존 설정 백업: $BACKUP_FILE"

  # registry.mirrors 섹션 추가
  sudo tee -a "$CONFIG_FILE" > /dev/null <<EOF

[plugins."io.containerd.grpc.v1.cri".registry.mirrors."$HARBOR_REGISTRY"]
  endpoint = ["http://$HARBOR_REGISTRY"]

[plugins."io.containerd.grpc.v1.cri".registry.configs."$HARBOR_REGISTRY".tls]
  insecure_skip_verify = true
EOF
  echo "[INFO] Harbor 레지스트리 설정 추가 완료: $HARBOR_REGISTRY"
fi

# containerd 재시작
echo "[INFO] containerd 서비스 재시작..."
sudo systemctl restart containerd

# 확인
echo "[INFO] Harbor 레지스트리 설정 확인:"
grep -A3 "$HARBOR_REGISTRY" "$CONFIG_FILE"
