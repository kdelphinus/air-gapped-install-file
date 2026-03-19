# 💾 Velero v1.14.1 (Backup & Recovery)

K8s 클러스터의 리소스 정의서(YAML) 및 영구 볼륨(PVC) 데이터를 백업하고 복구하는 재해 복구(DR) 도구입니다.

## 📦 구성 요소

| 경로 | 설명 |
| :--- | :--- |
| `charts/` | Velero Helm 차트 |
| `manifests/` | BackupStorageLocation 및 VolumeSnapshotClass 설정 |
| `images/` | Velero, Node-agent, AWS 플러그인 이미지 |
| `scripts/` | Velero CLI 바이너리 설치 및 초기화 스크립트 |

## 🛠️ 주요 설정 (변수화)

### 1. Registry (Harbor)
- `values.yaml` 내 `image.repository` 및 플러그인 경로.

### 2. Backup Target
- **MinIO**: 폐쇄망에서 S3 API를 제공하는 가장 보편적인 방법입니다.
- **NFS**: MinIO 없이 NFS를 직접 백엔드로 사용할 수도 있습니다. (Restic/Kopia 활용)

### 3. CLI Binary
- Velero는 `kubectl`처럼 전용 CLI 바이너리가 필요합니다. (`scripts/` 폴더에 반입 필요)

## 💡 운영 팁

- **Full Backup**: `velero backup create <name> --all-namespaces` 명령으로 클러스터 전체를 백업할 수 있습니다.
- **Partial Restore**: 특정 네임스페이스만 골라서 복구하는 것도 가능합니다.
