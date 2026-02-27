# Claude Context: Air-gapped Infrastructure Deployment

## Project Overview

폐쇄망(인터넷 차단) 환경에 전체 인프라 스택을 설치하기 위한 자산(RPM, DEB, 바이너리, 컨테이너 이미지, Helm chart, 스크립트) 보관소.

**핵심 전제: 항상 인터넷 없음을 가정한다. 모든 툴/패키지/이미지는 이 레포 또는 로컬 네트워크에서 조달.**
**멀티 OS 지원: Rocky Linux (RHEL-계열), Ubuntu (Debian-계열) 등 다양한 OS의 오프라인 설치 환경을 지향함.**

## Target Environment

| 항목 | 값 |
| :--- | :--- |
| OS | Rocky Linux 9.6, Ubuntu 24.04 등 (특정 OS 한정 없음) |
| Kubernetes | v1.30.0 (kubeadm 기반) |
| Container Runtime | containerd v2.2.0 |
| CNI | Calico |
| Internal Registry | Harbor v1.14.3 → `<NODE_IP>:30002` |

## Component Directory Map

```text
air-gapped/
├── k8s-1.30-*/                 # K8s 클러스터 구성 (RPM/DEB, 바이너리, 이미지)
├── harbor-1.14.3/              # 내부 컨테이너 레지스트리
├── docker-offline-*/           # Docker Engine (OS별)
├── git-*-rocky9.6/             # Git 오프라인 설치 (Rocky)
├── basic-tools-rocky9.6/       # 기본 유틸 (curl, vimi, jq 등) - Rocky
├── basic-tools-ubuntu24.04/    # 기본 유틸 - Ubuntu
├── nfs-provisioner-4.0.2/      # NFS 동적 스토리지 프로비저닝 (Multi-OS 스크립트 포함)
├── ingress-nginx-4.10.1/       # K8s Ingress 컨트롤러
├── envoy-1.36.3/               # Envoy Gateway (L7 라우팅)
├── gitlab-18.7/                # GitLab EE (Helm)
├── jenkins-2.528.3/            # Jenkins CI/CD (Helm)
├── argocd-2.12.1/              # ArgoCD GitOps (Helm)
└── mariadb-*-rocky9.6/         # MariaDB DB
```

## Deployment Order

1. OS 기본 설정 + `basic-tools`
2. `docker-offline` (필요 시)
3. `k8s-1.30-rocky9.6` — containerd + kubeadm + Calico
4. `harbor-1.14.3` — 내부 레지스트리 먼저 구축
5. `nfs-provisioner` — 스토리지 클래스 확보
6. `ingress-nginx` 또는 `envoy` — 인그레스
7. `gitlab`, `jenkins`, `argocd`, `mariadb` — 앱 레이어

## Key Conventions

- **스크립트**: Bash (`*.sh`), OS별 분기 처리
- **이미지 관리**: `.tar`/`.tgz` export → Harbor push 패턴
  - 기존 `upload_images_to_harbor_v2.sh` 스크립트 참조
- **패키지**: OS에 따라 분기
  - RHEL/Rocky → RPM (`dnf localinstall -y --disablerepo='*' *.rpm`)
  - Ubuntu/Debian → DEB (`dpkg -i` 또는 `apt install ./*.deb`)
- **스토리지**: PV는 `Retain` reclaim policy 필수
- **Harbor 포트**: `30002` (NodePort)
- **이미지 주소 형식**: `<NODE_IP>:30002/<project>/<image>:<tag>`

## Network Reference

| 서비스 | 접근 방식 | 포트 |
| :--- | :--- | :--- |
| Harbor | NodePort | 30002 |
| Jenkins | NodePort | 30000 |
| Ingress-Nginx | HostNetwork | 80 / 443 |
| Envoy Gateway | NodePort | 30080 / 30443 |
| K8s API | - | 6443 |
| CoreDNS | ClusterIP | 10.96.0.10 |

## K8s Cluster Spec

- Pod CIDR: `192.168.0.0/16`
- Service CIDR: `10.96.0.0/12`
- Cgroup driver: `systemd`
- Helm: v3.14.0

## AI Instructions

- 인터넷 접근 불가 환경 — `curl`, `wget`, `yum install` 등으로 외부에서 받는 코드 생성 금지
- 스크립트 생성 시 대상 OS 확인 후 작성, 멀티 OS 지원 시 RHEL계/Debian계 분기 처리
- K8s 리소스는 `Retain` policy 우선
- 이미지 관련 작업 시 기존 `upload_images_to_harbor_v2.sh` 패턴 참조
- 각 컴포넌트 폴더의 `README.md` / `guide.md` 먼저 확인
- **Markdown 파일 작성 시 markdownlint 규칙 준수**
  - 제목은 ATX 스타일 (`#`), 레벨은 순서대로 (h1 → h2 → h3)
  - 목록 들여쓰기는 2칸, 순서 있는 목록은 `1.` 통일 가능
  - 코드 블록에 언어 명시 (` ```bash `, ` ```yaml ` 등)
  - 빈 줄: 제목/목록/코드블록 앞뒤로 1줄
  - 줄 끝 공백 없음, 파일 끝 개행 1개
  - 인라인 HTML 사용 금지
