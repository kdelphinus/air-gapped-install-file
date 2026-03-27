# redis-stream-7.2-official 검증 및 수정 보고서

작성일: 2026-03-27

## 1. 개요

`redis-stream-7.2-official` (공식 Redis 이미지 + 자체 Helm Chart 기반 Sentinel HA) 및
관련 Spring Boot 예제(`redis-stream-7.2/examples`)에 대해 정적 분석 및 Live 검증을
수행하였고, 발견된 문제를 모두 수정하였습니다.

---

## 2. 검증 범위

| 항목 | 방법 |
| :--- | :--- |
| Helm Chart 렌더링 | `helm lint`, `helm template` |
| 스크립트 문법 | `bash -n` (install.sh, test-stream.sh, uninstall.sh) |
| PV 매니페스트 | `kubectl apply --dry-run=client` (HostPath, NFS) |
| Live 배포 | k3s 단일 노드 클러스터 직접 배포 |
| 기능 테스트 | Stream XADD/XLEN/XRANGE, Consumer Group, Sentinel Failover, 데이터 영속성 |

---

## 3. 발견 및 수정 내역

### 3.1 Critical — 폐쇄망 위반

| # | 파일 | 문제 | 수정 |
| :- | :--- | :--- | :--- |
| C1 | `redis-stream-7.2/examples/spring-boot-gradle/gradle/wrapper/gradle-wrapper.properties` | `distributionUrl`이 외부 인터넷(`services.gradle.org`) 참조 → 폐쇄망에서 `./gradlew` 실패 | Nexus 플레이스홀더 URL로 변경, `validateDistributionUrl=false` |

### 3.2 Major — 기능 오류

| # | 파일 | 문제 | 수정 |
| :- | :--- | :--- | :--- |
| M1 | `scripts/install.sh:101` | 단계 번호 오류 (1→2→**4**, 3 누락) | "4." → "3." |
| M2 | `scripts/install.sh:121-122` | 출력 서비스 주소에 `${RELEASE_NAME}` 사용 → fullnameOverride 무시 | `redis.${NAMESPACE}.svc` / `redis-sentinel.${NAMESPACE}.svc` 로 수정 |
| M3 | `scripts/test-stream.sh:28-29` | `<NODE_IP>` 리터럴 플레이스홀더 → 그대로 입력 시 이미지 pull 실패 | REGISTRY_IP 직접 입력 필수화 |
| M4 | `scripts/test-stream.sh:33-38` | `--rm -i ... &` 패턴 → `-i`(stdin)와 `&`(백그라운드)가 상충, `--rm` 동작 불안정 | `--rm -i` 제거, `kubectl wait --for=condition=Ready` 로 교체 |
| M5 | `redis-stream-7.2/examples/*/application.yml` | Sentinel 주소가 Bitnami 배포(`redis-stream.redis-stream.svc:26379`)를 가리킴 → official 배포 연결 불가 | `application-official.yml` 프로파일 신규 추가 (`redis-sentinel.redis-stream-official.svc:26379`) |

### 3.3 Major — Live 배포 후 발견

| # | 파일 | 문제 | 수정 |
| :- | :--- | :--- | :--- |
| M6 | `charts/redis-sentinel/templates/configmap-sentinel.yaml` | `sentinel resolve-hostnames yes` 누락 → Sentinel init이 FQDN으로 master 등록 시 Redis 7.2가 startup 단계에서 hostname resolve 실패 → CrashLoopBackOff | `sentinel resolve-hostnames yes` / `sentinel announce-hostnames yes` 추가 |

### 3.4 Minor — 잠재적 문제

