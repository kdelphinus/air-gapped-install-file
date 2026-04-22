# Kubernetes v1.33.11 오프라인 설치 가이드 (Ubuntu 24.04)

폐쇄망 환경에서 kubeadm 기반 Kubernetes v1.33.11 클러스터를 구성하는 수동 절차입니다.
containerd v2.2.x를 컨테이너 런타임으로, CNI는 **Calico(+ Envoy Gateway)** 또는 **Cilium** 중 선택합니다.

> 스크립트를 이용한 빠른 설치는 아래 **스크립트 사용 가이드** 섹션을 먼저 참고하세요.
> 수동 절차(Phase 0~10)는 내부 동작 이해 및 트러블슈팅용입니다.
>
> 온라인 설치는 `install-guide-online.md`를 참고하세요.

## 스크립트 사용 가이드

### 자동 / 수동 처리 범위

| 작업 | 단일 구성 | HA 구성 |
| --- | --- | --- |
| DEB 설치 · OS 설정 · containerd · 이미지 로드 | ✅ 자동 | ✅ 자동 |
| kubeadm init / join | ✅ 자동 | ✅ 자동 |
| kubeconfig 설정 | ✅ 자동 | ✅ 자동 |
| CNI 설치 (auto 선택 시) | ✅ 자동 | ✅ 자동 |
| HAProxy 중지/재시작 (충돌 방지) | — | ✅ 자동 (설치된 경우 감지) |
| HAProxy · Keepalived 설치 및 설정 | — | **🔧 수동 (Phase 5)** |
| kube-apiserver `--bind-address` 설정 | — | **🔧 수동 (각 마스터 init/join 직후)** |
| `/etc/hosts` FQDN 등록 | — | **🔧 수동 (FQDN 방식 선택 시)** |

### 스크립트 목록

| 스크립트 | 실행 위치 | 설명 |
| --- | --- | --- |
| `scripts/download.sh` | 인터넷 호스트 (root) | 오프라인 설치 파일 수집 → `k8s/` 채움 |
| `scripts/wsl2_prep.sh` | WSL2 노드 (root) | systemd 활성화 + iptables-legacy 전환 |
| `scripts/install.sh` | Master-1 (root) | 컨트롤 플레인 설치 (CNI·Gateway 포함) |
| `scripts/install.sh --join <token> <hash> <ep>` | Worker (root) | 워커 노드 합류 |
| `scripts/install.sh --join <token> <hash> <ep> --control-plane <cert-key>` | Master-2, 3 (root) | 추가 마스터 합류 |
| `scripts/uninstall.sh` | 모든 노드 (root) | 클러스터 초기화 |

---

### 구성 유형별 실행 순서

#### 단일 구성 (WSL2 / 단일 VM)

```
[WSL2만] scripts/wsl2_prep.sh  →  wsl --shutdown 재기동
    ↓
[Master-1] scripts/install.sh
    - 환경 확인 (wsl2 / vm)
    - CNI 선택 + Pod CIDR
    - CNI 설치 모드 (auto / manual)
    - Service CIDR
    - 컨트롤 플레인 엔드포인트 (노드 IP, WSL2는 자동 감지)
    ↓
완료 — 클러스터 Ready
```

#### HA 구성 (Master 3대 + Worker N대)

```
[전체 노드] 파일 배포 (scp + tar 해제)

[전체 마스터] 🔧 수동: Phase 5 — HAProxy + Keepalived 설치/설정 + VIP 확인

[전체 마스터, FQDN 방식] 🔧 수동: /etc/hosts 에 VIP → FQDN 등록

[Master-1] scripts/install.sh
    - 환경 확인 (vm)
    - CNI 선택 + Pod CIDR
    - CNI 설치 모드
    - Service CIDR
    - 컨트롤 플레인 엔드포인트: VIP 또는 FQDN 입력
    ※ HAProxy 자동 중지 → kubeadm init → HAProxy 자동 재시작
    ↓
[Master-1] 🔧 수동: kube-apiserver bind-address 설정 (아래 참고)
    ↓
[Master-2, 3] scripts/install.sh --join <token> <hash> <endpoint> --control-plane <cert-key>
    ※ HAProxy 자동 중지 → kubeadm join → HAProxy 자동 재시작
    ↓
[Master-2, 3] 🔧 수동: kube-apiserver bind-address 설정 (아래 참고)
    ↓
[Worker 1~N] scripts/install.sh --join <token> <hash> <endpoint>
    ↓
완료 — 클러스터 Ready
```

> `install.sh` 완료 시 워커/마스터 합류 명령(실제 토큰·hash 포함)이 자동 출력됩니다.
> certificate-key는 1시간 유효입니다. 만료 시 Master-1에서 재생성:
>
> ```bash
> kubeadm init phase upload-certs --upload-certs
> ```

---

### Step 1 — 파일 수집 (인터넷 호스트)

```bash
cd k8s-1.33.11-ubuntu24.04
sudo ./scripts/download.sh
# 완료 후 tar 묶음 생성 안내가 출력됨

cd ..
tar czf k8s-1.33.11-ubuntu24.04.tar.gz k8s-1.33.11-ubuntu24.04/
```

