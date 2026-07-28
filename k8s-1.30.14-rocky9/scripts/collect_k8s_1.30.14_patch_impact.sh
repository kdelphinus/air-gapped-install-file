#!/bin/bash

set -u
set -o pipefail

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
OUTPUT_DIR="${1:-k8s-v1.30.14-impact-${TIMESTAMP}}"

log() {
  printf '[INFO] %s\n' "$*"
}

collect() {
  local name="$1"
  shift

  {
    printf '# Command\n\n```bash\n'
    printf '%q ' "$@"
    printf '\n```\n\n# Output\n\n```text\n'
    "$@" 2>&1
    printf '```\n'
  } > "${OUTPUT_DIR}/${name}.md"
}

command -v kubectl >/dev/null 2>&1 || {
  printf '[ERROR] kubectl이 필요합니다.\n' >&2
  exit 1
}

mkdir -p "${OUTPUT_DIR}"

log "클러스터 기본 상태 수집"
collect 01-version kubectl version
collect 02-nodes kubectl get nodes -o wide
collect 03-pods kubectl get pods -A -o wide
collect 04-workloads kubectl get deployment,statefulset,daemonset -A -o wide
collect 05-pdb kubectl get poddisruptionbudget -A -o wide
collect 06-services kubectl get service,endpointslice -A -o wide
collect 07-storage kubectl get pv,pvc -A -o wide
collect 08-ingress kubectl get ingress -A -o wide
collect 09-gateway kubectl get gateway,httproute -A -o wide
collect 10-events kubectl get events -A \
  --sort-by=.metadata.creationTimestamp
collect 11-system-pods kubectl get pods -n kube-system -o wide

log "중단 위험 항목 수집"
kubectl get deployment -A \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas' \
  > "${OUTPUT_DIR}/risk-single-replica-deployments.txt" 2>&1

kubectl get statefulset -A \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,CURRENT:.status.currentReplicas' \
  > "${OUTPUT_DIR}/risk-statefulsets.txt" 2>&1

kubectl get poddisruptionbudget -A \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,MIN-AVAILABLE:.spec.minAvailable,MAX-UNAVAILABLE:.spec.maxUnavailable,ALLOWED-DISRUPTIONS:.status.disruptionsAllowed' \
  > "${OUTPUT_DIR}/risk-pdb.txt" 2>&1

kubectl get pv \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,STORAGECLASS:.spec.storageClassName,NODE-AFFINITY:.spec.nodeAffinity.required.nodeSelectorTerms[*].matchExpressions[*].values[*],HOSTPATH:.spec.hostPath.path,LOCAL:.spec.local.path' \
  > "${OUTPUT_DIR}/risk-local-storage.txt" 2>&1

kubectl get pods -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.nodeName}{"\t"}{range .spec.volumes[*]}{.name}{":hostPath="}{.hostPath.path}{":emptyDir="}{.emptyDir.medium}{";"}{end}{"\n"}{end}' \
  > "${OUTPUT_DIR}/risk-pod-volumes.txt" 2>&1

kubectl get pods -A \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName,OWNER-KIND:.metadata.ownerReferences[0].kind,OWNER:.metadata.ownerReferences[0].name,PHASE:.status.phase' \
  > "${OUTPUT_DIR}/risk-pod-owners.txt" 2>&1

kubectl get deployment -A \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,REPLICAS:.spec.replicas,NODE-SELECTOR:.spec.template.spec.nodeSelector,ANTI-AFFINITY:.spec.template.spec.affinity.podAntiAffinity' \
  > "${OUTPUT_DIR}/risk-deployment-placement.txt" 2>&1

cat > "${OUTPUT_DIR}/README.md" <<'EOF'
# Kubernetes v1.30.14 패치 영향도 사전점검 결과

이 디렉터리는 조회 명령만 실행하여 생성한 결과입니다. Secret 값과 전체 Pod YAML은
수집하지 않습니다.

다음 항목이 있으면 노드 `drain` 전에 서비스 담당자와 조치 방법을 확정합니다.

- Deployment 또는 StatefulSet의 replica가 1인 서비스
- `ALLOWED-DISRUPTIONS`가 0인 PodDisruptionBudget
- 동일 서비스의 Pod가 한 노드에 집중된 경우
- `hostPath`, Local PV 또는 `emptyDir`에 의존하는 Pod
- Deployment, StatefulSet, DaemonSet, Job이 소유하지 않는 단독 Pod
- 여유 Worker 자원이 부족하여 대체 Pod를 배치할 수 없는 경우
- Envoy Gateway, CoreDNS, 인증, 저장소 등 공통 서비스가 단일 replica인 경우

`risk-*.txt` 파일을 먼저 검토하고, 전체 현황은 번호가 붙은 Markdown 파일에서
확인합니다.
EOF

log "완료: ${OUTPUT_DIR}"
