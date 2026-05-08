# Kubernetes v1.30 (Rocky Linux 9.6) 재부팅 운영 가이드

> **대상 환경**: Rocky Linux 9.6 + Kubernetes v1.30 (kubeadm) + containerd
> **작성일**: 2026-05-08
> **참고 가이드**: [install-guide.md](./install-guide.md), [install-guide-online.md](./install-guide-online.md)

본 문서는 설치 가이드 기준으로 구축된 클러스터에서 **계획 재부팅 / 비계획 재부팅** 시 따라야 할 운영 절차입니다.
설치 단계에서 swap 영구 비활성, `systemctl enable kubelet/containerd/haproxy/keepalived`,
필수 커널 모듈 영구 로드(`/etc/modules-load.d/`)는 이미 적용되어 있다고 가정합니다.

---

## 목차

1. [개요](#1-개요)
2. [재부팅 전 점검](#2-재부팅-전-점검)
3. [재부팅 순서](#3-재부팅-순서)
4. [재부팅 후 검증](#4-재부팅-후-검증)
5. [트러블슈팅](#5-트러블슈팅)
6. [체크리스트](#6-체크리스트)

---

## 1. 개요

### 1.1 적용 범위

- 단일 구성 (Master 1 + Worker N)
- HA 구성 (Master 3 + Worker N + VIP, HAProxy + Keepalived)

### 1.2 핵심 원칙

| 원칙 | 이유 |
|------|------|
| **HA 환경에서 마스터는 한 번에 1대씩** | etcd quorum (3대 중 2대 이상 정상) 유지 |
| **워커는 `kubectl drain` 후 재부팅** | Pod evict 누락 시 PDB 위반 / 서비스 단절 |
| **재부팅 후 노드 Ready + 시스템 Pod Running 까지 대기** | 다음 노드 진행 전 동기화 보장 |
| **VIP 페일오버 검증** | Keepalived MASTER 전환 / API 단절 방지 |

---

## 2. 재부팅 전 점검

### 2.1 클러스터 상태 확인

```bash
# 모든 노드 Ready 확인
kubectl get nodes -o wide

# 시스템 Pod 정상 여부
kubectl get pods -A | grep -vE 'Running|Completed' | head

# etcd 멤버십 (HA, Master-1 에서)
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table

# (HA) VIP 현재 보유 노드 확인
ip -br addr | grep <VIP>
sudo systemctl status keepalived --no-pager | grep -E 'STATE|Active'
```

✅ **통과 기준**: 모든 노드 `Ready`, `kube-system` Pod 모두 `Running`, etcd 3개 멤버 모두 `started`.
하나라도 비정상이면 **재부팅 보류**하고 원인 해소 후 진행.

### 2.2 PDB / 워크로드 영향 확인

```bash
kubectl get pdb -A

# 단일 replica 인 중요 워크로드 식별
kubectl get deploy,sts -A -o json \
  | jq -r '.items[] | select(.spec.replicas==1) | "\(.kind)/\(.metadata.namespace)/\(.metadata.name)"'
```

### 2.3 영구 설정 사전 검증

```bash
# 1. swap 영구 비활성
sudo swapon --show          # 출력 없어야 정상
grep -v '^#' /etc/fstab | grep -i swap   # 출력 없어야 정상

# 2. 필수 커널 모듈 영구 로드
cat /etc/modules-load.d/k8s.conf 2>/dev/null
# 기대: br_netfilter, overlay

# 3. sysctl 영구 적용
ls /etc/sysctl.d/k8s.conf 2>/dev/null
sudo sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward

# 4. 자동 시작 서비스
systemctl is-enabled kubelet containerd
# HA 마스터: 추가로
systemctl is-enabled haproxy keepalived

# 5. SELinux 모드 (Rocky 9 — k8s 권장: permissive)
getenforce
# Enforcing 이면 /etc/selinux/config 가 permissive 인지 확인
sudo grep ^SELINUX= /etc/selinux/config

# 6. firewalld 정책 (사용 중이라면)
sudo systemctl is-active firewalld
sudo firewall-cmd --list-all 2>/dev/null
```

### 2.4 NFS / 외부 스토리지 의존성

```bash
mount | grep nfs
df -hT | grep -E 'nfs|cifs'
rpm -q nfs-utils
```

---

## 3. 재부팅 순서

### 3.1 단일 구성

```text
Worker N → … → Worker 1 → Master 1
```

```bash
# (워커) drain
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=10m

# 재부팅
sudo systemctl reboot

# 복귀 후
kubectl uncordon <node>
kubectl wait --for=condition=Ready node/<node> --timeout=10m
```

**Master 단독 재부팅 시**: API 서버가 일시적으로 끊어집니다 (~1–3분). 점검 시간으로 공지하세요.

### 3.2 HA 구성 (Master 3 + Worker N)

#### 3.2.1 Worker 노드 (한 번에 1대씩)

```bash
kubectl drain <worker-N> --ignore-daemonsets --delete-emptydir-data --timeout=10m
ssh <worker-N> sudo systemctl reboot
kubectl wait --for=condition=Ready node/<worker-N> --timeout=10m
kubectl uncordon <worker-N>
```

#### 3.2.2 Master 노드 (반드시 한 번에 1대씩, VIP 보유 노드는 마지막)

**1) VIP 비보유 마스터부터**

```bash
# VIP 보유 노드 식별
for n in master-1 master-2 master-3; do
  ssh "$n" "ip -br addr | grep <VIP> && echo '  ↑ VIP holder: $n'"
done

NODE=master-2
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --timeout=10m
ssh $NODE sudo systemctl reboot

kubectl wait --for=condition=Ready node/$NODE --timeout=10m
kubectl get pods -n kube-system -o wide | grep -E "etcd-$NODE|kube-apiserver-$NODE"
kubectl uncordon $NODE
```

**2) etcd quorum 회복 확인 (다음 마스터 재부팅 전 필수)**

```bash
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --cluster -w table
```

3개 멤버 모두 응답 후 다음 단계로.

**3) VIP 보유 마스터 마지막**

```bash
# 다른 마스터에서 VIP 페일오버 모니터링
watch -n1 'ip -br addr | grep <VIP>; date'

# VIP 보유 노드 재부팅
ssh <vip-master> sudo systemctl reboot

# 복귀 후 keepalived 상태 (선점 비활성 권장)
ssh <vip-master> sudo journalctl -u keepalived -n 50 --no-pager | grep -E 'STATE|MASTER|BACKUP'
```

### 3.3 전체 클러스터 정전/콜드 부팅 복구

```text
1. 모든 노드 부팅 → systemd 가 containerd / kubelet 자동 시작
2. (HA) Keepalived 가 VIP 결정
3. etcd quorum 형성 → kube-apiserver 정상화
4. 노드 Ready → 시스템 Pod 순차 Running
```

quorum 형성까지 1–5분. 그 이상이면 **5. 트러블슈팅** 참조.

---

## 4. 재부팅 후 검증

### 4.1 노드 / 시스템 서비스

```bash
systemctl is-active containerd kubelet
# HA 마스터
systemctl is-active haproxy keepalived

# 커널 / 네트워크
sudo swapon --show
lsmod | grep -E 'br_netfilter|overlay'
sudo sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward

# SELinux
getenforce

# 노드 상태
kubectl get nodes -o wide
kubectl describe node <node> | grep -A5 Conditions
```

### 4.2 시스템 Pod 정상화

```bash
kubectl get pods -n kube-system -o wide

# Calico
kubectl get pods -n kube-system -l k8s-app=calico-node -o wide

# Cilium (사용 시)
kubectl get pods -n kube-system -l k8s-app=cilium -o wide

# Ingress / Gateway 등 핵심 컴포넌트
kubectl get pods -A | grep -vE 'Running|Completed'
```

### 4.3 워크로드 / Ingress / Storage

```bash
kubectl get svc -A | grep -E 'NodePort|LoadBalancer'
curl -kI https://<node-ip>:30002/   # Harbor 등

kubectl get pv,pvc -A | grep -vE 'Bound|Available'
```

### 4.4 (HA) VIP 페일오버 동작

```bash
for n in master-1 master-2 master-3; do
  ssh "$n" "echo '=== '$n' ==='; ip -br addr | grep <VIP>"
done

kubectl --request-timeout=5s get --raw='/healthz'
```

---

## 5. 트러블슈팅

### 5.1 노드가 NotReady

```bash
sudo journalctl -u kubelet -n 200 --no-pager

# (a) swap 이 다시 켜짐
sudo swapon --show
sudo swapoff -a

# (b) containerd / cgroup driver 불일치
systemctl status containerd
sudo grep -i SystemdCgroup /etc/containerd/config.toml
sudo grep -i cgroupDriver /var/lib/kubelet/config.yaml

# (c) SELinux 차단 로그
sudo ausearch -m AVC -ts recent 2>/dev/null | tail -20
# 임시 완화 (운영 적용 전 정책 검토 필요)
sudo setenforce 0
```

### 5.2 시스템 Pod (CoreDNS / CNI) 가 Running 안 됨

```bash
lsmod | grep -E 'br_netfilter|overlay'
sudo modprobe br_netfilter overlay
sudo sysctl --system

kubectl -n kube-system rollout restart ds/calico-node 2>/dev/null
kubectl -n kube-system rollout restart ds/cilium 2>/dev/null
```

### 5.3 etcd quorum 손상

```bash
sudo crictl ps | grep etcd
sudo crictl logs <etcd-container-id> 2>&1 | tail -50
```

복구 방향:

- 다운된 마스터를 **재부팅으로 복구**하는 것이 1순위
- 영구 손상 시 [install-guide.md](./install-guide.md) 의 etcd 복원 / 마스터 재합류 절차 참조

### 5.4 VIP Split-Brain (두 노드 동시 보유)

```bash
for n in master-1 master-2 master-3; do
  ssh "$n" 'ip -br addr | grep <VIP>; sudo systemctl status keepalived --no-pager | grep -E "Active|STATE"'
done
```

원인: VRRP 멀티캐스트 차단(firewalld) 또는 priority 동일.

```bash
# firewalld 가 VRRP(IP protocol 112) 를 막고 있는지
sudo firewall-cmd --list-all
# 필요 시 (해당 인터페이스 zone 에서)
sudo firewall-cmd --add-rich-rule='rule protocol value="vrrp" accept' --permanent
sudo firewall-cmd --reload
```

### 5.5 NFS PV 마운트 실패

```bash
# 노드에서 직접 마운트 테스트
sudo mount -t nfs <nfs-server>:/<export> /mnt/test
sudo umount /mnt/test

# 패키지 / 서비스
rpm -q nfs-utils
sudo systemctl status rpc-statd 2>/dev/null

# firewalld
sudo firewall-cmd --list-all | grep -E 'nfs|2049|111'
```

### 5.6 firewalld / iptables 규칙 충돌

K8s 가 자체 iptables/nftables 규칙을 생성하므로, firewalld 가 재부팅 후 규칙을 덮어쓸 수 있습니다.

```bash
sudo iptables -L KUBE-IPTABLES-HINT 2>/dev/null
sudo nft list ruleset 2>/dev/null | head -50
```

설치 가이드에서 firewalld 비활성을 권장한 환경이라면 재부팅 후에도 비활성인지 재확인:

```bash
sudo systemctl is-enabled firewalld
sudo systemctl is-active firewalld
```

---

## 6. 체크리스트

### 6.1 재부팅 전

- [ ] 모든 노드 `Ready`, 시스템 Pod 모두 `Running`
- [ ] etcd 3 멤버 정상 (HA)
- [ ] PDB 와 단일 replica 워크로드 영향 평가
- [ ] swap / 모듈 / sysctl / SELinux / enabled 서비스 영구 설정 확인
- [ ] (HA) VIP 보유 노드 식별 → 마지막에 재부팅 예정으로 표시

### 6.2 재부팅 중 (노드별)

- [ ] (워커) drain 완료 후 재부팅
- [ ] 부팅 후 `containerd`, `kubelet` active
- [ ] 노드 `Ready`, 해당 노드의 시스템 Pod `Running`
- [ ] (마스터) etcd 멤버 healthy
- [ ] (필요 시) `kubectl uncordon`

### 6.3 재부팅 후 (전체)

- [ ] `kubectl get nodes` 모두 Ready
- [ ] `kubectl get pods -A` 비정상 Pod 없음
- [ ] (HA) VIP 단일 노드 보유, API healthz OK
- [ ] PV/PVC `Bound`, NFS 마운트 정상
- [ ] 핵심 서비스 응답 확인 (Harbor, Ingress, Gateway)
- [ ] 정전 / 비계획 재부팅이었다면 모니터링 알람·로그 확인

---

> **운영 팁**:
>
> - 점검 창은 **15–20분 / 노드** 로 잡는 것이 안전합니다.
> - HA 마스터 3대 순차 재부팅 + 검증 시 총 60–90분 예상.
> - 사전에 [install-guide.md](./install-guide.md) 의 검증 명령을 한 번 더 훑어두면 좋습니다.