### Step 2 — WSL2 전용: systemd 활성화 (최초 1회)

```bash
sudo ./scripts/wsl2_prep.sh
# "재기동 필요" 안내가 나오면 Windows 터미널에서:
#   wsl --shutdown
# 이후 WSL2 재진입 후 Step 3 진행
```

### Step 3 — 컨트롤 플레인 설치 (Master-1)

**⚠️ HA(3중화) 구성이라면 `install.sh` 실행 전에 반드시 Phase 5(로드밸런서 구성)를 먼저 완료하세요.**
HAProxy + Keepalived로 VIP를 확보한 뒤, 아래 스크립트 실행 시 엔드포인트에 VIP 또는 FQDN을 입력해야 합니다.
단일 구성(WSL2 / 단일 컨트롤 플레인)이라면 이 주의사항은 무시하세요.

```bash
sudo ./scripts/install.sh
# 대화형 메뉴:
#   1) 환경 확인 (wsl2 / vm)
#   2) CNI 선택 (calico / cilium) + Pod CIDR
#   3) CNI 설치 모드 (auto / manual)
#   4) Envoy Gateway 모드 (calico+auto 선택 시)
#   5) Service CIDR
#   6) 컨트롤 플레인 엔드포인트
#      → 단일: 노드 IP (WSL2는 자동 감지)
#      → HA  : VIP 또는 FQDN
```

**HA 구성이라면** 완료 후 즉시 아래를 수동으로 수행합니다.

#### 🔧 [HA 전용] kube-apiserver bind-address 설정

kube-apiserver가 기본 `0.0.0.0`으로 바인딩되면 HAProxy와 포트 충돌이 발생합니다.
이 노드의 실제 IP로 고정하세요.

```bash
# 이 노드의 실제 IP 확인
ip -4 -o addr show | grep -v '127\.' | awk '{print $4}' | cut -d/ -f1

# kube-apiserver 매니페스트 편집
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
# spec.containers[].command 섹션에 추가:
# - --bind-address=<이 노드의 실제 IP>   # 예: 192.168.10.11
```

저장 후 kubelet이 자동으로 apiserver를 재기동합니다. 약 30초 후 확인:

```bash
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock pods \
    --namespace kube-system | grep apiserver
# Running 확인 후 HAProxy 정상 동작 확인
curl -k https://<VIP>:6443/livez
```

### Step 4 — 추가 마스터 합류 (Master-2, 3 — HA 구성 시에만)

`install.sh` 완료 시 출력된 명령어를 그대로 사용합니다.
certificate-key가 만료됐다면 Master-1에서 재생성 후 사용하세요.

```bash
# Master-2, Master-3 각각에서 실행
sudo ./scripts/install.sh --join <token> <hash> <endpoint> --control-plane <cert-key>
```

**각 노드 완료 후** 즉시 위 **Step 3의 🔧 bind-address 설정**을 동일하게 수행합니다.
(각 노드의 실제 IP가 다르므로 노드별로 각각 실행)

### Step 5 — 워커 노드 합류

```bash
# Worker 각각에서 실행
sudo ./scripts/install.sh --join <token> <hash> <endpoint>
```

### Step 6 — 언인스톨

| 명령 | 동작 |
| --- | --- |
| `sudo ./scripts/uninstall.sh` | 대화형 확인 후 클러스터 상태 초기화 |
| `sudo ./scripts/uninstall.sh --yes` | 확인 생략 (install.sh 재설치 흐름에서 자동 호출) |
| `sudo ./scripts/uninstall.sh --purge` | 클러스터 초기화 + DEB 패키지(kubeadm/kubelet/kubectl/containerd.io)까지 제거 |

**초기화 후에도 `kubectl` / `kubelet` 바이너리는 남아있습니다.**
폐쇄망 환경에서 재설치 시 DEB를 다시 가져올 수 없으므로 패키지는 기본적으로 유지합니다.
바이너리까지 완전히 제거하려면 `--purge` 옵션을 사용하세요.

```bash
sudo ./scripts/uninstall.sh          # 클러스터만 초기화 (바이너리 유지)
sudo ./scripts/uninstall.sh --yes    # 확인 생략
sudo ./scripts/uninstall.sh --purge  # 바이너리까지 완전 제거
```

### 설정 저장 (`install.conf`)

`install.sh` 실행 시 선택한 설정은 `install.conf`에 자동 저장됩니다.
재실행 시 저장된 값이 기본값으로 적용되어 동일 설정으로 빠르게 재설치 가능합니다.

---

## 전제 조건

- Ubuntu 24.04 LTS (noble) 노드
  - **WSL2 단일 노드**: 로컬 개발/검증용
  - **폐쇄망 단일 구성**: 컨트롤 플레인 1대 + 워커 1대 이상
  - **폐쇄망 HA 구성**: 컨트롤 플레인 3대 + 워커 1대 이상 + VIP 1개
- 모든 노드에서 아래 설치 파일 접근 가능
- swap 비활성화 (`swapoff -a` + `/etc/fstab` 주석)
- WSL2의 경우 `/etc/wsl.conf`에 `[boot] systemd=true` 적용 후 재기동 (`scripts/wsl2_prep.sh` 사용)

