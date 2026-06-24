# Kubernetes v1.33.7 오프라인 설치 가이드 (Rocky Linux 9.6 / Ubuntu 24.04)

폐쇄망 환경에서 kubeadm 기반 Kubernetes v1.33.7 클러스터를 구성하는 절차를 안내합니다.
컨테이너 런타임은 containerd v2.2.x를, CNI는 Calico를 사용합니다.

## Phase -1: 인터넷 연결 호스트에서 에셋 다운로드

폐쇄망 환경으로 반입할 오프라인 설치 파일(RPM/DEB, 외부 바이너리, 컨테이너 이미지 등)을 다운로드하기 위해 인터넷이 작동하는 호스트에서 아래 스크립트를 먼저 실행합니다.

```bash
# 컴포넌트 루트 디렉토리에서 실행
sudo ./scripts/download_assets_offline.sh
```

- Rocky Linux/RHEL 환경에서 실행 시 `k8s/rpms/` 및 `common/rpms/`에 RPM이 다운로드됩니다.
- Ubuntu/Debian 환경에서 실행 시 `k8s/debs/` 및 `common/debs/`에 DEB이 다운로드됩니다.
- 감지된 실행 호스트의 OS 버전에 맞춰 패키지가 다운로드되므로, 실제 타겟 노드와 동일한 OS 버전을 갖춘 외부망 호스트에서 구동하는 것을 권장합니다.

다운로드가 완료되면 컴포넌트 디렉토리를 압축하여 폐쇄망 내부로 이관합니다.

## 전제 조건

- Rocky Linux 9.6 또는 Ubuntu 24.04 (폐쇄망)
  - **단일 구성**: 컨트롤 플레인 1대 + 워커 노드 1대 이상
  - **HA(3중화) 구성**: 컨트롤 플레인 3대 + 워커 노드 1대 이상 + VIP 1개
- 모든 노드에서 아래 설치 파일 접근 가능
- swap 비활성화 완료 (`swapoff -a` 및 `/etc/fstab` 주석 처리)

## 디렉토리 구조

| 경로 | 설명 |
| :--- | :--- |
| `common/rpms/` / `common/debs/` | 공통 의존성 RPM/DEB (모든 노드) |
| `k8s/rpms/` / `k8s/debs/` | kubeadm, kubelet, kubectl, containerd 패키지 |
| `k8s/binaries/` | helm, cri-dockerd, nerdctl 등 바이너리 |
| `k8s/images/` | Kubernetes 코어 및 Calico CNI 컨테이너 이미지 `.tar` |
| `k8s/utils/` | calico.yaml 등 구성 매니페스트 |

## Phase 1: 패키지 설치 (전체 노드)

### Rocky Linux (RPM) 설치의 경우
```bash
# 1. 공통 의존성 RPM 설치
sudo dnf localinstall -y --disablerepo='*' common/rpms/*.rpm

# 2. Kubernetes RPM 설치
sudo dnf localinstall -y --disablerepo='*' k8s/rpms/*.rpm

# 3. 서비스 활성화
sudo systemctl enable kubelet
```

### Ubuntu (DEB) 설치의 경우
```bash
# 1. 수집된 모든 deb 패키지 강제 로컬 설치
sudo dpkg -i common/debs/*.deb
sudo dpkg -i k8s/debs/*.deb

# 2. 서비스 활성화
sudo systemctl enable kubelet
```

## Phase 2: OS 사전 설정 (전체 노드)

```bash
# 1. SELinux permissive 모드 (Rocky Linux의 경우)
sudo setenforce 0 2>/dev/null || true
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true

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

# 4. 방화벽 비활성화 (보안 정책에 따라 포트 설정도 가능)
sudo systemctl stop firewalld 2>/dev/null || true
sudo systemctl disable firewalld 2>/dev/null || true
sudo systemctl stop ufw 2>/dev/null || true
sudo systemctl disable ufw 2>/dev/null || true
```

## Phase 3: containerd 설정 및 기동 (전체 노드)

### containerd 바이너리/패키지 설정
```bash
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

# SystemdCgroup = true 설정 적용
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl daemon-reload
sudo systemctl enable --now containerd
sudo systemctl restart containerd
```

이후 설치 상세 절차(HA 프록시 구성 및 `kubeadm init`)는 `install-guide-online.md`를 참고하여 동일하게 수행하되, 패키지 및 이미지 pull 부분만 오프라인으로 대체됩니다.
