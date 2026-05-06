# Kubernetes v1.33.11 온라인 설치 가이드 (Ubuntu 24.04)

인터넷이 가능한 환경에서 kubeadm 기반 Kubernetes v1.33.11 클러스터를 구성하는 절차입니다.
containerd v2.2.x + CNI(Calico 또는 Cilium) 선택 구성이며, 폐쇄망 설치는 `install-guide.md`를 참고하세요.

## 전제 조건

- Ubuntu 24.04 LTS 노드 (인터넷 가능)
  - **단일 구성**: 컨트롤 플레인 1대 + 워커 1대 이상
  - **HA(3중화) 구성**: 컨트롤 플레인 3대 + 워커 1대 이상 + VIP 1개
- swap 비활성화
- `sudo` 권한

## Phase 1: 저장소 등록 및 패키지 설치 (전체 노드)

```bash
# 1. 선행 패키지
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg \
    conntrack socat ebtables ipset jq chrony

# 2. Docker CE 저장소 (containerd.io 획득용)
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 3. Kubernetes 저장소 (v1.33)
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | \
    sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /" | \
    sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

sudo apt-get update

# 4. containerd + kubeadm/kubelet/kubectl
sudo apt-get install -y containerd.io
sudo apt-get install -y kubelet=1.33.11-1.1 kubeadm=1.33.11-1.1 kubectl=1.33.11-1.1
sudo apt-mark hold kubelet kubeadm kubectl

sudo systemctl enable kubelet
```

> Kubernetes repo는 v1.24부터 `pkgs.k8s.io`로 이전되었으며 버전별 경로(`/v1.33/`)가 구분됩니다.

## Phase 2: OS 사전 설정 (전체 노드)

```bash
sudo modprobe overlay br_netfilter
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

sudo swapoff -a
sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab

# hosts 파일 등록 (환경에 맞게 수정)
sudo tee -a /etc/hosts <<EOF
<MASTER1_IP> <MASTER1_HOSTNAME>
<MASTER2_IP> <MASTER2_HOSTNAME>
<MASTER3_IP> <MASTER3_HOSTNAME>
<WORKER1_IP> <WORKER1_HOSTNAME>
EOF

# AppArmor 확인 (Ubuntu 24.04 기본 활성)
sudo aa-status | head -5
```

### WSL2 추가

```bash
# /etc/wsl.conf에 systemd 활성화 후 wsl --shutdown 재기동 필요
cat <<EOF | sudo tee /etc/wsl.conf
[boot]
systemd=true
EOF
# Windows PowerShell에서: wsl --shutdown

sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
```

## Phase 3: containerd 설정 (전체 노드)

```bash
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml

# cgroup driver 를 systemd 로 변경 (필수)
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# v1.33 호환 pause 이미지
sudo sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10"|' /etc/containerd/config.toml

# Harbor(또는 사설 레지스트리) insecure registry 사용 시 config_path 단일화
sudo sed -i "s|config_path = '/etc/containerd/certs.d:/etc/docker/certs.d'|config_path = '/etc/containerd/certs.d'|g" /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd
```

> containerd 재시작 후 `SystemdCgroup = true` 적용 여부 확인:
>
> ```bash
> grep SystemdCgroup /etc/containerd/config.toml
> ```

### (선택) Harbor insecure registry 등록

> ⚠️ **`scripts/install.sh` 자동화 범위 밖 — 수동 적용 필요**
>
> `install.sh` 는 SystemdCgroup / sandbox_image / config_path 단일화까지만 처리합니다.
> 아래 hosts.toml 등록은 환경별로 Harbor 주소가 다르므로 의도적으로 수동 단계로 남겨둔 것이며,
> **`install.sh` 실행 후 Harbor 를 사용하는 노드에서 별도로 실행**해야 합니다.

Harbor 를 HTTP(insecure)로 운영하는 경우 각 노드에 아래 설정을 추가합니다.