## 디렉토리 구조

| 경로 | 설명 |
| --- | --- |
| `k8s/debs/` | kubeadm, kubelet, kubectl, cri-tools, containerd.io + 시스템 유틸 DEB |
| `k8s/binaries/` | helm, nerdctl tarball |
| `k8s/images/` | kubeadm 코어 + Calico 이미지 `.tar` |
| `k8s/utils/` | `calico.yaml`, `local-path-storage.yaml` 등 매니페스트 |
| `scripts/` | `download.sh`, `install.sh`, `uninstall.sh`, `wsl2_prep.sh` |

## Phase 0: 설치 파일 배포 (Bastion → 전체 노드)

```bash
# 배포 대상 노드 IP 목록 (환경에 맞게 수정)
NODES=("<MASTER1_IP>" "<MASTER2_IP>" "<MASTER3_IP>" "<WORKER1_IP>" "<WORKER2_IP>")

for IP in "${NODES[@]}"; do
    echo "Sending to $IP..."
    scp ~/k8s-1.33.11-ubuntu24.04.tar.gz ubuntu@$IP:~/
done

# 모든 노드에서 압축 해제
tar -zxvf ~/k8s-1.33.11-ubuntu24.04.tar.gz
cd k8s-1.33.11-ubuntu24.04
```

## Phase 1: DEB 설치 (전체 노드)

```bash
# kubeadm/kubelet/kubectl/cri-tools/containerd.io + 필수 유틸(conntrack, socat, ebtables, ipset, jq, chrony)
sudo dpkg -i k8s/debs/*.deb

# 의존성 누락 시(인터넷 호스트에서 apt-rdepends로 full graph를 가져왔다면 없어야 함)
sudo apt-get install -f --no-download || true

# kubelet 활성화 (kubeadm init 전에는 시작하지 않음)
sudo systemctl enable kubelet
```

## Phase 2: OS 사전 설정 (전체 노드)

```bash
# 1. 커널 모듈
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

# 2. sysctl
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# 3. swap 비활성화
sudo swapoff -a
sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab

# 4. AppArmor 상태 확인 (Ubuntu 24.04 기본 활성)
sudo aa-status | head -5
# containerd 관련 이슈 시: sudo aa-complain /usr/bin/containerd
```

### WSL2 추가 항목

```bash
# iptables 백엔드를 legacy로 변경 (Cilium/kube-proxy 호환)
sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
```

## Phase 3: containerd 설정 (전체 노드)

```bash
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml

# cgroup driver를 systemd로 (필수)
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# pause 이미지 3.10으로 통일 (k8s 1.33 기본)
sudo sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10"|' /etc/containerd/config.toml

# Harbor 인증서 경로 정리
sudo sed -i "s|config_path = '/etc/containerd/certs.d:/etc/docker/certs.d'|config_path = '/etc/containerd/certs.d'|g" /etc/containerd/config.toml

sudo systemctl enable --now containerd
sudo systemctl status containerd --no-pager
```

## Phase 4: 이미지 로드 (전체 노드)

```bash
for tar_file in k8s/images/*.tar; do
    echo "Loading $tar_file..."
    sudo ctr -n k8s.io images import "$tar_file"
done

sudo ctr -n k8s.io images list | grep kube-apiserver
```

## Phase 5: 로드밸런서 (HA 3중화 시에만 / 단일 구성이면 Phase 6으로)

WSL2 / 단일 구성은 이 단계를 건너뜁니다.

HA 구성을 위해 로드밸런서가 필요합니다. 환경에 따라 아래 두 가지 방식 중 하나를 선택합니다.

> **[사전 결정] VIP 주소를 인증서에 직접 설정할지, FQDN으로 추상화할지 먼저 결정하세요.**
>
> 이 선택은 이후 `kubeadm init`의 `--control-plane-endpoint` 및 인증서 SAN에 영향을 미치므로
> **설치를 시작하기 전에** 결정해야 합니다.
>
> | 방식 | 장점 | 단점 |
> | --- | --- | --- |
> | **FQDN** (`k8s-api.internal`) ← **권장** | VIP 변경 시 `/etc/hosts`만 수정, 인증서 재발급 불필요 | `/etc/hosts` 관리 필요 |
> | IP 직접 사용 | 설정 단순 | VIP 변경 시 인증서 재발급 필수 |
>
> FQDN 방식을 선택하면 **5-A-1**에서 바로 `/etc/hosts` 등록을 먼저 수행합니다.
> IP 직접 사용 방식이면 5-A-1을 건너뛰고 5-A-2부터 시작합니다.

### 옵션 A: VIP 방식 (표준, 권장)

Master 3대와 가상 IP(VIP) 환경을 가정합니다.
VIP를 K8s API Server(6443) 앞단에 두어 마스터 노드 장애 시에도 API 통신이 끊기지 않게 합니다.

> Ubuntu 24.04에서는 `haproxy` / `keepalived` DEB를 `k8s/debs/`에 포함시켜 두었어야 합니다.
> `scripts/download.sh`가 `apt-get download haproxy keepalived` + 의존성을 함께 수집합니다.

