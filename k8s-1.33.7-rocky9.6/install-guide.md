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

## 설치 전 체크리스트

아래 항목은 단일 구성과 HA 구성 모두 설치 전에 확정합니다. 확정한 값은 `/etc/hosts`, 로드밸런서 설정, `kubeadm init` 인자에 동일하게 반영해야 합니다.

### 1. 구성 및 작업 범위

- [ ] 구성 유형 확정: 단일 컨트롤 플레인, HA 3중화, 물리 서버, 가상 서버 여부
- [ ] 노드별 역할, hostname, 관리 IP, Kubernetes 통신 NIC, gateway, DNS, NTP 서버 확정
- [ ] 작업 가능 시간과 금지 작업 확인: reboot, 네트워크 서비스 재시작, 방화벽 reload, Docker/containerd 재시작, OS 전체 업데이트
- [ ] 기존 서비스, 기존 컨테이너, 6443 포트 사용 서비스, NodePort 사용 서비스, HAProxy/keepalived 사용 여부 확인

### 2. 네트워크 대역 및 엔드포인트

- [ ] Pod CIDR 확정: `/20` 권장, 최소 `/22` 수준으로 환경 규모에 맞게 조정
- [ ] Service CIDR 확정: `/24` 가능, 여유가 필요하면 `/22` 권장
- [ ] Pod CIDR과 Service CIDR이 서버 실제 IP, 사내망, VPN, DB망, 관리망, 백업망, 스토리지망과 겹치지 않음 확인
- [ ] API endpoint 확정: 단일 노드 IP, VIP, FQDN 중 선택하고 인증서 SAN, DNS 또는 `/etc/hosts` 반영 방식 확정
- [ ] VIP 사용 시 미사용 IP 여부, 로드밸런서 방식, keepalived VRRP protocol 112 허용 여부, HAProxy 6443 bind 충돌 여부 확인

### 3. 방화벽 및 포트

- [ ] Control Plane 포트 허용: 6443/TCP, 2379-2380/TCP, 10250/TCP, 10257/TCP, 10259/TCP
- [ ] Worker 포트 허용: 10250/TCP, 10256/TCP, NodePort 기본 범위 30000-32767/TCP,UDP
- [ ] CNI, Ingress, 스토리지, Harbor, DNS, NTP 등 부가 구성에서 필요한 추가 포트 확인
- [ ] 방화벽 flush, iptables/nftables 초기화, firewalld reload가 금지된 환경이면 허용 규칙 방식으로 사전 합의

### 4. 런타임, OS, 폐쇄망 자산

- [ ] Docker/containerd 설치 상태, 기존 컨테이너 사용 여부, containerd 또는 Docker 재시작 가능 여부 확인
- [ ] kubelet과 containerd의 cgroup driver를 `systemd`로 맞출 수 있는지 확인
- [ ] OS 버전, 커널 버전, Kubernetes 버전, containerd 버전, CNI 버전의 호환성 확인
- [ ] swap 비활성화 가능 여부, 시간 동기화 상태, 디스크 여유 공간, inode 여유, hostname/MAC address/product UUID 중복 없음 확인
- [ ] 폐쇄망 반입 자산 확인: RPM/DEB, 바이너리, 이미지, 매니페스트, Helm chart, Harbor 인증서와 레지스트리 접속 정보

### 5. 설치 진행 판단

- [ ] 미확정 항목이 없고, 운영 영향이 있는 조치의 승인 범위가 명확한지 확인
- [ ] 장애 발생 시 되돌릴 범위와 담당자 연락 경로 확인

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
