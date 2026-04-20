# Velero 오프라인 설치 가이드 (MinIO 통합형)

이 가이드는 폐쇄망 환경에서 **전용 MinIO 저장소**를 포함하여 Velero 백업 체계를 구축하고, 데이터를 복구하는 절차를 설명합니다.

## 0단계: 에셋 준비 (인터넷 가능 환경)

폐쇄망 서버로 반입하기 전, 인터넷이 되는 환경에서 필요한 모든 파일을 다운로드합니다.

```bash
chmod +x scripts/download_assets.sh
./scripts/download_assets.sh
# 생성된 파일들을 폐쇄망 서버의 velero-1.18.0/ 폴더로 복사합니다.
```

## 1단계: CLI 설치 및 이미지 업로드 (폐쇄망 환경)

### 1.1 Velero CLI 설치

```bash
tar -xvf velero-v1.18.0-linux-amd64.tar.gz
sudo mv velero-v1.18.0-linux-amd64/velero /usr/local/bin/
velero version --client-only
```

### 1.2 Harbor에 이미지 업로드

```bash
./images/upload_images_to_harbor_v3-lite.sh
```

## 2단계: 설치 실행

```bash
./scripts/install.sh
```

스크립트를 실행하면 아래 항목을 대화형으로 입력합니다.

### 이미지 소스 선택

```sh
이미지 소스를 선택하세요:
  1) Harbor 레지스트리 사용  ← 권장
  2) 로컬 tar 직접 import
```

Harbor 선택 시 레지스트리 주소와 프로젝트명을 입력합니다.

```sh
Harbor 레지스트리 주소 (예: 192.168.1.10:30002): 
Harbor 프로젝트 (예: library, oss): 
```

### 스토리지 타입 선택

MinIO 데이터 볼륨을 어디에 저장할지 선택합니다.

```sh
MinIO 스토리지 타입을 선택하세요:
  1) HostPath  — 로컬 노드 디렉토리 (단일 노드 환경 권장)
  2) NAS/NFS   — 네트워크 공유 스토리지
```

- **HostPath**: 노드의 로컬 디렉토리를 사용합니다. 기본 경로는 `/data/minio`이며 변경 가능합니다.
- **NFS**: NFS 서버 주소와 공유 경로를 입력합니다. 사전에 NFS 서버에서 해당 경로를 export해야 합니다.

입력한 설정은 **`install.conf`에 자동 저장**되어 다음 업그레이드 시 재사용됩니다.

## 3단계: 설치 확인 및 웹 접속

```bash
# Pod 및 백업 저장소 상태 확인 (Available 확인 필수)
kubectl get pods -n velero
velero backup-location get
```

MinIO 웹 콘솔은 아래 주소로 접속합니다.

- **주소**: `http://minio-velero.devops.internal`
- **계정/비밀번호**: `minioadmin` / `minioadmin`

## 4단계: 업그레이드 / 재설치 / 초기화

이미 설치된 상태에서 `install.sh`를 다시 실행하면 아래 메뉴가 나타납니다.

```sh
동작을 선택하세요:
  1) 업그레이드   — 저장된 설정 유지, Helm upgrade --install
  2) 재설치       — 설정 재입력, MinIO 데이터 삭제 여부 선택
  3) 초기화(리셋) — 모든 리소스 + 데이터 + install.conf 완전 삭제 후 종료
  4) 취소
```

| 선택 | 동작 | PVC/PV | install.conf |
| :--- | :--- | :--- | :--- |
| 업그레이드 | Deployment 이미지 갱신 + Helm upgrade | 유지 | 유지 |
| 재설치 | 기존 제거 후 전체 재설치 | 선택 삭제 | 재작성 |
| 초기화 | 모든 리소스 제거 후 종료 | 삭제 | 삭제 |

> 업그레이드 시 PV/PVC는 변경하지 않으므로 기존 백업 데이터가 보존됩니다.

## 5단계: 백업 및 복구 테스트

### 5.1 백업 실행

```bash
# 전체 백업
velero backup create cluster-full-backup --include-namespaces '*'

# 특정 네임스페이스 백업
velero backup create monitoring-backup --include-namespaces monitoring

# 백업 목록 확인
velero backup get
```

### 5.2 복구 실행

```bash
# 전체 복구
velero restore create --from-backup cluster-full-backup

# 특정 네임스페이스만 복구
velero restore create --from-backup monitoring-backup --include-namespaces monitoring

# 복구 상태 확인
velero restore get
velero restore describe <복구명>
```

## 6단계: 삭제

```bash
./scripts/uninstall.sh
```

삭제 시 MinIO 백업 데이터(PVC/PV) 및 `install.conf` 보존 여부를 각각 확인합니다.

> 실제 호스트/NFS 볼륨의 파일은 스크립트가 삭제하지 않습니다. 필요 시 수동으로 제거하세요.

## install.conf 참고

`install.conf`는 `install.sh` 실행 시 자동 생성/갱신됩니다. 직접 편집도 가능합니다.

```bash
IMAGE_SOURCE="harbor"
HARBOR_REGISTRY="192.168.1.10:30002"
HARBOR_PROJECT="oss"
STORAGE_TYPE="hostpath"         # hostpath | nfs
HOSTPATH_DIR="/data/minio"
NFS_SERVER=""
NFS_PATH=""
STORAGE_SIZE="50Gi"
INSTALLED_VERSION="v1.18.0"
```

### install.conf가 있을 때의 동작

| 상황 | 동작 |
| :--- | :--- |
| install.conf 있음 + 미설치 상태 | 저장된 설정으로 **프롬프트 없이 자동 설치** |
| install.conf 있음 + 설치된 상태 | 업그레이드/재설치/초기화 메뉴 표시 |
| install.conf 없음 | 모든 설정을 대화형으로 입력 |

새 노드에 동일한 구성을 배포할 때 `install.conf`를 미리 복사해두면 무인 설치가 가능합니다.
