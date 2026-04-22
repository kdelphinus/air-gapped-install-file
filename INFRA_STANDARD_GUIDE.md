# Infrastructure Standard Guide (인프라 설치 및 구성 표준 가이드)

본 문서는 본 프로젝트의 모든 인프라 서비스 컴포넌트(GitLab, Nexus, Envoy, Harbor 등)를 구성할 때 반드시 준수해야 하는 디렉토리 구조, 스크립트 작성 로직, 그리고 문서화 표준을 정의합니다. 인간 엔지니어와 AI 에이전트(Gemini, Claude 등)는 모든 신규 컴포넌트 생성 및 기존 컴포넌트 수정 시 이 가이드를 엄격히 따라야 합니다.

## 1. Directory Structure (디렉토리 표준 구조)

모든 서비스 컴포넌트는 아래와 같은 표준 디렉토리 구조를 가져야 합니다.

```text
<component-name>-<version>/
├── charts/          # Helm 차트 (폴더 또는 .tgz 파일)
├── images/          # 컨테이너 이미지 (.tar 파일) 및 Harbor 업로드 스크립트
├── manifests/       # 정적 K8s 매니페스트 (HTTPRoute, PV/PVC, ConfigMap 등)
├── scripts/         # 설치 및 운영 스크립트 (루트 상대 경로 실행 필수)
├── values.yaml      # 기본 설정 값 (Harbor 기반 이미지 경로 포함)
├── values-infra.yaml# (선택) 인프라 전용 설정 값
├── README.md        # 서비스 사양 및 전반적인 설명
└── install-guide.md # 단계별 설치 가이드 (수동 설치 절차 포함)
```

## 2. Execution Logic & Scripts (스크립트 작성 규칙)

### 2.1. 경로 독립성 (Path Independence)

- `scripts/` 내의 모든 스크립트는 반드시 컴포넌트 루트 디렉토리에서 실행될 것을 가정하거나, 내부적으로 `cd "$(dirname "$0")/.."` 명령을 사용하여 컴포넌트 루트를 기준으로 동작해야 합니다.

### 2.2. 상태 관리 및 대화형 로직 (`install.sh`)

설치 스크립트는 단순 실행을 넘어 사용자 편의와 시스템 안정성을 위해 다음 기능을 **반드시(MUST)** 구현해야 합니다.

1. **설정 보존 (`install.conf`)**:
    - 사용자가 입력한 값(이미지 소스, 서비스 타입, 스토리지 클래스 등)은 반드시 `install.conf` 파일에 저장하여 세션이 종료된 후에도 설정값이 유실되지 않도록 해야 합니다.
2. **설치 상태 감지 및 분기 처리**:
    - 기존 헬름 릴리스 또는 `install.conf`가 감지될 경우, 사용자에게 다음 옵션을 제공해야 합니다.
        - **Upgrade (업그레이드)**: 기존 설정을 유지하면서 `helm upgrade` 수행.
        - **Reinstall (재설치)**: 기존 자원을 삭제하고 초기 설정부터 다시 설치.
        - **Reset (초기화)**: 모든 자원, 네임스페이스, `install.conf` 파일을 완전히 삭제.
3. **YAML 동기화 (Single Source of Truth)**:
    - 스크립트에서 수집된 변수는 `helm --set`으로만 넘기지 말고, `sed` 명령어를 사용하여 `values.yaml` 또는 `values-infra.yaml` 파일에 직접 반영해야 합니다. 이는 스크립트 없이 수동으로 `helm upgrade`를 수행할 때도 동일한 환경을 보장하기 위함입니다.
4. **범용 명령어 사용**:
    - 특정 K8s 배포판에 종속된 명령어(예: `k3s ctr`) 대신 표준 명령어(`ctr` 또는 `docker`)를 사용하여 환경 범용성을 확보해야 합니다.

## 3. Installation Guides (문서화 표준)

### 3.1. 실행 지침

- 모든 설치 가이드는 사용자가 컴포넌트 루트 디렉토리에서 `./scripts/install.sh`와 같이 명령을 실행하도록 명시해야 합니다.

### 3.2. 수동 설치 절차 (Manual Fallback)

- 자동화 스크립트가 실패하거나 특수한 환경에서 설치해야 할 경우를 대비하여, 가이드 문서에는 반드시 **"Manual Installation & Upgrade"** 섹션을 포함해야 합니다.
- 이 섹션에는 `helm upgrade --install` 및 `kubectl apply`를 이용한 구체적인 명령어가 기재되어야 합니다.

---
**주의**: 본 가이드의 내용을 위반하는 스크립트나 구조는 기술 부채로 간주되며, 리뷰 단계에서 반드시 수정되어야 합니다.

## 4. Standardization Status (표준화 현황)

현재 프로젝트 내 서비스 중 본 표준에 따라 업데이트가 필요한 리스트입니다. (2026-04-22 기준)

### ⚠️ 업데이트 필요 (Non-compliant)

- **ArgoCD**: `argocd-2.12.1`
- **Harbor**: `harbor-2.10.3`
- **Nexus**: `nexus-3.70.1`
- **Jenkins**: `jenkins-2.528.3`
- **Gitea**: `gitea-1.25.5`
- **Ingress-Nginx**: `ingress-nginx-4.10.1`
- **Monitoring**: `monitoring-82.12.0`
- **NGINX Ingress Controller**: `nginx-nic-5.3.1`
- **Falco**: `falco-8.0.1`
- **Tetragon**: `tetragon-1.6.0`
- **Tekton**: `tekton-1.9.0`
- **Redis Stream**: `redis-stream-8.6.2-official`
- **MetalLB**: `metallb-0.14.8`
- **NFS Provisioner**: `nfs-provisioner-4.0.2`

### ✅ 준수 완료 (Compliant)

- **Envoy**: `envoy-1.37.2` (Standard Reference / 표준 모델)
- **Cilium**: `cilium-1.19.3`
- **GitLab**: `gitlab-18.7`, `gitlab-omnibus-18.7`
- **Velero**: `velero-1.18.0`
- **K8s Installation**: `k8s-1.33.11-ubuntu24.04`