| # | 파일 | 문제 | 수정 |
| :- | :--- | :--- | :--- |
| m1 | `scripts/uninstall.sh:35-39` | PVC 이름 하드코딩 (`redis-data-redis-node-{0..2}`) → `fullnameOverride` 변경 시 불일치 | `kubectl get pvc | grep "^redis-data-"` 동적 탐색으로 변경 |
| m2 | `values.yaml` | `hostpath.nodeName` 등 4개 필드가 Helm 템플릿에서 미사용임에도 문서화 없어 혼란 유발 | 각 필드에 "Helm 미사용, install.sh sed 전용" 주석 추가 |
| m3 | `values.yaml` | `maxmemory` 미설정 → Redis가 노드 전체 메모리를 사용 가능, OOM 위험 | `maxmemory: "1536mb"` 기본값 추가 (limits 2Gi의 75%) |
| m4 | `charts/redis-sentinel/templates/configmap-redis.yaml` | `maxmemory` 값을 redis.conf에 반영하는 템플릿 로직 없음 | `{{- if .Values.redis.config.maxmemory }}` 조건부 렌더링 추가 |
| m5 | `redis-stream-7.2/examples/spring-boot-gradle/build.gradle` | `mavenCentral()` → 폐쇄망에서 빌드 불가 | Nexus 플레이스홀더 URL로 변경 |
| m6 | `redis-stream-7.2/examples/spring-boot/pom.xml` | Maven 저장소 설정 없음 (주석만 존재) | `<repositories>` / `<pluginRepositories>` Nexus 플레이스홀더 추가 |
| m7 | `redis-stream-7.2/examples/*/config/RedisStreamConfig.java` | `StreamMessageListenerContainer<String, ?>` 와일드카드 타입 → Consumer 주입 타입(`MapRecord<String,String,String>`)과 불일치, 런타임 unchecked cast 위험 | 명시적 타입 `MapRecord<String, String, String>` 으로 수정 (두 예제 모두) |

### 3.5 Discord 플러그인 버그 (부수 발견)

| # | 파일 | 문제 | 수정 |
| :- | :--- | :--- | :--- |
| D1 | `~/.claude/plugins/cache/claude-plugins-official/discord/0.0.4/server.ts` | DM 채널이 gateway reconnect 후 캐시에서 `recipients` 없이 복원될 때 `recipientId = undefined` → `allowFrom.includes(undefined) = false` → reply 실패 | `recipientId` 없으면 REST API force-fetch 후 재체크 |

---

## 4. Live 검증 결과

### 4.1 정적 검증

| 항목 | 결과 |
| :--- | :--- |
| `helm lint` | PASS (경고 0, 실패 0) |
| `helm template` | PASS (전체 리소스 정상 렌더링) |
| `bash -n` (3개 스크립트) | PASS |
| PV dry-run (HostPath/NFS) | PASS |

### 4.2 Live 기능 검증

| 항목 | 결과 |
| :--- | :--- |
| redis-node 3개 Running | PASS |
| redis-sentinel 3개 Running | PASS |
| ClusterIP PING (redis, redis-sentinel) | PASS |
| Stream XADD / XLEN / XRANGE | PASS |
| Consumer Group XREADGROUP | PASS |
| Sentinel Failover (master 삭제 → 새 master 선출) | PASS (20초 이내) |
| Failover 후 Stream 데이터 영속성 | PASS (메시지 4건 보존) |

---

## 5. 수정 파일 목록

### redis-stream-7.2-official

| 파일 | 변경 내용 |
| :--- | :--- |
| `scripts/install.sh` | 단계 번호 수정, 서비스 주소 출력 수정 |
| `scripts/test-stream.sh` | 플레이스홀더 제거, Pod 생성 패턴 수정 |
| `scripts/uninstall.sh` | PVC 동적 탐색으로 변경 |
| `values.yaml` | `maxmemory` 추가, 미사용 필드 주석 명확화 |
| `charts/redis-sentinel/templates/configmap-redis.yaml` | `maxmemory` 조건부 렌더링 추가 |
| `charts/redis-sentinel/templates/configmap-sentinel.yaml` | `resolve-hostnames yes` / `announce-hostnames yes` 추가 |

### redis-stream-7.2/examples

| 파일 | 변경 내용 |
| :--- | :--- |
| `spring-boot-gradle/gradle/wrapper/gradle-wrapper.properties` | distributionUrl → Nexus 플레이스홀더 |
| `spring-boot-gradle/build.gradle` | `mavenCentral()` → Nexus 플레이스홀더 |
| `spring-boot-gradle/src/main/resources/application-official.yml` | 신규: official 배포용 Sentinel 주소 |
| `spring-boot-gradle/src/main/java/.../RedisStreamConfig.java` | 와일드카드 타입 → MapRecord 명시 타입 |
| `spring-boot/src/main/resources/application-official.yml` | 신규: official 배포용 Sentinel 주소 |
| `spring-boot/src/main/java/.../RedisStreamConfig.java` | 와일드카드 타입 → MapRecord 명시 타입 |
| `spring-boot/pom.xml` | Nexus Maven 저장소 추가 |
