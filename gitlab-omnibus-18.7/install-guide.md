# 🚀 GitLab Omnibus Installation Guide

본 문서는 `gitlab-omnibus-18.7` 컴포넌트를 폐쇄망 환경에 설치하는 단계별 절차를 설명합니다.

## 0. 오프라인 설치 자산 준비 (인터넷 환경)

폐쇄망에 반입할 Helm 차트와 컨테이너 이미지(.tar)가 `charts/` 및 `images/` 디렉토리에 없는 경우, **인터넷이 연결된 외부 PC(리눅스)**에서 아래 스크립트를 실행하여 자산을 다운로드해야 합니다.

> **주의**: 이 작업은 폐쇄망 내부가 아닌, 외부망에서 사전에 수행되어야 합니다. (Docker 또는 containerd(`ctr`), `helm` CLI 설치 필수)

```bash
# 컴포넌트 스크립트 디렉토리로 이동
cd scripts/

# 실행 권한 부여 및 다운로드 스크립트 실행
chmod +x ./scripts/download_assets_offline.sh
sudo ./scripts/download_assets_offline.sh
```

스크립트 실행이 완료되면 `charts/` 디렉토리에 `.tgz` 차트 파일이, `images/` 디렉토리에 `.tar` 이미지 파일들이 생성됩니다. 전체 프로젝트 폴더를 압축하여 폐쇄망 내부로 반입하십시오.



## 1. 사전 준비 (Prerequisites)

1. **이미지 준비**:
   - `images/` 디렉토리에 `gitlab-ce_18.7.0-ce.0.tar` 파일이 있는지 확인합니다.
   - Harbor를 사용하는 경우 `upload_images_to_harbor_v3-lite.sh`를 통해 이미지를 업로드합니다.
2. **스토리지 준비**:
   - `HostPath`를 사용하는 경우, 대상 노드에 데이터 저장 경로를 생성합니다. (예: `/data/gitlab_omnibus`)
   - `NFS`를 사용하는 경우, NFS 서버 및 공유 경로를 확인합니다.

## 2. 자동 설치 (Recommended)

컴포넌트 루트 디렉토리에서 제공되는 설치 스크립트를 사용합니다.

```bash
# 1. 설치 스크립트 실행
./scripts/install.sh

# 2. 안내에 따라 설정값 입력
# - 이미지 소스 (Harbor 또는 Local)
# - 스토리지 타입 (HostPath, NFS, Dynamic)
# - GitLab 도메인 또는 IP (예: 10.185.40.41:32135)
```

## 3. 수동 설치 및 업그레이드 (Manual Installation)

자동화 스크립트를 사용할 수 없는 경우, 아래 순서대로 설치를 진행합니다.

### 3.1. 네임스페이스 및 PV 생성
```bash
kubectl create ns gitlab-omnibus
# manifests/gitlab-omnibus-pv.yaml 수정 후 적용
kubectl apply -f manifests/gitlab-omnibus-pv.yaml
```

### 3.2. Helm 설치
`values.yaml` 파일을 환경에 맞게 수정한 후 아래 명령을 실행합니다.
```bash
helm upgrade --install gitlab-omnibus ./charts/gitlab-omnibus \
  -n gitlab-omnibus \
  -f values.yaml
```

## 4. 설치 후 확인 사항

### 4.1. 초기 root 비밀번호 확인
설치 완료 후 약 2~3분 뒤 아래 명령으로 확인 가능합니다.
```bash
kubectl exec -n gitlab-omnibus deploy/gitlab-omnibus -- cat /etc/gitlab/initial_root_password
```

### 4.2. 서비스 접속
설정한 `externalUrl` 주소로 브라우저에서 접속합니다.
- 예: `http://10.185.40.41:32135`

## 5. Terraform State 사용 (HTTP backend)

GitLab Managed Terraform State는 본 차트에서 기본 활성화되어 있습니다
(`terraformState.enabled: true` → `gitlab_rails['terraform_state_enabled'] = true`).
저장 위치는 `data` PVC 내부의 `/var/opt/gitlab/gitlab-rails/shared/terraform_state` —
별도 오브젝트 스토리지 없이 폐쇄망 단일 파드에서 그대로 사용 가능합니다.

### 5.1. 사용 예시

`backend.tf`:

```hcl
terraform {
  backend "http" {
    address        = "http://gitlab.devops.internal/api/v4/projects/<PROJECT_ID>/terraform/state/<STATE_NAME>"
    lock_address   = "http://gitlab.devops.internal/api/v4/projects/<PROJECT_ID>/terraform/state/<STATE_NAME>/lock"
    unlock_address = "http://gitlab.devops.internal/api/v4/projects/<PROJECT_ID>/terraform/state/<STATE_NAME>/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"
    retry_wait_min = 5
  }
}
```

초기화:

```bash
terraform init \
  -backend-config="username=<GITLAB_USERNAME>" \
  -backend-config="password=<PERSONAL_ACCESS_TOKEN>"
```

- Personal Access Token 권한: `api` scope 필요
- State 목록 확인: GitLab UI → Project → **Operate → Terraform states**

### 5.2. 비활성화 방법

비활성화가 필요한 경우 `values.yaml`에서 다음과 같이 변경 후 `helm upgrade`:

```yaml
terraformState:
  enabled: false
```
