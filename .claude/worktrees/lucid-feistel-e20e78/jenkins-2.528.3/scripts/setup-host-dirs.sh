#!/bin/bash

# ==============================================================================
# [Phase 2] Jenkins 데이터 영속성을 위한 호스트 디렉토리 생성 스크립트
#
# [실행 위치] Jenkins 데이터가 저장될 각 워커 노드에서 실행
#             (또는 Ansible 등으로 일괄 실행)
#
# 생성 경로:
#   /data/jenkins      — Jenkins 홈 디렉토리 (PV: jenkins-pv)
#
# 참고:
#   /data/gradle-cache — gradle-cache-pv 의 hostPath type 이 DirectoryOrCreate 이므로
#                        Kubernetes 가 자동 생성합니다. 수동 생성 불필요.
# ==============================================================================

set -e

# [설정] 경로를 변경하려면 아래 변수를 수정하세요.
# pv-volume.yaml 의 spec.hostPath.path 값과 반드시 일치해야 합니다.
DATA_ROOT="/data"
JENKINS_DATA="${DATA_ROOT}/jenkins"

echo "=========================================="
echo "📁 Jenkins 호스트 디렉토리 생성을 시작합니다."
echo "=========================================="

sudo mkdir -p "$JENKINS_DATA"
sudo chmod -R 777 "$JENKINS_DATA"

echo ""
echo "✅ 디렉토리 생성 완료:"
ls -ld "$JENKINS_DATA"
echo ""
echo "💡 다음 단계: Master 노드에서 'sudo bash deploy-jenkins.sh' 을 실행하세요."
echo "   (deploy-jenkins.sh 내부에서 pv-volume.yaml 이 자동으로 적용됩니다.)"
echo "=========================================="
