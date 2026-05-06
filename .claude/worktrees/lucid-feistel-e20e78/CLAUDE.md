# Claude Context: Air-gapped Infrastructure Deployment

## Project Overview

폐쇄망(인터넷 차단) 환경에 전체 인프라 스택을 설치하기 위한 자산
(RPM, DEB, 바이너리, 컨테이너 이미지, Helm chart, 스크립트) 보관소.

**핵심 전제: 항상 인터넷 없음을 가정한다. 모든 툴/패키지/이미지는 이 레포 또는 로컬 네트워크에서 조달.**
**멀티 OS 지원: Rocky Linux (RHEL-계열), Ubuntu (Debian-계열) 등 다양한 OS의 오프라인 설치 환경을 지향함.**

## Target Environment

| 항목 | 값 |
| :--- | :--- |
| OS | Rocky Linux 9.6, Ubuntu 24.04 등 (특정 OS 한정 없음) |
| Kubernetes | v1.30.0 / v1.33.11 (kubeadm 기반) — 컴포넌트별 상이 |
| Container Runtime | containerd v2.2.x |
| CNI | Calico / Cilium (v1.33.11 한정) |
| Internal Registry | Harbor v2.10.3 → `<NODE_IP>:30002` |

## Component Directory Map

```text
air-gapped/
├── k8s-*/                # K8s 클러스터 — 버전/OS별 복수 존재 (Rocky=RPM, Ubuntu=DEB)
├── harbor-*/             # 내부 컨테이너 레지스트리
├── docker-offline-*/     # Docker Engine (OS별)
├── git-*/                # Git 오프라인 설치 (OS별)
├── basic-tools-*/        # 기본 유틸 (curl, vim, jq 등) — OS별 복수 존재
├── nfs-provisioner-*/    # NFS 동적 스토리지 프로비저닝 (Multi-OS 스크립트 포함)
├── metallb-*/            # MetalLB L2 LoadBalancer
├── nginx-nic-*/          # NGINX Ingress Controller (NIC)
├── cilium-*/             # Cilium CNI (kubeProxyReplacement, Gateway API 내장)
├── envoy-*/              # Envoy Gateway (L7 라우팅, Calico CNI 선택 시 활용)
├── monitoring-*/         # kube-prometheus-stack
├── nexus-*/              # Nexus Repository Manager
├── gitlab-*/             # GitLab EE (Helm) — gitlab-omnibus 포함
├── jenkins-*/            # Jenkins CI/CD (Helm)
├── argocd-*/             # ArgoCD GitOps (Helm)
├── mariadb-*/            # MariaDB DB (OS별)
├── redis-stream-*/       # Redis Stream HA 구성
├── gitea-*/              # Gitea Git 서버 (Helm, 경량)
├── tekton-*/             # Tekton Pipelines CI/CD (manifests 기반)
├── velero-*/             # K8s 백업/복구
├── falco-*/              # 런타임 이상행위 감지
└── tetragon-*/           # 런타임 보안 차단
```

## Component Directory & Script Standard

> **전체 규칙은 `INFRA_STANDARD_GUIDE.md` 참조. 아래는 AI 작업 시 즉시 적용할 체크리스트.**

- Helm chart 경로: `./charts/<name>` 또는 `./charts/<name>.tgz`
- 매니페스트(HTTPRoute 등): 루트가 아닌 `./manifests/` 에 위치
- `scripts/` 내 모든 스크립트 첫 줄: `cd "$(dirname "$0")/.." || exit 1`

### install.sh 필수 구현 항목 (MUST)

1. **설정 보존**: 사용자 입력값을 `./install.conf`에 저장/로드 (`load_conf` / `save_conf` 패턴)
2. **설치 상태 분기**: 기존 릴리스 또는 `install.conf` 감지 시 세 가지 옵션 제공
   - `1) Upgrade` — `helm upgrade` (기존 설정 유지)
   - `2) Reinstall` — 자원 삭제 후 재설치
   - `3) Reset` — 네임스페이스·`install.conf` 포함 완전 삭제
3. **YAML 동기화**: 수집한 변수를 `helm --set`으로만 넘기지 말고, `sed`로 `values.yaml`/`values-infra.yaml`에 직접 반영 (수동 `helm upgrade` 시에도 동일 환경 보장)
4. **범용 명령어**: `k3s ctr` 같은 배포판 종속 명령어 금지 → `ctr` 또는 `docker` 사용

### install-guide.md 필수 포함 항목

- 실행 지침: 컴포넌트 루트에서 `./scripts/install.sh` 형태로 명시
- **"Manual Installation & Upgrade"** 섹션: `helm upgrade --install` 및 `kubectl apply` 기반 구체적 명령어 포함

## Key Conventions

- **스크립트**: Bash (`*.sh`), OS별 분기 처리
- **이미지 관리**: `.tar`/`.tgz` export → Harbor push 패턴
  - 기존 `upload_images_to_harbor_v3-lite.sh` 스크립트 참조
- **패키지**: OS에 따라 분기
  - RHEL/Rocky → RPM (`dnf localinstall -y --disablerepo='*' *.rpm`)
  - Ubuntu/Debian → DEB (`dpkg -i` 또는 `apt install ./*.deb`)
- **스토리지**: PV는 `Retain` reclaim policy 필수
- **Harbor 포트**: `30002` (NodePort)
- **이미지 주소 형식**: `<NODE_IP>:30002/<project>/<image>:<tag>`

## K8s Cluster Spec

- Pod CIDR: `192.168.0.0/16`
- Service CIDR: `10.96.0.0/12`
- Cgroup driver: `systemd`
- Helm: v3.20.2

## AI Instructions

- 인터넷 접근 불가 환경 — `curl`, `wget`, `yum install` 등으로 외부에서 받는 코드 생성 금지
- 스크립트 생성 시 대상 OS 확인 후 작성, 멀티 OS 지원 시 RHEL계/Debian계 분기 처리
- K8s 리소스는 `Retain` policy 우선
- 이미지 관련 작업 시 기존 `upload_images_to_harbor_v3-lite.sh` 패턴 참조
- 각 컴포넌트 폴더의 `README.md` / `guide.md` 먼저 확인
- **Markdown 파일 작성 시 markdownlint 규칙 준수**
  - 제목은 ATX 스타일 (`#`), 레벨은 순서대로 (h1 → h2 → h3)
  - 목록 들여쓰기는 2칸, 순서 있는 목록은 `1.` 통일 가능
  - 코드 블록에 언어 명시 (` ```bash `, ` ```yaml ` 등)
  - 빈 줄: 제목/목록/코드블록 앞뒤로 1줄
  - 줄 끝 공백 없음, 파일 끝 개행 1개
  - 인라인 HTML 사용 금지