#### 5-A-1. (FQDN 방식 선택 시) FQDN 등록 (전체 노드)

VIP IP를 직접 사용하는 대신 내부 FQDN(`k8s-api.internal`)으로 추상화합니다.
나중에 VIP가 변경되어도 **인증서 재발급 없이** DNS 서버 혹은 `/etc/hosts`만 수정하면 됩니다.

내부 DNS 서버가 있다면 관리자에게 요청하여 아래 내용을 추가합니다.

- 레코드 이름: k8s-api.internal
- IP 주소: VIP

만약 DNS 서버가 없다면 `hosts` 파일에 등록합니다.

**전체 노드(마스터 + 워커)에서 실행합니다.**

```bash
echo "<VIP>  k8s-api.internal" | sudo tee -a /etc/hosts
```

> HAProxy의 `bind`는 안정성을 위해 VIP IP(`<VIP>:6443`)를 그대로 사용합니다.
> FQDN은 kubeconfig의 server 주소와 인증서 SAN에만 적용됩니다.

#### 5-A-2. 커널 파라미터 설정 (전체 마스터 노드)

VIP가 자신의 인터페이스에 없어도 바인딩할 수 있도록 설정합니다.

```bash
cat <<EOF | sudo tee /etc/sysctl.d/haproxy.conf
net.ipv4.ip_nonlocal_bind = 1
EOF

sudo sysctl --system
```

#### 5-A-3. HAProxy 설정 (전체 마스터 노드)

```bash
sudo cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak

cat <<EOF | sudo tee /etc/haproxy/haproxy.cfg
global
    log         127.0.0.1 local2
    maxconn     4000
    daemon

defaults
    mode                    tcp
    log                     global
    option                  tcplog
    timeout connect         10s
    timeout client          1m
    timeout server          1m

# Kubernetes API Server LB
frontend k8s-api
    bind <VIP>:6443      # TODO 실제 VIP로 변경 필요
    mode tcp
    option tcplog
    default_backend k8s-masters

# TODO 실제 MASTER_IP, HOSTNAME 변경 필요
backend k8s-masters
    mode tcp
    balance roundrobin
    option tcp-check
    server <MASTER1_HOSTNAME> <MASTER1_IP>:6443 check fall 3 rise 2
    server <MASTER2_HOSTNAME> <MASTER2_IP>:6443 check fall 3 rise 2
    server <MASTER3_HOSTNAME> <MASTER3_IP>:6443 check fall 3 rise 2
EOF
```

> **Ubuntu 24.04 AppArmor 주의**: `/etc/apparmor.d/usr.sbin.haproxy` 프로파일이
> 기본 활성화되어 있으며 위 설정은 기본 허용 범위 내입니다. 외부 소켓이나
> 비표준 경로를 쓰는 경우 `sudo aa-complain /usr/sbin/haproxy` 로 임시 우회.

#### 5-A-4. Keepalived 설정 (전체 마스터 노드)

각 마스터 노드별로 `state`, `priority`, `interface` 값을 다르게 설정합니다.

| 노드 | state | priority |
| --- | --- | --- |
| Master-1 | `MASTER` | `101` |
| Master-2 | `BACKUP` | `100` |
| Master-3 | `BACKUP` | `99` |

Ubuntu 24.04의 기본 네트워크 인터페이스명은 `eth0`, `ens*`, `enp*` 등 환경마다 다릅니다.
`ip -br link` 로 확인한 후 아래 `interface` 값을 실제 인터페이스명으로 바꿉니다.

```bash
# Master-1 기준 예시 (Master-2, 3은 state/priority 값 수정)
cat <<EOF | sudo tee /etc/keepalived/keepalived.conf
global_defs {
    router_id LVS_DEVEL
}

vrrp_script check_haproxy {
    script "/usr/bin/killall -0 haproxy"
    interval 3
    weight -2
    fall 10
    rise 2
}

vrrp_instance VI_1 {
    state MASTER              # TODO Master-2, 3은 BACKUP
    interface eth0            # TODO 실제 네트워크 인터페이스명으로 변경 (ip -br link 로 확인)
    virtual_router_id 51
    priority 101              # TODO M1: 101, M2: 100, M3: 99
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass 42          # 모든 노드 동일하게 설정
    }

    virtual_ipaddress {
        <VIP>          # TODO VIP 주소
    }

    track_script {
        check_haproxy
    }
}
EOF
```

> `killall` 미설치 환경(Ubuntu 24.04 minimal)이라면 `sudo apt-get install psmisc` 또는
> DEB(`psmisc_*.deb`)를 `k8s/debs/`에 포함시킵니다. 대안으로 `pgrep -x haproxy` 를
> `script` 값으로 사용할 수 있습니다.

#### 5-A-5. 서비스 시작 및 VIP 확인

```bash
sudo systemctl enable --now haproxy
sudo systemctl enable --now keepalived

# VIP 활성화 확인 (Master-1에서 VIP가 보여야 함)
ip addr show | grep <VIP>
```

---

### 옵션 B: Localhost LB 방식 (VIP 사용 불가 환경)

