# Kubernetes v1.30.0 오프라인 설치 가이드 (Rocky Linux 9.6)

폐쇄망 환경에서 kubeadm 기반 Kubernetes v1.30.0 클러스터를 구성하는 절차를 안내합니다.
containerd v2.2.0을 컨테이너 런타임으로, Calico를 CNI로 사용합니다.

## 전제 조건

- Rocky Linux 9.6 서버
  - **단일 구성**: 컨트롤 플레인 1대 + 워커 노드 1대 이상
  - **HA(3중화) 구성**: 컨트롤 플레인 3대 + 워커 노드 1대 이상 + VIP 1개
- 모든 노드에서 아래 설치 파일 접근 가능
- swap 비활성화 완료 (`swapoff -a` 및 `/etc/fstab` 주석 처리)

## 디렉토리 구조

| 경로 | 설명 |
| :--- | :--- |
| `common/rpms/` | 공통 의존성 RPM (모든 노드) |
| `k8s/rpms/` | kubeadm, kubelet, kubectl, containerd RPM |
| `k8s/binaries/` | helm, cri-dockerd 등 바이너리 |
| `k8s/images/` | kubeadm, Calico 등 컨테이너 이미지 `.tar` |
| `k8s/charts/` | Helm 차트 |
| `k8s/utils/` | calico.yaml 등 매니페스트 |

## Phase 0: 설치 파일 배포 (Master-1 → 전체 노드)

마스터-1에 설치 파일이 있다고 가정하고, 나머지 노드에 배포합니다.

```bash
# 배포 대상 노드 IP 목록 (환경에 맞게 수정)
NODES=("10.10.10.71" "10.10.10.72" "10.10.10.73" "10.10.10.74" "10.10.10.75")

for IP in "${NODES[@]}"; do
    echo "Sending to $IP..."
    scp ~/k8s-1.30.tar.gz rocky@$IP:~/
done

# 모든 노드에서 압축 해제
tar -zxvf ~/k8s-1.30.tar.gz
```

## Phase 1: 공통 RPM 설치 (전체 노드)

```bash
# 1. 공통 의존성 RPM 설치
sudo dnf localinstall -y --disablerepo='*' common/rpms/*.rpm

# 2. kubeadm, kubelet, kubectl, containerd RPM 설치
sudo dnf localinstall -y --disablerepo='*' k8s/rpms/*.rpm

# 3. kubelet 활성화 (kubeadm init 전에는 시작하지 않아도 됨)
sudo systemctl enable kubelet
```

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
10.10.10.70 master1
10.10.10.71 master2
10.10.10.72 master3
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

# Harbor 인증서 경로 설정
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

## Phase 4: 이미지 로드 (전체 노드)

```bash
for tar_file in k8s/images/*.tar; do
    echo "Loading $tar_file..."
    sudo ctr -n k8s.io images import "$tar_file"
done

# 확인
sudo ctr -n k8s.io images list | grep kube-apiserver
```

## Phase 5: 로드밸런서 구성 (HA 3중화 시에만 / 단일 구성이면 Phase 6으로)

HA 구성을 위해 로드밸런서가 필요합니다. 환경에 따라 아래 두 가지 방식 중 하나를 선택합니다.

### 옵션 A: VIP 방식 (표준, 권장)

Master 3대(`10.10.10.70`, `71`, `72`)와 가상 IP(VIP, `10.10.10.200`) 환경을 가정합니다.
VIP를 K8s API Server(6443) 앞단에 두어 마스터 노드 장애 시에도 API 통신이 끊기지 않게 합니다.

#### 5-A-1. 커널 파라미터 설정 (전체 마스터 노드)

VIP가 자신의 인터페이스에 없어도 바인딩할 수 있도록 설정합니다.

```bash
cat <<EOF | sudo tee /etc/sysctl.d/haproxy.conf
net.ipv4.ip_nonlocal_bind = 1
EOF

sudo sysctl --system
```

