# Kubernetes v1.30.0 온라인 설치 가이드 (Rocky Linux 9.6)

인터넷이 가능한 환경에서 kubeadm 기반 Kubernetes v1.30.0 클러스터를 구성하는 절차를 안내합니다.
containerd를 컨테이너 런타임으로, Calico를 CNI로 사용합니다.

> 오프라인(폐쇄망) 환경은 `install-guide.md`를 참고하세요.

## 전제 조건

- Rocky Linux 9.6 서버
  - **단일 구성**: 컨트롤 플레인 1대 + 워커 노드 1대 이상
  - **HA(3중화) 구성**: 컨트롤 플레인 3대 + 워커 노드 1대 이상 + VIP 1개
- 모든 노드에서 인터넷 접근 가능
- swap 비활성화 완료 (`swapoff -a` 및 `/etc/fstab` 주석 처리)

## Phase 1: 패키지 설치 (전체 노드)

```bash
# 1. containerd 설치 (Docker 공식 리포지토리)
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y containerd.io

# 2. Kubernetes 리포지토리 등록 (v1.30)
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.30/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.30/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

# 3. kubeadm, kubelet, kubectl 설치
sudo dnf install -y --disableexcludes=kubernetes kubelet kubeadm kubectl

# 4. kubelet 활성화 (kubeadm init 전에는 시작하지 않아도 됨)
sudo systemctl enable kubelet
```

> Kubernetes 리포지토리는 v1.24부터 `pkgs.k8s.io`로 이전되었습니다.
> 버전별 리포 경로(`/v1.30/`)가 다르므로 다른 버전 설치 시 URL을 맞게 수정하세요.

## Phase 2: OS 사전 설정 (전체 노드)

```bash
# 1. SELinux permissive 모드
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

# 2. 커널 모듈 로드
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

# 3. sysctl 설정
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

# 4. hosts 파일 등록 (환경에 맞게 수정)
sudo tee -a /etc/hosts <<EOF
<MASTER1_IP> <MASTER1_HOSTNAME>
<MASTER2_IP> <MASTER2_HOSTNAME>
<MASTER3_IP> <MASTER3_HOSTNAME>
10.10.10.73 worker1
EOF
```

## Phase 3: containerd 설정 (전체 노드)

```bash
# containerd 기본 설정 생성
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml

# cgroup driver를 systemd로 변경 (필수)
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Harbor(또는 사설 레지스트리) insecure registry 사용 시 config_path 설정
sudo sed -i "s|config_path = '/etc/containerd/certs.d:/etc/docker/certs.d'|config_path = '/etc/containerd/certs.d'|g" /etc/containerd/config.toml

# containerd 시작 및 활성화
sudo systemctl enable --now containerd
sudo systemctl status containerd
```

> containerd 재시작 후에도 `SystemdCgroup = true` 가 적용되지 않으면 아래 명령으로 확인하세요.
>
> ```bash
> grep SystemdCgroup /etc/containerd/config.toml
> ```

### (선택) Harbor insecure registry 등록

Harbor를 HTTP(insecure)로 운영하는 경우 각 노드에 아래 설정을 추가합니다.

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
> `containerd config default`로 생성한 `config.toml`에서 `config_path`가 없을 경우
> containerd 버전에 따라 키 이름이 다릅니다.
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
> # containerd v2.x (io.containerd.cri.v1.images)
> [plugins."io.containerd.cri.v1.images".registry]
>   config_path = "/etc/containerd/certs.d"
> ```

### (선택) containerd 데이터 경로 변경 — 소프트링크 방식

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

> `config.toml`의 `root` 값을 직접 변경하는 방법도 있지만, 소프트링크 방식은
> 기존 경로를 그대로 유지하므로 다른 툴과의 호환성을 더 쉽게 확보할 수 있습니다.

## Phase 4: 이미지 사전 Pull (선택, Master-1)

온라인 환경에서는 `kubeadm init` 시 이미지를 자동으로 pull하므로 이 단계는 생략 가능합니다.
네트워크가 느리거나 init 전에 이미지 준비 여부를 확인하고 싶을 때 실행합니다.

```bash
sudo kubeadm config images pull --kubernetes-version v1.30.0