VIP를 사용할 수 없는 환경에서 각 노드에 HAProxy를 띄워 Loopback(`127.0.0.1:8443`)으로 통신합니다.
**전체 마스터 및 워커 노드에 동일하게 설정합니다.**

```bash
sudo cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak

cat <<EOF | sudo tee /etc/haproxy/haproxy.cfg
global
    maxconn     4000
    daemon

defaults
    mode                    tcp
    timeout connect         10s
    timeout client          1m
    timeout server          1m

frontend k8s-api-proxy
    bind 127.0.0.1:8443
    default_backend k8s-masters

backend k8s-masters
    balance roundrobin
    option tcp-check
    server <MASTER1_HOSTNAME> <MASTER1_IP>:6443 check
    server <MASTER2_HOSTNAME> <MASTER2_IP>:6443 check
    server <MASTER3_HOSTNAME> <MASTER3_IP>:6443 check
EOF

sudo systemctl enable --now haproxy
```

## Phase 6: kubeadm init (Master-1)

구성 유형(단일 / HA)과 CNI 선택(Calico / Cilium)에 따라 옵션을 조합합니다.

- 단일 구성 → **옵션 B** 사용
- HA(3중화) 구성 → **옵션 A** 사용 (VIP 또는 FQDN)
- CNI = Cilium 인 경우 모든 옵션에 `--skip-phases=addon/kube-proxy` 와 `--pod-network-cidr=10.0.0.0/16` 를 적용합니다. (Calico는 `192.168.0.0/16` 기본값)

### 옵션 A: HA(3중화) 구성 (VIP 사용)

`--apiserver-cert-extra-sans`에 VIP와 전체 마스터 IP를 포함해야 엄격한 SAN 검증을 통과할 수 있습니다.

FQDN을 사용하는 경우(`5-A-1` 적용 시) `VIP` 대신 `k8s-api.internal`로 대체합니다.

> **HAProxy 포트 충돌 주의**
> HAProxy가 VIP:6443을 점유하고 있으면 `kubeadm init`이 같은 포트를 열려다 실패합니다.
> `kubeadm init` 전에 HAProxy를 잠시 중지하고, API 서버 bind-address 설정 후 다시 시작합니다.

```bash
# 1. HAProxy 일시 중지
sudo systemctl stop haproxy

# 2-a. kubeadm init — VIP IP 직접 사용 + CNI=Calico
sudo kubeadm init \
  --control-plane-endpoint "<VIP>:6443" \
  --upload-certs \
  --apiserver-cert-extra-sans="<VIP>,<MASTER1_IP>,<MASTER2_IP>,<MASTER3_IP>,127.0.0.1" \
  --pod-network-cidr=192.168.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --kubernetes-version v1.33.11

# 2-b. kubeadm init — FQDN 사용 + CNI=Calico (권장)
sudo kubeadm init \
  --control-plane-endpoint "k8s-api.internal:6443" \
  --upload-certs \
  --apiserver-cert-extra-sans="k8s-api.internal,<VIP>,<MASTER1_IP>,<MASTER2_IP>,<MASTER3_IP>,127.0.0.1" \
  --pod-network-cidr=192.168.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --kubernetes-version v1.33.11

# 2-c. kubeadm init — FQDN 사용 + CNI=Cilium
sudo kubeadm init \
  --skip-phases=addon/kube-proxy \
  --control-plane-endpoint "k8s-api.internal:6443" \
  --upload-certs \
  --apiserver-cert-extra-sans="k8s-api.internal,<VIP>,<MASTER1_IP>,<MASTER2_IP>,<MASTER3_IP>,127.0.0.1" \
  --pod-network-cidr=10.0.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --kubernetes-version v1.33.11

# 3. API 서버 bind-address를 Master-1의 실제 IP로 수정
#    (설정하지 않으면 API 서버가 0.0.0.0으로 바인딩되어 HAProxy와 다시 충돌)
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
# spec.containers[].command 섹션에 추가:
# - --bind-address=<MASTER1_IP>

# 4. API 서버가 노드 IP로 재기동된 것을 확인 후 HAProxy 시작
sudo crictl pods --namespace kube-system | grep apiserver   # Running 확인
sudo systemctl start haproxy

# 5. kubeconfig 설정
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### 옵션 B: 단일 구성

```bash
# Calico 선택 시
sudo kubeadm init \
  --control-plane-endpoint "<MASTER_IP>:6443" \
  --pod-network-cidr=192.168.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --kubernetes-version v1.33.11

# Cilium 선택 시 (kube-proxy skip)
sudo kubeadm init \
  --skip-phases=addon/kube-proxy \
  --control-plane-endpoint "<MASTER_IP>:6443" \
  --pod-network-cidr=10.0.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --kubernetes-version v1.33.11

# kubeconfig 설정
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

## Phase 6-1: 추가 마스터 노드 조인 (Master-2, 3 — HA 구성 시에만)

Master-1 초기화 출력에서 **`--control-plane`** 조인 명령을 복사하여 실행합니다.
Master-2, 3에도 HAProxy가 VIP:6443을 점유하고 있으므로 조인 전에 중지합니다.