```bash
# Harbor 레지스트리 주소 (예: 192.168.1.10:30002)
HARBOR_HOST="<NODE_IP>:30002"

sudo mkdir -p /etc/containerd/certs.d/${HARBOR_HOST}
sudo tee /etc/containerd/certs.d/${HARBOR_HOST}/hosts.toml <<EOF
server = "http://${HARBOR_HOST}"

[host."http://${HARBOR_HOST}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF

sudo systemctl restart containerd
```

> **containerd v1.x vs v2.x 플러그인 키 차이**
>
> `containerd config default` 로 생성한 `config.toml` 에 `config_path` 가 비어 있다면
> containerd 버전에 따라 추가해야 할 플러그인 키 이름이 다릅니다. 본 가이드는
> containerd 2.2.x 라인이므로 **v2 키** 가 기본입니다.
>
> ```bash
> # containerd 버전 확인
> containerd --version
> ```
>
> ```toml
> # containerd v1.x (io.containerd.grpc.v1.cri)
> [plugins."io.containerd.grpc.v1.cri".registry]
>   config_path = "/etc/containerd/certs.d"
>
> # containerd v2.x (io.containerd.cri.v1.images) — 본 가이드 (2.2.x) 해당
> [plugins."io.containerd.cri.v1.images".registry]
>   config_path = "/etc/containerd/certs.d"
> ```

### (선택) containerd 데이터 경로 변경 — 소프트링크 방식

> ⚠️ **`scripts/install.sh` 자동화 범위 밖 — 수동 적용 필요**
>
> 디스크 레이아웃은 환경마다 다르고 잘못 적용하면 컨테이너 데이터가 유실될 수 있어
> 자동화 대상에서 제외했습니다. **반드시 수동으로**, 그리고 `install.sh` 가
> containerd 를 가동시키기 **전에** 적용해야 합니다 (이미 가동된 뒤라면 아래 절차의
> "서비스 중지" 부터 따라가야 함).

OS 루트 디스크 용량이 작고 별도 데이터 디스크(예: `/app`)가 마운트되어 있는 경우에 적용합니다.
**containerd 시작 전** 또는 **서비스를 중지한 상태**에서 진행해야 합니다.

```bash
# 서비스 중지 (이미 실행 중인 경우)
sudo systemctl stop kubelet
sudo systemctl stop containerd

# 1. 실제 데이터를 저장할 디렉토리 생성 (경로는 환경에 맞게 수정)
sudo mkdir -p /app/containerd_data

# 2. 기존 데이터가 있으면 이동 (처음 설치라면 /var/lib/containerd 자체가 없으므로 자동 skip)
if [ -d "/var/lib/containerd" ]; then
    sudo mv /var/lib/containerd/* /app/containerd_data/
    sudo rmdir /var/lib/containerd
fi

# 3. 소프트링크 생성: /var/lib/containerd -> /app/containerd_data
sudo ln -s /app/containerd_data /var/lib/containerd

# 4. 링크 확인 (화살표가 표시되어야 함)
ls -ld /var/lib/containerd
# 결과 예시: lrwxrwxrwx ... /var/lib/containerd -> /app/containerd_data

# 5. 서비스 재시작
sudo systemctl start containerd
sudo systemctl start kubelet
```

> `config.toml` 의 `root` 값을 직접 변경하는 방법도 있지만, 소프트링크 방식은
> 기존 경로를 그대로 유지하므로 다른 툴과의 호환성을 더 쉽게 확보할 수 있습니다.

## Phase 4: 로드밸런서 (HA 3중화 시에만 / 단일 구성이면 Phase 5로)

HA 구성에서 K8s API Server(6443) 앞단에 로드밸런서가 필요합니다.

> **[사전 결정] VIP 주소를 인증서에 직접 설정할지, FQDN으로 추상화할지 먼저 결정하세요.**
>
> | 방식 | 장점 | 단점 |
> | --- | --- | --- |
> | **FQDN** (`k8s-api.internal`) ← **권장** | VIP 변경 시 `/etc/hosts`만 수정, 인증서 재발급 불필요 | `/etc/hosts` 관리 필요 |
> | IP 직접 사용 | 설정 단순 | VIP 변경 시 인증서 재발급 필수 |

