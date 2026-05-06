# 🏗️ Kubernetes v1.30.0 기반 인프라 설치 구성 명세

## 1. 주요 실행 바이너리 (Binaries)

서버 OS(Rocky 9.6)에 직접 설치되어 구동되는 핵심 파일입니다.

* **Kubernetes Control Plane 도구**: `kubeadm`, `kubelet`, `kubectl` (v1.30.0)
* **컨테이너 런타임 (CRI)**: `containerd` (v2.2.0), `runc`
* **패키지 관리 도구**: `helm` (v3.14.0)

---

## 2. 필수 시스템 컨테이너 목록 (System Containers)

`kubeadm` 설치 및 `Calico` 배포 시 클러스터 내부에 생성되어야 하는 필수 컨테이너들입니다. 폐쇄망 환경에서는 아래 이미지들이 사전에 준비되어야 합니다.

### 🔹 Kubernetes 기본 컴포넌트 (kube-system)

| 컨테이너명 | 역할 | 비고 |
| --- | --- | --- |
| **kube-apiserver** | 클러스터 API 엔드포인트 및 통신 허브 | Static Pod |
| **etcd** | 클러스터 상태 저장용 키-값 DB | Static Pod |
| **kube-controller-manager** | 클러스터 상태 제어 루프 관리 | Static Pod |
| **kube-scheduler** | 워크로드(Pod) 배치 결정 | Static Pod |
| **kube-proxy** | 각 노드별 네트워크 규칙 및 부하 분산 관리 | DaemonSet |
| **coredns** | 클러스터 내부 도메인(DNS) 해석 및 검색 | Deployment |
| **pause** | 컨테이너 네임스페이스 유지를 위한 인프라 컨테이너 | Sidecar |

### 🔹 Calico CNI (Network Engine)

| 컨테이너명 | 역할 | 비고 |
| --- | --- | --- |
| **calico-node** | 호스트 네트워크와 Pod 연결, BGP 라우팅 관리 | DaemonSet |
| **calico-cni** | Pod 생성 시 네트워크 인터페이스 할당 | Init Container |
| **calico-kube-controllers** | Kubernetes API와 Calico 정책 동기화 | Deployment |
| **install-cni** | 각 노드에 CNL 설정 파일을 설치 | Init Container |

---

## 3. 설치 시 핵심 설정 (Core Params)

바이너리 설치 및 컨테이너 기동 시 반드시 일치시켜야 할 정보입니다.

* **Cgroup Driver**: `systemd` (Rocky 9.6과 containerd v2.2 간의 자원 관리 표준)
* **Pod CIDR**: `192.168.0.0/16` (Calico가 Pod에 할당할 IP 대역)
* **Service CIDR**: `10.96.0.0/12` (K8s 서비스 객체가 사용할 가상 IP 대역)
* **Internal DNS**: `10.96.0.10` (CoreDNS 서비스의 고정 IP)
