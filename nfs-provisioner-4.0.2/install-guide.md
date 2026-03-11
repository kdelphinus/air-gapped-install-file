# NFS Provisioner v4.0.2 오프라인 설치 가이드

폐쇄망 환경의 Kubernetes 클러스터에 NFS 동적 스토리지 프로비저닝을 구성하는 절차를 안내합니다.

## 전제 조건

- Kubernetes 클러스터 구성 완료
- `kubectl` CLI 사용 가능
- NFS 서버로 사용할 노드 또는 외부 NAS 준비

## Phase 1: 외부망에서 자원 준비

인터넷이 연결된 환경에서 필요한 OS 패키지와 컨테이너 이미지를 다운로드합니다.

```bash
# Ubuntu의 경우
chmod +x scripts/ubuntu/download_nfs_offline.sh
./scripts/ubuntu/download_nfs_offline.sh

# RHEL / Rocky Linux의 경우
chmod +x scripts/rhel_rocky/download_nfs_offline.sh
./scripts/rhel_rocky/download_nfs_offline.sh
```

생성 결과물인 `nfs-packages/` 폴더와 `nfs-provisioner.tar` 파일을 폐쇄망으로 반입합니다.

## Phase 2: OS 패키지 설치 (NFS 클라이언트)

모든 워커 노드에서 실행하여 `mount.nfs` 기능을 활성화합니다.

```bash
# Ubuntu의 경우
chmod +x scripts/ubuntu/install_nfs_offline.sh
./scripts/ubuntu/install_nfs_offline.sh

# RHEL / Rocky Linux의 경우
chmod +x scripts/rhel_rocky/install_nfs_offline.sh
./scripts/rhel_rocky/install_nfs_offline.sh
```

## Phase 3: 컨테이너 이미지 로드

```bash
chmod +x scripts/load_image.sh
./scripts/load_image.sh
```

대상 이미지: `registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2`

## Phase 4: 매니페스트 수정 및 배포

`manifests/nfs-provisioner.yaml` 파일에서 아래 항목을 환경에 맞게 수정합니다.

| 항목 | 설명 | 예시 |
| :--- | :--- | :--- |
| `image` | 내부 레지스트리 이미지 주소 | `<NODE_IP>:30002/library/nfs-subdir-external-provisioner:v4.0.2` |
| `NFS_SERVER` | NFS 서버 IP | `192.168.1.100` |
| `NFS_PATH` | NFS 공유 디렉토리 경로 | `/data/nfs-share` |

수정 후 배포합니다.

```bash
kubectl apply -f manifests/nfs-provisioner.yaml
```

## Phase 5: 설치 확인

```bash
kubectl get pods -n nfs-provisioner
kubectl get storageclass
```

## 운영 참고 사항

- NFS 서버 노드는 고정 IP를 사용하고 `nodeSelector` 로 특정 노드에 고정 배포를 권장합니다.
- 노드 간 **TCP/UDP 2049(NFS), 111(RPC)** 포트가 열려 있는지 확인합니다.
- `StorageClass` 의 `archiveOnDelete: "false"` 설정은 PVC 삭제 시 데이터를 삭제합니다. 데이터 보호가 필요하면 `true` 로 변경하세요.
