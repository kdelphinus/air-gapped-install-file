# 📂 NFS Provisioner v4.0.2 폐쇄망 설치 가이드

이 디렉토리는 폐쇄망(Air-gapped) 환경의 Kubernetes 클러스터에서 외부 도움 없이 **클러스터 내부 자원만으로 NAS 기능을 구현**하기 위한 설치 패키지 및 가이드를 제공합니다. `nfs-subdir-external-provisioner`를 기반으로 합니다.

---

## 📁 디렉토리 구조

- `manifests/`: Kubernetes 배포용 YAML (RBAC, Deployment, StorageClass)
- `scripts/`: OS 패키지 및 이미지 관리용 스크립트
  - `ubuntu/`: Ubuntu용 준비/설치 스크립트
  - `rhel_rocky/`: RHEL, Rocky Linux용 준비/설치 스크립트
  - `load_image.sh`: 컨테이너 런타임별 이미지 로드 도구
- `nfs-packages/`: (생성 예정) 오프라인 설치용 OS 패키지 보관함

---

## 1️⃣ [외부망] 준비 단계 (인터넷 가능 환경)

폐쇄망 내부로 반입할 자원(이미지, 패키지)을 준비합니다.

### 수행 작업

1. NFS 관련 OS 패키지 다운로드 (`nfs-packages/` 폴더 생성)
2. 컨테이너 이미지 다운로드 및 저장 (`nfs-provisioner.tar` 생성)
   - **대상 이미지:** `registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2`

### 실행 명령어

```bash
# Ubuntu의 경우
chmod +x scripts/ubuntu/download_nfs_offline.sh
./scripts/ubuntu/download_nfs_offline.sh

# RHEL / Rocky Linux / CentOS의 경우
chmod +x scripts/rhel_rocky/download_nfs_offline.sh
./scripts/rhel_rocky/download_nfs_offline.sh
```

**결과물:** `nfs-packages/` 폴더와 `nfs-provisioner.tar` 파일을 폐쇄망 내부로 반입하세요.

---

## 2️⃣ [폐쇄망] 설치 단계 (클러스터 내부 환경)

### 2-1. OS 패키지 설치 (NFS Server/Client)

모든 워커 노드와 NFS 서버 예정 노드에서 실행하여 `mount.nfs` 기능을 활성화합니다.

```bash
# Ubuntu의 경우
chmod +x scripts/ubuntu/install_nfs_offline.sh
./scripts/ubuntu/install_nfs_offline.sh

# RHEL / Rocky Linux / CentOS의 경우
chmod +x scripts/rhel_rocky/install_nfs_offline.sh
./scripts/rhel_rocky/install_nfs_offline.sh
```

### 2-2. 컨테이너 이미지 로드

환경에 맞는 런타임(Containerd, Docker)에 이미지를 주입합니다.

```bash
chmod +x scripts/load_image.sh
./scripts/load_image.sh
```

### 2-3. 매니페스트 수정 및 배포

`manifests/nfs-provisioner.yaml` 파일을 환경에 맞게 수정합니다. 이 파일은 **RBAC 권한, Provisioner 배포, StorageClass 설정**을 모두 포함하고 있습니다.

- **image**: 내부 레지스트리 주소로 변경
- **NFS_SERVER**: NFS 서버 IP (예: 192.168.1.100)
- **NFS_PATH**: 공유 디렉토리 경로 (예: /data/nfs-share)

**배포 실행:**

```bash
kubectl apply -f manifests/nfs-provisioner.yaml
```

---

## 💡 운영 및 기술 가이드

### 기술적 분석 및 트레이드오프

| 항목 | 직접 구축 방식 (In-cluster) | 외부 지원 방식 (Managed NAS) |
| :--- | :--- | :--- |
| **자율성** | 인프라 팀 협조 없이 즉시 구축 가능 | 인프라 팀의 정책에 종속됨 |
| **운영 부담** | NFS 서버 소프트웨어 관리를 직접 수행 | 저장소 안정성은 인프라 팀이 책임짐 |
| **성능** | 워커 노드의 네트워크/디스크 성능 공유 | 전용 스토리지 네트워크 사용 가능 |

### 🛠 전문가의 조언 (Tips)

1. **NFS 서버 노드 고정**: NFS 서버 역할을 하는 노드는 고정 IP를 사용해야 하며, `nodeSelector`를 사용하여 특정 노드에 고정 배포하는 것을 권장합니다.
2. **방화벽 설정**: 노드 간 **TCP/UDP 2049(NFS), 111(RPC)** 포트가 열려 있는지 확인하십시오.
3. **데이터 보존**: `StorageClass`의 `archiveOnDelete: "false"` 설정은 PVC 삭제 시 데이터를 삭제합니다. 데이터 보호가 중요하다면 `true`로 변경을 고려하세요.

---

### ❓ FAQ 및 심화 질문

- **Q: NFS 서버 노드가 물리적으로 고장나면 어떻게 되나요?**
  - A: 해당 노드의 디스크를 복구하거나 백업된 데이터를 새 노드에 마운트한 뒤 Provisioner 설정을 업데이트해야 합니다. 고가용성이 중요하다면 전용 스토리지 솔루션 도입을 검토하세요.
- **Q: 기존 hostPath 데이터를 옮기려면?**
  - A: 데이터 권한(UID/GID)을 유지하며 `cp -p` 혹은 `rsync`를 사용하여 NFS 마운트 경로로 복사해야 합니다.
