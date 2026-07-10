# 🚀 Redis Stream (HA) 폐쇄망 설치 가이드 (v8.6.2-official)

공식 Redis 이미지를 기반으로 3-Node Master-Replica 복제본 및 3-Node Sentinel HA를 구축하고, Redis Stream을 폐쇄망 환경에 설치하는 가이드입니다.

---

## 0. 오프라인 설치 자산 준비 (인터넷 환경)

폐쇄망에 반입할 YAML 매니페스트와 컨테이너 이미지(.tar)가 `manifests/` 및 `images/` 디렉토리에 없는 경우, **인터넷이 연결된 외부 PC(리눅스)**에서 아래 스크립트를 실행하여 자산을 다운로드해야 합니다.

> **주의**: 이 작업은 폐쇄망 내부가 아닌, 외부망에서 사전에 수행되어야 합니다. (Docker 또는 containerd(`ctr`), `helm` CLI 설치 필수)

```bash
# 컴포넌트 루트 디렉토리에서 스크립트 실행 권한 부여 및 자산 다운로드
chmod +x ./scripts/download_assets_offline.sh
sudo ./scripts/download_assets_offline.sh
```

스크립트 실행이 완료되면 `images/` 디렉토리에 릴리즈와 동기화된 컨테이너 이미지 `.tar` 파일이 생성됩니다. 전체 프로젝트 폴더를 압축하여 폐쇄망 내부로 반입하십시오.

---

## 1. 사전 준비 (폐쇄망 환경)

환경에 따라 두 가지 방식 중 하나를 선택하여 이미지를 로드합니다.

### 방식 A: Harbor 레지스트리 사용 (권장)

Harbor가 구축되어 있다면 업로드 스크립트를 실행합니다:

```bash
chmod +x images/upload_images_to_harbor_v3-lite.sh
sudo ./images/upload_images_to_harbor_v3-lite.sh
```

실행 시 대화형으로 다음을 입력합니다:

| 항목 | 예시 |
| :--- | :--- |
| 실행 모드 | `2` (Harbor 업로드) |
| Harbor 레지스트리 주소 | `192.168.1.10:30002` 또는 `harbor.example.com` |
| Harbor 프로젝트 | `library` 또는 `oss` 등 |
| Harbor 비밀번호 | (입력) |

### 방식 B: 로컬 tar 직접 import

업로드 스크립트에서 모드 `1` (로컬 이미지 로드 전용)을 선택하여 실행하거나, `./scripts/install.sh` 실행 시 이미지 소스를 `2`로 선택하면 자동으로 containerd `k8s.io` 네임스페이스에 이미지를 import 합니다.

---

## 2. 대화형 설치 실행

모든 작업은 컴포넌트 루트 디렉토리(`redis-stream-8.6.2-official/`)에서 실행합니다.

```bash
chmod +x scripts/install.sh
./scripts/install.sh
```

### 주요 입력 정보 및 처리 방식

* **이미지 소스**:
  * `1` (Harbor) 또는 `2` (로컬 tar 직접 import)
* **설정 동기화**:
  * 입력된 설정은 가변 인프라 설정 전용 파일인 `install.conf` 와 `values-infra.yaml` 에 저장되어 재배포 및 업그레이드 시 멱등성을 보장합니다.
  * **보안 준수 사항**: 보안을 위해 비밀번호(`REDIS_PASSWORD`)는 `install.conf` 와 `values-infra.yaml` 에 평문으로 절대 저장하지 않습니다.
* **비밀번호 복구 및 입력**:
  * `Upgrade` 시 기존에 구축된 Secret(`redis-secret`)에서 패스워드를 복구하여 사용합니다.
  * 복구에 실패한 경우에만 대화식 비밀번호 입력 프롬프트가 표시됩니다.
* **표준 수명주기**:
  * 기존 설치나 `install.conf` 감지 시 표준 메뉴(`1) Upgrade`, `2) Reinstall`, `3) Reset`, `4) Cancel`) 분기를 제공합니다.

