# Air-gapped Infrastructure Install Assets

폐쇄망(인터넷 차단) 환경에 전체 인프라 스택을 설치하기 위한 자산 보관소입니다.
RPM/DEB 패키지, 바이너리, 컨테이너 이미지(.tar), Helm 차트, 설치 스크립트를
포함합니다.

> **핵심 전제:** 모든 툴·패키지·이미지는 이 레포 또는 로컬 네트워크에서만
> 조달합니다. 외부 인터넷 접근을 전제로 한 명령어(`curl`, `wget`,
> `yum install` 등)는 사용하지 않습니다.

## 설치 파일 다운로드

컨테이너 이미지(`.tar`) 등 대용량 파일은 GitHub 대신 Google Drive에서
제공합니다. 레포와 동일한 폴더 구조로 구성되어 있습니다.

**[Google Drive — 설치 파일 보관소](https://drive.google.com/drive/folders/1joMQRpZPWzKgU9BBsdxy3b0qzJMWpBC8?hl=ko)**

---

## 대상 환경

| 항목 | 값 |
| :--- | :--- |
| OS | Rocky Linux 9.6, Ubuntu 24.04 (멀티 OS 지원) |
| Kubernetes | v1.30.0 / v1.33.11 (컴포넌트별 상이, kubeadm 기반) |
| Container Runtime | containerd v2.2.x |
| CNI | Calico / Cilium (v1.33.11 컴포넌트 한정) |
| Internal Registry | Harbor v2.10.3 — `<NODE_IP>:30002` |

> **CIDR 참고:** Pod CIDR(`192.168.0.0/16`)과 Service CIDR(`10.96.0.0/12`)는
> kubeadm 설치 시 예시로 사용하는 값입니다. 실제 환경의 노드 네트워크 대역과
> 충돌 여부를 확인한 뒤 `kubeadm init` 옵션으로 직접 지정합니다.

---

## 컴포넌트 구성

### 클러스터 기반

| 디렉토리 | 컴포넌트 | 버전 | 설명 |
| :--- | :--- | :--- | :--- |
| `k8s-1.30-rocky9.6/` | K8s | v1.30.0 | kubeadm + containerd + Calico — Rocky Linux (RPM) |
| `k8s-1.33.11-ubuntu24.04/` | K8s | v1.33.11 | kubeadm + containerd + Calico/Cilium — Ubuntu 24.04 (DEB), WSL2/VM 공용 |
| `cilium-1.19.3/` | Cilium | v1.19.3 | CNI — kubeProxyReplacement + Gateway API 내장 |
| `docker-offline-29.1.5/` | Docker | 29.1.5 | 컨테이너 런타임 (선택) |
| `basic-tools-rocky9.6/` | Tools | - | curl, vim, jq 등 — Rocky Linux |
| `basic-tools-ubuntu24.04/` | Tools | - | curl, vim, jq 등 — Ubuntu |
| `git-2.43.0-rocky9.6/` | Git | 2.43.0 | Rocky Linux용 오프라인 설치 |

### 인프라 레이어

| 디렉토리 | 컴포넌트 | 버전 | 설명 |
| :--- | :--- | :--- | :--- |
| `harbor-2.10.3/` | Harbor | v2.10.3 | 내부 컨테이너 레지스트리 |
| `nfs-provisioner-4.0.2/` | NFS Provisioner | 4.0.2 | NFS 동적 스토리지 프로비저닝 |
| `metallb-0.14.8/` | MetalLB | 0.14.8 | L2 LoadBalancer IP 풀 |
| `nginx-nic-5.3.1/` | F5 NGINX Ingress Controller | v5.3.1 | NIC OSS — NodePort 30080/30443 |
| `envoy-1.36.3/` | Envoy Gateway | 1.36.3 | L7 라우팅 / Gateway API (Calico CNI 연동) |
| `envoy-1.37.2/` | Envoy Gateway | 1.37.2 | L7 라우팅 / Gateway API (k8s-1.33.11 연동) |
| `monitoring-82.12.0/` | kube-prometheus-stack | 82.12.0 | Prometheus + Grafana + Alertmanager |
| `velero-1.18.0/` | Velero | 1.18.0 | K8s 리소스·PV 백업 및 복구 |
| `falco-8.0.1/` | Falco | 8.0.1 (엔진 0.43.0) | eBPF 런타임 이상행위 감지 |
| `tetragon-1.6.0/` | Tetragon | 1.6.0 | eBPF 런타임 보안 차단 (TracingPolicy) |

### 애플리케이션 레이어

| 디렉토리 | 컴포넌트 | 버전 | 설명 |
| :--- | :--- | :--- | :--- |
| `nexus-3.70.1/` | Nexus Repository | 3.70.1 | Maven/NPM/PyPI 아티팩트 저장소 |
| `gitlab-18.7/` | GitLab EE | 18.7 | 소스 코드 관리 (Helm) |
| `gitlab-omnibus-18.7/` | GitLab Omnibus | 18.7 | 소스 코드 관리 (단일 패키지) |
| `gitea-1.25.5/` | Gitea | 1.25.5 | 경량 Git 서버 |
| `jenkins-2.528.3/` | Jenkins | 2.528.3 | CI/CD 파이프라인 |
| `tekton-1.9.0/` | Tekton Pipelines | v1.9.0 LTS | Kubernetes-native CI/CD |
| `argocd-2.12.1/` | ArgoCD | 2.12.1 | GitOps 배포 |
| `mariadb-10.11.14-rocky9.6/` | MariaDB | 10.11.14 | 관계형 DB / Galera 클러스터 |
| `redis-stream-8.6.2-official/` | Redis | 7.2 (Sentinel) | Redis Stream HA 구성 |

---

## 배포 순서

```text
[클러스터 기반]
1.  basic-tools          — OS 기본 유틸리티
2.  docker-offline       — Docker Engine (필요 시)
3.  k8s-*               — K8s 클러스터 (containerd + kubeadm + Calico 또는 Cilium)

[인프라 레이어]
4.  harbor-*             — 내부 레지스트리 (이후 모든 이미지는 Harbor에서 조달)
5.  nfs-provisioner      — StorageClass 확보
6.  metallb              — LoadBalancer IP 풀 (L2 모드)
7.  nginx-nic / envoy    — Ingress / Gateway API
8.  monitoring           — Prometheus + Grafana

[애플리케이션 레이어]
9.  nexus                — 아티팩트 저장소 (Maven/NPM 등)
10. gitlab / gitea       — 소스 코드 관리
11. jenkins / tekton     — CI/CD
12. argocd               — GitOps CD
13. mariadb              — 데이터베이스
14. redis-stream-official — Redis (Sentinel)

[선택]
15. velero               — 백업 및 재해 복구
16. falco                — 런타임 이상행위 감지
17. tetragon             — 런타임 보안 차단
```

---

## 네트워크 포트 참조

| 서비스 | 접근 방식 | 포트 |
| :--- | :--- | :--- |
| Harbor | NodePort | 30002 |
| Jenkins | NodePort | 30000 |
| ArgoCD | NodePort | 30001 |
| Gitea HTTP | NodePort | 30003 |
| Tekton Dashboard | NodePort | 30004 |
| F5 NGINX Ingress Controller | NodePort | 30080 / 30443 |
| Envoy Gateway | NodePort | 30080 / 30443 |
| Gitea SSH | NodePort | 30022 |
| K8s API Server | - | 6443 |
| CoreDNS | ClusterIP | 10.96.0.10 (Service CIDR 기본값 기준) |

---

## 인프라 서비스 표준 (Infrastructure Standards)

모든 인프라 서비스 컴포넌트는 일관된 설치 경험과 유지보수를 위해 프로젝트 표준을 준수해야 합니다. 상세한 기술 표준 및 준수 현황은 **[INFRA_STANDARD_GUIDE.md](INFRA_STANDARD_GUIDE.md)** 문서를 참조하십시오.

### 표준 디렉토리 구조

`harbor`, `envoy`, `gitlab`, `nexus` 등 주요 서비스 컴포넌트는 아래의 표준 구조를 따릅니다.

```text
<component>/
├── charts/          # Helm 차트 (폴더 또는 .tgz)
├── images/          # 컨테이너 이미지 .tar + Harbor 업로드 스크립트
├── manifests/       # 보조 K8s 매니페스트 (HTTPRoute, PV/PVC 등)
├── scripts/         # 설치·운영 스크립트 (컴포넌트 루트 기준으로 동작)
├── values.yaml      # Helm values — Harbor 레지스트리 대상 (운영 환경)
├── README.md        # 서비스 사양 및 전반적인 설명
└── install-guide.md # Phase 기반 설치 절차 가이드 (수동 설치 포함)
```

| 주요 항목 | 표준 준수 사항 |
| :--- | :--- |
| **설치 스크립트** | `scripts/install.sh`는 `install.conf`를 통해 설정을 보존하며, 업그레이드/재설치/초기화 로직을 포함해야 합니다. |
| **수동 설치** | `install-guide.md`는 자동화 스크립트 사용이 불가능한 환경을 위해 반드시 `Manual Installation` 절차를 기재해야 합니다. |
| **환경 동기화** | 모든 설정값은 `sed` 등을 통해 `values.yaml`에 직접 반영되어야 합니다. |

상세 규칙 및 서비스별 표준 준수 현황은 [표준 가이드](INFRA_STANDARD_GUIDE.md)에서 확인할 수 있습니다.

---

## 주요 규칙

### 패키지 설치

```bash
# RHEL / Rocky Linux
dnf localinstall -y --disablerepo='*' *.rpm

# Ubuntu / Debian
dpkg -i ./*.deb
# 또는
apt install ./*.deb
```

### 컨테이너 이미지 업로드

```bash
# images/upload_images_to_harbor_v3-lite.sh 상단 Config 수정 후 실행
# HARBOR_REGISTRY: <NODE_IP>:30002
# HARBOR_PROJECT : library
# HARBOR_USER    : admin
# HARBOR_PASSWORD: <비밀번호>

cd images
bash upload_images_to_harbor_v3-lite.sh
```

이미지 주소 형식: `<NODE_IP>:30002/<project>/<image>:<tag>`

### 스토리지

PersistentVolume은 반드시 `Retain` reclaim policy를 사용합니다.