# 확인
sudo ctr -n k8s.io images list | grep kube-apiserver
```

## Phase 5: 로드밸런서 구성 (HA 3중화 시에만 / 단일 구성이면 Phase 6으로)

HA 구성을 위해 로드밸런서가 필요합니다. 환경에 따라 아래 두 가지 방식 중 하나를 선택합니다.

> **[사전 결정] VIP 주소를 인증서에 직접 설정할지, FQDN으로 추상화할지 먼저 결정하세요.**
>
> 이 선택은 이후 `kubeadm init`의 `--control-plane-endpoint` 및 인증서 SAN에 영향을 미치므로
> **설치를 시작하기 전에** 결정해야 합니다.
>
> | 방식 | 장점 | 단점 |
> | :--- | :--- | :--- |
> | **FQDN** (`k8s-api.internal`) ← **권장** | VIP 변경 시 `/etc/hosts`만 수정, 인증서 재발급 불필요 | `/etc/hosts` 관리 필요 |
> | IP 직접 사용 | 설정 단순 | VIP 변경 시 인증서 재발급 필수 |
>
> FQDN 방식을 선택하면 **5-A-1**에서 바로 `/etc/hosts` 등록을 먼저 수행합니다.
> IP 직접 사용 방식이면 5-A-1을 건너뛰고 5-A-2부터 시작합니다.

### 옵션 A: VIP 방식 (표준, 권장)

Master 3대와 가상 IP(VIP) 환경을 가정합니다.
VIP를 K8s API Server(6443) 앞단에 두어 마스터 노드 장애 시에도 API 통신이 끊기지 않게 합니다.

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

#### 5-A-2. HAProxy, Keepalived 패키지 설치 (전체 마스터 노드)

```bash
sudo dnf install -y haproxy keepalived
```

#### 5-A-3. 커널 파라미터 설정 (전체 마스터 노드)

VIP가 자신의 인터페이스에 없어도 바인딩할 수 있도록 설정합니다.

```bash
cat <<EOF | sudo tee /etc/sysctl.d/haproxy.conf
net.ipv4.ip_nonlocal_bind = 1
EOF

sudo sysctl --system
```

#### 5-A-4. HAProxy 설정 (전체 마스터 노드)

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
    bind <VIP>:6443      # VIP로 바인딩 (API 서버와 포트 충돌 방지)
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

#### 5-A-5. Keepalived 설정 (전체 마스터 노드)

각 마스터 노드별로 `state`, `priority`, `interface` 값을 다르게 설정합니다.

| 노드 | state | priority |
| :--- | :--- | :--- |
| Master-1 | `MASTER` | `101` |
| Master-2 | `BACKUP` | `100` |
| Master-3 | `BACKUP` | `99` |

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
    state MASTER              # Master-2, 3은 BACKUP
    interface eth0            # 본인 네트워크 인터페이스명으로 변경 필수
    virtual_router_id 51
    priority 101              # M1: 101, M2: 100, M3: 99
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass 42          # 모든 노드 동일하게 설정
    }

    virtual_ipaddress {
        <VIP>          # VIP 주소
    }

    track_script {
        check_haproxy
    }
}
EOF
```

#### 5-A-6. 서비스 시작 및 VIP 확인

```bash
sudo systemctl enable --now haproxy
sudo systemctl enable --now keepalived

# VIP 활성화 확인 (Master-1에서 VIP가 보여야 함)
ip addr show eth0 | grep <VIP>
```

---

### 옵션 B: Localhost LB 방식 (VIP 사용 불가 환경)

VIP를 사용할 수 없는 환경에서 각 노드에 HAProxy를 띄워 Loopback(`127.0.0.1:8443`)으로 통신합니다.
**전체 마스터 및 워커 노드에 동일하게 설정합니다.**

```bash
sudo dnf install -y haproxy

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

### 옵션 A: HA(3중화) 구성 (VIP 사용)

`--apiserver-cert-extra-sans`에 VIP와 전체 마스터 IP를 포함해야 RHEL/Rocky 9계열의 엄격한 SAN 검증을 통과할 수 있습니다.

`pod-network-cidr` 와 `service-cidr` 는 현재 기본값으로 되어있습니다. 환경에 따라 해당 네트워크 대역 사용이 불가하다면 변경해야 합니다.

FQDN을 사용하는 경우(`5-A-1` 적용 시) `<VIP>` 대신 `k8s-api.internal`로 대체합니다.

> **HAProxy 포트 충돌 주의**
> HAProxy가 VIP:6443을 점유하고 있으면 `kubeadm init`이 같은 포트를 열려다 실패합니다.
> `kubeadm init` 전에 HAProxy를 잠시 중지하고, API 서버 bind-address 설정 후 다시 시작합니다.

```bash
# 1. HAProxy 일시 중지
sudo systemctl stop haproxy

# 2. kubeadm init — VIP IP 직접 사용 시
sudo kubeadm init \
  --control-plane-endpoint "<VIP>:6443" \
  --upload-certs \
  --apiserver-cert-extra-sans="<VIP>,<MASTER1_IP>,<MASTER2_IP>,<MASTER3_IP>,127.0.0.1" \
  --pod-network-cidr=192.168.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --kubernetes-version v1.30.0