#### 5-A-2. HAProxy 설정 (전체 마스터 노드)

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
    bind 10.10.10.200:6443      # VIP로 바인딩 (API 서버와 포트 충돌 방지)
    mode tcp
    option tcplog
    default_backend k8s-masters

backend k8s-masters
    mode tcp
    balance roundrobin
    option tcp-check
    server master1 10.10.10.70:6443 check fall 3 rise 2
    server master2 10.10.10.71:6443 check fall 3 rise 2
    server master3 10.10.10.72:6443 check fall 3 rise 2
EOF
```

#### 5-A-3. Keepalived 설정 (전체 마스터 노드)

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
        10.10.10.200          # VIP 주소
    }

    track_script {
        check_haproxy
    }
}
EOF
```

#### 5-A-4. 서비스 시작 및 VIP 확인

```bash
sudo systemctl enable --now haproxy
sudo systemctl enable --now keepalived

# VIP 활성화 확인 (Master-1에서 VIP가 보여야 함)
ip addr show eth0 | grep 10.10.10.200
```

#### 5-A-5. (권장) FQDN으로 VIP 추상화

VIP IP를 직접 사용하는 대신 내부 FQDN(예: `k8s-api.internal`)으로 추상화하면,
나중에 VIP가 변경되어도 **인증서 재발급 없이** `/etc/hosts`만 수정하면 됩니다.

**전체 노드(마스터 + 워커)에서 실행합니다.**

```bash
# /etc/hosts에 FQDN 등록
echo "10.10.10.200  k8s-api.internal" | sudo tee -a /etc/hosts
```

이후 Phase 6의 `kubeadm init` 시 `--control-plane-endpoint`와 `--apiserver-cert-extra-sans`에
IP 대신 FQDN을 사용합니다.

```bash
sudo kubeadm init \
  --control-plane-endpoint "k8s-api.internal:6443" \
  --upload-certs \
  --apiserver-cert-extra-sans="k8s-api.internal,10.10.10.200,10.10.10.70,10.10.10.71,10.10.10.72,127.0.0.1" \
  --pod-network-cidr=192.168.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --kubernetes-version v1.30.0
```

> HAProxy의 `bind`는 안정성을 위해 VIP IP(`10.10.10.200:6443`)를 그대로 사용합니다.
> FQDN은 kubeconfig의 server 주소와 인증서 SAN에만 적용됩니다.

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
    server master1 10.10.10.70:6443 check
    server master2 10.10.10.71:6443 check
    server master3 10.10.10.72:6443 check
EOF

sudo systemctl enable --now haproxy
```

## Phase 6: kubeadm init (Master-1)

### 옵션 A: HA(3중화) 구성 (VIP 사용)

`--apiserver-cert-extra-sans`에 VIP와 전체 마스터 IP를 포함해야 RHEL/Rocky 9계열의 엄격한 SAN 검증을 통과할 수 있습니다.

FQDN을 사용하는 경우(`5-A-5` 적용 시) `10.10.10.200` 대신 `k8s-api.internal`로 대체합니다.

```bash
# VIP IP 직접 사용 시
sudo kubeadm init \
  --control-plane-endpoint "10.10.10.200:6443" \
  --upload-certs \
  --apiserver-cert-extra-sans="10.10.10.200,10.10.10.70,10.10.10.71,10.10.10.72,127.0.0.1" \
  --pod-network-cidr=192.168.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --kubernetes-version v1.30.0

# FQDN 사용 시 (권장)
sudo kubeadm init \
  --control-plane-endpoint "k8s-api.internal:6443" \
  --upload-certs \
  --apiserver-cert-extra-sans="k8s-api.internal,10.10.10.200,10.10.10.70,10.10.10.71,10.10.10.72,127.0.0.1" \
  --pod-network-cidr=192.168.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --kubernetes-version v1.30.0
```

초기화 완료 후 **API 서버 bind-address를 해당 노드의 실제 IP로 수정**합니다.
설정하지 않으면 API 서버가 `0.0.0.0`으로 바인딩되어 HAProxy(VIP:6443)와 포트 충돌이 발생합니다.

```bash
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml

# spec.containers[].command 섹션에 추가
# - --bind-address=10.10.10.70   (Master-1의 실제 IP)
```

### 옵션 B: 단일 구성

```bash
sudo kubeadm init \
  --control-plane-endpoint "10.10.10.70:6443" \
  --pod-network-cidr=192.168.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --kubernetes-version v1.30.0
```

### kubeconfig 설정 (컨트롤 플레인 공통)

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

## Phase 6-1: 추가 마스터 노드 조인 (Master-2, 3 — HA 구성 시에만)

Master-1 초기화 출력에서 **`--control-plane`** 조인 명령을 복사하여 실행합니다.

```bash
sudo kubeadm join 10.10.10.200:6443 --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH> \
    --control-plane --certificate-key <CERT_KEY>
```

조인 완료 후 **즉시** 해당 노드의 IP로 bind-address를 수정합니다.

```bash
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml

# Master-2: - --bind-address=10.10.10.71
# Master-3: - --bind-address=10.10.10.72
```

kubeconfig도 각 노드에 설정합니다.

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

## Phase 7: Calico CNI 설치 (Master-1)

```bash
kubectl apply -f k8s/utils/calico.yaml

# Calico Pod가 Running이 될 때까지 대기
kubectl get pods -n kube-system -w
```

## Phase 8: Helm 설치 (컨트롤 플레인 노드)

```bash
cd k8s/binaries
tar -xzvf helm-v3.14.0-linux-amd64.tar.gz
sudo mv linux-amd64/helm /usr/local/bin/helm
helm version
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

**1단계: 모든 노드에 FQDN 등록 (마스터 + 워커)**

```bash
echo "10.10.10.200  k8s-api.internal" | sudo tee -a /etc/hosts
```

**2단계: API 서버 인증서에 FQDN SAN 추가 (전체 마스터 노드)**

```bash
# 기존 인증서 백업
sudo cp /etc/kubernetes/pki/apiserver.crt ~/apiserver.crt.bak
sudo cp /etc/kubernetes/pki/apiserver.key ~/apiserver.key.bak

# 삭제 후 FQDN 포함하여 재발급
sudo rm /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
sudo kubeadm init phase certs apiserver \
  --control-plane-endpoint "k8s-api.internal:6443" \
  --apiserver-cert-extra-sans="k8s-api.internal,10.10.10.200,10.10.10.70,10.10.10.71,10.10.10.72,127.0.0.1"

# FQDN이 SAN에 포함되었는지 확인
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A1 "Subject Alternative"
```

**3단계: kube-apiserver 재시작 (전체 마스터 노드)**

```bash
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sleep 10
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/

watch sudo crictl pods --namespace kube-system
```

**4단계: kubeconfig server 주소를 FQDN으로 변경 (전체 마스터 노드)**

```bash
for conf in /etc/kubernetes/admin.conf \
            /etc/kubernetes/controller-manager.conf \
            /etc/kubernetes/scheduler.conf; do
    sudo sed -i "s|https://10.10.10.200:6443|https://k8s-api.internal:6443|g" "$conf"
done

# 현재 사용자 kubeconfig 갱신
cp /etc/kubernetes/admin.conf ~/.kube/config
```

**5단계: 워커 노드 kubelet.conf 업데이트 (전체 워커 노드)**

```bash
sudo sed -i 's|https://10.10.10.200:6443|https://k8s-api.internal:6443|g' /etc/kubernetes/kubelet.conf
sudo systemctl restart kubelet
```

**6단계: 확인**

```bash
kubectl get nodes
kubectl cluster-info
```

`Kubernetes control plane` 주소가 `https://k8s-api.internal:6443`으로 표시되면 완료입니다.

---

### 케이스 A: FQDN 방식으로 초기 구성한 경우 (권장 구성)

FQDN(`k8s-api.internal`)이 인증서 SAN에 포함되어 있으므로, **인증서 재발급 없이** 아래 순서만 따르면 됩니다.