### 옵션 A: VIP 방식 (표준, 권장)

#### 4-A-0. HAProxy / Keepalived 설치 (전체 마스터 노드)

```bash
sudo apt-get install -y haproxy keepalived psmisc
```

> `psmisc`는 keepalived 스크립트의 `killall` 을 위해 필요합니다.

#### 4-A-1. (FQDN 방식 선택 시) FQDN 등록 (전체 노드)

내부 DNS 서버가 있다면 관리자에게 요청(레코드 `k8s-api.internal` → VIP)합니다.
없다면 `/etc/hosts`에 등록합니다. **마스터 + 워커 전 노드에서** 실행:

```bash
echo "<VIP>  k8s-api.internal" | sudo tee -a /etc/hosts
```

#### 4-A-2. 커널 파라미터 (전체 마스터 노드)

VIP가 자신의 인터페이스에 없어도 바인딩할 수 있도록 설정합니다.

```bash
cat <<EOF | sudo tee /etc/sysctl.d/haproxy.conf
net.ipv4.ip_nonlocal_bind = 1
EOF
sudo sysctl --system
```

#### 4-A-3. HAProxy 설정 (전체 마스터 노드)

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

frontend k8s-api
    bind <VIP>:6443      # TODO 실제 VIP로 변경 필요
    mode tcp
    option tcplog
    default_backend k8s-masters

backend k8s-masters
    mode tcp
    balance roundrobin
    option tcp-check
    server <MASTER1_HOSTNAME> <MASTER1_IP>:6443 check fall 3 rise 2
    server <MASTER2_HOSTNAME> <MASTER2_IP>:6443 check fall 3 rise 2
    server <MASTER3_HOSTNAME> <MASTER3_IP>:6443 check fall 3 rise 2
EOF
```

#### 4-A-4. Keepalived 설정 (전체 마스터 노드)

| 노드 | state | priority |
| --- | --- | --- |
| Master-1 | `MASTER` | `101` |
| Master-2 | `BACKUP` | `100` |
| Master-3 | `BACKUP` | `99` |

인터페이스명은 `ip -br link`로 확인 후 `interface` 값을 실제명으로 교체합니다.

```bash
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
    interface eth0            # TODO 실제 네트워크 인터페이스명으로 변경
    virtual_router_id 51
    priority 101              # TODO M1: 101, M2: 100, M3: 99
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass 42
    }

    virtual_ipaddress {
        <VIP>
    }

    track_script {
        check_haproxy
    }
}
EOF
```

#### 4-A-5. 서비스 시작 및 VIP 확인

```bash
sudo systemctl enable --now haproxy
sudo systemctl enable --now keepalived

# Master-1에서 VIP가 활성화되어야 함
ip addr show | grep <VIP>
```

### 옵션 B: Localhost LB 방식 (VIP 사용 불가 환경)

전체 마스터 + 워커 노드에 HAProxy를 띄워 Loopback(`127.0.0.1:8443`)으로 통신합니다.

```bash
sudo apt-get install -y haproxy

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

## Phase 5: kubeadm init (Master-1)

구성 유형(단일 / HA)과 CNI 선택(Calico / Cilium)에 따라 옵션을 조합합니다.

- Calico: `--pod-network-cidr=192.168.0.0/16` (기본)
- Cilium: `--skip-phases=addon/kube-proxy --pod-network-cidr=10.0.0.0/16`

### 옵션 A: HA(3중화) 구성

HAProxy가 VIP:6443을 점유하고 있으므로 init 전에 중지합니다.

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

# 3. API 서버 bind-address를 Master-1 실제 IP로 수정
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
# - --bind-address=<MASTER1_IP>

# 4. API 서버 재기동 확인 후 HAProxy 시작
sudo crictl pods --namespace kube-system | grep apiserver
sudo systemctl start haproxy

