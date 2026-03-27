# Redis Stream 7.2 공식 이미지 — Helm Chart 설치 가이드

## 1. 사전 준비

### 이미지 반입

인터넷 연결된 환경에서 스크립트로 이미지를 저장합니다:

```bash
bash scripts/save_images.sh
```

생성된 `docker.io_library_redis_7.2.tar` 파일을 `images/` 디렉토리에 배치합니다.

### Harbor 업로드

```bash
cd redis-stream-7.2-official
./images/upload_images_to_harbor_v3-lite.sh
```

Harbor에 `library/redis:7.2` 이미지가 등록됩니다.

### values.yaml 설정 수정

`values.yaml` 의 `global.imageRegistry` 값을 실제 Harbor 주소로 변경합니다:

```yaml
global:
  imageRegistry: "192.168.1.100:30002"  # 실제 Harbor 노드 IP로 변경
```

## 2. 설치

```bash
./scripts/install.sh
```

설치 시 다음을 입력합니다:

1. Redis 비밀번호
2. Storage Type: `hostpath` 또는 `nfs`
3. (hostpath) 노드 선택 및 데이터 경로
4. (nfs) NFS 서버 IP 및 경로

### hostpath 사전 작업

hostpath 선택 시, **해당 노드에서** 미리 디렉토리를 생성해야 합니다:

```bash
# 노드에서 직접 실행
sudo mkdir -p /data/redis-official/{node-0,node-1,node-2}
sudo chmod 777 /data/redis-official/{node-0,node-1,node-2}
```

### NFS 사전 작업

```bash
# NFS 서버에서 실행
sudo mkdir -p /nfs/redis-official/{node-0,node-1,node-2}
sudo chmod 777 /nfs/redis-official/{node-0,node-1,node-2}
```

## 3. 설치 확인

```bash
kubectl get pods -n redis-stream-official
# 예상 결과:
# redis-node-0    1/1  Running
# redis-node-1    1/1  Running
# redis-node-2    1/1  Running
# redis-sentinel-0      1/1  Running
# redis-sentinel-1      1/1  Running
# redis-sentinel-2      1/1  Running

# Replication 상태 확인
kubectl exec -it redis-node-0 -n redis-stream-official -- \
    redis-cli -a <password> --no-auth-warning INFO replication

# Sentinel 상태 확인
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

# Sentinel이 새 master 선출 확인 (약 5-10초 후)
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
2. `redis-node-1`, `redis-node-2` → init container → Sentinel 없음 → `replicaof redis-node-0.redis-headless` 설정 → **replica 모드**
3. `redis-sentinel-0/1/2` → init container → `redis-node-0` 을 master로 설정 → Sentinel 시작

### Failover 후 재시작

1. Pod 재시작 시 init container가 `redis-sentinel-{0,1,2}` 에 쿼리
2. 현재 master IP를 확인하여 자동으로 역할 결정
3. 원래 master 노드도 재시작 후 replica로 올바르게 설정됨

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
| [REPORT.md](./REPORT.md) | Gemini 검증 및 수정 이력 |
