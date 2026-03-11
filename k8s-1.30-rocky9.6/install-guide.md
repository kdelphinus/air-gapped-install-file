# Kubernetes v1.30.0 오프라인 설치 가이드 (Rocky Linux 9.6)

폐쇄망 환경에서 kubeadm 기반 Kubernetes v1.30.0 클러스터를 구성하는 절차를 안내합니다.
containerd v2.2.0을 컨테이너 런타임으로, Calico를 CNI로 사용합니다.

## 전제 조건

- Rocky Linux 9.6 서버 (컨트롤 플레인 1대 + 워커 노드 1대 이상)
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
| `k8s/utils/` | calico.yaml, ingress-nginx.yaml 등 매니페스트 |

## Phase 1: 공통 RPM 설치 (전체 노드)

```bash
# 1. 공통 의존성 RPM 설치
sudo dnf localinstall -y --disablerepo='*' common/rpms/*.rpm

# 2. kubeadm, kubelet, kubectl, containerd RPM 설치
sudo dnf localinstall -y --disablerepo='*' k8s/rpms/*.rpm

# 3. kubelet 활성화 (kubeadm init 전에는 시작하지 않아도 됨)
sudo systemctl enable kubelet
```

## Phase 2: containerd 설정 (전체 노드)

```bash
# containerd 기본 설정 생성
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml

# cgroup driver를 systemd로 변경
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# containerd 시작 및 활성화
sudo systemctl enable --now containerd
sudo systemctl status containerd
```

## Phase 3: 시스템 사전 설정 (전체 노드)

```bash
# 커널 모듈 로드
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

# sysctl 설정
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

## Phase 4: kubeadm init (컨트롤 플레인 노드)

```bash
# 컨테이너 이미지 로드
for tar_file in k8s/images/*.tar; do
  sudo ctr -n k8s.io images import "$tar_file"
done

# kubeadm init 실행
sudo kubeadm init \
  --pod-network-cidr=192.168.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --cri-socket=unix:///run/containerd/containerd.sock

# kubectl 설정
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

## Phase 5: Calico CNI 설치 (컨트롤 플레인 노드)

```bash
kubectl apply -f k8s/utils/calico.yaml
```

Calico Pod가 Running 상태가 될 때까지 대기합니다.

```bash
kubectl get pods -n kube-system -w
```

## Phase 6: Helm 설치 (컨트롤 플레인 노드)

```bash
cd k8s/binaries
tar -xzvf helm-v3.14.0-linux-amd64.tar.gz
sudo mv linux-amd64/helm /usr/local/bin/helm
helm version
```

## Phase 7: 워커 노드 조인

컨트롤 플레인 노드의 `kubeadm init` 출력에서 조인 명령을 복사합니다.

```bash
# 워커 노드에서 실행 (kubeadm init 출력의 join 명령 사용)
sudo kubeadm join <CONTROL_PLANE_IP>:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```

## Phase 8: 설치 확인

```bash
kubectl get nodes
kubectl get pods -n kube-system
```

모든 노드가 `Ready` 상태이고 kube-system Pod들이 `Running` 이면 설치 완료입니다.
