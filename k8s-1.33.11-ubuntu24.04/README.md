# Kubernetes v1.33.11 오프라인 설치 파일 (Ubuntu 24.04 LTS)

폐쇄망(Ubuntu 24.04) 환경에 kubeadm 기반 Kubernetes v1.33.11 클러스터를 구성하기 위한 파일과 설치 스크립트입니다.
containerd v2.2.x를 컨테이너 런타임으로 사용하며, CNI는 설치 시점에 **Calico** 또는 **Cilium**을 선택할 수 있습니다.

WSL2 로컬 단일 노드 환경과 폐쇄망 VM 환경 모두 동일한 파일로 설치됩니다.

## 1. 버전 매트릭스

| 컴포넌트 | 버전 | 비고 |
| --- | --- | --- |
| Kubernetes | **v1.33.11** | `kubeadm`, `kubelet`, `kubectl` |
| OS | Ubuntu 24.04 LTS (noble) | WSL2/VM 공통 |
| containerd | v2.2.x | Docker CE repo의 `containerd.io` |
| runc | v1.2.x | `containerd.io` 의존 |
| pause | 3.10 | k8s 1.33 기본 |
| CoreDNS | v1.12.x | k8s 1.33 기본 |
| etcd | 3.5.21-0 | k8s 1.33 기본 |
| helm | v3.18.x | k8s 1.33 지원 최소 |
| nerdctl | v2.2.2 (full) | rootlesskit, slirp4netns 포함 |
| **CNI 옵션 A** | Calico v3.29.x (Tigera Operator) | kube-proxy 사용, L7은 `envoy-1.36.3/` 사용 |
| **CNI 옵션 B** | Cilium v1.19.3 | `kubeProxyReplacement=true`, `cilium-1.19.3/` 사용 |

## 2. 필수 시스템 컨테이너 이미지

`kubeadm` 초기화 및 CNI 배포 시 생성되는 필수 컨테이너입니다. 폐쇄망에서는 `download.sh`로 사전에 `.tar` 파일로 확보합니다.

### Kubernetes 기본 (kube-system)

| 컨테이너 | 역할 | 비고 |
| --- | --- | --- |
| kube-apiserver | API 엔드포인트 | Static Pod |
| etcd | 클러스터 상태 KV 저장 | Static Pod |
| kube-controller-manager | 상태 제어 루프 | Static Pod |
| kube-scheduler | Pod 배치 결정 | Static Pod |
| kube-proxy | 네트워크 규칙 (Calico 선택 시) | DaemonSet |
| coredns | 내부 DNS | Deployment |
| pause | 네임스페이스 유지 | Sidecar |

### Calico 선택 시

| 컨테이너 | 역할 |
| --- | --- |
| calico-node | 호스트↔Pod 네트워크, BGP |
| calico-typha | 대규모 클러스터 데이터 캐시 |
| calico-kube-controllers | API 동기화 |
| install-cni | 노드 CNI 바이너리 배치 |

### Cilium 선택 시

Cilium 관련 이미지는 `cilium-1.19.3/images/`에서 관리합니다.
이 컴포넌트는 k8s 코어 이미지만 포함하고, Cilium 이미지는 해당 컴포넌트에서 로드합니다.

## 3. 디렉토리 구조

```text
k8s-1.33.11-ubuntu24.04/
├── README.md                  # 이 파일
├── install-guide.md           # 오프라인 수동 설치 가이드
├── install-guide-online.md    # 온라인 설치 가이드 (참고)
├── k8s/
│   ├── debs/                  # k8s DEB + 시스템 유틸
│   ├── binaries/              # helm, nerdctl tarball
│   ├── images/                # k8s 코어 + Calico 이미지 (.tar)
│   └── utils/                 # calico.yaml, local-path-storage.yaml
└── scripts/
    ├── download.sh            # [인터넷 호스트] 파일 수집
    ├── install.sh             # [폐쇄망] 메인 설치 (WSL2/VM · CNI 분기)
    ├── uninstall.sh           # kubeadm reset + 잔재 제거
    └── wsl2_prep.sh           # WSL2 systemd 활성화
```

## 4. 핵심 설정 파라미터

| 항목 | 값 | 비고 |
| --- | --- | --- |
| Cgroup Driver | `systemd` | containerd v2.2 권장 |
| Pod CIDR (Calico) | `192.168.0.0/16` | |
| Pod CIDR (Cilium) | `10.0.0.0/16` | Cilium 기본 권장 |
| Service CIDR | `10.96.0.0/12` | |
| Internal DNS | `10.96.0.10` | CoreDNS 고정 IP |
| CRI Socket | `unix:///run/containerd/containerd.sock` | |

## 5. 사용 흐름

```text
[인터넷 호스트]
  scripts/download.sh
    └─ DEB · 바이너리 · 이미지 · 매니페스트 다운로드 → k8s/ 채움
    └─ tar czf k8s-1.33.11-ubuntu24.04.tar.gz k8s-1.33.11-ubuntu24.04/

[폐쇄망 노드 / WSL2]
  tar xzf k8s-1.33.11-ubuntu24.04.tar.gz
  cd k8s-1.33.11-ubuntu24.04

  # (WSL2 전용 1회) systemd 활성화
  scripts/wsl2_prep.sh

  # 메인 설치
  scripts/install.sh
    └─ WSL2/VM 자동 감지 · CNI 선택 · install.conf 저장
    └─ CNI=calico → ../envoy-1.36.3/scripts/install.sh 자동 호출 (L7)
    └─ CNI=cilium → ../cilium-1.19.3/scripts/install.sh 자동 호출

  # 워커 노드 합류
  scripts/install.sh --join <token> <ca-hash> <endpoint>
```

## 6. 연동 컴포넌트

| 경로 | 용도 | 호출 시점 |
| --- | --- | --- |
| `../cilium-1.19.3/scripts/install.sh` | Cilium CNI 설치 | `CNI_CHOICE=cilium` 선택 시 자동 |
| `../envoy-1.36.3/scripts/install.sh` | Envoy Gateway (L7) | `CNI_CHOICE=calico` 선택 시 자동 |

> Cilium 선택 시에는 Cilium의 Gateway API 기능을 사용하므로 Envoy Gateway를 별도로 설치하지 않습니다.
