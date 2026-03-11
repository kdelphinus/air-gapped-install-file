# Air-gapped Infrastructure Install Assets

폐쇄망(인터넷 차단) 환경에 전체 인프라 스택을 설치하기 위한 자산 보관소입니다.
RPM/DEB 패키지, 바이너리, 컨테이너 이미지(.tar), Helm 차트, 설치 스크립트를 포함합니다.

> **핵심 전제:** 모든 툴·패키지·이미지는 이 레포 또는 로컬 네트워크에서만 조달합니다.
> 외부 인터넷 접근을 전제로 한 명령어(`curl`, `wget`, `yum install` 등)는 사용하지 않습니다.

## 설치 파일 다운로드

컨테이너 이미지(`.tar`) 등 대용량 파일은 GitHub 대신 Google Drive에서 제공합니다.
레포와 동일한 폴더 구조로 구성되어 있습니다.

**[Google Drive — 설치 파일 보관소](https://drive.google.com/drive/folders/1joMQRpZPWzKgU9BBsdxy3b0qzJMWpBC8?hl=ko)**

---

## 대상 환경

| 항목 | 값 |
| :--- | :--- |
| OS | Rocky Linux 9.6, Ubuntu 24.04 (멀티 OS 지원) |
| Kubernetes | v1.30.0 (kubeadm 기반) |
| Container Runtime | containerd v2.2.0 |
| CNI | Calico |
| Internal Registry | Harbor v1.14.3 — `<NODE_IP>:30002` |
| Helm | v3.14.0 |
| Pod CIDR | `192.168.0.0/16` |
| Service CIDR | `10.96.0.0/12` |

---

## 컴포넌트 구성

| 디렉토리 | 컴포넌트 | 버전 | 설명 |
| :--- | :--- | :--- | :--- |
| `k8s-1.30-rocky9.6/` | Kubernetes | v1.30.0 | kubeadm + containerd + Calico |
| `harbor-1.14.3/` | Harbor | v1.14.3 | 내부 컨테이너 레지스트리 |
| `docker-offline-29.1.5/` | Docker Engine | 29.1.5 | 컨테이너 런타임 (선택) |
| `git-2.43.0-rocky9.6/` | Git | 2.43.0 | Rocky Linux용 오프라인 설치 |
| `basic-tools-rocky9.6/` | Basic Tools | - | curl, vim, jq 등 — Rocky Linux |
| `basic-tools-ubuntu24.04/` | Basic Tools | - | curl, vim, jq 등 — Ubuntu |
| `nfs-provisioner-4.0.2/` | NFS Provisioner | 4.0.2 | NFS 동적 스토리지 프로비저닝 |
| `ingress-nginx-4.10.1/` | Ingress-Nginx | 4.10.1 | K8s Ingress 컨트롤러 (HostNetwork) |
| `envoy-1.36.3/` | Envoy Gateway | 1.36.3 | L7 라우팅 / Gateway API |
| `gitlab-18.7/` | GitLab EE | 18.7 | 소스 코드 관리 (Helm) |
| `jenkins-2.528.3/` | Jenkins | 2.528.3 | CI/CD 파이프라인 (Helm) |
| `argocd-2.12.1/` | ArgoCD | 2.12.1 | GitOps 배포 (Helm) |
| `mariadb-10.11.14-rocky9.6/` | MariaDB | 10.11.14 | 관계형 DB / Galera 클러스터 |

---

## 배포 순서

```text
1. basic-tools          — OS 기본 유틸리티 설치
2. docker-offline       — Docker Engine (필요 시)
3. k8s-1.30-rocky9.6   — K8s 클러스터 구성 (containerd + kubeadm + Calico)
4. harbor-1.14.3        — 내부 레지스트리 구축 (이후 모든 이미지는 Harbor에서)
5. nfs-provisioner      — StorageClass 확보
6. ingress-nginx / envoy — Ingress / Gateway API
7. gitlab               — 소스 코드 관리
8. jenkins              — CI/CD
9. argocd               — GitOps CD
10. mariadb             — 데이터베이스
```

---

## 네트워크 포트 참조

| 서비스 | 접근 방식 | 포트 |
| :--- | :--- | :--- |
| Harbor | NodePort | 30002 |
| Jenkins | NodePort | 30000 |
| ArgoCD | NodePort | 30001 |
| Ingress-Nginx | HostNetwork | 80 / 443 |
| Envoy Gateway | NodePort | 30080 / 30443 |
| K8s API Server | - | 6443 |
| CoreDNS | ClusterIP | 10.96.0.10 |

---

## 각 컴포넌트 문서 구조

각 컴포넌트 디렉토리는 아래 두 파일로 구성됩니다.

| 파일 | 내용 |
| :--- | :--- |
| `README.md` | 서비스 스펙 (버전, 컴포넌트, 네트워크, 디렉토리 구조) |
| `install-guide.md` | Phase 기반 설치 절차 가이드 |

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
# scripts/upload_images.sh (또는 upload_images_to_harbor_v2.sh) 상단 설정 후 실행
HARBOR_REGISTRY="<NODE_IP>:30002"
HARBOR_PROJECT="<PROJECT>"
HARBOR_USER="admin"
HARBOR_PASSWORD="<PASSWORD>"

bash ./scripts/upload_images.sh
```

이미지 주소 형식: `<NODE_IP>:30002/<project>/<image>:<tag>`

### 스토리지

PersistentVolume은 반드시 `Retain` reclaim policy를 사용합니다.
