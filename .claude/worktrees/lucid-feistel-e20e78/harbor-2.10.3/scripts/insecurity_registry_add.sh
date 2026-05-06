#!/bin/bash
# 스크립트 위치 기준으로 컴포넌트 루트로 이동
cd "$(dirname "$0")/.." || exit 1

# Root 권한 체크
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.\033[0m"
    exit 1
fi

# ==================== 설정 ====================
CONFIG_FILE="/etc/containerd/config.toml"
CERTS_D_BASE="/etc/containerd/certs.d"
# ==============================================

# 색상 코드
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "========================================================================"
echo " 🏗️  Containerd Insecure Registry 설정 (certs.d 방식)"
echo "========================================================================"

# 1. Harbor 주소 입력
echo -e "${YELLOW}[안내] 포트 번호가 있다면 반드시 포함해주세요 (예: 172.30.235.20:30002 또는 harbor.devops.internal)${NC}"
read -p "Harbor 레지스트리 주소 입력: " HARBOR_REGISTRY
if [ -z "$HARBOR_REGISTRY" ]; then
    echo -e "${RED}[오류] 레지스트리 주소를 입력해야 합니다.${NC}"
    exit 1
fi

# 2. config.toml 정리 (config_path 설정 최적화)
echo "1. $CONFIG_FILE 내 config_path 설정 확인 및 정리 중..."

# 백업 생성
sudo cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"

# 빈 값이거나 잘못된 형식의 config_path 제거 및 표준 경로 설정
# - 빈 값 제거 (config_path = '')
# - 콜론(:)이 포함된 다중 경로 제거
# - 최종적으로 표준 경로(/etc/containerd/certs.d) 하나만 남기도록 유도
sudo sed -i "s/config_path = ''//g" "$CONFIG_FILE"
sudo sed -i "s/config_path = \".*:.*/config_path = \"\/etc\/containerd\/certs.d\"/g" "$CONFIG_FILE"
sudo sed -i "s/config_path = '.*:.*/config_path = '\/etc\/containerd\/certs.d'/g" "$CONFIG_FILE"

# 만약 config_path 설정 자체가 없다면 (또는 위에서 지워져서 없다면) 명시적으로 추가 필요
if ! grep -q "config_path = " "$CONFIG_FILE"; then
    echo "   [알림] config_path 설정이 없어서 추가합니다."
    # containerd v2.x vs v1.x 플러그인 키 자동 감지
    if grep -q 'io.containerd.cri.v1.images' "$CONFIG_FILE"; then
        # v2.x 키
        REGISTRY_SECTION='plugins."io.containerd.cri.v1.images".registry'
        echo "   [감지] containerd v2.x 플러그인 키 사용"
    else
        # v1.x 키 (기본)
        REGISTRY_SECTION='plugins."io.containerd.grpc.v1.cri".registry'
        echo "   [감지] containerd v1.x 플러그인 키 사용"
    fi
    sudo sed -i "/\[${REGISTRY_SECTION}\]/a \      config_path = \"\/etc\/containerd\/certs.d\"" "$CONFIG_FILE"
fi

# 3. hosts.toml 생성
REGISTRY_DIR="${CERTS_D_BASE}/${HARBOR_REGISTRY}"
echo "2. $REGISTRY_DIR/hosts.toml 설정 생성 중..."

sudo mkdir -p "$REGISTRY_DIR"
cat <<EOF | sudo tee "${REGISTRY_DIR}/hosts.toml" > /dev/null
server = "http://${HARBOR_REGISTRY}"

[host."http://${HARBOR_REGISTRY}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF

echo -e "   └─ ${GREEN}[성공]${NC} ${REGISTRY_DIR}/hosts.toml 생성 완료"

# 4. Containerd 재시작
echo "3. containerd 서비스 재시작 중..."
sudo systemctl restart containerd

echo ""
echo "========================================================================"
echo -e " ${GREEN}✅ 설정 완료!${NC}"
echo "========================================================================"
echo " [확인 명령]"
echo " grep \"config_path\" $CONFIG_FILE"
echo " cat ${REGISTRY_DIR}/hosts.toml"
echo "========================================================================"
