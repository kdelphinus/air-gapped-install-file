# Kubernetes v1.33.11 (Ubuntu 24.04) 재부팅 운영 가이드

> **대상 환경**: Ubuntu 24.04 LTS + Kubernetes v1.33.11 (kubeadm) + containerd v2.2.x
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
5. [WSL2 환경 추가 절차](#5-wsl2-환경-추가-절차)
6. [트러블슈팅](#6-트러블슈팅)
7. [체크리스트](#7-체크리스트)

---

## 1. 개요

### 1.1 적용 범위

- 단일 구성 (Master 1 + Worker N)
- HA 구성 (Master 3 + Worker N + VIP, HAProxy + Keepalived)
- WSL2 단일 노드 (개발/검증용)

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
# Pod Disruption Budget 확인 — drain 시 막힐 수 있음
kubectl get pdb -A

# 단일 인스턴스로만 운영되는 중요 워크로드 식별
kubectl get deploy,sts -A -o json \
  | jq -r '.items[] | select(.spec.replicas==1) | "\(.kind)/\(.metadata.namespace)/\(.metadata.name)"'
```

### 2.3 영구 설정 사전 검증 (재부팅 후 비정상 방지)

```bash
# 1. swap 영구 비활성 확인
sudo swapon --show          # 출력 없어야 정상
grep -v '^#' /etc/fstab | grep -i swap   # 출력 없어야 정상

# 2. 필수 커널 모듈 영구 로드
cat /etc/modules-load.d/k8s.conf 2>/dev/null
# 기대: br_netfilter, overlay (없으면 추가 후 sudo modprobe)

# 3. sysctl 영구 적용
ls /etc/sysctl.d/k8s.conf 2>/dev/null
sudo sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward

# 4. 자동 시작 서비스 enabled 확인
systemctl is-enabled kubelet containerd
# HA 마스터: 추가로
systemctl is-enabled haproxy keepalived
```

### 2.4 NFS / 외부 스토리지 의존성 확인

```bash
# 외부 NFS 등을 PV 로 쓰는 경우 마운트 가능 여부 사전 점검
mount | grep nfs
df -hT | grep -E 'nfs|cifs'
```

NFS export 가 변경되었거나 firewall 정책이 바뀐 경우 재부팅 후 PV mount 실패 가능.

---

## 3. 재부팅 순서

### 3.1 단일 구성 (Master 1 + Worker N)

```text
Worker N → … → Worker 1 → Master 1
```

각 노드별 절차:

```bash
# (워커) drain
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=10m

# 재부팅
sudo systemctl reboot

# 노드 복귀 후
kubectl uncordon <node>
kubectl wait --for=condition=Ready node/<node> --timeout=10m
```

**Master 단독 재부팅 시 주의**: API 서버가 일시적으로 끊어집니다 (~1–3분).
운영 영향이 있다면 점검 시간으로 공지하세요.

### 3.2 HA 구성 (Master 3 + Worker N)

#### 3.2.1 Worker 노드 (한 번에 1대씩)

```bash
# 워커별로
kubectl drain <worker-N> --ignore-daemonsets --delete-emptydir-data --timeout=10m
ssh <worker-N> sudo systemctl reboot
# 복귀 대기
kubectl wait --for=condition=Ready node/<worker-N> --timeout=10m
kubectl uncordon <worker-N>
```

#### 3.2.2 Master 노드 (반드시 한 번에 1대씩, VIP 보유 노드는 마지막)

**1) VIP 비보유 마스터부터 재부팅**

```bash
# 어떤 마스터가 VIP MASTER 인지 확인
for n in master-1 master-2 master-3; do
  ssh "$n" "ip -br addr | grep <VIP> && echo '  ↑ VIP holder: $n'"
done

# VIP 비보유 노드부터
NODE=master-2
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --timeout=10m
ssh $NODE sudo systemctl reboot

# etcd quorum 유지 + 노드 Ready 까지 대기
kubectl wait --for=condition=Ready node/$NODE --timeout=10m
kubectl get pods -n kube-system -o wide | grep -E "etcd-$NODE|kube-apiserver-$NODE"
# 모두 Running 인지 확인 후 다음 노드로 진행
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

3개 멤버 모두 `IS LEADER` 또는 follower 로 응답해야 다음 단계로.

**3) VIP 보유 마스터 마지막**

VIP 보유 노드를 재부팅하면 Keepalived 가 다른 마스터로 페일오버합니다.
페일오버 중 1–3초 API 단절이 가능하므로 가급적 점검 시간에 수행.

```bash
# (VIP 보유 노드 재부팅 직전)
# 다른 마스터에서 VIP 페일오버 모니터링
watch -n1 'ip -br addr | grep <VIP>; date'

# VIP 보유 노드 재부팅
ssh <vip-master> sudo systemctl reboot

# 복귀 후 keepalived 가 BACKUP 으로 시작했는지 확인 (선점 비활성 권장)
ssh <vip-master> sudo journalctl -u keepalived -n 50 --no-pager | grep -E 'STATE|MASTER|BACKUP'
```

### 3.3 전체 클러스터 정전/콜드 부팅 복구

전원 동시 차단 후 일괄 부팅 시나리오:

```text
1. 모든 노드 부팅 → systemd 가 containerd / kubelet 자동 시작
2. (HA) Keepalived 가 VIP 결정 (가장 높은 priority 노드가 MASTER)
3. etcd 가 quorum 형성하면 kube-apiserver 가 정상화
4. 노드 Ready → 시스템 Pod (CoreDNS, kube-proxy/Cilium-agent, calico-node) 순차 Running
```

quorum 형성까지 보통 1–5분. 그 이상 걸리면 **6.트러블슈팅** 참조.

---

## 4. 재부팅 후 검증

### 4.1 노드 / 시스템 서비스 검증

```bash
# 1. 시스템 서비스
systemctl is-active containerd kubelet
# HA 마스터
systemctl is-active haproxy keepalived

# 2. 커널 설정
sudo swapon --show          # 비어 있어야 정상
lsmod | grep -E 'br_netfilter|overlay'
sudo sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward

# 3. 노드 상태
kubectl get nodes -o wide
kubectl describe node <node> | grep -A5 Conditions
```

### 4.2 시스템 Pod 정상화

```bash
# 모든 kube-system Pod Running
kubectl get pods -n kube-system -o wide

# Calico 사용 시
kubectl get pods -n kube-system -l k8s-app=calico-node -o wide

# Cilium 사용 시
kubectl get pods -n kube-system -l k8s-app=cilium -o wide
cilium status --wait 2>/dev/null || true   # CLI 가 있으면

# Envoy Gateway (옵션)
kubectl get pods -n envoy-gateway-system 2>/dev/null
```

### 4.3 워크로드 / Ingress / Storage 검증

```bash
# 모든 네임스페이스에서 비정상 Pod 식별
kubectl get pods -A | grep -vE 'Running|Completed'

# Ingress / NodePort / LoadBalancer 동작
kubectl get svc -A | grep -E 'NodePort|LoadBalancer'
curl -kI https://<node-ip>:30002/   # Harbor 등 핵심 서비스 헬스

# PV / PVC 상태 — 특히 NFS 기반
kubectl get pv,pvc -A | grep -vE 'Bound|Available'
```

### 4.4 (HA) VIP 페일오버 동작 확인

```bash
# VIP 가 정상 마스터에 한 명에게만 있는지
for n in master-1 master-2 master-3; do
  ssh "$n" "echo '=== '$n' ==='; ip -br addr | grep <VIP>"
done

# kubeconfig 가 가리키는 endpoint 로 API 응답 확인
kubectl --request-timeout=5s get --raw='/healthz'
```

---

## 5. WSL2 환경 추가 절차

WSL2 단일 노드 클러스터(`wsl2_prep.sh` 로 구성된 환경)는 호스트 Windows 재부팅 / `wsl --shutdown` 마다
WSL2 가상머신이 새로 뜨므로, 다음을 함께 점검합니다.

### 5.1 systemd / iptables-legacy 유지 확인

```bash
# /etc/wsl.conf 에 [boot] systemd=true 가 살아 있는지
cat /etc/wsl.conf

# iptables 가 legacy 모드인지 (nftables 모드면 kube-proxy / CNI 가 비정상)
sudo update-alternatives --display iptables | head -5
```

`auto` 모드면 다시 legacy 로 전환:

```bash
sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
```

### 5.2 컨트롤 플레인 엔드포인트 IP 변경 대응

WSL2 의 가상 네트워크 IP 는 재기동 시 변경될 수 있습니다.
`/etc/hosts` 또는 kubeadm 인증서에 IP 가 직접 박혀 있으면 API 가 실패합니다.

```bash
# 현재 IP 확인
hostname -I
# kubeconfig 의 server 주소
grep server ~/.kube/config
```

IP 가 바뀌었다면 단일 노드 환경에서는 **재설치가 가장 확실**합니다 (`scripts/uninstall.sh` → `scripts/install.sh`).
운영용으로는 WSL2 를 권장하지 않습니다.

---

## 6. 트러블슈팅

### 6.1 노드가 NotReady 로 머무름

```bash
# kubelet 로그
sudo journalctl -u kubelet -n 200 --no-pager

# 자주 발생하는 원인
# (a) swap 이 다시 켜짐
sudo swapon --show          # 켜져 있으면
sudo swapoff -a
# /etc/fstab 에서 swap 라인 주석 처리됐는지 재확인

# (b) containerd 가 죽었거나 cgroup driver 불일치
systemctl status containerd
sudo cat /etc/containerd/config.toml | grep -i SystemdCgroup
# kubelet 도 동일하게 systemd cgroup 인지
sudo cat /var/lib/kubelet/config.yaml | grep -i cgroupDriver
```

### 6.2 시스템 Pod (CoreDNS / CNI) 가 Running 안 됨

```bash
# 커널 모듈 / sysctl 누락
lsmod | grep -E 'br_netfilter|overlay'
# 누락이면
sudo modprobe br_netfilter overlay
sudo sysctl --system

# CNI Pod 재기동
kubectl -n kube-system rollout restart ds/calico-node 2>/dev/null
kubectl -n kube-system rollout restart ds/cilium 2>/dev/null
```

### 6.3 etcd quorum 손상 (마스터 2대 이상 동시 다운)

증상: `kubectl` 명령이 timeout.

```bash
# 살아있는 마스터에서 etcd 상태
sudo crictl ps | grep etcd
sudo crictl logs <etcd-container-id> 2>&1 | tail -50
```

복구 방향:

- 다운된 마스터를 **재부팅으로 복구**하는 것이 1순위 (데이터 그대로)
- 영구 손상 시 [install-guide.md](./install-guide.md) 의 etcd 복원 / 마스터 재합류 절차 참조

### 6.4 VIP 가 두 노드에 동시에 잡힘 (Split-Brain)

```bash
# 모든 마스터 점검
for n in master-1 master-2 master-3; do
  ssh "$n" 'ip -br addr | grep <VIP>; sudo systemctl status keepalived --no-pager | grep -E "Active|STATE"'
done
```

원인 대부분은 VRRP 멀티캐스트 차단(방화벽) 또는 priority 동일.
한쪽 keepalived 를 멈춰 정상화 후 네트워크 / 설정 점검:

```bash
# 한쪽에서
sudo systemctl stop keepalived
# (잠시 후) VIP 가 다른 노드 단독 보유 확인 후
sudo systemctl start keepalived
```

### 6.5 NFS PV 가 마운트 실패

```bash
# 노드에서 직접 마운트 테스트
sudo mount -t nfs <nfs-server>:/<export> /mnt/test
sudo umount /mnt/test
```

방화벽(ufw) / NFS 서버 export 정책 / `nfs-common` 패키지 확인.

```bash
sudo systemctl status ufw
dpkg -l | grep nfs-common
```

### 6.6 AppArmor / containerd 충돌

Ubuntu 24.04 기본 AppArmor 가 일부 컨테이너 프로필을 차단할 수 있음.

```bash
sudo aa-status | head -10
sudo journalctl -k | grep -i apparmor | tail -20
```

차단 로그가 보이면 해당 프로필을 complain 모드로 전환하거나 컨테이너 securityContext 조정.

---

## 7. 체크리스트

### 7.1 재부팅 전

- [ ] 모든 노드 `Ready`, 시스템 Pod 모두 `Running`
- [ ] etcd 3 멤버 정상 (HA)
- [ ] PDB 와 단일 replica 워크로드 영향 평가
- [ ] swap / 모듈 / sysctl / enabled 서비스 영구 설정 확인
- [ ] (HA) VIP 보유 노드 식별 → 마지막에 재부팅 예정으로 표시

### 7.2 재부팅 중 (노드별)

- [ ] (워커) drain 완료 후 재부팅
- [ ] 부팅 후 `containerd`, `kubelet` active
- [ ] 노드 `Ready`, 해당 노드의 시스템 Pod `Running`
- [ ] (마스터) etcd 멤버 healthy
- [ ] (필요 시) `kubectl uncordon`

### 7.3 재부팅 후 (전체)

- [ ] `kubectl get nodes` 모두 Ready
- [ ] `kubectl get pods -A` 비정상 Pod 없음
- [ ] (HA) VIP 단일 노드 보유, API healthz OK
- [ ] PV/PVC `Bound`, NFS 마운트 정상
- [ ] 핵심 서비스 응답 확인 (Harbor, Ingress, Gateway)
- [ ] 정전 / 비계획 재부팅이었다면 모니터링 알람·로그 확인

---

> **운영 팁**:
>
> - 점검 창은 **15–20분 / 노드** 로 잡는 것이 안전합니다 (drain + 재부팅 + Ready + Pod 정상화).
> - HA 마스터 3대 순차 재부팅 + 검증 시 총 60–90분 예상.
> - 사전에 [install-guide.md](./install-guide.md) 의 검증 명령을 한 번 더 훑어두면 좋습니다.
