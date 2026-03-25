#!/bin/bash
cd "$(dirname "$0")/.."

echo "📂 HostPath 디렉토리 생성 (/data/redis-stream/*)"
sudo mkdir -p /data/redis-stream/master
sudo mkdir -p /data/redis-stream/replica-0
sudo mkdir -p /data/redis-stream/replica-1

sudo chmod -R 777 /data/redis-stream
echo "✅ 호스트 디렉토리 준비 완료"