# 5. kubeconfig
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### 옵션 B: HA(3중화) — Localhost LB 방식 (Phase 4 옵션 B 에서 진행한 경우)

각 노드의 HAProxy 가 `127.0.0.1:8443` 만 점유하고, 백엔드는 마스터들의 6443 으로 포워딩합니다.
**kube-apiserver 의 6443 과 포트가 겹치지 않으므로 HAProxy 중지·재시작 단계가 불필요**하고,
`bind-address` 수정도 필요 없습니다(기본 `0.0.0.0` 사용).

> 인증서 SAN 에 반드시 `127.0.0.1` 을 포함해야 모든 노드의 kubeconfig(`https://127.0.0.1:8443`)가
> 동일 인증서로 검증됩니다.

```bash
sudo kubeadm init \
  --control-plane-endpoint "127.0.0.1:8443" \
  --upload-certs \
  --apiserver-cert-extra-sans="127.0.0.1,<MASTER1_IP>,<MASTER2_IP>,<MASTER3_IP>" \
  --pod-network-cidr=192.168.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --kubernetes-version v1.33.11

# kubeconfig 설정
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# HAProxy 백엔드 헬스체크 확인 — Master-1 만 UP 으로 보여야 정상
ss -tlnp | grep 8443
```

### 옵션 C: 단일 구성

```bash
# Calico
sudo kubeadm init \
  --pod-network-cidr=192.168.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --kubernetes-version v1.33.11

# Cilium (kube-proxy skip)
sudo kubeadm init \
  --skip-phases=addon/kube-proxy \
  --pod-network-cidr=10.0.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --kubernetes-version v1.33.11

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

## Phase 5-1: 추가 마스터 노드 조인 (Master-2, 3 — HA 구성 시에만)

Master-1 초기화 출력에서 **`--control-plane`** 조인 명령을 복사하여 실행합니다.
Phase 4 에서 선택한 LB 방식에 따라 절차가 달라집니다.

### VIP 방식 (Phase 4 옵션 A)

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

# 5. kubeconfig
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### Localhost LB 방식 (Phase 4 옵션 B)

각 마스터의 HAProxy 가 `127.0.0.1:8443` 만 점유하므로 **HAProxy 중지 / bind-address 수정 단계 모두 불필요**합니다.
Master-1 의 `kubeadm init` 출력에 표시된 join 명령은 endpoint 가 `127.0.0.1:8443` 으로 이미 지정되어 있습니다.

```bash
# 1. 컨트롤 플레인 조인 (endpoint = 127.0.0.1:8443)
sudo kubeadm join 127.0.0.1:8443 --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH> \
    --control-plane --certificate-key <CERT_KEY>

# 2. kubeconfig
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# 3. (선택) HAProxy 백엔드 상태 — 모든 마스터가 합류하면 3대 모두 UP
sudo journalctl -u haproxy -n 20 --no-pager
```

## Phase 6: CNI 설치

### 옵션 A: Calico

환경에 따라 **엔터프라이즈용(Operator)** 또는 **경량용(Manifest)** 방식 중 하나를 선택하여 설치합니다.

#### 방식 1: Tigera Operator 방식 (엔터프라이즈 권장)
```bash
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/tigera-operator.yaml

# Operator 준비 대기 (CRD 등록 시간 확보)
kubectl wait --for=condition=Available deployment/tigera-operator -n tigera-operator --timeout=60s

kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/custom-resources.yaml
```

#### 방식 2: Manifest 방식 (경량/학습용 권장)
```bash
# 단일 파일로 즉시 설치
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/calico.yaml
```

> **Pod CIDR을 변경한 경우 (방식 2)**: `calico.yaml`의 `CALICO_IPV4POOL_CIDR` 항목 수정이 필요합니다.

### 옵션 B: Cilium (Helm)

> **L4 vs L7 책임 분리 — 먼저 결정**
>
> `kubeProxyReplacement=true` 는 **L4 (Service ClusterIP/NodePort)** 라우팅만 대체합니다.
> L7 (HTTPRoute / Ingress 같은 path·host 기반 라우팅) 은 별도 Gateway 컨트롤러가 담당해야 하며,
> 두 가지 선택지가 있습니다.
>
> | 방식 | 설치 옵션 | 비고 |
> | :--- | :--- | :--- |
> | **별도 Gateway 컨트롤러 사용** (이 레포 표준 — `envoy-1.37.2`) | `--set gatewayAPI.enabled=false` | Cilium 은 CNI + kpr 만, L7 은 Envoy Gateway. **권장** |
> | **Cilium 내장 Gateway 사용** | `--set gatewayAPI.enabled=true` + Gateway API CRD 별도 설치 | 단일 컴포넌트로 끝낼 때만. Envoy Gateway 와 동시 활성화 시 GatewayClass/HTTPRoute 충돌 |

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

# 단일 구성 (Envoy Gateway 와 병행 — 권장)
helm install cilium cilium/cilium --version 1.19.3 \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set gatewayAPI.enabled=false \
  --set k8sServiceHost=<MASTER_IP> \
  --set k8sServicePort=6443

# HA 구성 (FQDN)
helm install cilium cilium/cilium --version 1.19.3 \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set gatewayAPI.enabled=false \
  --set k8sServiceHost=k8s-api.internal \
  --set k8sServicePort=6443
```

#### Cilium 내장 Gateway API 사용 시

Envoy Gateway 를 별도로 설치하지 않고 Cilium 만으로 HTTPRoute 를 운영하려면:

```bash
# 1. Gateway API CRD 먼저 설치 (Cilium 이 자동 설치하지 않음)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

# 2. Cilium Helm upgrade — gatewayAPI 활성화
helm upgrade cilium cilium/cilium --version 1.19.3 -n kube-system \
  --reuse-values \
  --set gatewayAPI.enabled=true
```

→ HTTPRoute 작성 시 `parentRefs` 가 가리키는 Gateway 의 `gatewayClassName: cilium` 으로 지정.

> ⚠️ Envoy Gateway (`envoy-1.37.2`) 와 **둘 다 활성화된 상태로 운영하지 마세요**. 두 컨트롤러가 같은
> HTTPRoute 를 가져가려고 경쟁하며, GatewayClass 가 다르더라도 운영 복잡도가 크게 올라갑니다.

#### LoadBalancer IP 발급기 충돌 주의

`kubeProxyReplacement=true` + Envoy Gateway 조합에서 LoadBalancer Service IP 는 다음 중 **하나만**:

- MetalLB (`metallb-0.14.8`) — 본 레포 기본
- Cilium LB IPAM (`--set loadBalancer.l2.enabled=true` 등)

둘 다 켜면 같은 IP 풀을 두고 경쟁합니다.

## Phase 7: 워커 노드 조인

Master-1의 `kubeadm init` 출력에서 워커 조인 명령을 복사하여 실행합니다.
Phase 5(또는 4)에서 선택한 구성 방식에 맞춰 아래 옵션을 선택하세요.

위 출력의 `<ENDPOINT>` 는 Phase 4 에서 선택한 LB 방식에 따라 달라집니다:

| Phase 4 옵션 | 워커가 사용할 endpoint | 사전 작업 |
| --- | --- | --- |
| A (HA — VIP IP) | `<VIP>:6443` | 워커 노드에는 추가 작업 불필요 |
| A (HA — FQDN) | `k8s-api.internal:6443` | **워커 노드 `/etc/hosts` 에 FQDN 등록 필요** (Phase 4-A-1) |
| B (HA — Localhost LB) | `127.0.0.1:8443` | **워커 노드에도 HAProxy 설치·설정 완료되어 있어야 함** (Phase 4 옵션 B) |
| C (단일 구성) | `<MASTER_IP>:6443` | 추가 작업 불필요 |

```bash
sudo kubeadm join <ENDPOINT> --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```

## Phase 8: 설치 확인

```bash
kubectl get nodes
kubectl get pods -A
```

