# NFS Provisioner v4.0.2 설치 가이드

본 문서는 **Rocky Linux 9.6 / K8s v1.33.7** 환경에서 NetApp NFS v4.1을 백엔드로 연동하는 절차를 설명합니다.

---

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



## 📋 사전 준비 사항

### 1. (온라인인 경우) 헬름 차트 다운로드
설치 스크립트 실행 전, 공식 차트를 아래 명령어로 확보해야 합니다.
```bash
cd nfs-provisioner-4.0.2/charts
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm pull nfs-subdir-external-provisioner/nfs-subdir-external-provisioner --version 4.0.18 --untar
```

### 2. OS 패키지 설치 (전체 워커 노드)
NFS 마운트를 위해 모든 노드에 관련 패키지가 설치되어 있어야 합니다.
- **Rocky 9**: `sudo dnf install -y nfs-utils`
- **Ubuntu 24**: `sudo apt install -y nfs-common`

---

## 🛠️ 단계별 설치 프로세스

### Step 1: 설치 스크립트 실행
```bash
cd scripts/
chmod +x install.sh
./install.sh
```

### Step 2: 정보 입력
- **NFS 서버 IP**: NetApp Vserver의 LIF IP 입력.
- **NFS 공유 경로**: `/k8s/data` 등 실제 Export된 경로 입력.

---

## 💡 NetApp NFS v4.1 최적화 내용 (Rationale)

본 패키지의 `values.yaml`에는 NetApp 벤더 권장 최적화 옵션이 기본 적용되어 있습니다.

- **`vers=4.1`**: v3에서 발생하는 파일 잠금(Locking) 문제를 해결하고 고가용성을 확보합니다.
- **`proto=tcp`**: 전송 안정성을 보장합니다.
- **`rsize/wsize=1048576`**: 1MB 단위 대용량 입출력을 통해 성능을 극대화합니다.
- **`hard`**: 네트워크 일시 단절 시 데이터 유실 방지를 위해 마운트를 유지합니다.
- **`noresvport`**: 클라이언트 재접속 시 포트 제약 없이 즉시 연결하도록 설정합니다.

---

## 📁 다중 StorageClass 운영 (Multi-SC)

기본적으로 `nfs-app` StorageClass가 생성됩니다. 추가로 백업이나 테스트용이 필요한 경우 아래 명령어를 참고하십시오.

1. `manifests/additional-sc.yaml` 파일에서 원하는 이름과 설정을 확인합니다.
2. 설치 스크립트 실행 시 자동으로 함께 적용됩니다.
3. 수동 적용 시: `kubectl apply -f manifests/additional-sc.yaml`

| SC 명칭 | 용도 | 삭제 시 데이터 정책 |
| :--- | :--- | :--- |
| **nfs-app** | 일반 애플리케이션 | Archive (보관) |
| **nfs-backup** | DB 백업 등 | Retain (완전 유지) |
| **nfs-test** | 임시 테스트 | Delete (즉시 삭제) |

---

## ✅ 설치 검증
```bash
# 1. StorageClass 상태 확인
kubectl get sc

# 2. 프로비저너 포드 상태 확인
kubectl get pods -n kube-system -l app=nfs-client-provisioner

# 3. 테스트 PVC 생성 및 바인딩 확인
kubectl apply -f - <<EOF
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: nfs-test-pvc
spec:
  storageClassName: nfs-app
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
EOF
kubectl get pvc nfs-test-pvc
```
