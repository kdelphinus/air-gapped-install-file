#!/bin/bash
cd "$(dirname "$0")/.." || exit 1

NODE_NAME="${1:-}"
BASE_PATH="${2:-/data/redis-stream}"
LOCAL_HOSTNAME=$(hostname)

echo "📂 HostPath 디렉토리 생성 (${BASE_PATH}/*)"

if [ -n "$NODE_NAME" ] && [ "$NODE_NAME" != "$LOCAL_HOSTNAME" ]; then
    echo "⚠️  대상 노드($NODE_NAME)가 현재 호스트($LOCAL_HOSTNAME)와 다릅니다."
    echo "   대상 노드에 SSH 접속 후 다음 명령을 실행하세요:"
    echo ""
    echo "   ssh $NODE_NAME 'sudo mkdir -p ${BASE_PATH}/{master,replica-0,replica-1} && sudo chmod -R 777 ${BASE_PATH}'"
    echo ""
    exit 0
fi

sudo mkdir -p "${BASE_PATH}/master"
sudo mkdir -p "${BASE_PATH}/replica-0"
sudo mkdir -p "${BASE_PATH}/replica-1"

sudo chmod -R 777 "${BASE_PATH}"
echo "✅ 호스트 디렉토리 준비 완료 (${BASE_PATH})"