```bash
# 1. HAProxy 일시 중지
sudo systemctl stop haproxy

# 2. 컨트롤 플레인 조인
sudo kubeadm join <VIP>:6443 --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH> \
    --control-plane --certificate-key <CERT_KEY>

# 3. bind-address를 해당 노드 실제 IP로 수정
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
# Master-2: - --bind-address=<MASTER2_IP>
# Master-3: - --bind-address=<MASTER3_IP>

# 4. API 서버 재기동 확인 후 HAProxy 시작
sudo crictl pods --namespace kube-system | grep apiserver   # Running 확인
sudo systemctl start haproxy
```

kubeconfig도 각 노드에 설정합니다.

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

## Phase 7: CNI 설치

### 옵션 A: Calico + Envoy Gateway

```bash
# 1. Calico 설치
kubectl apply -f k8s/utils/calico.yaml

# 2. Calico 파드가 전부 Running이 될 때까지 대기
kubectl get pods -n kube-system -w

# 3. Envoy Gateway 설치 (L7 라우팅)
cd ../envoy-1.37.2
./scripts/install.sh
```

> Pod CIDR을 기본(`192.168.0.0/16`)에서 변경한 경우 `k8s/utils/calico.yaml`의
> `CALICO_IPV4POOL_CIDR` 주석을 해제하고 값을 수정한 뒤 적용합니다.

### 옵션 B: Cilium

```bash
# Cilium은 별도 컴포넌트에서 설치 (이미지 pre-load + helm install 포함)
cd ../cilium-1.19.3
# install.conf에 K8S_SERVICE_HOST/PORT, kubeProxyReplacement=true 가 저장되어 있어야 함
./scripts/install.sh
```

Cilium은 Gateway API를 기본 지원하므로 Envoy Gateway를 별도로 설치하지 않습니다.

## Phase 8: helm & nerdctl 설치 (컨트롤 플레인)

```bash
cd k8s/binaries
tar -xzvf helm-v3.20.*-linux-amd64.tar.gz
sudo mv linux-amd64/helm /usr/local/bin/helm
helm version

# nerdctl (full)
tar -xzvf nerdctl-full-2.2.2-linux-amd64.tar.gz -C /tmp/nerdctl-full
sudo cp /tmp/nerdctl-full/bin/* /usr/local/bin/
nerdctl --version
```

## Phase 9: 워커 노드 조인

Master-1 `kubeadm init` 출력에서 워커 조인 명령을 복사하여 실행합니다.
Phase 6에서 선택한 구성 방식에 맞춰 아래 옵션을 선택하세요.

### 옵션 A: HA 구성 — VIP 사용

```bash
sudo kubeadm join <VIP>:6443 --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH>
```

### 옵션 B: HA 구성 — Localhost LB 사용

각 워커 노드에도 HAProxy가 `127.0.0.1:8443`으로 떠 있어야 합니다.

```bash
sudo kubeadm join 127.0.0.1:8443 --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH>
```

### 옵션 C: 단일 구성

```bash
sudo kubeadm join <MASTER_IP>:6443 --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH>
```

## Phase 10: 설치 확인

```bash
kubectl get nodes
kubectl get pods -A
```

모든 노드가 `Ready`, 전 네임스페이스 파드가 `Running`이면 완료입니다.

추가 확인:

```bash
# Cilium 선택 시
kubectl get ciliumendpoints -A
ip link show cni0  # 존재하지 않아야 함 (flannel 잔재 없음)
iptables -L -n | grep KUBE-SVC  # 비어있어야 함 (kubeProxyReplacement 동작)

# Calico 선택 시
kubectl get ippools -o yaml
kubectl get pods -n projectcalico-system
```

## 재설치 시 초기화

`scripts/uninstall.sh`를 사용하는 것을 권장하며, 수동으로 할 경우:

```bash
# 1. kubeadm reset
sudo kubeadm reset -f

# 2. CNI/kube 설정 삭제
sudo rm -rf /etc/cni/net.d /var/lib/cni
rm -rf $HOME/.kube
sudo rm -rf /root/.kube /var/lib/etcd /var/lib/kubelet

# 3. iptables 규칙 초기화
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X

# 4. CNI 인터페이스 제거 (있을 시)
for iface in cni0 flannel.1 cilium_host cilium_net cilium_vxlan; do
    sudo ip link show "$iface" &>/dev/null && sudo ip link del "$iface"
done

# 5. containerd 재시작
sudo systemctl restart containerd
```

## VIP 변경 시 조치

운영 중 VIP 대역이 변경되거나 새로운 IP를 할당받아야 하는 경우의 절차입니다.

### 케이스 0: 운영 중인 클러스터를 IP → FQDN으로 전환

이미 VIP IP로 초기 구성한 클러스터에 FQDN을 사후 적용하는 절차입니다.
이후 VIP가 변경되면 케이스 A 절차만으로 처리할 수 있게 됩니다.

#### **1단계: 모든 노드에 FQDN 등록 (마스터 + 워커)**

> DNS 서버가 운영 중이라면 DNS 서버에 등록합니다.

