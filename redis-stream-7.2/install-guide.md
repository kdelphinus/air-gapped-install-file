# Redis Stream 설치 가이드

본 가이드는 폐쇄망(Air-gapped) 환경에서 Redis Stream HA 클러스터를 설치하는 과정을 설명합니다.

## 1. 전제 조건

- Kubernetes 클러스터 접근 권한 (`kubectl` 설정 완료)
- Helm v3 이상
- Local Harbor 레지스트리 (기본 포트: 30002)

## 2. 이미지 업로드

> **주의**: `bitnami/redis-sentinel:7.2.4-debian-12-r7` 이미지는 기본 제공 파일에 포함되어 있지 않을 수 있습니다. 외부에서 해당 이미지를 `docker save`하여 반입한 뒤 `images/` 디렉토리에 위치시켜야 합니다.

```bash
cd redis-stream-7.2/images
./upload_images_to_harbor_v3-lite.sh
```

## 3. 설치 진행

컴포넌트 루트 디렉토리(`redis-stream-7.2/`)에서 다음 스크립트를 실행합니다.

```bash
./scripts/install.sh
```

- 스토리지 타입(`hostpath` 또는 `nfs`)을 선택합니다.
- `hostpath` 선택 시 각 노드에 `/data/redis-stream/*` 디렉토리가 생성됩니다.
- 설정할 Redis 비밀번호를 입력합니다.

## 4. 스트림 테스트 및 At-Least-Once 검증

```bash
./scripts/test-stream.sh
```

해당 스크립트는 다음 사항을 자동으로 검증합니다:

1. `XADD` 시 `MAXLEN`을 지정하여 OOM을 방지하는지 확인
2. `WAIT` 명령어로 동기 복제가 이루어지는지 확인
3. `XPENDING` 상태를 통한 Consumer ACK 처리 대기열 확인

## 5. Spring Boot 연동

`examples/spring-boot` 디렉토리에 제공된 예제 프로젝트를 참고하세요.

### ⚠️ 핵심 주의사항 (Kafka 대비)

1. **MAXLEN을 통한 OOM 방지 (필수)**
   - Redis는 메모리 기반이므로 `XADD` 수행 시 반드시 `MAXLEN` 파라미터를 명시해야 합니다. (예: `XADD mystream MAXLEN ~ 100000 * ...`)
   - 이를 누락하면 스트림이 무한정 커져 OOM이 발생합니다.
2. **Consumer 자동 리밸런싱 부재**
   - Kafka는 Consumer가 죽으면 자동으로 파티션을 재할당하지만, Redis는 이를 스스로 수행하지 않습니다.
   - 따라서 어플리케이션(Spring Boot 등)에서 주기적인 `XAUTOCLAIM`을 통해 처리되지 못한(Zombie) 메시지를 회수해야 합니다.

## 6. 삭제

```bash
./scripts/uninstall.sh
```

- 삭제 시 PV(Persistent Volume)는 `Retain` 정책으로 인해 데이터가 보존됩니다.
