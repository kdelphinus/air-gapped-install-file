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
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10"|' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
```

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

### 옵션 B: 단일 구성

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

Master-1의 `kubeadm init` 출력에서 **`--control-plane`** 조인 명령을 복사하여 실행합니다.

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
sudo crictl pods --namespace kube-system | grep apiserver
sudo systemctl start haproxy

# 5. kubeconfig
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

## Phase 6: CNI 설치

### 옵션 A: Calico

```bash
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/tigera-operator.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/custom-resources.yaml

# 파드 Running 대기
kubectl get pods -n calico-system -w
```

### 옵션 B: Cilium (Helm)

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

# 단일 구성
helm install cilium cilium/cilium --version 1.19.3 \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=<MASTER_IP> \
  --set k8sServicePort=6443

# HA 구성 (FQDN)
helm install cilium cilium/cilium --version 1.19.3 \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=k8s-api.internal \
  --set k8sServicePort=6443
```

## Phase 7: 워커 조인 및 확인

```bash
# 컨트롤 플레인에서 조인 명령 출력
kubeadm token create --print-join-command

# 워커 노드에서 실행 (단일 구성 / HA 구성 모두 endpoint만 달라짐)
sudo kubeadm join <ENDPOINT>:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>

# 확인
kubectl get nodes
kubectl get pods -A
```

## Phase 8: helm / nerdctl 설치 (선택)

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
