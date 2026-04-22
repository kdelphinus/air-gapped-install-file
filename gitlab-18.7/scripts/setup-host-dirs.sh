#!/bin/bash

# ==============================================================================
# [Phase 2] GitLab 데이터 영속성을 위한 호스트 디렉토리 생성 스크립트
#
# [실행 위치] GitLab 데이터가 저장될 각 워커 노드에서 실행
#             (또는 Ansible 등으로 일괄 실행)
#
# 생성 경로:
#   /data/gitlab_data  — Gitaly (Git 리포지토리) 데이터
#   /data/gitlab_pg    — PostgreSQL 데이터
#   /data/gitlab_redis — Redis 데이터
#   /data/gitlab_data/minio — MinIO 오브젝트 스토리지 데이터
# ==============================================================================

set -e

# [설정] 경로를 변경하려면 아래 변수를 수정하세요.
# gitlab-pv.yaml 의 spec.hostPath.path 값과 반드시 일치해야 합니다.
DATA_ROOT="/data"
GITLAB_DATA="${DATA_ROOT}/gitlab_data"
GITLAB_PG="${DATA_ROOT}/gitlab_pg"
GITLAB_REDIS="${DATA_ROOT}/gitlab_redis"
GITLAB_MINIO="${DATA_ROOT}/gitlab_data/minio"

echo "=========================================="
echo "📁 GitLab 호스트 디렉토리 생성을 시작합니다."
echo "=========================================="

sudo mkdir -p "$GITLAB_DATA"
sudo mkdir -p "$GITLAB_PG"
sudo mkdir -p "$GITLAB_REDIS"
sudo mkdir -p "$GITLAB_MINIO"

sudo chmod -R 777 "$DATA_ROOT"

echo ""
echo "✅ 디렉토리 생성 완료:"
ls -ld "$GITLAB_DATA" "$GITLAB_PG" "$GITLAB_REDIS" "$GITLAB_MINIO"
echo ""
echo "💡 다음 단계: Master 노드에서 'kubectl apply -f gitlab-pv.yaml' 을 실행하세요."
echo "=========================================="
