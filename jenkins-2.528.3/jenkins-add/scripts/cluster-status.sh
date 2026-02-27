#!/bin/bash
# cluster-status.sh — 클러스터 전체 상태 빠르게 확인

echo "=== Nodes ==="
kubectl get nodes -o wide

echo ""
echo "=== Namespaces ==="
kubectl get ns

echo ""
echo "=== All Pods (non-Running) ==="
kubectl get pods -A --field-selector='status.phase!=Running' 2>/dev/null | grep -v "Completed" || echo "(all running)"

echo ""
echo "=== All Pods ==="
kubectl get pods -A

echo ""
echo "=== Helm Releases ==="
helm list -A

echo ""
echo "=== Containerd Images (k8s.io) ==="
ctr -n k8s.io images ls | awk 'NR==1 || NR>1 {print $1, $2}' | column -t
