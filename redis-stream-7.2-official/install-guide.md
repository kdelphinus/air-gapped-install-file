# Redis Stream 7.2 공식 이미지 — Helm Chart 설치 가이드

## 1. 사전 준비

### 이미지 반입

인터넷 연결된 환경에서 스크립트로 이미지를 저장합니다:

```bash
bash scripts/save_images.sh
```

생성된 `docker.io_library_redis_7.2.tar` 파일을 `images/` 디렉토리에 배치합니다.

### 이미지 배포 방식 선택

환경에 따라 두 가지 방식 중 하나를 선택합니다.

#### 방식 A — Harbor 레지스트리 사용 (권장)

Harbor가 구축되어 있다면 업로드 스크립트를 실행합니다:

```bash
cd redis-stream-7.2-official
./images/upload_images_to_harbor_v3-lite.sh
```

실행 시 대화형으로 다음을 입력합니다:

| 항목 | 예시 |
| :--- | :--- |
| 실행 모드 | `2` (Harbor 업로드) |
| Harbor 레지스트리 주소 | `192.168.1.10:30002` 또는 `harbor.example.com` |
| Harbor 프로젝트 | `library` 또는 `oss` 등 |
| Harbor 비밀번호 | (입력) |

> `HARBOR_REGISTRY`, `HARBOR_PROJECT`, `HARBOR_USER`, `HARBOR_PASSWORD` 환경변수를
> 사전에 설정하면 대화형 입력을 건너뜁니다.

#### 방식 B — Harbor 없음 (로컬 tar import)

업로드 스크립트에서 모드 `1` (로컬 이미지 로드 전용)을 선택하거나,
`install.sh` 실행 중 이미지 소스를 `2`로 선택하면 자동으로 `ctr import`합니다.

## 2. 설치

```bash
./scripts/install.sh
```

스크립트가 대화형으로 다음을 안내합니다:

1. **이미지 소스 선택**
   - `1` — Harbor 레지스트리 사용 (레지스트리 주소, 프로젝트 입력)
   - `2` — 로컬 tar import (`./images/*.tar` → containerd `k8s.io` 네임스페이스)
1. **Redis 비밀번호** 입력
1. **Storage Type** 선택: `hostpath` 또는 `nfs`
1. (hostpath) 노드 선택 및 데이터 경로 입력
1. (nfs) NFS 서버 IP 및 경로 입력

### HostPath 사전 작업

hostpath 선택 시, **해당 노드에서** 미리 디렉토리를 생성해야 합니다:

```bash
# 노드에서 직접 실행
sudo mkdir -p /data/redis-official/{node-0,node-1,node-2}
sudo chmod 777 /data/redis-official/{node-0,node-1,node-2}
```

스크립트가 Enter 대기 프롬프트를 표시할 때 위 작업을 완료한 뒤 진행합니다.

### NFS 사전 작업

```bash
# NFS 서버에서 실행
sudo mkdir -p /nfs/redis-official/{node-0,node-1,node-2}
sudo chmod 777 /nfs/redis-official/{node-0,node-1,node-2}
```

### PV 재사용 안내

기존 PV(`redis-official-node-{0,1,2}-pv`)가 이미 존재하는 경우:

- **동일 경로**: 재사용 여부를 Y/n으로 선택합니다.
- **다른 경로**: PV 경로는 생성 후 변경 불가(Immutable)입니다. 기존 PV를 삭제하고 재생성할지 확인합니다.
  - 기존 데이터는 호스트 디렉토리에 그대로 보존됩니다.

### StorageClass 주의 사항

이 Chart는 PVC에 `storageClassName: ""`을 사용합니다.
`""` 설정 시 **storageClassName이 명시적으로 비어 있는 PV**에만 바인딩됩니다.

정적 HostPath PV를 사용할 경우 PV의 `storageClassName`도 `""`(생략 또는 빈 값)이어야 합니다.
StorageClass가 있는 환경에서 동적 프로비저닝을 원한다면 `values.yaml`에서
`storage.storageClassName`을 해당 클래스명으로 오버라이드하세요.

