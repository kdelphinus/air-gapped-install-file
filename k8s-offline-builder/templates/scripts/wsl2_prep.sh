#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if ! grep -qi "microsoft" /proc/version 2>/dev/null; then
    echo -e "${RED}[오류] 이 스크립트는 WSL2 환경에서만 실행 가능합니다.${NC}"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[오류] 이 스크립트는 root 권한(sudo)으로 실행해야 합니다.${NC}"
    exit 1
fi

echo "============================================================"
echo " WSL2 Kubernetes 사전 설정"
echo "============================================================"

WSL_CONF="/etc/wsl.conf"
NEED_RESTART=0

echo "[1/3] systemd 활성화..."
if [ ! -f "$WSL_CONF" ]; then
    cat > "$WSL_CONF" <<EOF
[boot]
systemd=true
EOF
    NEED_RESTART=1
elif ! grep -qE "^\s*systemd\s*=\s*true" "$WSL_CONF"; then
    if grep -qE "^\s*\[boot\]" "$WSL_CONF"; then
        sed -i '/^\s*\[boot\]/a systemd=true' "$WSL_CONF"
    else
        printf "\n[boot]\nsystemd=true\n" >> "$WSL_CONF"
    fi
    NEED_RESTART=1
fi

echo "[2/3] iptables legacy 전환..."
if [ -f /usr/sbin/iptables-legacy ]; then
    update-alternatives --set iptables /usr/sbin/iptables-legacy >/dev/null 2>&1 || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >/dev/null 2>&1 || true
else
    echo -e "${YELLOW}iptables-legacy 미존재: iptables 패키지 설치 후 재실행하세요.${NC}"
fi

echo "[3/3] swap 비활성화..."
swapoff -a 2>/dev/null || true

if [ "$NEED_RESTART" -eq 1 ]; then
    echo -e "${YELLOW}WSL2 재기동이 필요합니다: Windows PowerShell/CMD 에서 wsl --shutdown 실행${NC}"
else
    echo -e "${GREEN}재기동 없이 install.sh 실행 가능합니다.${NC}"
fi
