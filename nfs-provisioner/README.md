# NFS Provisioner 폐쇄망 설치 가이드

이 디렉토리는 폐쇄망(Air-gapped) 환경의 Kubernetes 클러스터에 NFS Provisioner를 구축하기 위한 스크립트와 매니페스트를 포함하고 있습니다.

## 디렉토리 구조
- `manifests/`: Kubernetes 배포용 YAML 파일
- `scripts/ubuntu/`: Ubuntu용 준비 및 설치 스크립트
- `scripts/rhel_rocky/`: RHEL, Rocky Linux, CentOS용 준비 및 설치 스크립트

---

## 1. [외부망] 준비 단계

**인터넷이 가능한 환경**에서 OS에 맞는 준비 스크립트를 실행하세요.
이 스크립트는 다음 작업을 자동으로 수행합니다:
1. NFS 관련 OS 패키지 다운로드 (`nfs-packages/` 폴더 생성)
2. Docker가 없으면 자동 설치 (이미지 다운로드용)
3. NFS Provisioner 컨테이너 이미지 다운로드 및 저장 (`nfs-provisioner.tar` 생성)

> **RHEL/Rocky 사용자 주의사항:** 외부망(다운로드하는 곳)과 내부망(설치하는 곳)의 **OS 메이저 버전**을 맞춰주세요. (예: Rocky 9에서 다운로드 -> RHEL 9에 설치)

```bash
# Ubuntu의 경우
chmod +x scripts/ubuntu/download_nfs_offline.sh
./scripts/ubuntu/download_nfs_offline.sh

# RHEL / Rocky Linux / CentOS의 경우
chmod +x scripts/rhel_rocky/download_nfs_offline.sh
./scripts/rhel_rocky/download_nfs_offline.sh
```

**결과물:**
- `nfs-packages/` (폴더)
- `nfs-provisioner.tar` (파일)

위 두 가지를 폐쇄망 내부로 반입하세요.

---

## 2. [폐쇄망] 설치 단계

### 2-1. OS 패키지 설치 (NFS Server/Client)
모든 워커 노드와 NFS 서버 예정 노드에서 실행합니다.

```bash
# Ubuntu의 경우 (nfs-packages 폴더가 있는 위치에서)
chmod +x scripts/ubuntu/install_nfs_offline.sh
./scripts/ubuntu/install_nfs_offline.sh

# RHEL / Rocky Linux / CentOS의 경우
chmod +x scripts/rhel_rocky/install_nfs_offline.sh
./scripts/rhel_rocky/install_nfs_offline.sh
```

### 2-2. 컨테이너 이미지 로드
`scripts/load_image.sh` 스크립트를 사용하면 **Containerd(ctr)** 또는 **Docker** 환경을 자동으로 감지하여 이미지를 로드합니다.

```bash
chmod +x scripts/load_image.sh
./scripts/load_image.sh
```

**수동으로 실행할 경우 (Containerd):**
Kubernetes에서 사용하는 Containerd는 기본적으로 `k8s.io` 네임스페이스를 사용합니다. 따라서 `-n k8s.io` 옵션이 필수입니다.
```bash
# 이미지 로드
sudo ctr -n k8s.io images import nfs-provisioner.tar

# (선택) 내부 레지스트리로 푸시할 경우
# 태그 변경
sudo ctr -n k8s.io images tag registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2 <내부-레지스트리>/nfs-subdir-external-provisioner:v4.0.2
# 푸시
sudo ctr -n k8s.io images push <내부-레지스트리>/nfs-subdir-external-provisioner:v4.0.2 --plain-http
```

**수동으로 실행할 경우 (Docker):**
```bash
docker load < nfs-provisioner.tar
```

### 2-3. 매니페스트 수정 및 배포
`manifests/nfs-provisioner.yaml` 파일을 열어 다음 항목을 환경에 맞게 수정하세요.
- `image`: 내부 레지스트리 주소로 변경
- `NFS_SERVER`: NFS 서버 IP (예: 192.168.1.100)
- `NFS_PATH`: 공유 디렉토리 경로 (예: /data/nfs-share)

수정 후 배포:
```bash
kubectl apply -f manifests/nfs-provisioner.yaml
```