## 3. 설치 확인

```bash
kubectl get pods -n redis-stream-official
```

예상 결과:

```text
redis-node-0       2/2   Running   0   2m
redis-node-1       2/2   Running   0   2m
redis-node-2       2/2   Running   0   2m
redis-sentinel-0   1/1   Running   0   2m
redis-sentinel-1   1/1   Running   0   2m
redis-sentinel-2   1/1   Running   0   2m
```

Replication 상태 확인:

```bash
kubectl exec -it redis-node-0 -n redis-stream-official -- \
    redis-cli -a <password> --no-auth-warning INFO replication
```

Sentinel 상태 확인:

```bash
kubectl exec -it redis-sentinel-0 -n redis-stream-official -- \
    redis-cli -p 26379 --no-auth-warning SENTINEL masters
```

## 4. 테스트

```bash
./scripts/test-stream.sh
```

## 5. Failover 테스트

```bash
# Master Pod 강제 종료
kubectl delete pod redis-node-0 -n redis-stream-official

# Sentinel이 새 master 선출 확인 (약 5~10초 후)
kubectl exec -it redis-sentinel-0 -n redis-stream-official -- \
    redis-cli -p 26379 --no-auth-warning SENTINEL get-master-addr-by-name mymaster
```

## 6. 삭제

```bash
./scripts/uninstall.sh
```

PV는 `Retain` policy로 데이터가 보존됩니다.

## 7. 초기화 동작 원리

### 초기 부팅

1. `redis-node-0` → init container 실행 → Sentinel 없음 감지 → **master 모드**로 시작
1. `redis-node-1`, `redis-node-2` → init container → Sentinel 없음 → `replicaof redis-node-0.redis-headless` 설정 → **replica 모드**
1. `redis-sentinel-0/1/2` → init container → `redis-node-0`을 master로 설정 → Sentinel 시작

### Failover 후 재시작

1. Pod 재시작 시 init container가 `redis-sentinel-{0,1,2}`에 쿼리
1. 현재 master IP를 확인하여 자동으로 역할 결정
1. 원래 master 노드도 재시작 후 replica로 올바르게 설정됨

> **Sentinel 설정 비영속성**: `sentinel-data` 볼륨은 `emptyDir`입니다.
> Sentinel Pod 재시작 시 init container가 매번 config를 재생성하므로 정상 동작합니다.
> Sentinel 설정 파일을 영속화할 필요는 없습니다.

## 8. 주요 차이점 (vs Bitnami 커스텀 빌드 방식)

| 항목 | 공식 이미지 방식 (Helm) | Bitnami 커스텀 빌드 |
| :--- | :--- | :--- |
| 이미지 크기 | ~130MB | ~400MB (bitnami rootfs 포함) |
| Bitnami 의존성 | 없음 | bitnami rootfs 필요 |
| 설정 방식 | init container 스크립트 | Bitnami 부트스트랩 스크립트 |
| Helm 필요 | 예 (자체 개발 Chart) | 예 (Bitnami Chart) |
| 운영 복잡도 | 낮음 (Helm 통합) | 낮음 (Helm 관리) |
| Failover 강건성 | 양호 (sentinel 쿼리 기반) | 높음 (Bitnami 검증된 로직) |

## 9. 관련 문서

| 문서 | 내용 |
| :--- | :--- |
| [DEVELOPER-GUIDE.md](./DEVELOPER-GUIDE.md) | Spring Boot 연결 설정, Producer/Consumer 구현, at-least-once 보장, 폐쇄망 빌드 설정 |
| [KAFKA-REPLACEMENT-GUIDE.md](./KAFKA-REPLACEMENT-GUIDE.md) | Kafka → Redis Stream 마이그레이션 가이드 |
| [REPORT.md](./REPORT.md) | 검증 및 수정 이력 |