```bash
echo "<OLD_VIP>  k8s-api.internal" | sudo tee -a /etc/hosts
```

#### **2단계: API 서버 인증서에 FQDN SAN 추가 (전체 마스터 노드)**

```bash
# 기존 인증서 백업
sudo cp /etc/kubernetes/pki/apiserver.crt ~/apiserver.crt.bak
sudo cp /etc/kubernetes/pki/apiserver.key ~/apiserver.key.bak

# 삭제 후 FQDN 포함하여 재발급
sudo rm /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
sudo kubeadm init phase certs apiserver \
  --control-plane-endpoint "k8s-api.internal:6443" \
  --apiserver-cert-extra-sans="k8s-api.internal,<OLD_VIP>,<MASTER1_IP>,<MASTER2_IP>,<MASTER3_IP>,127.0.0.1"

# FQDN이 SAN에 포함되었는지 확인
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A1 "Subject Alternative"
```

#### **3단계: kube-apiserver 재시작 (전체 마스터 노드)**

```bash
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sleep 10
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/

watch sudo crictl pods --namespace kube-system
```

#### **4단계: kubeconfig 및 kubelet.conf 업데이트 (전체 마스터 노드)**

```bash
for conf in /etc/kubernetes/admin.conf \
            /etc/kubernetes/controller-manager.conf \
            /etc/kubernetes/scheduler.conf \
            /etc/kubernetes/kubelet.conf; do
    sudo sed -i "s|https://<OLD_VIP>:6443|https://k8s-api.internal:6443|g" "$conf"
done
sudo systemctl restart kubelet

# 현재 사용자 kubeconfig 갱신
cp /etc/kubernetes/admin.conf ~/.kube/config
```

#### **5단계: 워커 노드 kubelet.conf 업데이트 (전체 워커 노드)**

```bash
sudo sed -i 's|https://<OLD_VIP>:6443|https://k8s-api.internal:6443|g' /etc/kubernetes/kubelet.conf
sudo systemctl restart kubelet
```

#### **6단계: 클러스터 내부 ConfigMap 갱신 (Master-1에서 1회 실행)**

로컬 파일 수정과 별개로, 클러스터 내부 etcd에 저장된 엔드포인트도 갱신해야 합니다.
이를 누락하면 kube-proxy 파드가 재시작될 때 구 VIP로 접속을 시도하여 `CrashLoopBackOff`가 발생할 수 있습니다.

> CNI = Cilium 구성의 경우 kube-proxy 가 없으므로 아래 `kube-proxy ConfigMap` 단계는 생략하고,
> `kubeadm-config` 갱신만 수행합니다. Cilium 파드는 `K8S_SERVICE_HOST`/`K8S_SERVICE_PORT` 환경
> 변수로 API를 찾으므로 `kubectl -n kube-system rollout restart ds cilium` 으로 재기동합니다.

```bash
# kube-proxy ConfigMap 갱신 (Calico 경로만)
kubectl get configmap kube-proxy -n kube-system -o yaml | \
  sed 's|<OLD_VIP>:6443|k8s-api.internal:6443|g' | \
  kubectl apply -f -

# kube-proxy 롤아웃
kubectl rollout restart daemonset kube-proxy -n kube-system

# (권장) kubeadm-config ConfigMap 갱신 — 추후 kubeadm upgrade 시 필요
kubectl get configmap kubeadm-config -n kube-system -o yaml | \
  sed 's|<OLD_VIP>:6443|k8s-api.internal:6443|g' | \
  kubectl apply -f -
```

#### **7단계: 확인**

```bash
kubectl get nodes
kubectl cluster-info
```

`Kubernetes control plane` 주소가 `https://k8s-api.internal:6443`으로 표시되면 완료입니다.

---

### 케이스 A: FQDN 방식으로 초기 구성한 경우 (권장 구성)

FQDN(`k8s-api.internal`)이 인증서 SAN에 포함되어 있으므로, **인증서 재발급 없이** 아래 순서만 따르면 됩니다.

#### **1단계: 모든 노드의 `/etc/hosts` 업데이트 (마스터 + 워커)**

> DNS 서버가 운영 중이라면 DNS 서버에 등록합니다.

```bash
# <OLD_VIP> → <NEW_VIP> 로 변경
sudo sed -i 's/<OLD_VIP>  k8s-api.internal/<NEW_VIP>  k8s-api.internal/' /etc/hosts

# 확인
grep k8s-api.internal /etc/hosts
```

#### **2단계: Keepalived VIP 변경 (전체 마스터 노드)**

```bash
sudo sed -i 's/<OLD_VIP>/<NEW_VIP>/' /etc/keepalived/keepalived.conf
sudo systemctl restart keepalived

# 새 VIP 활성화 확인 (Master-1)
ip addr show | grep <NEW_VIP>
```

#### **3단계: HAProxy bind IP 변경 (전체 마스터 노드)**

```bash
sudo sed -i 's/<OLD_VIP>:6443/<NEW_VIP>:6443/' /etc/haproxy/haproxy.cfg
sudo systemctl restart haproxy
```

> `backend k8s-masters`의 `server` 항목(마스터 노드 IP)은 변경하지 않습니다.

