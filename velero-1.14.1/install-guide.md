# 🚀 Velero 오프라인 설치 가이드 (MinIO 통합형)

이 가이드는 폐쇄망 환경에서 **전용 MinIO 저장소**를 포함하여 Velero 백업 체계를 구축하고, 데이터를 복구하는 절차를 설명합니다.

## 0단계: 에셋 준비 (인터넷 가능 환경)

폐쇄망 서버로 반입하기 전, 인터넷이 되는 환경에서 필요한 모든 파일을 다운로드합니다.

```bash
# 1. 에셋 다운로드 스크립트 실행 (차트, 이미지, CLI 통합 다운로드)
chmod +x scripts/download_assets.sh
./scripts/download_assets.sh

# 2. 생성된 파일들을 폐쇄망 서버의 velero-1.14.1/ 폴더로 복사합니다.
```

## 1단계: CLI 설치 및 이미지 업로드 (폐쇄망 환경)

### 1.1 Velero CLI 설치

```bash
tar -xvf velero-v1.14.1-linux-amd64.tar.gz
sudo mv velero-v1.14.1-linux-amd64/velero /usr/local/bin/
velero version --client-only
```

### 1.2 Harbor에 이미지 업로드

`images/upload_images_to_harbor_v3-lite.sh`의 `HARBOR_REGISTRY`를 수정한 뒤 실행합니다.

```bash
./images/upload_images_to_harbor_v3-lite.sh
```

## 2단계: 설치 실행

### 2.1 옵션 A: Harbor 레지스트리 사용 시 (권장)

`scripts/install.sh` 파일 상단의 `HARBOR_IP`를 수정한 뒤 실행합니다.

```bash
./scripts/install.sh
```

### 2.2 옵션 B: 로컬 이미지(ctr 로드) 사용 시

```bash
./scripts/install-local.sh
```

## 3단계: 설치 확인 및 웹 접속

### 3.1 서비스 상태 확인

```bash
# Pod 및 백업 저장소 상태 확인 (Available 확인 필수)
kubectl get pods -n velero
velero backup-location get
```

### 3.2 MinIO 웹 콘솔 접속

웹 브라우저에서 아래 주소로 접속하여 백업 파일이 저장된 버킷을 시각적으로 확인할 수 있습니다.

- **주소**: `http://minio-velero.devops.internal`
- **계정/비밀번호**: `minioadmin` / `minioadmin`

## 4단계: 백업 및 복구 테스트

### 4.1 백업 실행 (Backup)

전체 클러스터 또는 특정 네임스페이스를 백업합니다.

```bash
# 전체 백업 생성
velero backup create cluster-full-backup --include-namespaces '*'

# 특정 네임스페이스(예: monitoring) 백업
velero backup create monitoring-backup --include-namespaces monitoring

# 백업 목록 확인
velero backup get
```

### 4.2 복구 실행 (Restore)

문제가 발생한 네임스페이스를 백업 시점으로 되돌립니다.

```bash
# 1. 전체 복구 실행
velero restore create --from-backup cluster-full-backup

# 2. 특정 네임스페이스만 선택 복구
velero restore create --from-backup monitoring-backup --include-namespaces monitoring

# 3. 복구 상태 확인
velero restore get
velero restore describe <복구명>
```

## 5단계: 삭제 (Uninstall)

```bash
./scripts/uninstall.sh
```
