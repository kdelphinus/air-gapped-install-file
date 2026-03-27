# Redis Stream 서비스 개발자 가이드

작성일: 2026-03-27

---

## 목차

1. [인프라 구조 개요](#1-인프라-구조-개요)
2. [Redis Stream vs Pub/Sub — 혼동 주의](#2-redis-stream-vs-pubsub--혼동-주의)
3. [Spring Boot 연결 설정](#3-spring-boot-연결-설정)
4. [핵심 개념](#4-핵심-개념)
5. [Producer 구현](#5-producer-구현)
6. [Consumer 구현](#6-consumer-구현)
7. [Consumer 두절 시 동작](#7-consumer-두절-시-동작)
8. [데이터 용량·시간 한도 설정](#8-데이터-용량시간-한도-설정)
9. [At-least-once 보장](#9-at-least-once-보장)
10. [폐쇄망 빌드 설정](#10-폐쇄망-빌드-설정)
11. [운영 체크리스트](#11-운영-체크리스트)

---

## 1. 인프라 구조 개요

```
Namespace: redis-stream-official

[Producer App]  ──XADD──►  [Redis Master (redis-node-0)]
                                 │
                            replication
                                 │
                        ┌────────┴────────┐
                [Replica (redis-node-1)]  [Replica (redis-node-2)]
                        └────────┬────────┘
                                 │
[Consumer App]  ◄─XREADGROUP─────┘
                (Sentinel이 master 선출 시 자동 전환)

[Sentinel-0] [Sentinel-1] [Sentinel-2]
 → quorum=2, down-after=5s, failover-timeout=60s
```

| 항목 | 값 |
| :--- | :--- |
| Redis 서비스 (master 진입점) | `redis.redis-stream-official.svc.cluster.local:6379` |
| Sentinel 서비스 | `redis-sentinel.redis-stream-official.svc.cluster.local:26379` |
| master set 이름 | `mymaster` |
| 네임스페이스 | `redis-stream-official` |

> Spring Boot는 Sentinel 주소만 지정하면 Sentinel이 현재 master 주소를 자동으로 알려줍니다.
> `redis` ClusterIP 서비스로 직접 접속하면 Failover 시 연결이 끊깁니다.
> **반드시 Sentinel 주소로 연결하십시오.**

---

## 2. Redis Stream vs Pub/Sub — 혼동 주의

Redis에는 메시지 전달 방식이 두 가지 있습니다. **이 인프라는 Stream 전용**입니다.

| 항목 | Redis Stream (`XADD`) | Redis Pub/Sub (`PUBLISH`) |
| :--- | :--- | :--- |
| **메시지 저장** | Redis에 영구 저장 (AOF) | 저장 안 함 (휘발) |
| **Consumer 두절 시** | 메시지 보존 → 복구 후 재전달 | **유실** (구독 중이 아니면 사라짐) |
| **재처리** | PEL + XCLAIM으로 재처리 가능 | 불가 |
| **여러 Consumer** | Consumer Group으로 분산 처리 | 연결된 모든 구독자에게 동시 전달 |
| **Spring Data Redis API** | `opsForStream()`, `StreamListener` | `opsForPubSub()`, `MessageListener` |

> 코드 작성 시 `opsForPubSub()` 또는 `MessageListener`를 절대 사용하지 마십시오.
> Stream 관련 API는 `opsForStream()` 및 `StreamMessageListenerContainer`를 사용합니다.

---

## 3. Spring Boot 연결 설정

### 3.1 의존성

**Maven (pom.xml)**

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-redis</artifactId>
</dependency>
```

**Gradle (build.gradle)**

```groovy
implementation 'org.springframework.boot:spring-boot-starter-data-redis'
```

### 3.2 application.yml 설정

`src/main/resources/application-official.yml` 프로파일을 사용합니다.

```yaml
spring:
  data:
    redis:
      sentinel:
        master: mymaster
        nodes: redis-sentinel.redis-stream-official.svc:26379
      password: "${REDIS_PASSWORD}"
      timeout: 5000ms
```

애플리케이션 실행 시 프로파일을 지정합니다.

```bash
# 환경변수로 비밀번호 주입 필수
export REDIS_PASSWORD=your_password

# 프로파일 지정 실행
java -jar app.jar --spring.profiles.active=official

# 또는 환경변수로 지정
export SPRING_PROFILES_ACTIVE=official
java -jar app.jar
```

Kubernetes 환경에서는 Secret으로 비밀번호를 관리합니다.

```yaml
# deployment.yaml 일부
env:
  - name: REDIS_PASSWORD
    valueFrom:
      secretKeyRef:
        name: redis-secret
        key: password
  - name: SPRING_PROFILES_ACTIVE
    value: official
```

### 3.3 RedisStreamConfig Bean 등록

```java
@Configuration
public class RedisStreamConfig {

    @Bean
    public StringRedisTemplate stringRedisTemplate(RedisConnectionFactory connectionFactory) {
        return new StringRedisTemplate(connectionFactory);
    }

    @Bean
    public StreamMessageListenerContainer<String, MapRecord<String, String, String>>
            streamMessageListenerContainer(RedisConnectionFactory connectionFactory) {

        StreamMessageListenerContainerOptions<String, MapRecord<String, String, String>> options =
                StreamMessageListenerContainerOptions.builder()
                        .pollTimeout(Duration.ofSeconds(1))
                        .build();
        return StreamMessageListenerContainer.create(connectionFactory, options);
    }
}
```

**주의**: `StreamMessageListenerContainer<String, ?>` 와일드카드 타입 사용 금지.
`MapRecord<String, String, String>`으로 명시해야 런타임 `ClassCastException`을 방지할 수 있습니다.

---

## 4. 핵심 개념

### 4.1 Stream Key

Redis에서 Stream을 식별하는 키입니다. 애플리케이션 간 통일하십시오.

```
STREAM_KEY = "mystream"
```

### 4.2 Consumer Group

같은 Consumer Group에 속한 여러 Consumer 인스턴스가 메시지를 **분산**해서 처리합니다.
(같은 메시지가 두 Consumer에게 동시에 전달되지 않습니다.)

```
GROUP_NAME  = "mygroup"   # 동일 그룹의 Consumer들이 메시지를 나눠 처리
CONSUMER_NAME = "consumer1"  # 각 인스턴스마다 유일한 이름 권장
```

여러 Pod가 있다면 Consumer 이름에 Pod 이름/IP 등을 포함시키십시오.

```java
// Pod 이름을 Consumer 이름으로 사용
String consumerName = System.getenv().getOrDefault("POD_NAME", "consumer-default");
```

### 4.3 PEL (Pending Entry List)

Consumer가 메시지를 수신했으나 `XACK`하지 않은 메시지 목록입니다.
Consumer가 장애로 사라져도 PEL에 메시지가 남아 있어 zombie recovery를 통해 재처리됩니다.

### 4.4 메시지 ID 형식

```
<millisecondsTime>-<sequenceNumber>
예: 1710000000000-0
```

메시지 ID는 자동 생성됩니다. XADD 시 `*`를 사용하면 됩니다.

---

## 5. Producer 구현

### 5.1 기본 패턴

```java
@Service
public class RedisStreamProducer {

    private final StringRedisTemplate redisTemplate;
    private final ConcurrentLinkedQueue<Map<String, String>> localBuffer = new ConcurrentLinkedQueue<>();

    private static final String STREAM_KEY    = "mystream";
    private static final long   MAXLEN        = 100_000L;   // 스트림 최대 보관 메시지 수
    private static final int    WAIT_REPLICAS = 1;           // 동기 복제 최소 replica 수
    private static final long   WAIT_TIMEOUT_MS = 5_000L;

    public void sendMessage(String key, String value) {
        try {
            // 1. XADD + approximate trim으로 메시지 추가 및 크기 제한
            Map<Object, Object> body = new LinkedHashMap<>();
            body.put(key, value);
            MapRecord<String, Object, Object> record = MapRecord.create(STREAM_KEY, body);
            RecordId recordId = redisTemplate.opsForStream().add(record);
            redisTemplate.opsForStream().trim(STREAM_KEY, MAXLEN);   // XLEN > MAXLEN 초과분 삭제

            // 2. WAIT — replica 복제 확인 (at-least-once 보장)
            Long replicas = redisTemplate.execute((RedisCallback<Long>) conn -> {
                Object result = conn.execute("WAIT",
                    String.valueOf(WAIT_REPLICAS).getBytes(StandardCharsets.UTF_8),
                    String.valueOf(WAIT_TIMEOUT_MS).getBytes(StandardCharsets.UTF_8));
                return result instanceof Long ? (Long) result : 0L;
            });

            if (replicas == null || replicas < WAIT_REPLICAS) {
                // 복제 미확인 — 로컬 버퍼로 이동 후 flushBuffer()에서 재전송
                localBuffer.offer(Collections.singletonMap(key, value));
            }
        } catch (Exception e) {
            // 연결 실패 등 — 로컬 버퍼에 저장
            localBuffer.offer(Collections.singletonMap(key, value));
        }
    }

    @Scheduled(fixedDelay = 5_000)
    public void flushBuffer() {
        Map<String, String> msg;
        while ((msg = localBuffer.poll()) != null) {
            sendMessage(msg.keySet().iterator().next(), msg.values().iterator().next());
        }
    }
}
```

### 5.2 MAXLEN 튜닝 가이드

```
MAXLEN = (예상 최대 처리 지연 시간[초]) × (초당 메시지 수) × (안전 마진 2배)

예) 처리 지연 최대 10분, 초당 100건:
    MAXLEN = 600 × 100 × 2 = 120,000 → 넉넉하게 100,000 설정
```

`values.yaml`의 `maxmemory: "1536mb"` 와 `maxmemory-policy: noeviction` 설정에 따라
Redis는 메모리가 가득 찰 경우 쓰기 오류를 반환합니다. MAXLEN으로 스트림 크기를 먼저 통제하십시오.

> `stream-node-max-bytes`와 `stream-node-max-entries`는 **스트림 전체 크기 제한이 아닙니다.**
> 내부 radix-tree 노드 크기 튜닝 파라미터이며 메모리/성능 최적화 용도입니다.
> 스트림 크기 제한은 반드시 **`XADD MAXLEN`** 또는 `XTRIM`으로 직접 제어하십시오.

---

## 6. Consumer 구현

### 6.1 기본 패턴

```java
@Service
public class RedisStreamConsumer
        implements StreamListener<String, MapRecord<String, String, String>> {

    private final StreamMessageListenerContainer<String, MapRecord<String, String, String>> container;
    private final StringRedisTemplate redisTemplate;

    private static final String STREAM_KEY     = "mystream";
    private static final String GROUP_NAME     = "mygroup";
    private static final String CONSUMER_NAME  = "consumer1";
    private static final Duration ZOMBIE_THRESHOLD = Duration.ofSeconds(30);

    @PostConstruct
    public void init() {
        // Consumer Group 생성 (이미 존재하면 무시 — 멱등성)
        try {
            redisTemplate.opsForStream().createGroup(STREAM_KEY, GROUP_NAME);
        } catch (Exception ignored) {}

        // ReadOffset.lastConsumed() == ">" : 아직 다른 Consumer에게 전달되지 않은 신규 메시지만 수신
        container.receive(
            Consumer.from(GROUP_NAME, CONSUMER_NAME),
            StreamOffset.create(STREAM_KEY, ReadOffset.lastConsumed()),
            this
        );
        container.start();
    }

    @Override
    public void onMessage(MapRecord<String, String, String> message) {
        try {
            // 비즈니스 로직
            processMessage(message.getValue());

            // 처리 성공 시에만 XACK — 실패 시 PEL에 남아 재처리 대상이 됨
            redisTemplate.opsForStream().acknowledge(GROUP_NAME, message);
        } catch (Exception e) {
            // ACK하지 않음 → zombie recovery에서 재처리
            log.error("처리 실패, PEL에 유지: {}", message.getId(), e);
        }
    }
}
```

### 6.2 중요: ACK 타이밍

```
메시지 수신 (XREADGROUP)
       │
       ▼
  비즈니스 로직 실행
       │
  ┌────┴────┐
성공        실패
  │          │
XACK 전송  ACK 하지 않음
  │          │
PEL 제거    PEL 유지 → zombie recovery에서 재처리
```

**절대로 처리 전에 ACK를 먼저 보내지 마십시오.**
처리 전 ACK는 처리 실패 시 메시지가 영구 유실됩니다.

---

## 7. Consumer 두절 시 동작

### 7.1 흐름 요약

```
Consumer 장애 발생
       │
       ▼
메시지는 PEL에 보존 (Redis에서 자동 삭제하지 않음)
       │
       ▼
ZOMBIE_THRESHOLD(30초) 경과 후 zombie recovery 실행
       │
       ▼
XPENDING으로 오래된 pending 메시지 목록 조회
       │
       ▼
XCLAIM으로 살아있는 Consumer가 소유권 획득
       │
       ▼
재처리 → 성공 시 XACK
```

Consumer가 두절되어도 **데이터는 Redis PEL에 보존**됩니다.
복구된 Consumer(또는 다른 살아있는 Consumer)가 zombie recovery 로직을 통해 재처리합니다.

> Kafka와의 차이: Kafka는 Group Coordinator가 파티션 리밸런싱을 자동으로 수행합니다.
> Redis Streams는 앱 레벨에서 XPENDING + XCLAIM을 직접 구현해야 합니다.
> 예제 코드의 `autoClaimZombieMessages()` 메서드가 이 역할을 담당합니다.

### 7.2 zombie recovery 구현

```java
@Scheduled(fixedDelay = 30_000)  // 30초마다 실행
public void autoClaimZombieMessages() {
    // PEL이 비어있으면 즉시 반환
    PendingMessagesSummary summary =
        redisTemplate.opsForStream().pending(STREAM_KEY, GROUP_NAME);
    if (summary == null || summary.getTotalPendingMessages() == 0) return;

    // ZOMBIE_THRESHOLD 이상 대기 중인 메시지 조회 (최대 100개)
    PendingMessages pending = redisTemplate.opsForStream()
        .pending(STREAM_KEY, GROUP_NAME, Range.unbounded(), 100L);

    for (PendingMessage msg : pending) {
        if (msg.getElapsedTimeSinceLastDelivery().compareTo(ZOMBIE_THRESHOLD) < 0) continue;

        // XCLAIM으로 소유권 획득 후 재처리
        List<MapRecord<String, Object, Object>> claimed =
            redisTemplate.opsForStream().claim(
                STREAM_KEY, GROUP_NAME, CONSUMER_NAME, ZOMBIE_THRESHOLD, msg.getId());

        if (claimed != null) {
            claimed.forEach(record -> {
                // Object → String 타입 변환 후 onMessage() 재호출
                MapRecord<String, String, String> typed = convertToStringRecord(record);
                onMessage(typed);
            });
        }
    }
}
```

### 7.3 Consumer 복구 후 순서 보장

Redis Stream은 메시지 ID가 단조 증가하므로 **메시지 순서는 항상 보장**됩니다.
단, zombie recovery로 재처리되는 메시지는 신규 메시지보다 늦게 처리될 수 있습니다.

엄격한 순서 처리가 필요한 경우:
- Consumer를 단일 인스턴스로 운영하거나
- 메시지 본문에 시퀀스 번호를 포함시켜 애플리케이션 레벨에서 정렬하십시오.

---

## 8. 데이터 용량·시간 한도 설정

### 8.1 설정 레이어 구조

```
Layer 1 (Redis 서버 메모리 제한)  ← values.yaml의 maxmemory
Layer 2 (스트림 크기 직접 제한)   ← XADD MAXLEN / XTRIM (Producer 코드)
Layer 3 (메시지 만료)             ← 없음 (TTL 미지원, 수동 XTRIM 필요)
```

### 8.2 Redis 서버 메모리 설정 (values.yaml)

```yaml
redis:
  config:
    maxmemory: "1536mb"          # 컨테이너 limits.memory(2Gi)의 약 75%
    maxmemoryPolicy: noeviction  # 메모리 초과 시 쓰기 오류 반환 (데이터 자동 삭제 안 함)
```

`noeviction` 정책을 사용하므로 **메모리가 가득 차면 XADD가 실패**합니다.
이를 방지하려면 MAXLEN으로 스트림 크기를 반드시 제한하십시오.

다른 정책을 선택하고 싶은 경우:

| 정책 | 동작 | Stream에 적합 여부 |
| :--- | :--- | :--- |
| `noeviction` | 쓰기 오류 반환 | **권장** (명시적 오류로 대응 가능) |
| `allkeys-lru` | 전체 키에서 LRU 삭제 | 비권장 (Stream 키 자체가 삭제될 수 있음) |
| `volatile-lru` | TTL 있는 키에서 LRU 삭제 | 제한적 허용 (Stream 키에 TTL 미설정 시 보호됨) |

### 8.3 스트림 크기 제한 (Producer 코드)

```java
// MAXLEN 초과분 approximate trim (~ 기호: 성능 최적화, 약간의 초과 허용)
redisTemplate.opsForStream().add(record);
redisTemplate.opsForStream().trim(STREAM_KEY, MAXLEN);

// 또는 XADD 시 인라인 MAXLEN (Spring Data Redis 지원 여부 확인 필요)
// cli: XADD mystream MAXLEN ~ 100000 * field value
```

### 8.4 시간 기반 만료 (TTL 미지원 대안)

Redis Stream은 **메시지 단위 TTL을 지원하지 않습니다.**
시간 기반 만료가 필요한 경우 별도 스케줄러를 구현하십시오.

```java
// 예: 24시간 이상된 메시지 삭제 (Producer 또는 별도 스케줄러)
@Scheduled(cron = "0 0 * * * *")   // 매 시간 실행
public void trimOldMessages() {
    // 24시간 전 timestamp를 메시지 ID 범위로 변환
    long cutoffMs = System.currentTimeMillis() - Duration.ofHours(24).toMillis();
    String cutoffId = cutoffMs + "-0";

    // cutoffId 이전 메시지 삭제
    redisTemplate.opsForStream().trim(STREAM_KEY,
        org.springframework.data.redis.connection.stream.StreamRange.leftUnbounded()
            .to(cutoffId), 0);
}
```

> 주의: 아직 처리되지 않은 메시지(PEL에 있는 메시지)가 삭제될 수 있습니다.
> PEL 조회 후 pending 메시지 ID와 겹치지 않는 범위만 삭제하는 것을 권장합니다.

### 8.5 현재 스트림 상태 확인

```bash
# kubectl exec으로 redis-cli 접속 후
redis-cli -a $REDIS_PASSWORD

# 스트림 총 메시지 수
XLEN mystream

# Consumer Group 정보 (pending 메시지 수 포함)
XINFO GROUPS mystream

# PEL 상세 조회 (pending 메시지 목록)
XPENDING mystream mygroup - + 10

# 메모리 사용량 확인
INFO memory
```

---

## 9. At-least-once 보장

### 9.1 Producer at-least-once

```
XADD → WAIT(replica=1, timeout=5s)
         │
    복제 확인 성공 → 완료
         │
    복제 미확인 또는 오류
         │
    로컬 버퍼에 저장 → 5초 후 재전송 시도
```

`WAIT numreplicas timeout` 명령은 지정한 수의 replica에 복제가 완료될 때까지 대기합니다.
timeout 내 완료되지 않으면 현재 복제된 replica 수를 반환합니다.

```java
// WAIT 1 5000 : 1개 replica에 5초 이내 복제 확인
Long replicas = redisTemplate.execute((RedisCallback<Long>) conn ->
    conn.execute("WAIT",
        "1".getBytes(StandardCharsets.UTF_8),
        "5000".getBytes(StandardCharsets.UTF_8))
);
if (replicas == null || replicas < 1) {
    // 재전송 필요
}
```

### 9.2 Consumer at-least-once

```
XREADGROUP (메시지 수신, PEL에 추가)
     │
비즈니스 로직 실행
     │
성공: XACK (PEL에서 제거) ← 메시지 완료
     │
실패: ACK 미전송 → PEL 유지 → zombie recovery에서 재처리
```

### 9.3 중복 처리(Idempotency) 고려

at-least-once는 **최소 1회 전달을 보장**하며, 장애 시 **중복 처리가 발생할 수 있습니다.**

비즈니스 로직에 멱등성을 보장하십시오.

```java
@Override
public void onMessage(MapRecord<String, String, String> message) {
    String messageId = message.getId().getValue();

    // DB에 이미 처리된 메시지 ID가 있으면 ACK만 보내고 반환 (중복 처리 방지)
    if (messageRepository.existsByRedisMessageId(messageId)) {
        redisTemplate.opsForStream().acknowledge(GROUP_NAME, message);
        return;
    }

    // 신규 메시지 처리
    processAndSave(message, messageId);
    redisTemplate.opsForStream().acknowledge(GROUP_NAME, message);
}
```

### 9.4 exactly-once는 지원하지 않습니다

Redis Streams는 at-least-once까지만 지원합니다.
exactly-once가 필요하다면 처리 결과와 메시지 ID를 원자적으로 저장하는 외부 트랜잭션(DB)이 필요합니다.

---

## 10. 폐쇄망 빌드 설정

### 10.1 Maven (pom.xml)

```xml
<repositories>
    <repository>
        <id>nexus</id>
        <url>http://<NEXUS_IP>:8081/repository/maven-public/</url>
    </repository>
</repositories>
<pluginRepositories>
    <pluginRepository>
        <id>nexus</id>
        <url>http://<NEXUS_IP>:8081/repository/maven-public/</url>
    </pluginRepository>
</pluginRepositories>
```

`<NEXUS_IP>`를 실제 Nexus 서버 IP로 교체하십시오.

### 10.2 Gradle (build.gradle + gradle-wrapper.properties)

**build.gradle**

```groovy
repositories {
    maven { url "http://<NEXUS_IP>:8081/repository/maven-public/" }
}
```

**gradle/wrapper/gradle-wrapper.properties**

```properties
distributionUrl=http\://<NEXUS_IP>:8081/repository/gradle-distributions/gradle-8.14.4-bin.zip
validateDistributionUrl=false
```

Nexus raw-hosted 저장소에 Gradle 배포판을 업로드한 후 URL을 지정하십시오.

### 10.3 컨테이너 이미지 빌드

```dockerfile
FROM <NODE_IP>:30002/library/eclipse-temurin:21-jdk AS builder
# ...
FROM <NODE_IP>:30002/library/eclipse-temurin:21-jre
```

Harbor 레지스트리(`<NODE_IP>:30002`)에서 base 이미지를 가져옵니다.

---

## 11. 운영 체크리스트

### 배포 전

- [ ] `values.yaml`에 `redis.password` 설정
- [ ] `values.yaml`에 `maxmemory` 설정 (기본값: `1536mb`, limits.memory의 75%)
- [ ] `application-official.yml`에 Sentinel 주소 확인 (`redis-sentinel.redis-stream-official.svc:26379`)
- [ ] Pod 환경변수에 `REDIS_PASSWORD` Secret 주입 설정
- [ ] `SPRING_PROFILES_ACTIVE=official` 환경변수 설정

### Producer 점검

- [ ] `MAXLEN` 값이 예상 처리 지연 × 초당 메시지 수 × 2 이상으로 설정
- [ ] `WAIT` 명령으로 replica 복제 확인 구현
- [ ] 로컬 버퍼 + `@Scheduled` flushBuffer 구현 (연결 실패 시 재전송)

### Consumer 점검

- [ ] `StreamMessageListenerContainer` 타입 파라미터에 와일드카드(`?`) 사용 안 함
- [ ] `onMessage()`에서 처리 성공 시에만 `XACK` 호출
- [ ] `autoClaimZombieMessages()` (`@Scheduled`)로 ZOMBIE_THRESHOLD 초과 메시지 회수
- [ ] Consumer 이름이 Pod 인스턴스마다 고유함 (다중 인스턴스 배포 시)

### 모니터링

```bash
# Sentinel master 확인
redis-cli -h redis-sentinel.redis-stream-official.svc -p 26379 SENTINEL MASTERS

# 스트림 크기 확인
redis-cli -a $REDIS_PASSWORD XLEN mystream

# 미처리(pending) 메시지 확인
redis-cli -a $REDIS_PASSWORD XPENDING mystream mygroup - + 10

# 메모리 사용량
redis-cli -a $REDIS_PASSWORD INFO memory | grep used_memory_human
```

---

*이 가이드는 `redis-stream-7.2-official` v1.0 기준으로 작성되었습니다.*
*변경 사항은 [REPORT.md](./REPORT.md)를 함께 참조하십시오.*