# 2. kubeadm init — FQDN 사용 시 (권장)
sudo kubeadm init \
  --control-plane-endpoint "k8s-api.internal:6443" \
  --upload-certs \
  --apiserver-cert-extra-sans="k8s-api.internal,<VIP>,<MASTER1_IP>,<MASTER2_IP>,<MASTER3_IP>,127.0.0.1" \
  --pod-network-cidr=192.168.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --kubernetes-version v1.30.0

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
sudo kubeadm init \
  --control-plane-endpoint "<MASTER_IP>:6443" \
  --pod-network-cidr=192.168.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --kubernetes-version v1.30.0

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

## Phase 7: Calico CNI 설치 (Master-1)

Calico v3.28은 Kubernetes v1.30과 호환됩니다. 다른 버전을 사용할 경우
[Calico 호환 매트릭스](https://docs.tigera.io/calico/latest/getting-started/kubernetes/requirements)를 확인하세요.

> **`--pod-network-cidr`을 기본값(`192.168.0.0/16`)에서 변경한 경우**, 아래와 같이
> manifest를 로컬에 받아 `CALICO_IPV4POOL_CIDR` 항목을 수정한 뒤 적용합니다.
> `--service-cidr`는 Calico가 관리하지 않으므로 변경 불필요합니다.
>
> ```bash
> curl -O https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
>
> # 라인 번호 확인
> grep -n 'CALICO_IPV4POOL_CIDR' calico.yaml
> ```
>
> 해당 라인으로 이동해 주석(`#`)을 제거하고 값을 수정합니다.
>
> ```yaml
> # 변경 전 (주석 처리된 상태)
> # - name: CALICO_IPV4POOL_CIDR
> #   value: "192.168.0.0/16"
>
> # 변경 후 (주석 해제 + CIDR 수정)
> - name: CALICO_IPV4POOL_CIDR
>   value: "<YOUR_POD_CIDR>"
> ```

```bash
# 기본 CIDR(192.168.0.0/16) 그대로 사용 시 — URL에서 직접 적용
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml

# CIDR 수정 후 로컬 파일로 적용 시
kubectl apply -f calico.yaml

# Calico Pod가 Running이 될 때까지 대기
kubectl get pods -n kube-system -w
```

## Phase 8: Helm 설치 (컨트롤 플레인 노드)

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

helm version
```

> 특정 버전을 고정하고 싶다면 스크립트 실행 전 환경변수를 설정합니다.
>
> ```bash
> DESIRED_VERSION=v3.14.0 bash <(curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3)
> ```

## Phase 8-1: nerdctl 설치 (선택, 전체 노드)

컨테이너 이미지 조회·조작이 필요한 노드에 설치합니다. containerd와 직접 통신하며 `docker` CLI와 유사한 UX를 제공합니다. Rootless 모드 사용을 위해 모든 의존성(`rootlesskit`, `slirp4netns` 등)이 포함된 **Full 패키지** 사용을 권장합니다.

```bash
# GitHub Releases에서 Full 패키지 다운로드
NERDCTL_VERSION="2.2.2"
curl -LO "https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/nerdctl-full-${NERDCTL_VERSION}-linux-amd64.tar.gz"

# 압축 해제 후 전체 바이너리 및 스크립트 배포
tar -xzvf nerdctl-full-${NERDCTL_VERSION}-linux-amd64.tar.gz
sudo mv bin/* /usr/local/bin/
sudo chmod +x /usr/local/bin/nerdctl /usr/local/bin/rootlesskit /usr/local/bin/slirp4netns /usr/local/bin/containerd-rootless*

# 설치 확인
nerdctl --version
```

### Rootless 모드 활성화 절차 (일반 사용자 계정)

바이너리 설치 후, `sudo` 없이 `nerdctl`을 사용하려면 아래 절차를 **일반 사용자 계정**으로 진행해야 합니다.

1. **필수 패키지 확인**: `shadow-utils` 패키지가 설치되어 있어야 합니다.
   ```bash
   sudo dnf install -y shadow-utils
   ```

2. **사용자 환경 설정 도구 실행**: (root가 아닌 일반 계정으로 실행)
   ```bash
   containerd-rootless-setuptool.sh install
   ```
   *성공 시 `~/.config/systemd/user/containerd.service`가 등록됩니다.*

3. **환경 변수 등록**: `~/.bashrc` 또는 `~/.zshrc` 하단에 아래 내용을 추가하고 적용(`source`)합니다.
   ```bash
   export CONTAINERD_ADDRESS="unix://$XDG_RUNTIME_DIR/containerd/containerd.sock"
   ```

4. **Linger 설정 (권장)**: 로그아웃 후에도 서비스가 유지되도록 설정합니다.
   ```bash
   sudo loginctl enable-linger $(id -un)
   ```

주요 사용 예시:

```bash
# containerd k8s.io 네임스페이스 이미지 목록 확인
sudo nerdctl -n k8s.io images

# Harbor에서 이미지 pull (insecure registry)
sudo nerdctl -n k8s.io pull --insecure-registry <NODE_IP>:30002/library/myapp:1.0.0
```

## Phase 8-2: skopeo 설치 (선택, 전체 노드)

레지스트리 간 이미지 복사, 이미지 메타데이터 검사 등에 사용합니다. 데몬 없이 동작하며 Harbor push/pull 검증에 유용합니다.

```bash
sudo dnf install -y skopeo

# 설치 확인
skopeo --version
```

주요 사용 예시:

```bash
# Harbor 이미지 목록 조회 (insecure registry)
skopeo list-tags --tls-verify=false docker://<NODE_IP>:30002/library/myapp

# 레지스트리 간 이미지 복사
skopeo copy --src-tls-verify=false --dest-tls-verify=false \
  docker://<SRC_REGISTRY>/myapp:1.0.0 \
  docker://<NODE_IP>:30002/library/myapp:1.0.0

# 이미지 메타데이터 확인
skopeo inspect --tls-verify=false docker://<NODE_IP>:30002/library/myapp:1.0.0
```

## Phase 9: 워커 노드 조인

Master-1의 `kubeadm init` 출력에서 워커 조인 명령을 복사하여 실행합니다.

```bash
sudo kubeadm join <CONTROL_PLANE_ENDPOINT>:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```

## Phase 10: 설치 확인

```bash
kubectl get nodes
kubectl get pods -n kube-system
```

모든 노드가 `Ready` 상태이고 kube-system Pod들이 `Running` 이면 설치 완료입니다.

```bash
# HA 구성 시 CIDR 설정 확인
kubectl get pod -n kube-system -l component=kube-controller-manager -o yaml | grep cluster

# Calico IP Pool 확인
kubectl get ippools -o yaml
```

## 재설치 시 초기화

오류 발생 등으로 재설치가 필요한 경우 아래 순서로 초기화합니다.

```bash
# 1. kubeadm reset
sudo kubeadm reset -f

# 2. CNI 및 kube 설정 파일 삭제
sudo rm -rf /etc/cni/net.d
rm -rf $HOME/.kube
sudo rm -rf /root/.kube

# 3. etcd, kubelet 데이터 삭제
sudo rm -rf /var/lib/etcd
sudo rm -rf /var/lib/kubelet

# 4. iptables 규칙 초기화
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X

# 5. containerd 재시작
sudo systemctl restart containerd
```

---

## VIP 변경 시 조치

운영 중 VIP 대역이 변경되거나 새로운 IP를 할당받아야 하는 경우의 절차입니다.

### 케이스 0: 운영 중인 클러스터를 IP → FQDN으로 전환

이미 VIP IP로 초기 구성한 클러스터에 FQDN을 사후 적용하는 절차입니다.
이후 VIP가 변경되면 케이스 A 절차만으로 처리할 수 있게 됩니다.

#### **1단계: 모든 노드에 FQDN 등록 (마스터 + 워커)**

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

```bash
# kube-proxy ConfigMap 갱신
kubectl get configmap kube-proxy -n kube-system -o yaml | \
  sed 's|<OLD_VIP>:6443|k8s-api.internal:6443|g' | \
  kubectl apply -f -

# 변경 사항 적용을 위해 kube-proxy 파드 롤아웃
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
ip addr show eth0 | grep <NEW_VIP>
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
# 마스터 노드 kubeconfig + kubelet.conf 업데이트
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

로컬 파일 수정과 별개로, 클러스터 내부 etcd에 저장된 엔드포인트도 갱신해야 합니다.
이를 누락하면 kube-proxy 파드가 재시작될 때 구 VIP로 접속을 시도하여 `CrashLoopBackOff`가 발생할 수 있습니다.

```bash
# kube-proxy ConfigMap 갱신
kubectl get configmap kube-proxy -n kube-system -o yaml | \
  sed 's|<OLD_VIP>:6443|<NEW_VIP>:6443|g' | \
  kubectl apply -f -

# 변경 사항 적용을 위해 kube-proxy 파드 롤아웃
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