**1단계: 모든 노드의 `/etc/hosts` 업데이트 (마스터 + 워커)**

```bash
# OLD_VIP → NEW_VIP 로 변경
sudo sed -i 's/OLD_VIP  k8s-api.internal/NEW_VIP  k8s-api.internal/' /etc/hosts

# 확인
grep k8s-api.internal /etc/hosts
```

**2단계: Keepalived VIP 변경 (전체 마스터 노드)**

```bash
sudo sed -i 's/OLD_VIP/NEW_VIP/' /etc/keepalived/keepalived.conf
sudo systemctl restart keepalived

# 새 VIP 활성화 확인 (Master-1)
ip addr show eth0 | grep NEW_VIP
```

**3단계: HAProxy bind IP 변경 (전체 마스터 노드)**

```bash
sudo sed -i 's/OLD_VIP:6443/NEW_VIP:6443/' /etc/haproxy/haproxy.cfg
sudo systemctl restart haproxy
```

> `backend k8s-masters`의 `server` 항목(마스터 노드 IP)은 변경하지 않습니다.

**4단계: API 서버 재시작 확인**

```bash
# kubeconfig의 server 주소는 FQDN이므로 변경 불필요
kubectl get nodes
```

---

### 케이스 B: VIP IP를 직접 사용하여 초기 구성한 경우

인증서 SAN에 기존 VIP IP가 고정되어 있으므로, **인증서 재발급이 필수**입니다.
전체 마스터 노드에서 순서대로 진행합니다.

**1단계: Keepalived / HAProxy VIP 변경 (전체 마스터 노드)**

```bash
sudo sed -i 's/OLD_VIP/NEW_VIP/' /etc/keepalived/keepalived.conf
sudo systemctl restart keepalived

sudo sed -i 's/OLD_VIP:6443/NEW_VIP:6443/' /etc/haproxy/haproxy.cfg
sudo systemctl restart haproxy
```

**2단계: API 서버 인증서 재발급 (전체 마스터 노드)**

```bash
# 기존 인증서 백업
sudo cp /etc/kubernetes/pki/apiserver.crt ~/apiserver.crt.bak
sudo cp /etc/kubernetes/pki/apiserver.key ~/apiserver.key.bak

# 삭제 후 재발급 (새 VIP 포함)
sudo rm /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
sudo kubeadm init phase certs apiserver \
  --control-plane-endpoint "NEW_VIP:6443" \
  --apiserver-cert-extra-sans="NEW_VIP,10.10.10.70,10.10.10.71,10.10.10.72,127.0.0.1"
```

**3단계: kube-apiserver 재시작 (전체 마스터 노드)**

static pod는 manifest를 잠시 제거했다가 복원하면 자동 재시작됩니다.

```bash
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sleep 10
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/

# Pod가 다시 Running 상태가 될 때까지 대기
watch sudo crictl pods --namespace kube-system
```

**4단계: kubeconfig server 주소 변경 (전체 마스터 노드)**

```bash
# 마스터 노드 kubeconfig 업데이트
for conf in /etc/kubernetes/admin.conf \
            /etc/kubernetes/controller-manager.conf \
            /etc/kubernetes/scheduler.conf; do
    sudo sed -i "s|https://OLD_VIP:6443|https://NEW_VIP:6443|g" "$conf"
done

# 현재 사용자 kubeconfig 갱신
cp /etc/kubernetes/admin.conf ~/.kube/config
```

**5단계: 워커 노드 kubelet.conf 업데이트 (전체 워커 노드)**

```bash
sudo sed -i 's|https://OLD_VIP:6443|https://NEW_VIP:6443|g' /etc/kubernetes/kubelet.conf
sudo systemctl restart kubelet
```

**6단계: 정상 동작 확인**

```bash
kubectl get nodes
kubectl get pods -n kube-system
```

모든 노드가 `Ready` 상태이고 kube-system Pod가 `Running`이면 완료입니다.