### 볼륨 사전 작업

* **HostPath 선택 시 (해당 노드에서 직접 실행)**:
  ```bash
  sudo mkdir -p /data/redis-official/{node-0,node-1,node-2}
  sudo chmod 777 /data/redis-official/{node-0,node-1,node-2}
  ```
* **NFS 선택 시 (NFS 서버에서 직접 실행)**:
  ```bash
  sudo mkdir -p /nfs/redis-official/{node-0,node-1,node-2}
  sudo chmod 777 /nfs/redis-official/{node-0,node-1,node-2}
  ```

---

## 3. 설치 확인 및 상태 점검

```bash
# 전체 Pod 상태
kubectl get pods -n redis-stream-official

# Replication 복제 상태 확인
kubectl exec -it redis-node-0 -n redis-stream-official -- \
    redis-cli -a <password> --no-auth-warning INFO replication

# Sentinel 마스터 상태 확인
kubectl exec -it redis-sentinel-0 -n redis-stream-official -- \
    redis-cli -p 26379 --no-auth-warning SENTINEL masters
```

---

## 4. 장애 복구 (Failover) 테스트

```bash
# Master Pod 강제 종료
kubectl delete pod redis-node-0 -n redis-stream-official

# Sentinel이 새 master 선출하는지 확인 (약 5~10초 후)
kubectl exec -it redis-sentinel-0 -n redis-stream-official -- \
    redis-cli -p 26379 --no-auth-warning SENTINEL get-master-addr-by-name mymaster
```

---

## 5. 수동 설치 및 업그레이드 가이드 (Manual Setup)

자동화 스크립트 장애 대처용 수동 반영 가이드라인입니다.

1. **PV 매니페스트 `__NAMESPACE__` 치환**:
   * PV 매니페스트 내 `claimRef.namespace` 에 선언된 `__NAMESPACE__` 치환자를 배포할 대상 네임스페이스명으로 치환해야 볼륨 바인딩(Pending) 실패 결함을 방지할 수 있습니다.
   ```bash
   # 예시: HostPath PV 매니페스트의 네임스페이스 치환 및 생성
   sed -e "s|__NODE_NAME__|worker-node1|g" \
       -e "s|__BASE_PATH__|/data/redis-official|g" \
       -e "s|__STORAGE_SIZE__|10Gi|g" \
       -e "s|__NAMESPACE__|redis-stream-official|g" \
       manifests/10-pv-hostpath.yaml | kubectl apply -f -
   ```

2. **Helm 인프라 설정 분리 적용**:
   * 비밀번호 주입 및 이미지 경로 적용을 위해 `values-infra.yaml` 을 작성합니다.
   ```yaml
   global:
     imageRegistry: "192.168.1.10:30002"
   image:
     repository: "library/redis"
   storage:
     type: "hostpath"
     size: "10Gi"
   ```
   * 작성된 인프라 파일과 패스워드를 헬름 명령을 통해 주입 배포합니다.
   ```bash
   helm upgrade --install redis-stream-official charts/redis-sentinel \
       --namespace redis-stream-official \
       -f values.yaml \
       -f values-infra.yaml \
       --set redis.password="your-secure-password" \
       --wait
   ```

---

## 6. 서비스 삭제 및 초기화

### 일반 삭제 (데이터 및 가변 설정 보존)

```bash
# 릴리즈만 언인스톨하며 PVC/PV, 설정 파일은 안전하게 보존합니다.
sudo ./scripts/uninstall.sh
```

### 완전 초기화 (데이터 및 네임스페이스, 설정 파일 완전 제거)

```bash
# 2차 정밀 y/N 프롬프트를 통해 영구 데이터 볼륨 및 Namespace, 설정을 영구 제거합니다.
sudo ./scripts/uninstall.sh --reset
```