#### **4단계: API 서버 재시작 확인**

```bash
# kubeconfig의 server 주소는 FQDN이므로 변경 불필요
kubectl get nodes
```

---

### 케이스 B: VIP IP를 직접 사용하여 초기 구성한 경우

인증서 SAN에 기존 VIP IP가 고정되어 있으므로, **인증서 재발급이 필수**입니다.
전체 마스터 노드에서 순서대로 진행합니다.

#### **1단계: Keepalived / HAProxy VIP 변경 (전체 마스터 노드)**

```bash
sudo sed -i 's/<OLD_VIP>/<NEW_VIP>/' /etc/keepalived/keepalived.conf
sudo systemctl restart keepalived

sudo sed -i 's/<OLD_VIP>:6443/<NEW_VIP>:6443/' /etc/haproxy/haproxy.cfg
sudo systemctl restart haproxy
```

#### **2단계: API 서버 인증서 재발급 (전체 마스터 노드)**

```bash
# 기존 인증서 백업
sudo cp /etc/kubernetes/pki/apiserver.crt ~/apiserver.crt.bak
sudo cp /etc/kubernetes/pki/apiserver.key ~/apiserver.key.bak

# 삭제 후 재발급 (새 VIP 포함)
sudo rm /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
sudo kubeadm init phase certs apiserver \
  --control-plane-endpoint "<NEW_VIP>:6443" \
  --apiserver-cert-extra-sans="<NEW_VIP>,<MASTER1_IP>,<MASTER2_IP>,<MASTER3_IP>,127.0.0.1"
```

#### **3단계: kube-apiserver 재시작 (전체 마스터 노드)**

static pod는 manifest를 잠시 제거했다가 복원하면 자동 재시작됩니다.

```bash
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sleep 10
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/

# Pod가 다시 Running 상태가 될 때까지 대기
watch sudo crictl pods --namespace kube-system
```

#### **4단계: kubeconfig 및 kubelet.conf 업데이트 (전체 마스터 노드)**

```bash
for conf in /etc/kubernetes/admin.conf \
            /etc/kubernetes/controller-manager.conf \
            /etc/kubernetes/scheduler.conf \
            /etc/kubernetes/kubelet.conf; do
    sudo sed -i "s|https://<OLD_VIP>:6443|https://<NEW_VIP>:6443|g" "$conf"
done
sudo systemctl restart kubelet

# 현재 사용자 kubeconfig 갱신
cp /etc/kubernetes/admin.conf ~/.kube/config
```

#### **5단계: 워커 노드 kubelet.conf 업데이트 (전체 워커 노드)**

```bash
sudo sed -i 's|https://<OLD_VIP>:6443|https://<NEW_VIP>:6443|g' /etc/kubernetes/kubelet.conf
sudo systemctl restart kubelet
```

#### **6단계: 클러스터 내부 ConfigMap 갱신 (Master-1에서 1회 실행)**

> CNI = Cilium 구성의 경우 kube-proxy 가 없으므로 아래 `kube-proxy ConfigMap` 단계는 생략하고,
> `kubeadm-config` 갱신만 수행합니다. Cilium 파드는 `K8S_SERVICE_HOST`/`K8S_SERVICE_PORT` 환경
> 변수로 API를 찾으므로 `kubectl -n kube-system rollout restart ds cilium` 으로 재기동합니다.

```bash
# kube-proxy ConfigMap 갱신 (Calico 경로만)
kubectl get configmap kube-proxy -n kube-system -o yaml | \
  sed 's|<OLD_VIP>:6443|<NEW_VIP>:6443|g' | \
  kubectl apply -f -

# kube-proxy 롤아웃
kubectl rollout restart daemonset kube-proxy -n kube-system

# (권장) kubeadm-config ConfigMap 갱신 — 추후 kubeadm upgrade 시 필요
kubectl get configmap kubeadm-config -n kube-system -o yaml | \
  sed 's|<OLD_VIP>:6443|<NEW_VIP>:6443|g' | \
  kubectl apply -f -
```

#### **7단계: 정상 동작 확인**

```bash
kubectl get nodes
kubectl get pods -n kube-system
```

모든 노드가 `Ready` 상태이고 kube-system Pod가 `Running`이면 완료입니다.

---

## Ubuntu 24.04 vs Rocky 9.6 주요 치환 포인트

이 가이드가 HA 절차를 직접 포함하지만, 보조 참조용으로 정리합니다.

| Rocky 9.6 | Ubuntu 24.04 |
| --- | --- |
| `dnf install haproxy keepalived psmisc` | `apt-get install haproxy keepalived psmisc` (DEB는 `k8s/debs/`) |
| `/etc/selinux/config` + `setenforce 0` | AppArmor (`aa-status`, 필요 시 `aa-complain`) |
| `ip addr show eth0 \| grep VIP` | `ip addr show \| grep <VIP>` (인터페이스명 다를 수 있음) |
| `firewalld` 고려 | `ufw` 고려 (폐쇄망에서는 대부분 `sudo ufw disable`) |
| iptables backend 고정 | WSL2만 `iptables-legacy` 강제, VM은 기본값 충분 |
