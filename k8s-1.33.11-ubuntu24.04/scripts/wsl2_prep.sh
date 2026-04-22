#!/bin/bash

# ==========================================
# WSL2 Ubuntu 24.04 전처리 스크립트
#   - /etc/wsl.conf 에 systemd=true 활성화
#   - iptables 백엔드를 legacy 로 전환 (Cilium/kube-proxy 호환)
#   - swap 비활성화 (일시)
#   - wsl --shutdown 재기동 안내 후 종료
#
#   실제 kubeadm 설치는 재기동 후 scripts/install.sh 실행
# ==========================================

cd "$(dirname "$0")/.." || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ── WSL2 환경 확인 ────────────────────────────────────────────
if ! grep -qi "microsoft" /proc/version 2>/dev/null; then
    echo -e "${RED}[오류] 이 스크립트는 WSL2 환경에서만 실행 가능합니다.${NC}"
    echo "       VM/베어메탈 환경에서는 scripts/install.sh 만 실행하세요."
    exit 1
fi

# ── Root 권한 체크 ───────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.${NC}"
    exit 1
fi

echo "============================================================"
echo " WSL2 Ubuntu 24.04 사전 설정"
echo "============================================================"

# ── [1/3] /etc/wsl.conf systemd 활성화 ───────────────────────
echo ""
echo "[1/3] /etc/wsl.conf systemd 활성화 확인..."

WSL_CONF="/etc/wsl.conf"
NEED_RESTART=0

if [ ! -f "$WSL_CONF" ]; then
    cat <<EOF > "$WSL_CONF"
[boot]
systemd=true
EOF
    echo -e "  ${GREEN}→ /etc/wsl.conf 신규 생성 (systemd=true)${NC}"
    NEED_RESTART=1
elif ! grep -qE "^\s*systemd\s*=\s*true" "$WSL_CONF"; then
    # [boot] 섹션이 있는지 확인
    if grep -qE "^\s*\[boot\]" "$WSL_CONF"; then
        # [boot] 섹션 밑에 systemd=true 추가
        sed -i '/^\s*\[boot\]/a systemd=true' "$WSL_CONF"
    else
        # 파일 끝에 섹션 추가
        printf "\n[boot]\nsystemd=true\n" >> "$WSL_CONF"
    fi
    echo -e "  ${GREEN}→ /etc/wsl.conf 에 systemd=true 추가${NC}"
    NEED_RESTART=1
else
    echo "  → 이미 systemd=true 활성화됨 (skip)"
fi

# ── [2/3] iptables 백엔드 legacy 전환 ────────────────────────
echo ""
echo "[2/3] iptables 백엔드 → legacy 전환..."

# update-alternatives 는 대상 파일이 있어야 동작
if [ -f /usr/sbin/iptables-legacy ]; then
    update-alternatives --set iptables /usr/sbin/iptables-legacy >/dev/null 2>&1 || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >/dev/null 2>&1 || true
    echo "  → iptables/ip6tables → legacy 설정 완료"
else
    echo -e "  ${YELLOW}! iptables-legacy 미존재 (iptables 패키지 설치 후 재실행 필요)${NC}"
    echo "    sudo apt-get install -y iptables"
fi

# ── [3/3] swap 비활성화 (일시) ───────────────────────────────
echo ""
echo "[3/3] swap 비활성화..."
swapoff -a 2>/dev/null || true
echo "  → swapoff -a 실행 (WSL2 재기동 시 /etc/wsl.conf 로 영구화 가능)"

# ── 완료 안내 ────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " 사전 설정 완료"
echo "============================================================"

if [ "$NEED_RESTART" -eq 1 ]; then
    echo -e "${YELLOW}"
    echo " [중요] WSL2 재기동이 필요합니다."
    echo ""
    echo "   Windows PowerShell/CMD 에서 아래 명령 실행:"
    echo ""
    echo "       wsl --shutdown"
    echo ""
    echo "   이후 WSL2 재진입 → sudo scripts/install.sh 실행"
    echo -e "${NC}"
else
    echo -e "${GREEN} 재기동 불필요 — 바로 sudo scripts/install.sh 실행 가능${NC}"
fi
echo "============================================================"