모든 노드가 `Ready`, 전 네임스페이스 파드가 `Running`이면 완료입니다.



## Phase 9: helm / nerdctl 설치 (선택)

```bash
# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# nerdctl (full)
NERDCTL_VERSION=2.2.2
curl -fsSL https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/nerdctl-full-${NERDCTL_VERSION}-linux-amd64.tar.gz \
    -o /tmp/nerdctl-full.tar.gz
sudo tar xzf /tmp/nerdctl-full.tar.gz -C /usr/local/
nerdctl --version
```

## VIP 변경 시 조치

운영 중 VIP가 변경되는 경우의 절차입니다. 초기 구성 방식(IP 직접 / FQDN)에 따라 케이스를 선택합니다.

### 케이스 0: 운영 중인 클러스터를 IP → FQDN으로 전환

이미 VIP IP로 초기 구성한 클러스터에 FQDN을 사후 적용하는 절차입니다.

#### 1단계: 모든 노드에 FQDN 등록 (마스터 + 워커)

```bash
echo "<OLD_VIP>  k8s-api.internal" | sudo tee -a /etc/hosts
```

#### 2단계: API 서버 인증서에 FQDN SAN 추가 (전체 마스터 노드)

```bash
sudo cp /etc/kubernetes/pki/apiserver.crt ~/apiserver.crt.bak
sudo cp /etc/kubernetes/pki/apiserver.key ~/apiserver.key.bak

sudo rm /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
sudo kubeadm init phase certs apiserver \
  --control-plane-endpoint "k8s-api.internal:6443" \
  --apiserver-cert-extra-sans="k8s-api.internal,<OLD_VIP>,<MASTER1_IP>,<MASTER2_IP>,<MASTER3_IP>,127.0.0.1"

openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A1 "Subject Alternative"
```

#### 3단계: kube-apiserver 재시작 (전체 마스터 노드)

```bash
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sleep 10
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/

watch sudo crictl pods --namespace kube-system
```

#### 4단계: kubeconfig / kubelet.conf 업데이트 (전체 마스터)

```bash
for conf in /etc/kubernetes/admin.conf \
            /etc/kubernetes/controller-manager.conf \
            /etc/kubernetes/scheduler.conf \
            /etc/kubernetes/kubelet.conf; do
    sudo sed -i "s|https://<OLD_VIP>:6443|https://k8s-api.internal:6443|g" "$conf"
done
sudo systemctl restart kubelet
cp /etc/kubernetes/admin.conf ~/.kube/config
```

#### 5단계: 워커 노드 kubelet.conf 업데이트

```bash
sudo sed -i 's|https://<OLD_VIP>:6443|https://k8s-api.internal:6443|g' /etc/kubernetes/kubelet.conf
sudo systemctl restart kubelet
```

#### 6단계: 클러스터 내부 ConfigMap 갱신 (Master-1에서 1회)

> CNI = Cilium 인 경우 `kube-proxy` 가 없으므로 `kube-proxy ConfigMap` 단계는 생략하고,
> `kubeadm-config` 갱신만 수행 후 `kubectl -n kube-system rollout restart ds cilium` 를 실행합니다.

```bash
# Calico 경로
kubectl get configmap kube-proxy -n kube-system -o yaml | \
  sed 's|<OLD_VIP>:6443|k8s-api.internal:6443|g' | \
  kubectl apply -f -
kubectl rollout restart daemonset kube-proxy -n kube-system

# (공통) kubeadm-config
kubectl get configmap kubeadm-config -n kube-system -o yaml | \
  sed 's|<OLD_VIP>:6443|k8s-api.internal:6443|g' | \
  kubectl apply -f -
```

#### 7단계: 확인

```bash
kubectl get nodes
kubectl cluster-info
```

---

### 케이스 A: FQDN 방식으로 초기 구성한 경우 (권장)

인증서 SAN에 FQDN이 이미 포함되어 있으므로 **인증서 재발급 없이** 처리 가능.

