# 🏗️ Kubernetes v1.30.14 기반 인프라 설치 구성 명세

> 이 디렉터리는 Kubernetes `v1.30.14` 최종 패치와 Rocky Linux 9 최신 마이너를 대상으로 합니다.
> Kubernetes 1.30은 업스트림 지원 종료 상태이므로 신규 운영 클러스터에는 1.36 패키지를 우선 사용하십시오.
> 설치기는 SELinux Enforcing, firewalld, 감사 로그, 저장 데이터 암호화, Pod Security Admission 및 kubelet 보안 기준을 기본 적용합니다.

지원 CNI는 Kubernetes 1.30 호환 라인의 최종 패치인 Calico `v3.29.7`입니다. 설치 전 외부망 Rocky 9 수집 호스트를 최신 마이너로 업데이트하며, 대상 노드는 수집 메타데이터와 같은 Rocky 마이너여야 합니다.

## 1. 주요 실행 바이너리 (Binaries)

서버 OS(Rocky 9)에 직접 설치되어 구동되는 핵심 파일입니다.

* **Kubernetes Control Plane 도구**: `kubeadm`, `kubelet`, `kubectl` (v1.30.14)
* **컨테이너 런타임 (CRI)**: 수집 시점의 검증된 `containerd.io` 정확 버전, `runc`
* **패키지 관리 도구**: `helm` (v3.20.2)

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

* **Cgroup Driver**: `systemd` (Rocky 9과 containerd의 자원 관리 표준)
* **Pod CIDR**: `192.168.0.0/16` (Calico가 Pod에 할당할 IP 대역)
* **Service CIDR**: `10.96.0.0/12` (K8s 서비스 객체가 사용할 가상 IP 대역)
* **Internal DNS**: `10.96.0.10` (CoreDNS 서비스의 고정 IP)

---

## 4. 운영 점검 문서

| 문서 | 설명 |
| --- | --- |
| `install-guide.md` | 폐쇄망 Kubernetes v1.30.14 설치 절차 |
| `reboot-guide.md` | Kubernetes 노드 재부팅 및 복구 절차 |
| `kubernetes-kubeadm-vulnerability-check-remediation.md` | Kubernetes v1.30.x API Server, etcd, Kubelet, RBAC, Pod, 파일 권한, 이미지 및 로그 취약점 점검·조치 절차 |
| `kubernetes-v1.30.14-security-remediation-impact-analysis.md` | PDF 전체 보안 조치와 v1.30.14 패치의 운영 서비스 영향도, 중단 조건 및 판정 기준 |
| `scripts/download_k8s_1.30.14_patch_assets.sh` | v1.30.14 대상·롤백 RPM과 필수 이미지 폐쇄망 반입 묶음 생성 |
| `scripts/collect_k8s_1.30.14_patch_impact.sh` | 운영 클러스터의 replica, PDB, 저장소 및 배치 위험 조회 |
