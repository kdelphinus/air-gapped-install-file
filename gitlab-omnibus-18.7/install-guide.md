# 🚀 GitLab Omnibus Installation Guide

본 문서는 `gitlab-omnibus-18.7` 컴포넌트를 폐쇄망 환경에 설치하는 단계별 절차를 설명합니다.

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