```bash
# 1. /etc/hosts 갱신 (마스터 + 워커 전 노드)
sudo sed -i 's/<OLD_VIP>  k8s-api.internal/<NEW_VIP>  k8s-api.internal/' /etc/hosts

# 2. Keepalived VIP 변경 (전체 마스터)
sudo sed -i 's/<OLD_VIP>/<NEW_VIP>/' /etc/keepalived/keepalived.conf
sudo systemctl restart keepalived
ip addr show | grep <NEW_VIP>

# 3. HAProxy bind IP 변경 (전체 마스터)
sudo sed -i 's/<OLD_VIP>:6443/<NEW_VIP>:6443/' /etc/haproxy/haproxy.cfg
sudo systemctl restart haproxy

# 4. 확인
kubectl get nodes
```

---

### 케이스 B: VIP IP를 직접 사용한 경우

인증서 SAN이 고정되어 있으므로 **인증서 재발급 필수**.

#### 1단계: Keepalived / HAProxy VIP 변경 (전체 마스터)

```bash
sudo sed -i 's/<OLD_VIP>/<NEW_VIP>/' /etc/keepalived/keepalived.conf
sudo systemctl restart keepalived

sudo sed -i 's/<OLD_VIP>:6443/<NEW_VIP>:6443/' /etc/haproxy/haproxy.cfg
sudo systemctl restart haproxy
```

#### 2단계: API 서버 인증서 재발급 (전체 마스터)

```bash
sudo cp /etc/kubernetes/pki/apiserver.crt ~/apiserver.crt.bak
sudo cp /etc/kubernetes/pki/apiserver.key ~/apiserver.key.bak

sudo rm /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
sudo kubeadm init phase certs apiserver \
  --control-plane-endpoint "<NEW_VIP>:6443" \
  --apiserver-cert-extra-sans="<NEW_VIP>,<MASTER1_IP>,<MASTER2_IP>,<MASTER3_IP>,127.0.0.1"
```

#### 3단계: kube-apiserver 재시작 (전체 마스터)

```bash
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sleep 10
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
watch sudo crictl pods --namespace kube-system
```

#### 4단계: kubeconfig / kubelet.conf 업데이트 (전체 마스터)

```bash
for conf in /etc/kubernetes/admin.conf \
            /etc/kubernetes/controller-manager.conf \
            /etc/kubernetes/scheduler.conf \
            /etc/kubernetes/kubelet.conf; do
    sudo sed -i "s|https://<OLD_VIP>:6443|https://<NEW_VIP>:6443|g" "$conf"
done
sudo systemctl restart kubelet
cp /etc/kubernetes/admin.conf ~/.kube/config
```

#### 5단계: 워커 노드 kubelet.conf 업데이트

```bash
sudo sed -i 's|https://<OLD_VIP>:6443|https://<NEW_VIP>:6443|g' /etc/kubernetes/kubelet.conf
sudo systemctl restart kubelet
```

#### 6단계: 클러스터 내부 ConfigMap 갱신 (Master-1에서 1회)

> Cilium 구성 시 `kube-proxy ConfigMap` 단계 생략, `kubeadm-config` 갱신 후
> `kubectl -n kube-system rollout restart ds cilium` 실행.

```bash
kubectl get configmap kube-proxy -n kube-system -o yaml | \
  sed 's|<OLD_VIP>:6443|<NEW_VIP>:6443|g' | \
  kubectl apply -f -
kubectl rollout restart daemonset kube-proxy -n kube-system

kubectl get configmap kubeadm-config -n kube-system -o yaml | \
  sed 's|<OLD_VIP>:6443|<NEW_VIP>:6443|g' | \
  kubectl apply -f -
```

#### 7단계: 확인

```bash
kubectl get nodes
kubectl get pods -n kube-system
```

## 참고

- 폐쇄망 배포용 파일은 `scripts/download.sh`로 수집합니다.
- 오프라인 설치 절차와 동일한 HA 구성이 `install-guide.md` 에 상세히 기술되어 있습니다.
